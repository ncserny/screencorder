import AppKit

/// Dims every screen and lets the user drag out a rectangle on one of them.
@MainActor
final class AreaSelector {
    static let shared = AreaSelector()

    private var windows: [NSWindow] = []
    private var onDone: ((NSScreen, CGRect) -> Void)?

    /// `onDone` gets the screen and the rectangle in that screen's points,
    /// measured from its top-left corner. It is not called if the user cancels.
    /// `aspect` (width over height) locks the rectangle to that shape.
    func begin(aspect: CGFloat? = nil, aspectName: String? = nil,
               onDone: @escaping (NSScreen, CGRect) -> Void) {
        close()
        hideHighlight()
        self.onDone = onDone

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.aspect = aspect
            view.aspectName = aspectName
            view.onFinish = { [weak self] rect in self?.finish(screen: screen, rect: rect) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Highlight

    private var highlight: NSWindow?

    /// Keeps the chosen area clear and dims the rest of that screen. Clicks
    /// pass straight through, and the recording does not include it because
    /// this app's windows are left out of the capture.
    func showHighlight(screen: NSScreen, rect: CGRect) {
        hideHighlight()
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = HighlightView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.hole = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY,
                           width: rect.width, height: rect.height)
        window.contentView = view
        window.orderFrontRegardless()
        highlight = window

        // Keep the recorder's own window above the dimming, so it stays readable.
        for other in NSApp.windows where !(other is OverlayWindow) && other.canBecomeMain {
            other.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        }
    }

    func hideHighlight() {
        guard let highlight else { return }
        highlight.orderOut(nil)
        self.highlight = nil
        for other in NSApp.windows where !(other is OverlayWindow) && other.canBecomeMain {
            other.level = .normal
        }
    }

    private func finish(screen: NSScreen, rect: CGRect?) {
        let done = onDone
        close()
        if let rect { done?(screen, rect) }
    }

    private func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onDone = nil
    }
}

/// Borderless windows refuse key status by default, and Esc needs it.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The dimming that stays up once an area is chosen.
private final class HighlightView: NSView {
    /// The area to leave clear, in this view's coordinates.
    var hole: CGRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        NSColor.clear.setFill()
        hole.fill(using: .copy)
        // The border sits just outside the area, so it is never recorded.
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()
    }
}

private final class SelectionView: NSView {
    /// Called with the rectangle (top-left origin), or nil on cancel.
    var onFinish: ((CGRect?) -> Void)?
    var aspect: CGFloat?
    var aspectName: String?

    private var start: CGPoint?
    private var selection: CGRect?
    private var shiftAspect: CGFloat?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        updateShiftLock(event)
        if let aspect = aspect ?? shiftAspect {
            // Grow from the starting corner towards the pointer, keeping the
            // shape and stopping at the edge of the screen.
            let right = point.x >= start.x
            let up = point.y >= start.y
            let roomX = right ? bounds.maxX - start.x : start.x - bounds.minX
            let roomY = up ? bounds.maxY - start.y : start.y - bounds.minY
            let wanted = max(abs(point.x - start.x), abs(point.y - start.y) * aspect)
            let width = min(wanted, roomX, roomY * aspect)
            let height = width / aspect
            selection = CGRect(x: right ? start.x : start.x - width,
                               y: up ? start.y : start.y - height,
                               width: width, height: height)
        } else {
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
                .intersection(bounds)
        }
        needsDisplay = true
    }

    /// Holding Shift during a free drag keeps the proportions the rectangle
    /// had when Shift went down. Letting go frees it again.
    private func updateShiftLock(_ event: NSEvent) {
        guard event.modifierFlags.contains(.shift), start != nil else {
            shiftAspect = nil
            return
        }
        if shiftAspect == nil, let selection, selection.width >= 4, selection.height >= 4 {
            shiftAspect = selection.width / selection.height
        }
    }

    override func flagsChanged(with event: NSEvent) {
        updateShiftLock(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; shiftAspect = nil }
        guard let selection, selection.width >= 16, selection.height >= 16 else {
            // A click or a sliver is not a selection: let the user try again.
            self.selection = nil
            needsDisplay = true
            return
        }
        let rect = CGRect(x: selection.minX.rounded(), y: selection.minY.rounded(),
                          width: selection.width.rounded(), height: selection.height.rounded())
        onFinish?(CGRect(x: rect.minX, y: bounds.height - rect.maxY,
                         width: rect.width, height: rect.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        guard let selection else {
            let shape = aspectName.map { "a \($0) area" } ?? "the area"
            drawLabel("Drag to choose \(shape) to record. Esc cancels.",
                      centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), size: 18)
            return
        }

        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let below = selection.minY - 18
        let labelY = below > 12 ? below : selection.maxY + 18
        let size = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        drawLabel(aspectName.map { "\(size)  \($0)" } ?? size,
                  centeredAt: CGPoint(x: selection.midX, y: labelY), size: 13)
    }

    private func drawLabel(_ text: String, centeredAt point: CGPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let box = CGRect(x: point.x - textSize.width / 2 - 8, y: point.y - textSize.height / 2 - 4,
                         width: textSize.width + 16, height: textSize.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }
}
