import AppKit
import CoreGraphics
import Foundation

@MainActor
final class PointerHighlight: NSObject {
    private let view = PointerHighlightView(frame: NSRect(x: 0, y: 0, width: 56, height: 74))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()
    private var screens: [NSRect] = []
    private var timer: Timer?
    private var started: UInt64 = 0
    private var growDuration: Double = 0

    func show(colors: PointerColors, animated: Bool) {
        view.setColors(colors)
        screens = NSScreen.screens.map(\.frame)
        growDuration = animated ? 0.3 : 0
        started = DispatchTime.now().uptimeNanoseconds
        tick()
        if !panel.isVisible { panel.orderFrontRegardless() }
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func tick() {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        if elapsed >= growDuration + 1.5 {
            panel.orderOut(nil)
            timer?.invalidate()
            timer = nil
            return
        }
        let progress = growDuration == 0 ? 1 : min(elapsed / growDuration, 1)
        let scale = 0.55 + 0.8 * progress * progress * (3 - 2 * progress)
        let position = NSEvent.mouseLocation
        let screen = screens.first { $0.contains(position) }
        let flipX = screen.map { $0.maxX - position.x < view.bounds.width - 4 } ?? false
        let flipY = screen.map { position.y - $0.minY < view.bounds.height - 4 } ?? false
        let tip = view.update(scale: scale, flipX: flipX, flipY: flipY)
        let origin = NSPoint(x: position.x - tip.x, y: position.y - tip.y)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

final class PointerHighlightView: NSView {
    static func arrowPath() -> NSBezierPath {
        let arrow = NSBezierPath()
        arrow.move(to: .zero)
        arrow.line(to: NSPoint(x: 0, y: -44))
        arrow.line(to: NSPoint(x: 11, y: -33))
        arrow.line(to: NSPoint(x: 19, y: -48))
        arrow.line(to: NSPoint(x: 25, y: -45))
        arrow.line(to: NSPoint(x: 17, y: -30))
        arrow.line(to: NSPoint(x: 32, y: -30))
        arrow.close()
        arrow.lineWidth = 4
        arrow.lineJoinStyle = .round
        return arrow
    }

    static func drawArrow(colors: PointerColors, scale: CGFloat, tip: NSPoint, flipX: Bool = false, flipY: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let arrow = arrowPath()
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.scaleBy(x: flipX ? -scale : scale, y: flipY ? -scale : scale)
        PointerColors.color(colors.border).setStroke()
        PointerColors.color(colors.fill).setFill()
        arrow.stroke()
        arrow.fill()
        context.restoreGState()
    }

    private var colors = PointerStyle.defaultColors
    private var scale: CGFloat = 1
    private var flipX = false
    private var flipY = false

    private var tip: NSPoint {
        NSPoint(x: flipX ? bounds.maxX - 4 : 4, y: flipY ? 4 : bounds.maxY - 4)
    }

    func setColors(_ colors: PointerColors) {
        self.colors = colors
        needsDisplay = true
    }

    func update(scale: CGFloat, flipX: Bool, flipY: Bool) -> NSPoint {
        if self.scale != scale || self.flipX != flipX || self.flipY != flipY {
            self.scale = scale
            self.flipX = flipX
            self.flipY = flipY
            needsDisplay = true
        }
        return tip
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        Self.drawArrow(colors: colors, scale: scale, tip: tip, flipX: flipX, flipY: flipY)
    }
}

enum DisplayCenter {
    static func move(advance: Bool) -> String? {
        guard let position = CGEvent(source: nil)?.location else { return "Could not read the pointer position." }
        let bounds = NSScreen.screens.lazy.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            return CGDisplayBounds(id)
        }
        guard let target = target(for: position, in: bounds, advance: advance),
              CGWarpMouseCursorPosition(target) == .success else { return "Could not center the pointer." }
        return nil
    }

    static func target(for position: CGPoint, in bounds: some Sequence<CGRect>, advance: Bool) -> CGPoint? {
        var displays = bounds.makeIterator()
        guard let first = displays.next() else { return nil }
        var display = first
        while !display.contains(position) {
            guard let next = displays.next() else { return CGPoint(x: first.midX, y: first.midY) }
            display = next
        }
        if advance { display = displays.next() ?? first }
        return CGPoint(x: display.midX, y: display.midY)
    }
}

