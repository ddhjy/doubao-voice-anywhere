// mrbridge.m — 在 Apple 签名的 perl 进程内调用 MediaRemote 私有框架的小动态库。
//
// 背景：macOS 15.4 起，mediaremoted 只对 Apple 平台二进制返回真实的
// 「正在播放 (Now Playing)」信息，普通第三方进程会拿到假数据
// （isPlaying=false、pid=0，本机 26.5 实测）。绕行方式是让系统自带的
// /usr/bin/perl（Apple 平台二进制）通过 DynaLoader 加载本库并调用入口，
// MediaRemote 的调用发生在 perl 进程内，身份检查即可通过。
// 机制与 ungive/mediaremote-adapter (MIT) 相同，这里只做本项目需要的精简版。
//
// 协议（提供给 mrbridge-host.pl / MediaPlaybackPauser.swift）：
//   - 命令经环境变量 MRB_COMMAND 传入：status | pause | play
//   - 结果以单行 JSON 写到 stdout：
//       status        -> {"ok":true,"playing":true,"pid":1194}
//       pause / play  -> {"ok":true}
//       任何失败      -> {"ok":false,"error":"..."}
//   - 入口函数完成后直接 exit()，永不返回 perl（因此无需遵守 XSUB 栈约定）。
//
// 编译（见 build.sh）：
//   clang -dynamiclib -fobjc-arc -O2 -framework Foundation -o mrbridge.dylib mrbridge.m

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MediaRemote.framework 私有符号的函数类型（来源：公开逆向头文件，
// nowplaying-cli / mediaremote-adapter 等项目均使用同一组签名）。
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*MRGetPidFn)(dispatch_queue_t queue, void (^handler)(int pid));
typedef Boolean (*MRSendCommandFn)(int command, id userInfo);

// MRMediaRemoteCommand 枚举值（与 nowplaying-cli 一致）。
static const int kMRCommandPlay = 0;
static const int kMRCommandPause = 1;

// 单个异步查询等待回调的上限。Swift 侧另有整个进程级别的超时兜底。
static const int64_t kCallbackTimeoutNs = (int64_t)(1.0 * NSEC_PER_SEC);

// 发送命令后给 XPC 消息留的送达时间：MRMediaRemoteSendCommand 返回并不代表
// 消息已发出，立刻 exit 会丢命令。
static const CFTimeInterval kSendSettleSeconds = 0.15;

__attribute__((noreturn))
static void bail(const char *error) {
    printf("{\"ok\":false,\"error\":\"%s\"}\n", error);
    fflush(stdout);
    exit(1);
}

__attribute__((noreturn))
static void runStatus(void *handle) {
    MRGetIsPlayingFn getIsPlaying =
        (MRGetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPidFn getPid =
        (MRGetPidFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (getIsPlaying == NULL || getPid == NULL) {
        bail("missing status symbols");
    }

    dispatch_queue_t queue = dispatch_queue_create("mrbridge.status", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block Boolean playing = false;
    getIsPlaying(queue, ^(Boolean value) {
        playing = value;
        dispatch_semaphore_signal(semaphore);
    });
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kCallbackTimeoutNs)) != 0) {
        bail("isPlaying callback timeout");
    }

    __block int pid = 0;
    getPid(queue, ^(int value) {
        pid = value;
        dispatch_semaphore_signal(semaphore);
    });
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kCallbackTimeoutNs)) != 0) {
        bail("pid callback timeout");
    }

    printf("{\"ok\":true,\"playing\":%s,\"pid\":%d}\n", playing ? "true" : "false", pid);
    fflush(stdout);
    exit(0);
}

__attribute__((noreturn))
static void runSendCommand(void *handle, int command) {
    MRSendCommandFn sendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
    if (sendCommand == NULL) {
        bail("missing MRMediaRemoteSendCommand");
    }

    Boolean accepted = sendCommand(command, nil);
    // 跑一小段 runloop，让底层 XPC 把命令真正送出去。
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, kSendSettleSeconds, false);

    printf("{\"ok\":%s}\n", accepted ? "true" : "false");
    fflush(stdout);
    exit(accepted ? 0 : 1);
}

// perl 的 dl_install_xsub 会按 XSUB 调用约定传入 1-2 个指针参数
// （threaded perl 下是 (aTHX, cv)）。这里全部忽略，并且从不返回，
// 所以无需处理 perl 栈。
__attribute__((visibility("default")))
void mrbridge_entry(void *unused1, void *unused2) {
    (void)unused1;
    (void)unused2;

    const char *command = getenv("MRB_COMMAND");
    if (command == NULL || command[0] == '\0') {
        bail("MRB_COMMAND not set");
    }

    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    );
    if (handle == NULL) {
        bail("dlopen MediaRemote failed");
    }

    if (strcmp(command, "status") == 0) {
        runStatus(handle);
    }
    if (strcmp(command, "pause") == 0) {
        runSendCommand(handle, kMRCommandPause);
    }
    if (strcmp(command, "play") == 0) {
        runSendCommand(handle, kMRCommandPlay);
    }
    bail("unknown command");
}
