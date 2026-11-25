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
    private var highlightView: HighlightView?
    private var highlightScreen: NSScreen?
    private var handle: NSWindow?
    private var onMove: ((CGRect) -> Void)?
    private var movable = true

    private static let handleSize = CGSize(width: 112, height: 26)

    /// Keeps the chosen area clear and dims the rest of that screen. Clicks
    /// pass straight through, and the recording does not include it because
    /// this app's windows are left out of the capture. A small handle on the
    /// area's edge drags it somewhere else: `onMove` gets the new rectangle,
    /// in the screen's points from its top-left corner.
    func showHighlight(screen: NSScreen, rect: CGRect, onMove: ((CGRect) -> Void)? = nil) {
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
        highlightView = view
        highlightScreen = screen
        self.onMove = onMove

        if onMove != nil { showHandle() }

        // Keep the recorder's own window above the dimming, so it stays readable.
        for other in NSApp.windows where !(other is OverlayWindow) && other.canBecomeMain {
            other.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        }
    }

    func hideHighlight() {
        handle?.orderOut(nil)
        handle = nil
        onMove = nil
        highlightView = nil
        highlightScreen = nil
        guard let highlight else { return }
        highlight.orderOut(nil)
        self.highlight = nil
        for other in NSApp.windows where !(other is OverlayWindow) && other.canBecomeMain {
            other.level = .normal
        }
    }

    /// Takes everything this class has put on the screen away again.
    func hideEverything() {
        close()
        hideHighlight()
    }

    /// The area stays where it is while a recording runs.
    func setMovable(_ movable: Bool) {
        self.movable = movable
        guard let handle else { return }
        if movable { handle.orderFrontRegardless() } else { handle.orderOut(nil) }
    }

    private func showHandle() {
        let window = OverlayWindow(contentRect: CGRect(origin: .zero, size: Self.handleSize),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = MoveHandleView(frame: CGRect(origin: .zero, size: Self.handleSize))
        var startHole = CGRect.zero
        view.onBegin = { [weak self] in startHole = self?.highlightView?.hole ?? .zero }
        view.onDrag = { [weak self] delta in self?.moveHole(from: startHole, by: delta) }
        view.onEnd = { [weak self] in self?.reportMove() }
        window.contentView = view
        handle = window
        placeHandle()
        if movable { window.orderFrontRegardless() }
    }

    private func moveHole(from startHole: CGRect, by delta: CGSize) {
        guard let view = highlightView else { return }
        var hole = startHole
        hole.origin.x = min(max(0, (startHole.minX + delta.width).rounded()),
                            view.bounds.width - hole.width)
        hole.origin.y = min(max(0, (startHole.minY + delta.height).rounded()),
                            view.bounds.height - hole.height)
        view.hole = hole
        view.needsDisplay = true
        placeHandle()
    }

    private func reportMove() {
        guard let view = highlightView else { return }
        let hole = view.hole
        onMove?(CGRect(x: hole.minX, y: view.bounds.height - hole.maxY,
                       width: hole.width, height: hole.height))
    }

    /// The handle sits just above the area's top-left corner, or just inside
    /// it when the area reaches the top of the screen.
    private func placeHandle() {
        guard let handle, let view = highlightView, let screen = highlightScreen else { return }
        let hole = view.hole
        let size = Self.handleSize
        let x = min(max(0, hole.minX), view.bounds.width - size.width)
        var y = hole.maxY + 6
        if y + size.height > view.bounds.height { y = hole.maxY - size.height - 6 }
        handle.setFrameOrigin(CGPoint(x: screen.frame.minX + x, y: screen.frame.minY + y))
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

/// The small pill that drags the chosen area to another place.
private final class MoveHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?

    private var startMouse: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: startMouse == nil ? .openHand : .closedHand)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        onBegin?()
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse else { return }
        let now = NSEvent.mouseLocation
        onDrag?(CGSize(width: now.x - startMouse.x, height: now.y - startMouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard startMouse != nil else { return }
        startMouse = nil
        NSCursor.pop()
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: "Move area", attributes: attributes)
        let textSize = string.size()
        let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        let iconSide: CGFloat = symbol == nil ? 0 : 13
        let gap: CGFloat = symbol == nil ? 0 : 6
        var x = (bounds.width - iconSide - gap - textSize.width) / 2
        if let symbol {
            symbol.draw(in: CGRect(x: x, y: (bounds.height - iconSide) / 2,
                                   width: iconSide, height: iconSide))
            x += iconSide + gap
        }
        string.draw(at: CGPoint(x: x, y: (bounds.height - textSize.height) / 2))
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
    private var lastPoint: CGPoint?
    private var spaceDown = false

    /// Space is read both from key events and from the keyboard itself, so a
    /// press that never reached this view still counts.
    private var movingWithSpace: Bool {
        spaceDown || CGEventSource.keyState(.combinedSessionState, key: 49)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        lastPoint = start
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        defer { lastPoint = point }
        // Holding Space moves the rectangle instead of resizing it.
        if movingWithSpace, let last = lastPoint, let current = selection {
            let dx = min(max(point.x - last.x, bounds.minX - current.minX),
                         bounds.maxX - current.maxX)
            let dy = min(max(point.y - last.y, bounds.minY - current.minY),
                         bounds.maxY - current.maxY)
            selection = current.offsetBy(dx: dx, dy: dy)
            self.start = CGPoint(x: start.x + dx, y: start.y + dy)
            needsDisplay = true
            return
        }
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
        defer { start = nil; shiftAspect = nil; lastPoint = nil }
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
        switch event.keyCode {
        case 53: onFinish?(nil)
        case 49: spaceDown = true
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        guard let selection else {
            let shape = aspectName.map { "a \($0) area" } ?? "the area"
            drawLabel("Drag to choose \(shape) to record. Esc cancels.",
                      centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), size: 18)
            drawLabel("Hold Space while dragging to move it.",
                      centeredAt: CGPoint(x: bounds.midX, y: bounds.midY - 40), size: 13)
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
