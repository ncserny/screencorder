import AVKit
import Combine
import ScreenCaptureKit
import SwiftUI

// MARK: - App

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recorder = Recorder.shared

    var body: some Scene {
        Window("Screencorder", id: "main") {
            ContentView(recorder: recorder)
        }
        .windowResizability(.contentSize)
        .commands {
            // Command-N starts an empty recording instead of opening a window.
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { recorder.newRecording() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(recorder.state != .idle || recorder.lastURL == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    // Closing the recorder window quits the app. The dimming around a chosen
    // area is a window too, so without this it would stay up, keep the app
    // running and leave no window to get back to.
    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, window.canBecomeMain,
                  window.styleMask.contains(.titled), !(window is NSPanel) else { return }
            MainActor.assumeIsolated {
                AreaSelector.shared.hideEverything()
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AreaSelector.shared.hideEverything() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quitting mid-recording would leave an unplayable file, so finish it first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Recorder.shared.state != .idle else { return .terminateNow }
        Task { @MainActor in
            await Recorder.shared.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Recorder

@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    enum State { case idle, recording, finishing }

    @Published var state: State = .idle
    @Published var sourceName = "No source chosen yet"
    @Published var startedAt: Date?
    @Published var lastURL: URL?
    @Published var message: String?
    @Published var isPlaying = false
    @Published var hasSource = false

    let player = AVPlayer()

    private var filter: SCContentFilter?
    /// Set when recording a drawn area: the part of the display to keep, in
    /// its points from the top-left corner.
    private var area: CGRect?
    /// Set for the YouTube shapes, which are saved at a standard video size.
    private var outputSize: (width: Int, height: Int)?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var pendingURL: URL?
    private var startAfterPick = false
    private let frameSink = FrameSink()
    private let frameQueue = DispatchQueue(label: "screen-recorder.frames")
    private var endObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?

    override init() {
        super.init()
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .map { $0 != .paused }
            .assign(to: &$isPlaying)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.player.seek(to: .zero) }
        }
        // "--empty" starts without the last recording loaded.
        if !CommandLine.arguments.contains("--empty") { loadLatestRecording() }
        // The area cannot be moved while it is being recorded.
        stateObserver = $state.receive(on: RunLoop.main).sink { state in
            MainActor.assumeIsolated { AreaSelector.shared.setMovable(state == .idle) }
        }
    }

    /// Makes Play work straight after launch, on the most recent recording.
    private func loadLatestRecording() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let folder = movies.appendingPathComponent("Screen Recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let latest = files.filter { $0.pathExtension == "mp4" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (da ?? .distantPast) < (db ?? .distantPast)
        }
        guard let latest else { return }
        lastURL = latest
        player.replaceCurrentItem(with: AVPlayerItem(url: latest))
    }

    // MARK: Source

    func chooseSource(thenRecord: Bool = false) {
        startAfterPick = thenRecord
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    /// Lets the user draw a rectangle on a screen and records just that part.
    func chooseArea(_ shape: AreaShape = .free) {
        guard state == .idle else { return }
        AreaSelector.shared.begin(aspect: shape.aspect, aspectName: shape.ratioName) {
            [weak self] screen, rect in
            Task { await self?.setArea(screen: screen, rect: rect, shape: shape) }
        }
    }

    private func setArea(screen: NSScreen, rect: CGRect, shape: AreaShape) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            let id = (number as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                message = "Could not find that display."
                return
            }
            // Leave this app's own window out of the picture.
            let pid = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == pid }
            filter = SCContentFilter(display: display, excludingApplications: own,
                                     exceptingWindows: [])
            hasSource = true
            applyArea(rect, on: screen, shape: shape, verb: "chosen")
            AreaSelector.shared.showHighlight(screen: screen, rect: rect, aspect: shape.aspect) {
                [weak self] changed in
                guard let self, self.state == .idle else { return }
                self.applyArea(changed, on: screen, shape: shape, verb: "changed")
            }
        } catch {
            message = "Recording an area needs the Screen Recording permission. Allow "
                + "Screencorder under System Settings, Privacy & Security, "
                + "Screen & System Audio Recording, then choose the area again."
        }
    }

    /// Takes a drawn, moved or resized area as the thing to record.
    private func applyArea(_ rect: CGRect, on screen: NSScreen, shape: AreaShape, verb: String) {
        area = rect
        outputSize = shape.outputSize(pixelWidth: rect.width * screen.backingScaleFactor)
        sourceName = "\(shape.ratioName ?? "Area") \(Int(rect.width)) × \(Int(rect.height))"
        if let outputSize {
            message = "Area \(verb). Press Record. The video will be "
                + "\(outputSize.width) × \(outputSize.height)."
        } else {
            message = "Area \(verb). Press Record."
        }
    }

    /// Clears the last recording from the window, ready for a fresh one. The
    /// file stays on disk and the chosen source is kept.
    func newRecording() {
        guard state == .idle else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        lastURL = nil
        message = nil
    }

    // MARK: Record

    func record() {
        guard state == .idle else { return }
        guard let filter else {
            chooseSource(thenRecord: true)
            return
        }
        message = nil
        player.pause()
        Task { await start(with: filter) }
    }

    private func start(with filter: SCContentFilter) async {
        do {
            let url = try Self.newOutputURL()

            let config = SCStreamConfiguration()
            if let area { config.sourceRect = area }
            let size = outputSize ?? Self.videoSize(
                points: area?.size ?? filter.contentRect.size,
                scale: CGFloat(filter.pointPixelScale))
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameQueue)

            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = url
            outputConfig.outputFileType = .mp4
            outputConfig.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            try stream.addRecordingOutput(output)

            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.pendingURL = url
            self.startedAt = Date()
            self.state = .recording
        } catch {
            message = "Could not start recording: \(error.localizedDescription)"
            state = .idle
        }
    }

    // MARK: Stop

    func stop() {
        guard state == .recording, let stream else { return }
        state = .finishing
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                self.message = "Stopping failed: \(error.localizedDescription)"
            }
            // The recording output normally reports that the file is finalised.
            // If that never arrives, finish anyway.
            try? await Task.sleep(for: .seconds(3))
            self.finish()
        }
    }

    func stopAndWait() async {
        stop()
        while state != .idle { try? await Task.sleep(for: .milliseconds(100)) }
    }

    fileprivate func finish(error: Error? = nil) {
        guard let url = pendingURL else { return }
        pendingURL = nil
        stream = nil
        recordingOutput = nil
        startedAt = nil
        state = .idle

        if let error { message = "Recording ended: \(error.localizedDescription)" }

        if FileManager.default.fileExists(atPath: url.path) {
            lastURL = url
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            if error == nil { message = "Saved \(url.lastPathComponent)" }
        } else if error == nil {
            message = "Nothing was saved."
        }
    }

    // MARK: Play

    func togglePlay() {
        guard lastURL != nil, state == .idle else { return }
        if isPlaying { player.pause() } else { player.play() }
    }

    func revealInFinder() {
        guard let lastURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastURL])
    }

    // MARK: Helpers

    private static func newOutputURL() throws -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let folder = movies.appendingPathComponent("Screen Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")
    }

    /// Native pixel size of the source, kept within what H.264 encodes (4K) and even.
    private static func videoSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var width = points.width * scale
        var height = points.height * scale
        let fit = min(1, 3840 / max(width, 1), 2160 / max(height, 1))
        width *= fit
        height *= fit
        func even(_ value: CGFloat) -> Int { max(2, Int(value.rounded()) / 2 * 2) }
        return (even(width), even(height))
    }

    private static func name(for filter: SCContentFilter) -> String {
        switch filter.style {
        case .window:
            let window = filter.includedWindows.first
            let app = window?.owningApplication?.applicationName
            let title = window?.title
            return [app, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                .ifEmpty("Window")
        case .display:
            return "Entire display"
        default:
            return "Selected content"
        }
    }

    fileprivate func picked(_ filter: SCContentFilter) {
        self.filter = filter
        area = nil
        outputSize = nil
        hasSource = true
        AreaSelector.shared.hideHighlight()
        sourceName = Self.name(for: filter)
        if startAfterPick {
            startAfterPick = false
            record()
        }
    }
}

/// The shapes an area can be drawn in.
enum AreaShape: CaseIterable {
    case free, youtube, shorts

    var title: String {
        switch self {
        case .free: return "Free area"
        case .youtube: return "YouTube (16:9)"
        case .shorts: return "YouTube Shorts (9:16)"
        }
    }

    var ratioName: String? {
        switch self {
        case .free: return nil
        case .youtube: return "16:9"
        case .shorts: return "9:16"
        }
    }

    /// Width over height.
    var aspect: CGFloat? {
        switch self {
        case .free: return nil
        case .youtube: return 16.0 / 9.0
        case .shorts: return 9.0 / 16.0
        }
    }

    /// The standard video size to save at: the largest one the drawn area
    /// fills, and never less than 1080p.
    func outputSize(pixelWidth: CGFloat) -> (width: Int, height: Int)? {
        switch self {
        case .free: return nil
        case .youtube:
            if pixelWidth >= 3840 { return (3840, 2160) }
            if pixelWidth >= 2560 { return (2560, 1440) }
            return (1920, 1080)
        case .shorts:
            return (1080, 1920)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// ScreenCaptureKit only delivers frames to a stream that has an output attached.
private final class FrameSink: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {}
}

extension Recorder: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        Task { @MainActor in self.picked(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                          didCancelFor stream: SCStream?) {
        Task { @MainActor in self.startAfterPick = false }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.startAfterPick = false
            self.message = "Could not open the picker: \(error.localizedDescription)"
        }
    }
}

extension Recorder: SCStreamDelegate, SCRecordingOutputDelegate {
    // The window closed, or sharing was stopped from the menu bar.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.state == .recording else { return }
            self.finish(error: error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput,
                                     didFailWithError error: Error) {
        Task { @MainActor in self.finish(error: error) }
    }
}

// MARK: - UI

/// AppKit's player view. SwiftUI's own VideoPlayer aborts at runtime in a
/// build made without Xcode, because AVKit is never loaded for it.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ContentView: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 0) {
            screen
            Divider()
            controls
        }
        .frame(width: 700)
    }

    private var screen: some View {
        ZStack {
            Color.black
            if recorder.state != .idle, let start = recorder.startedAt {
                TimelineView(.periodic(from: start, by: 0.5)) { context in
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 12, height: 12)
                            Text("Recording").foregroundStyle(.white.opacity(0.8))
                        }
                        Text(Self.clock(context.date.timeIntervalSince(start)))
                            .font(.system(size: 44, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            } else if recorder.state == .finishing {
                ProgressView().controlSize(.large).colorScheme(.dark)
            } else if recorder.lastURL != nil {
                PlayerView(player: recorder.player)
            } else {
                Text(recorder.hasSource
                     ? "Press Record to start."
                     : "Press Record, then pick a screen or a window.")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(height: 394)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Button {
                        recorder.chooseSource()
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .help("Choose a window or a screen to record")
                    .accessibilityLabel("Choose a window or a screen")

                    Menu {
                        ForEach(AreaShape.allCases, id: \.self) { shape in
                            Button(shape.title) { recorder.chooseArea(shape) }
                        }
                    } label: {
                        Image(systemName: "rectangle.dashed")
                    }
                    .fixedSize()
                    .help("Draw an area of the screen to record")
                    .accessibilityLabel("Record an area")
                }
                .disabled(recorder.state != .idle)
                .frame(width: 200, alignment: .leading)

                Spacer(minLength: 0)

                transport("record.circle.fill", "Record", tint: .red,
                          enabled: recorder.state == .idle) { recorder.record() }
                transport("stop.fill", "Stop", tint: .primary,
                          enabled: recorder.state == .recording) { recorder.stop() }
                transport(recorder.isPlaying ? "pause.fill" : "play.fill",
                          recorder.isPlaying ? "Pause" : "Play", tint: .primary,
                          enabled: recorder.state == .idle && recorder.lastURL != nil) {
                    recorder.togglePlay()
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        recorder.newRecording()
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .disabled(recorder.state != .idle || recorder.lastURL == nil)
                    .help("Clear the last recording and start with an empty one (N or Command-N)")
                    // A plain N does the same as Command-N.
                    .background {
                        Button("") { recorder.newRecording() }
                            .keyboardShortcut("n", modifiers: [])
                            .disabled(recorder.state != .idle || recorder.lastURL == nil)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }

                    Button("Show in Finder") { recorder.revealInFinder() }
                        .disabled(recorder.lastURL == nil)
                }
                .frame(width: 200, alignment: .trailing)
            }
            Text(recorder.hasSource ? "Source: \(recorder.sourceName)" : recorder.sourceName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
            if let message = recorder.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
    }

    private func transport(_ symbol: String, _ label: String, tint: Color, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
