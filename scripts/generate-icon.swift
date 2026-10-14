import AppKit
import Foundation

// Resize the committed ImageGen source without redrawing or flattening its transparency.
// Run from the repository root: swift scripts/generate-icon.swift [source.png] [appiconset]
let arguments = Array(CommandLine.arguments.dropFirst())
let source = URL(fileURLWithPath: arguments.first ?? "AgentSwapApp/Assets/AppIconSource.png")
let output = URL(fileURLWithPath: arguments.dropFirst().first ?? "AgentSwapApp/Assets.xcassets/AppIcon.appiconset")

guard let image = NSBitmapImageRep(data: try Data(contentsOf: source)),
      image.pixelsWide == image.pixelsHigh, image.pixelsWide >= 1024,
      image.hasAlpha, let sourceImage = image.cgImage else {
    fatalError("AppIcon source must be a square PNG of at least 1024 pixels with an alpha channel")
}

func resizedIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create transparent icon canvas")
    }
    let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.cgContext.clear(bounds)
    context.cgContext.interpolationQuality = .high
    context.cgContext.draw(sourceImage, in: bounds)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode resized icon PNG")
    }
    return data
}

// Keep the asset manifest and filenames unchanged; each declared macOS size comes from the same source.
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("Contents.json")))
guard let contents = manifest as? [String: Any], let entries = contents["images"] as? [[String: String]], entries.count == 10 else {
    fatalError("Expected ten macOS AppIcon entries")
}
for entry in entries {
    guard entry["idiom"] == "mac", let filename = entry["filename"],
          let size = entry["size"]?.split(separator: "x").first.flatMap({ Int($0) }),
          let scale = entry["scale"]?.first.flatMap({ Int(String($0)) }),
          filename == "icon_\(size)x\(size)@\(scale)x.png" else {
        fatalError("Unsupported AppIcon manifest entry")
    }
    try resizedIcon(pixels: size * scale).write(to: output.appendingPathComponent(filename), options: .atomic)
}
print("Generated \(entries.count) transparent AppIcon PNGs from \(image.pixelsWide)×\(image.pixelsHigh) source")
