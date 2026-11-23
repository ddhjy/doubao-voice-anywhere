#!/usr/bin/env swift
//
// 生成 App 图标：Resources/AppIcon.icns + AppIcon.icon + Assets.car。
//
// 用法：
//   swift tools/GenerateAppIcon.swift                     # 写回 Resources/ 三件套
//   swift tools/GenerateAppIcon.swift out/AppIcon.icns    # 指定输出目录（三件套跟随）
//   ICON_KEEP_ICONSET=1 swift tools/GenerateAppIcon.swift  # 同时保留 .iconset 便于逐尺寸检查
//   ICON_PREVIEW_DIR=out/preview swift tools/GenerateAppIcon.swift
//                                                         # 另用 Icon Composer 的 ictool 导出六种外观的预览图
//
// 设计是从「这个 App 只做一件事」推出来的：按一下，说话，字落在光标处。
//   - 声音的样子是一排竖条（波形），文字的样子是一根竖条（光标），两者本来就是同一种形状。
//     所以全图只有一族胶囊：三根玻璃声波，接一根朱砂色光标——声波的下一拍就是光标。
//   - 三根声波从左到右由虚到实（三档固定的不透明度）：声音会散，落成字才留得下来。
//   - 高度走 3 : 5 : 4 : 6 的模数，光标最高，它是终点，也是全图唯一的高彩度色。
//   - 不放任何字符和麦克风：快捷键可配置，写死 "fn" 是错的；麦克风和气泡是所有语音 App
//     的公共符号，认不出是谁。
//   - 配色取「丹青」：青只给底，丹（朱砂）只给光标。
//     避开语音类 App 条件反射的蓝紫和豆包本体的品牌色，朱砂同时接住了上一版图标的主色。
//   - 全图只用平涂色，不用渐变：层次靠三档不透明度、边缘高光和投影，不靠颜色过渡。
//
// 双轨输出的原因：
//   - AppIcon.icns（CFBundleIconFile）：macOS 13–15 的标准图标格式。
//   - Assets.car（CFBundleIconName）：macOS 26+ 会把纯 icns 当「旧式图标」缩小垫在
//     白色底板上；要满版显示必须走 Icon Composer 的 .icon → actool 编译。
//     编译需要 Xcode 26 及以上的 actool，本机没有时会告警跳过（icns 兜底仍然可用）。
//     Assets.car 与 icns 一样是入库产物，CI（macos-15 runner）只负责拷贝。
//
// 两条轨道共用同一套构图坐标。液态玻璃（边缘高光、投影、各外观的变体）全部交给
// Icon Composer 的材质参数，图层只提供纯形状的 SVG；icns 没有系统材质可用，
// 用 CoreGraphics 把同样的层次手绘出来。
//
// icns 的每个尺寸都按矢量重画而不是缩放大图：16pt / 32pt 用简化构图（竖条加粗、去掉受光边），
// 128pt 以上用完整构图。这是 Apple 图标的惯例，也是小尺寸不糊的唯一办法。
//

import AppKit
import Foundation
import ImageIO
import SwiftUI

// MARK: - 颜色

/// OKLCH → sRGB。配色按 OKLCH 写，改起来才是「亮度/彩度/色相」三个独立旋钮。
func oklch(_ l: CGFloat, _ c: CGFloat, _ h: CGFloat, alpha: CGFloat = 1) -> NSColor {
    let hr = h * .pi / 180
    let a = c * cos(hr)
    let b = c * sin(hr)

    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b

    let lc = l_ * l_ * l_
    let mc = m_ * m_ * m_
    let sc = s_ * s_ * s_

    let rLinear = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
    let gLinear = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
    let bLinear = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

    func encode(_ x: CGFloat) -> CGFloat {
        let v = max(0, min(1, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    return NSColor(srgbRed: encode(rLinear), green: encode(gLinear), blue: encode(bLinear), alpha: alpha)
}

/// 每个面一个平涂色，没有渐变。所有取值都留在 sRGB 色域内（彩度再高会被裁掉，色相就跑了）。
/// 调色时注意：ictool 导出的 PNG 是 Display P3，用不做色彩管理的看图工具看会偏灰，
/// 照着那个观感加彩度，上屏就过艳了。
enum Palette {
    /// 青：色相取在朱砂的对面（接近互补），明度压到 0.50，白色声波和朱砂光标都立得住；
    /// 彩度不超过 0.08，底色不抢戏。
    static let body = oklch(0.50, 0.080, 210)

    /// 丹：全图唯一的高彩度色，只给光标。红绿色盲视角下与青底退成黄对蓝，仍然分得开。
    static let caret = oklch(0.67, 0.180, 38)

    static let bar = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// 深色外观：底色退成墨青，「青」改由声波自己带着（白色声波配墨底会只剩黑白橙）。
    static let darkBody = oklch(0.23, 0.025, 230)
    static let darkBar = oklch(0.80, 0.080, 185)
}

// MARK: - 构图

/// 坐标一律写在 Icon Composer 的满版 1024 画布上（y 轴向上），.icon 图层直接用；
/// icns 的图标本体只有 824 见方（Apple 的 macOS 图标模板），画的时候整体缩小 824/1024。
struct Layout {
    static let canvas: CGFloat = 1024
    static let bodySide: CGFloat = 824

    /// 声波高度（模数的倍数）与由虚到实的不透明度；光标高 6 个模数。
    static let barUnits: [CGFloat] = [3, 5, 4]
    static let barOpacities: [CGFloat] = [0.55, 0.78, 1]
    static let caretUnits: CGFloat = 6

    let unit: CGFloat
    let barWidth: CGFloat
    let gap: CGFloat
    let caretWidth: CGFloat

    static let full = Layout(unit: 92, barWidth: 128, gap: 56, caretWidth: 52)

    /// 16pt / 32pt 专用：完整构图在 16px 下光标不到 1 像素、间隙只剩半个像素。
    /// 宽度按「16px 图里的整像素」取（声波 2px、间隙和光标各 1px，总宽 10px 居中），
    /// 竖边才能落在像素格上；32px / 64px 是它的整数倍，同样对齐。
    static let compact: Layout = {
        let pixel = canvas / 16 * canvas / bodySide
        return Layout(unit: 106, barWidth: pixel * 2, gap: pixel, caretWidth: pixel)
    }()

    private var totalWidth: CGFloat {
        barWidth * CGFloat(Layout.barUnits.count) + gap * CGFloat(Layout.barUnits.count) + caretWidth
    }

    var bars: [CGRect] {
        let left = Layout.canvas / 2 - totalWidth / 2
        return Layout.barUnits.enumerated().map { index, units in
            CGRect(
                x: left + CGFloat(index) * (barWidth + gap),
                y: Layout.canvas / 2 - units * unit / 2,
                width: barWidth,
                height: units * unit
            )
        }
    }

    var caret: CGRect {
        let height = Layout.caretUnits * unit
        return CGRect(
            x: Layout.canvas / 2 + totalWidth / 2 - caretWidth,
            y: Layout.canvas / 2 - height / 2,
            width: caretWidth,
            height: height
        )
    }
}

// MARK: - 形状

/// Apple 图标那颗「连续圆角」方形。直接取系统自己的曲线（SwiftUI 的 .continuous 圆角），
/// 与按官方模板出图的图标轮廓只差抗锯齿级别的像素。
/// 别自己拿超椭圆去拟合：在角上套 n=5 的超椭圆，四角会明显偏方。
func squircle(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath
}

func capsule(_ rect: CGRect) -> CGPath {
    let radius = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - icns 手绘

func white(_ alpha: CGFloat) -> NSColor {
    Palette.bar.withAlphaComponent(alpha)
}

struct Painter {
    let context: CGContext
    /// 1 个构图单位合多少设备像素。CoreGraphics 的阴影偏移和模糊不跟 CTM 走，要自己乘。
    let unitScale: CGFloat

    /// 只在形状外侧投影。半透明的玻璃条下面不该透出自己的影子；
    /// 也不能「先填实色投影、再盖上填色」，那样浅色边缘的抗锯齿像素会透出一圈深色。
    func shadow(of path: CGPath, drop: CGFloat, blur: CGFloat, alpha: CGFloat) {
        context.saveGState()
        context.addRect(context.boundingBoxOfClipPath)
        context.addPath(path)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: CGSize(width: 0, height: -drop * unitScale),
            blur: blur * unitScale,
            color: NSColor(white: 0, alpha: alpha).cgColor
        )
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    func fill(_ path: CGPath, _ color: NSColor) {
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    /// 贴着形状内侧的一圈受光边：玻璃的厚度感全靠它。
    func rim(_ path: CGPath, width: CGFloat, _ color: NSColor) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.addPath(path)
        context.setLineWidth(width * 2)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
        context.restoreGState()
    }
}

func drawIcon(pointSize: CGFloat, painter: Painter) {
    let detailed = pointSize >= 128

    // 模板尺寸：1024 画布里本体 824 见方、圆角 185.4。
    let bodySide = Layout.bodySide
    let inset = (Layout.canvas - bodySide) / 2
    let body = squircle(
        in: CGRect(x: inset, y: inset, width: bodySide, height: bodySide),
        cornerRadius: 185.4
    )
    painter.shadow(of: body, drop: 10, blur: 22, alpha: 0.20)
    painter.fill(body, Palette.body)
    if detailed {
        painter.rim(body, width: 3, white(0.14))
    }

    let context = painter.context
    let glyphScale = bodySide / Layout.canvas
    context.saveGState()
    context.translateBy(x: Layout.canvas / 2, y: Layout.canvas / 2)
    context.scaleBy(x: glyphScale, y: glyphScale)
    context.translateBy(x: -Layout.canvas / 2, y: -Layout.canvas / 2)
    drawGlyphs(
        layout: detailed ? .full : .compact,
        detailed: detailed,
        painter: Painter(context: context, unitScale: painter.unitScale * glyphScale)
    )
    context.restoreGState()
}

/// 手绘版的液态玻璃：平涂的半透明白 + 内侧一圈受光边 + 外侧柔影，不用渐变。
/// 小尺寸下受光边会糊成灰边，不画；由虚到实的差距也收窄，免得最左一根淡到看不见。
func drawGlyphs(layout: Layout, detailed: Bool, painter: Painter) {
    for (rect, baseOpacity) in zip(layout.bars, Layout.barOpacities) {
        let opacity = detailed ? baseOpacity : 0.35 + 0.65 * baseOpacity
        let path = capsule(rect)
        painter.shadow(of: path, drop: 8, blur: 20, alpha: 0.20 * opacity)
        painter.fill(path, white(opacity))
        if detailed {
            painter.rim(path, width: 3, white(0.5))
        }
    }

    let caret = capsule(layout.caret)
    painter.shadow(of: caret, drop: 8, blur: 18, alpha: 0.26)
    painter.fill(caret, Palette.caret)
    if detailed {
        painter.rim(caret, width: 2.5, white(0.22))
    }
}

// MARK: - 输出

func renderPNG(pixels: Int, pointSize: CGFloat) -> Data {
    // 位图直接建在 sRGB 上：用 calibratedRGB 会把 NSColor(srgbRed:) 的取值再换算一次，
    // 导出的 PNG 又不带 profile，看图工具按 sRGB 解释，颜色就整体偏了。
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: pixels,
              height: pixels,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        fatalError("无法创建 \(pixels)px 位图")
    }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let scale = CGFloat(pixels) / Layout.canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(pointSize: pointSize, painter: Painter(context: context, unitScale: scale))

    guard let image = context.makeImage() else {
        fatalError("无法生成 \(pixels)px 图像")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        fatalError("PNG 编码失败")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("PNG 编码失败")
    }
    return output as Data
}

func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[警告] \(message)\n".utf8))
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputPath = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], relativeTo: repoRoot)
    : repoRoot.appendingPathComponent("Resources/AppIcon.icns")

let keepIconset = ProcessInfo.processInfo.environment["ICON_KEEP_ICONSET"] == "1"
let iconsetURL = keepIconset
    ? outputPath.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
    : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// (点尺寸, 倍率)。@2x 用的是同一套「点尺寸构图」，所以 16pt@2x 与 32pt@1x 虽然
// 都是 32 像素，前者是简化构图放大、后者是 32pt 构图，跟系统图标的做法一致。
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    let suffix = variant.scale == 2 ? "@2x" : ""
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    let data = renderPNG(pixels: pixels, pointSize: CGFloat(variant.points))
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

try? FileManager.default.createDirectory(
    at: outputPath.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let iconutil = try run("/usr/bin/iconutil", ["-c", "icns", iconsetURL.path, "-o", outputPath.path])
guard iconutil.status == 0 else {
    FileHandle.standardError.write(Data("[错误] iconutil 失败：\(iconutil.output)\n".utf8))
    exit(1)
}

if !keepIconset {
    try? FileManager.default.removeItem(at: iconsetURL)
}

print("[信息] 已生成 \(outputPath.path)")

// MARK: - macOS 26 满版图标（AppIcon.icon + Assets.car）

func srgbString(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { fatalError("颜色转换失败") }
    return String(
        format: "extended-srgb:%.5f,%.5f,%.5f,%.5f",
        c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent
    )
}

func hexString(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { fatalError("颜色转换失败") }
    return String(
        format: "#%02x%02x%02x",
        Int((c.redComponent * 255).rounded()),
        Int((c.greenComponent * 255).rounded()),
        Int((c.blueComponent * 255).rounded())
    )
}

/// 图层用 SVG 而不是位图：Icon Composer 的高光是沿形状边缘算的，矢量边缘在任何尺寸下都干净。
/// SVG 的 y 轴向下，与构图坐标相反。
func capsuleSVG(_ rect: CGRect, fill: NSColor) -> String {
    func n(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }
    let size = n(Layout.canvas)
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(size) \(size)">\
    <rect x="\(n(rect.minX))" y="\(n(Layout.canvas - rect.maxY))" width="\(n(rect.width))" height="\(n(rect.height))" \
    rx="\(n(min(rect.width, rect.height) / 2))" fill="\(hexString(fill))"/>\
    </svg>

    """
}

/// 平涂填色。别换成 automatic-gradient：那是 Icon Composer 按单色自动派生的渐变。
func solid(_ color: NSColor) -> [String: Any] {
    ["solid": srgbString(color)]
}

/// JSONSerialization 会把 Double 0.78 写成 0.78000000000000003；走十进制数才能原样落盘。
/// 返回 Any 是有意的：返回 NSNumber 的话，同一个字典字面量里的 true / false 会被一并
/// 推断成 NSNumber，落盘变成 1 / 0，Icon Composer 直接拒读。
func number(_ value: CGFloat) -> Any {
    NSDecimalNumber(string: String(Double(value)))
}

let outputDir = outputPath.deletingLastPathComponent()
let iconPackageURL = outputDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
let assetsDir = iconPackageURL.appendingPathComponent("Assets", isDirectory: true)

try? FileManager.default.removeItem(at: iconPackageURL)
try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

// 每根声波单独一层：「由虚到实」靠的是层不透明度，同一层里做不出三档。
// 深色外观下把白色声波换成玉色。
var barLayers: [[String: Any]] = []
for (index, rect) in Layout.full.bars.enumerated() {
    let name = "bar\(index + 1)"
    try capsuleSVG(rect, fill: Palette.bar)
        .write(to: assetsDir.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)

    var layer: [String: Any] = [
        "name": name,
        "image-name": "\(name).svg",
        "glass": true,
        "fill-specializations": [
            ["appearance": "dark", "value": solid(Palette.darkBar)],
        ],
    ]
    let opacity = Layout.barOpacities[index]
    if opacity < 1 {
        layer["opacity"] = number(opacity)
    }
    barLayers.append(layer)
}

// 光标的颜色写在 SVG 里而不是用图层 fill：这样各外观下它都保持朱砂色，不被系统改写。
try capsuleSVG(Layout.full.caret, fill: Palette.caret)
    .write(to: assetsDir.appendingPathComponent("caret.svg"), atomically: true, encoding: .utf8)

// groups / layers 数组的顺序是「最前的在最前面」，与 Icon Composer 图层面板一致。
// 材质参数是在 Icon Composer 里逐项对比渲染后定下来的：
//   - 全部平涂（solid），半透明必须关：Icon Composer 的半透明自带一道「上实下透」的过渡，
//     开了就等于给每根胶囊加了渐变。三档虚实只靠图层不透明度。
//   - 不开折射（Icon Composer 27 才有）：纯色底上没有东西可折，只会在胶囊里多出一圈淡影。
//   - 玻璃质感留给边缘高光和中性阴影；layer-color 阴影会把朱砂色晕到青底上，发脏。
//   - 根 fill 一旦要给深色外观单独取值，就得整体写成 fill-specializations（默认值是不带
//     appearance 的那一条）；fill 与 fill-specializations 并存时，后者会被静默丢弃。
//     背景用原生填色而不是贴图，着色 / 透明外观才能由系统从它派生。
let iconDocument: [String: Any] = [
    "fill-specializations": [
        ["value": solid(Palette.body)],
        ["appearance": "dark", "value": solid(Palette.darkBody)],
    ],
    "groups": [
        [
            "name": "glyphs",
            "layers": [["name": "caret", "image-name": "caret.svg", "glass": true]] + barLayers.reversed(),
            "shadow": ["kind": "neutral", "opacity": number(0.5)],
            "specular": true,
            "translucency": ["enabled": false, "value": number(0.5)],
        ],
    ],
    "supported-platforms": [
        "circles": ["watchOS"],
        "squares": "shared",
    ],
]
try JSONSerialization.data(withJSONObject: iconDocument, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconPackageURL.appendingPathComponent("icon.json"))
print("[信息] 已生成 \(iconPackageURL.path)")

// actool 编译成 Assets.car。需要 Xcode 26 及以上；失败只告警——icns 兜底仍然可用。
let actoolOut = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-car-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: actoolOut, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: actoolOut) }

do {
    let actool = try run("/usr/bin/xcrun", [
        "actool", iconPackageURL.path,
        "--compile", actoolOut.path,
        "--platform", "macosx",
        "--minimum-deployment-target", "13.0",
        "--app-icon", "AppIcon",
        "--include-all-app-icons",
        "--output-partial-info-plist", actoolOut.appendingPathComponent("partial.plist").path,
    ])
    let compiledCar = actoolOut.appendingPathComponent("Assets.car")
    if actool.status == 0, FileManager.default.fileExists(atPath: compiledCar.path) {
        let carURL = outputDir.appendingPathComponent("Assets.car")
        try? FileManager.default.removeItem(at: carURL)
        try FileManager.default.copyItem(at: compiledCar, to: carURL)
        print("[信息] 已生成 \(carURL.path)")
    } else {
        warn("actool 编译 Assets.car 失败（macOS 26 将退回旧式图标显示）：\n\(actool.output)")
    }
} catch {
    warn("无法执行 actool（需要 Xcode 26 及以上）：\(error)")
}

// MARK: - 预览（可选）

// 调材质参数时不必打开 Icon Composer：ictool 走的是同一套渲染，六种外观一次导出。
if let previewPath = ProcessInfo.processInfo.environment["ICON_PREVIEW_DIR"], !previewPath.isEmpty {
    let previewDir = URL(fileURLWithPath: previewPath, relativeTo: repoRoot)
    do {
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        let developerDir = try run("/usr/bin/xcode-select", ["-p"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ictool = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("../Applications/Icon Composer.app/Contents/Executables/ictool")
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: ictool) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: ictool])
        }
        var exported = 0
        for rendition in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"] {
            let file = previewDir.appendingPathComponent("AppIcon-\(rendition).png")
            try? FileManager.default.removeItem(at: file)
            var arguments = [
                iconPackageURL.path, "--export-image",
                "--output-file", file.path,
                "--platform", "macOS",
                "--rendition", rendition,
                "--width", "1024", "--height", "1024", "--scale", "1",
            ]
            if rendition.hasPrefix("Tinted") {
                arguments += ["--tint-color", "0.58", "--tint-strength", "0.8"]
            }
            let result = try run(ictool, arguments)
            if result.status == 0, FileManager.default.fileExists(atPath: file.path) {
                exported += 1
            } else {
                warn("ictool 导出 \(rendition) 失败：\(result.output)")
            }
        }
        if exported > 0 {
            print("[信息] 已导出 \(exported) 张预览到 \(previewDir.path)")
        }
    } catch {
        warn("无法导出预览（需要 Xcode 自带的 Icon Composer）：\(error)")
    }
}
