// Draws the app icon and in-app logo. Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: diagonal indigo to cyan gradient.
let gradient = CGGradient(colorsSpace: space, colors: [color(0x4F2BD8), color(0x1FA2E6), color(0x2FD4C4)] as CFArray,
                          locations: [0, 0.6, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft glow behind the microphone.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size * 0.5), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size * 0.5), endRadius: size * 0.42, options: [])

// Microphone: the same SF Symbol as the keyboard's record button (mic.fill, semibold), in white.
let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
let symbolHeight = size * 0.46
let symbolWidth = symbolHeight * symbol.size.width / symbol.size.height
let symbolRect = CGRect(x: (size - symbolWidth) / 2, y: (size - symbolHeight) / 2 - size * 0.01,
                        width: symbolWidth, height: symbolHeight)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
symbol.draw(in: symbolRect)
NSGraphicsContext.restoreGraphicsState()

// Two sound waves on each side, centered on the microphone's head.
let waveCenter = CGPoint(x: size / 2, y: symbolRect.minY + symbolHeight * 0.66)
context.setLineCap(.round)
context.setLineWidth(size * 0.03)
for (radius, alpha) in [(size * 0.235, CGFloat(0.9)), (size * 0.315, 0.55)] {
    context.setStrokeColor(color(0xFFFFFF, alpha))
    for (start, end) in [(-CGFloat.pi * 0.2, CGFloat.pi * 0.2), (CGFloat.pi * 0.8, CGFloat.pi * 1.2)] {
        context.addArc(center: waveCenter, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()
    }
}

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Icon saved to \(output)")
