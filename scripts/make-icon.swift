// Turns assets/icon-render.png (1024² full-bleed render) into a macOS icon
// master: the render clipped to the standard rounded-square shape, inset on
// a transparent 1024² canvas like Apple's icon template.
import AppKit

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

guard let source = NSImage(contentsOf: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Can't read \(input.path)")
}
let canvas = 1024
let context = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.addPath(shape)
context.clip()
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fill(tile)
context.interpolationQuality = .high
context.draw(source, in: tile)

let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(output.path)") }
