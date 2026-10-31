// วาดไอคอนแอป (SF Symbol บนพื้นสี่เหลี่ยมมุมมน) เป็น PNG 1024px: swift app/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
NSGradient(colors: [NSColor(red: 0.89, green: 0.12, blue: 0.16, alpha: 1), NSColor(red: 0.55, green: 0.05, blue: 0.08, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185), angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "car.side.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 20, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
