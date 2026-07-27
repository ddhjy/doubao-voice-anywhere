#!/usr/bin/env swift
//
// 生成 App 图标：Resources/AppIcon.icns + AppIcon.icon + Assets.car。
//
// 用法：
//   swift tools/GenerateAppIcon.swift                     # 写回 Resources/ 三件套
//   swift tools/GenerateAppIcon.swift out/AppIcon.icns    # 指定输出目录（三件套跟随）
//   ICON_KEEP_ICONSET=1 swift tools/GenerateAppIcon.swift  # 同时保留 .iconset 便于逐尺寸检查
//
// 双轨输出的原因：
//   - AppIcon.icns（CFBundleIconFile）：macOS 13–15 的标准图标格式。
//   - Assets.car（CFBundleIconName）：macOS 26+ 会把纯 icns 当「旧式图标」缩小垫在
//     白色底板上；要满版显示必须走 Icon Composer 的 .icon → actool 编译。
//     编译需要 Xcode 26 的 actool，本机没有时会告警跳过（icns 兜底仍然可用）。
//     Assets.car 与 icns 一样是入库产物，CI（macos-14 runner）只负责拷贝。
//
// 每个尺寸都按矢量重画而不是缩放大图：16pt / 32pt 用简化构图（去掉声波弧线、放大键帽），
// 128pt 以上用完整构图。这是 Apple 图标的惯例，也是小尺寸不糊的唯一办法。
//

import AppKit
import CoreText
import Foundation
import ImageIO

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

enum Palette {
    /// 朱砂红：避开语音类 App 条件反射的蓝紫，也避开豆包本体的品牌色。
    /// 上下只差 0.07 明度——是「受光」，不是渐变特效。
    static let bodyTop = oklch(0.618, 0.168, 36)
    static let bodyBottom = oklch(0.548, 0.172, 29)
    static let bodySheen = NSColor(white: 1, alpha: 0.10)

    /// 键帽：极浅暖白，走「材质」而不是纯白色块。
    static let capFaceTop = oklch(0.988, 0.003, 75)
    static let capFaceBottom = oklch(0.952, 0.008, 66)
    static let capWall = oklch(0.830, 0.012, 52)
    static let capWallShade = oklch(0.760, 0.016, 44)

    static let legend = oklch(0.400, 0.040, 32)

    static let wave = NSColor(white: 1, alpha: 1)
}

// MARK: - 形状

/// Apple 图标那颗「连续圆角」方形：直边保持笔直，四角走超椭圆。
/// 纯超椭圆会让直边微微鼓起（824 宽下约 5px），只在角上用超椭圆才对得上系统图标。
func squircle(in rect: CGRect, cornerRadius r: CGFloat, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 64

    /// 角落 R×R 方框里的四分之一超椭圆。
    func corner(cx: CGFloat, cy: CGFloat, sx: CGFloat, sy: CGFloat, reversed: Bool) {
        for i in 0...steps {
            let u = CGFloat(reversed ? steps - i : i) / CGFloat(steps)
            let t = u * .pi / 2
            let x = cx + sx * r * pow(cos(t), 2 / n)
            let y = cy + sy * r * pow(sin(t), 2 / n)
            path.line(to: CGPoint(x: x, y: y))
        }
    }

    path.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    path.line(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
    corner(cx: rect.maxX - r, cy: rect.maxY - r, sx: 1, sy: 1, reversed: true)
    path.line(to: CGPoint(x: rect.maxX, y: rect.minY + r))
    corner(cx: rect.maxX - r, cy: rect.minY + r, sx: 1, sy: -1, reversed: false)
    path.line(to: CGPoint(x: rect.minX + r, y: rect.minY))
    corner(cx: rect.minX + r, cy: rect.minY + r, sx: -1, sy: -1, reversed: true)
    path.line(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    corner(cx: rect.minX + r, cy: rect.maxY - r, sx: -1, sy: 1, reversed: false)
    path.close()
    return path
}

func fillVertical(_ path: NSBezierPath, top: NSColor, bottom: NSColor) {
    NSGradient(starting: bottom, ending: top)?.draw(in: path, angle: 90)
}

// MARK: - 构图

/// 键帽正面的字符。产品的默认快捷键就是 Fn，图标直接把这件事说出来。
let legendText = "fn"

struct Layout {
    /// 画布 1024 下，图标本体是 824 见方、圆角 185.4——Apple 的 macOS 图标模板尺寸。
    let canvas: CGFloat = 1024
    let bodySide: CGFloat = 824
    let bodyRadius: CGFloat = 185.4

    /// 小尺寸下弧线会退化成半个像素的脏点，所以 32pt 及以下直接不画，改为放大键帽。
    let detailed: Bool

    var capSide: CGFloat { detailed ? 386 : 500 }
    var capCenter: CGPoint { detailed ? CGPoint(x: 512, y: 504) : CGPoint(x: 512, y: 512) }
    var capRadius: CGFloat { capSide * 0.215 }
    /// 键帽正面相对底座的内缩。侧边只留一道细边，底部多缩一截露出前壁——
    /// 四周等宽会变成一圈灰镜框，而不是一颗能按下去的键。
    var capInset: CGFloat { capSide * 0.034 }
    var capFrontWall: CGFloat { capSide * 0.072 }

    var legendSize: CGFloat { capSide * 0.360 }
    /// 声波按「越远弧越长」画（扬声器图标的惯例）：
    /// 内圈 ±36° 收在键帽侧边旁，端点避开键帽圆角；外圈 ±46° 把构图纵向撑开——
    /// 等张角时内圈端点会正好怼在键帽四角上，元素关系变含糊。
    var waves: [(radius: CGFloat, alpha: CGFloat, spread: CGFloat)] {
        [(268, 1.0, 36), (356, 0.62, 46)]
    }
    var waveWidth: CGFloat { 27 }
    var glowRadius: CGFloat { 430 }
}

func drawIcon(pointSize: CGFloat, into context: CGContext) {
    let layout = Layout(detailed: pointSize >= 128)
    let body = CGRect(
        x: (layout.canvas - layout.bodySide) / 2,
        y: (layout.canvas - layout.bodySide) / 2,
        width: layout.bodySide,
        height: layout.bodySide
    )
    let bodyPath = squircle(in: body, cornerRadius: layout.bodyRadius)

    // 投影：先用实色填一遍投出影子，再把渐变画在上面，避免渐变自己带上一层灰。
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 22,
        color: NSColor(white: 0, alpha: 0.18).cgColor
    )
    Palette.bodyBottom.setFill()
    bodyPath.fill()
    context.restoreGState()

    context.saveGState()
    bodyPath.addClip()
    fillVertical(bodyPath, top: Palette.bodyTop, bottom: Palette.bodyBottom)

    // 顶部一层极淡的受光，让色块变成「材质」。
    let sheen = NSBezierPath(rect: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2))
    NSGradient(starting: Palette.bodySheen, ending: NSColor(white: 1, alpha: 0))?.draw(in: sheen, angle: -90)
    context.restoreGState()

    if layout.detailed {
        context.saveGState()
        bodyPath.addClip()
        drawGlow(layout: layout, context: context)
        context.restoreGState()

        drawWaves(layout: layout, context: context)
    }
    drawKeycap(layout: layout, context: context, showLegend: pointSize >= 32)
}

/// 键帽背后一层极淡的径向辉光：把「正在发声」的光感垫在构图底下，
/// 也让纯平红底有了受光的材质。小尺寸像素太少，画了只会发灰，不画。
func drawGlow(layout: Layout, context: CGContext) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let glow = CGGradient(
              colorsSpace: space,
              colors: [NSColor(white: 1, alpha: 0.12).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
              locations: [0, 1]
          )
    else { return }
    context.drawRadialGradient(
        glow,
        startCenter: layout.capCenter, startRadius: 0,
        endCenter: layout.capCenter, endRadius: layout.glowRadius,
        options: []
    )
}

/// 键帽左右对称的两组弧线：声音从这颗键里发出来。
/// 只放右侧会变成 Wi-Fi 信号那套；左右各两道读起来才是「在出声」。
func drawWaves(layout: Layout, context: CGContext) {
    let center = layout.capCenter

    for wave in layout.waves {
        for mirrored in [false, true] {
            let path = NSBezierPath()
            let base: CGFloat = mirrored ? 180 : 0
            path.appendArc(
                withCenter: center,
                radius: wave.radius,
                startAngle: base - wave.spread,
                endAngle: base + wave.spread
            )
            path.lineWidth = layout.waveWidth
            path.lineCapStyle = .round
            Palette.wave.withAlphaComponent(wave.alpha).setStroke()
            path.stroke()
        }
    }
}

func drawKeycap(layout: Layout, context: CGContext, showLegend: Bool) {
    let side = layout.capSide
    let base = CGRect(
        x: layout.capCenter.x - side / 2,
        y: layout.capCenter.y - side / 2,
        width: side,
        height: side
    )

    let basePath = squircle(in: base, cornerRadius: layout.capRadius)
    fillVertical(basePath, top: Palette.capWall, bottom: Palette.capWallShade)

    let inset = layout.capInset
    let face = CGRect(
        x: base.minX + inset,
        y: base.minY + inset + layout.capFrontWall,
        width: base.width - inset * 2,
        height: base.height - inset * 2 - layout.capFrontWall
    )
    let facePath = squircle(in: face, cornerRadius: layout.capRadius * 0.72)
    fillVertical(facePath, top: Palette.capFaceTop, bottom: Palette.capFaceBottom)

    guard showLegend else { return }

    let baseFont = NSFont.systemFont(ofSize: layout.legendSize, weight: .semibold)
    let font = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: layout.legendSize) } ?? baseFont
    let attributed = NSAttributedString(
        string: legendText,
        attributes: [.font: font, .foregroundColor: Palette.legend, .kern: layout.legendSize * 0.01]
    )

    // 用字形轮廓的实际外框对齐，而不是行高：行高会把 "fn" 压在视觉中心偏上。
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.saveGState()
    context.textPosition = CGPoint(
        x: face.midX - (bounds.minX + bounds.width / 2),
        y: face.midY - (bounds.minY + bounds.height / 2)
    )
    CTLineDraw(line, context)
    context.restoreGState()
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

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.saveGState()
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    drawIcon(pointSize: pointSize, into: context)
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

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

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("[错误] iconutil 失败\n".utf8))
    exit(1)
}

if !keepIconset {
    try? FileManager.default.removeItem(at: iconsetURL)
}

print("[信息] 已生成 \(outputPath.path)")

// MARK: - macOS 26 满版图标（AppIcon.icon + Assets.car）

/// Icon Composer 的层画布没有 icns 那圈约 100px 的透明边距：1024 画布直接被系统
/// 裁成图标形状。沿用同一套构图坐标时要放大 1024/824，元素在成品里的占比才与 icns 一致。
let layerScale: CGFloat = 1024.0 / 824.0

func renderLayerPNG(draw: (CGContext) -> Void) -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: 1024,
              height: 1024,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        fatalError("无法创建图层位图")
    }

    context.setShouldAntialias(true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.scaleBy(x: layerScale, y: layerScale)
    context.translateBy(x: -512, y: -512)
    draw(context)
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = context.makeImage() else {
        fatalError("无法生成图层图像")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
        fatalError("图层 PNG 编码失败")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("图层 PNG 编码失败")
    }
    return output as Data
}

func srgbString(_ color: NSColor) -> String {
    guard let c = color.usingColorSpace(.sRGB) else { fatalError("颜色转换失败") }
    return String(
        format: "extended-srgb:%.5f,%.5f,%.5f,%.5f",
        c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent
    )
}

let outputDir = outputPath.deletingLastPathComponent()
let iconPackageURL = outputDir.appendingPathComponent("AppIcon.icon", isDirectory: true)
let assetsDir = iconPackageURL.appendingPathComponent("Assets", isDirectory: true)

try? FileManager.default.removeItem(at: iconPackageURL)
try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

let layerLayout = Layout(detailed: true)
try renderLayerPNG { context in
    drawGlow(layout: layerLayout, context: context)
    drawWaves(layout: layerLayout, context: context)
}.write(to: assetsDir.appendingPathComponent("waves.png"))
try renderLayerPNG { context in
    drawKeycap(layout: layerLayout, context: context, showLegend: true)
}.write(to: assetsDir.appendingPathComponent("keycap.png"))

// 背景用 .icon 原生的线性渐变而不是贴图：系统的深色/着色外观变体都从它派生。
// groups/layers 数组的顺序是「最前的在最前面」，与 Icon Composer 图层面板一致。
// 键帽单独一组并关掉半透明：默认的 Liquid Glass 会让红底透进来把暖白键帽染成粉色，
// 而这颗键的设计本意是「实体按键」；声波留在另一组吃默认玻璃材质，光感是加分的。
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "\(srgbString(Palette.bodyTop))",
      "\(srgbString(Palette.bodyBottom))"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "keycap.png",
          "name" : "keycap"
        }
      ],
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    },
    {
      "layers" : [
        {
          "image-name" : "waves.png",
          "name" : "waves"
        }
      ]
    }
  ],
  "supported-platforms" : {
    "circles" : [ "watchOS" ],
    "squares" : "shared"
  }
}
"""
try iconJSON.write(
    to: iconPackageURL.appendingPathComponent("icon.json"),
    atomically: true,
    encoding: .utf8
)
print("[信息] 已生成 \(iconPackageURL.path)")

// actool 编译成 Assets.car。需要 Xcode 26；失败只告警——icns 兜底仍然可用。
let actoolOut = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon-car-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: actoolOut, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: actoolOut) }

let actool = Process()
actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
actool.arguments = [
    "actool", iconPackageURL.path,
    "--compile", actoolOut.path,
    "--platform", "macosx",
    "--minimum-deployment-target", "13.0",
    "--app-icon", "AppIcon",
    "--include-all-app-icons",
    "--output-partial-info-plist", actoolOut.appendingPathComponent("partial.plist").path,
]
let actoolStdout = Pipe()
actool.standardOutput = actoolStdout
actool.standardError = actoolStdout

do {
    try actool.run()
    actool.waitUntilExit()
    let compiledCar = actoolOut.appendingPathComponent("Assets.car")
    guard actool.terminationStatus == 0,
          FileManager.default.fileExists(atPath: compiledCar.path)
    else {
        let log = String(data: actoolStdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        FileHandle.standardError.write(Data("[警告] actool 编译 Assets.car 失败（macOS 26 将退回旧式图标显示）：\n\(log)\n".utf8))
        exit(0)
    }
    let carURL = outputDir.appendingPathComponent("Assets.car")
    try? FileManager.default.removeItem(at: carURL)
    try FileManager.default.copyItem(at: compiledCar, to: carURL)
    print("[信息] 已生成 \(carURL.path)")
} catch {
    FileHandle.standardError.write(Data("[警告] 无法执行 actool（需要 Xcode 26）：\(error)\n".utf8))
}
