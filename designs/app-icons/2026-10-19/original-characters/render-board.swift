import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = project.appendingPathComponent("designs/app-icons/2026-10-19/original-characters")
let boardWidth = 2200
let boardHeight = 2460
let tileSize: CGFloat = 900
let ink = "171B1F"
let paper = "FFF9EE"

struct Placement {
    let asset: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
}

struct Concept {
    let number: String
    let name: String
    let detail: String
    let background: String
    let circle: String
    let circleRect: CGRect
    let placements: [Placement]
}

// These are the original PNGs, drawn without color filters, mirroring or repainting.
// A square clip changes the icon's framing, never the character asset itself.
let concepts: [Concept] = [
    Concept(number: "08", name: "台灯 · 同拍招呼", detail: "保留提帽动作，用角色记忆点建立品牌。",
        background: "C5B7EB", circle: paper, circleRect: CGRect(x: 65, y: 65, width: 770, height: 770),
        placements: [Placement(asset: "avatars/lamp.png", x: 10, y: 80, width: 880)]),
    Concept(number: "09", name: "云行者 · 节拍伙伴", detail: "原版打鼓动作，让节奏玩法直接可见。",
        background: "FF7056", circle: paper, circleRect: CGRect(x: 42, y: 45, width: 816, height: 816),
        placements: [Placement(asset: "poses/cloud.png", x: 40, y: 18, width: 820)]),
    Concept(number: "10", name: "茶壶太太 · 轻快一拍", detail: "原版茶壶与手鼓，突出温暖的漫画气质。",
        background: "A9C9F2", circle: paper, circleRect: CGRect(x: 24, y: 45, width: 852, height: 852),
        placements: [Placement(asset: "poses/teapot.png", x: 23, y: 12, width: 854)]),
    Concept(number: "11", name: "同频伙伴 · 结伴出发", detail: "两张原版头像同向组合，强调多人同行。",
        background: "29B5AE", circle: paper, circleRect: CGRect(x: 48, y: 58, width: 804, height: 804),
        placements: [Placement(asset: "avatars/wave.png", x: 285, y: 270, width: 670),
                     Placement(asset: "avatars/mismatch.png", x: -36, y: 175, width: 780)])
]

func color(_ hex: String) -> CGColor {
    let value = UInt32(hex, radix: 16)!
    return CGColor(red: CGFloat((value >> 16) & 255) / 255,
        green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

func canvas(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    return context
}

func fill(_ context: CGContext, _ rect: CGRect, _ hex: String) {
    context.setFillColor(color(hex))
    context.fill(rect)
}

func text(_ context: CGContext, _ value: String, _ x: CGFloat, _ y: CGFloat,
          _ size: CGFloat, _ hex: String = ink, _ fontName: String = "PingFangSC-Semibold") {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    context.saveGState()
    context.translateBy(x: x, y: y + size)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = .identity
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}

func drawImage(_ context: CGContext, _ image: CGImage, _ rect: CGRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    context.restoreGState()
}

func loadAsset(_ path: String) -> CGImage {
    let sourceURL = project.appendingPathComponent("entry/src/main/resources/rawfile/comic/\(path)")
    let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func save(_ image: CGImage, _ filename: String) {
    let destinationURL = output.appendingPathComponent(filename)
    let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}

func renderIcon(_ concept: Concept) -> CGImage {
    let context = canvas(Int(tileSize), Int(tileSize))
    fill(context, CGRect(x: 0, y: 0, width: tileSize, height: tileSize), concept.background)
    context.setFillColor(color(concept.circle))
    context.fillEllipse(in: concept.circleRect)
    for placement in concept.placements {
        let image = loadAsset(placement.asset)
        let height = placement.width * CGFloat(image.height) / CGFloat(image.width)
        drawImage(context, image, CGRect(x: placement.x, y: placement.y, width: placement.width, height: height))
    }
    return context.makeImage()!
}

let board = canvas(boardWidth, boardHeight)
fill(board, CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight), paper)
text(board, "oneBeat", 140, 56, 44, ink, "HelveticaNeue-BoldItalic")
text(board, "ORIGINAL CHARACTERS / APP ICON", 1370, 76, 22, "777065", "HelveticaNeue-Medium")
text(board, "一起，走在同一拍", 140, 131, 64)
text(board, "项目原角色 · 四款正方形图标提案", 142, 223, 29, "625C54")

let positions: [CGPoint] = [CGPoint(x: 140, y: 320), CGPoint(x: 1160, y: 320),
                            CGPoint(x: 140, y: 1360), CGPoint(x: 1160, y: 1360)]
for (index, concept) in concepts.enumerated() {
    let origin = positions[index]
    let icon = renderIcon(concept)
    save(icon, "\(concept.number)-original-character-icon.png")
    drawImage(board, icon, CGRect(x: origin.x, y: origin.y, width: tileSize, height: tileSize))
    text(board, "\(concept.number)  \(concept.name)", origin.x, origin.y + tileSize + 20, 36)
    text(board, concept.detail, origin.x, origin.y + tileSize + 74, 25, "625C54")
}
text(board, "原 PNG 直接组合 · 保留原有脸型、服装、配色与动作", 140, 2390, 24, "777065")
save(board.makeImage()!, "08-11-original-characters-board.png")
print("Saved four 900×900 icons and the 2200×2460 comparison board.")
