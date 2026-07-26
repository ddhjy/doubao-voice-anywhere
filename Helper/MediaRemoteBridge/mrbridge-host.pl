#!/usr/bin/perl
# mrbridge-host.pl — 在 Apple 签名的 perl 进程内加载 mrbridge.dylib 并调用入口。
#
# macOS 15.4+ 只对 Apple 平台二进制返回真实的 Now Playing 信息，
# 所以 MediaRemote 的调用必须发生在 perl 这类系统自带进程内。
# 加载机制参考 ungive/mediaremote-adapter (MIT)。
#
# 用法：/usr/bin/perl mrbridge-host.pl <mrbridge.dylib 路径>
# 命令经环境变量 MRB_COMMAND 传入（status | pause | play），
# 结果由 dylib 直接写到 stdout（单行 JSON），入口内部 exit()，不会返回。

use strict;
use warnings;
use DynaLoader;

my $dylib = shift @ARGV
    or die "usage: mrbridge-host.pl <mrbridge.dylib path>\n";
-f $dylib
    or die "dylib not found: $dylib\n";

my $handle = DynaLoader::dl_load_file($dylib, 0)
    or die "dl_load_file failed: " . (DynaLoader::dl_error() // "unknown") . "\n";

my $symbol = DynaLoader::dl_find_symbol($handle, "mrbridge_entry")
    or die "mrbridge_entry not found: " . (DynaLoader::dl_error() // "unknown") . "\n";

my $entry = DynaLoader::dl_install_xsub("main::mrbridge_entry", $symbol, __FILE__);
$entry->();

die "mrbridge_entry returned unexpectedly\n";
