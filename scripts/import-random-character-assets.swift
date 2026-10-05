import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift scripts/import-random-character-assets.swift SOURCE_ROOT RAWFILE_ROOT CHARACTER...
// SOURCE_ROOT contains cycling/<character>_frames/cutout_palette_v1 and cutout_palette_v2.
struct PlannedAsset {
    let destination: URL
    let contents: Data
}

enum ImportFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}

func decodedPNG(_ data: Data, name: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0 else {
        throw ImportFailure.invalid("Cannot decode PNG: \(name)")
    }
    switch image.alphaInfo {
    case .premultipliedFirst, .premultipliedLast, .first, .last:
        return image
    default:
        throw ImportFailure.invalid("Sprite must have an alpha channel: \(name)")
    }
}

func concealedSilhouette(_ image: CGImage) throws -> Data {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let silhouette: CGImage? = pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Keep exact coverage, edges and contact shadow, but never expose a palette in the lobby.
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
        }
        return context.makeImage()
    }
    guard let silhouette else {
        throw ImportFailure.invalid("Cannot render concealed silhouette")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output,
        UTType.png.identifier as CFString, 1, nil) else {
        throw ImportFailure.invalid("Cannot create silhouette PNG")
    }
    CGImageDestinationAddImage(destination, silhouette, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ImportFailure.invalid("Cannot encode silhouette PNG")
    }
    return output as Data
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 4 else {
        throw ImportFailure.invalid("Expected SOURCE_ROOT RAWFILE_ROOT CHARACTER...")
    }
    let sourceRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let rawfileRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let characters = Array(arguments.dropFirst(3))
    guard Set(characters).count == characters.count else {
        throw ImportFailure.invalid("Duplicate character keys")
    }
    var assets: [PlannedAsset] = []
    for character in characters {
        guard character.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
            throw ImportFailure.invalid("Invalid character key: \(character)")
        }
        for palette in 1...2 {
            for frame in 1...8 {
                let filename = String(format: "frame_%02d.png", frame)
                let source = sourceRoot.appendingPathComponent(
                    "cycling/\(character)_frames/cutout_palette_v\(palette)/\(filename)")
                let contents = try Data(contentsOf: source)
                let image = try decodedPNG(contents, name: source.path)
                assets.append(PlannedAsset(destination: rawfileRoot.appendingPathComponent(
                    "walk/\(character)/palette_\(palette)/\(filename)"), contents: contents))
                if frame == 1 {
                    assets.append(PlannedAsset(destination: rawfileRoot.appendingPathComponent(
                        "comic/avatars/\(character)_palette_\(palette).png"), contents: contents))
                    if palette == 1 {
                        assets.append(PlannedAsset(destination: rawfileRoot.appendingPathComponent(
                            "comic/mystery/\(character).png"), contents: try concealedSilhouette(image)))
                    }
                }
            }
        }
    }
    let manager = FileManager.default
    // Preflight the whole import; do not silently replace any existing artwork.
    for asset in assets where manager.fileExists(atPath: asset.destination.path) {
        if try Data(contentsOf: asset.destination) != asset.contents {
            throw ImportFailure.invalid("Refusing to overwrite different asset: \(asset.destination.path)")
        }
    }
    var copied = 0
    for asset in assets where !manager.fileExists(atPath: asset.destination.path) {
        try manager.createDirectory(at: asset.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try asset.contents.write(to: asset.destination, options: .atomic)
        copied += 1
    }
    print("Imported \(copied) assets; validated \(assets.count): \(characters.joined(separator: ", "))")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Asset import failed: \(error)\n".utf8))
    exit(1)
}
