import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("designs/app-icons/2026-10-19")
let sourceName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "20-23-sticker-characters-board.png"
let destinationName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "23-skater-duo-1024.png"
let sourceURL = directory.appendingPathComponent(sourceName)
let destinationURL = directory.appendingPathComponent(destinationName)
let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!

// Use the interior of tile 23 to remove the sheet, number and antialiased tile edges.
// The generated tile is slightly taller than wide; a centered square avoids stretching the artwork.
let cropRect = CGRect(x: 652, y: 631, width: 552, height: 552)
let cropped = image.cropping(to: cropRect)!
let outputSize = 1024
let context = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
    bytesPerRow: outputSize * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)!
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
print(destinationURL.path)
