#!/usr/bin/env swift
import Foundation
import AppKit

guard CommandLine.arguments.count > 2 else {
    print("Usage: generate_icns.swift <input-image> <output-icns>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let srcImage = NSImage(contentsOfFile: inputPath),
      let tiffData = srcImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let cgImage = bitmap.cgImage else {
    print("Failed to load source image from \(inputPath)")
    exit(1)
}

let tempIconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tempIconset)
try! FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    if let resizedCG = context.makeImage() {
        let destURL = tempIconset.appendingPathComponent(name)
        if let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, resizedCG, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

// Run iconutil to create .icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", tempIconset.path, "-o", outputPath]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Successfully generated ICNS at: \(outputPath)")
} else {
    print("iconutil failed with code \(process.terminationStatus)")
    exit(1)
}
