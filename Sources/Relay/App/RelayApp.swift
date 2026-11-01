import AppKit
import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var delegate
    @State private var model = RelayModel()

    init() {
        // Older versions saved this frame independently of scene restoration.
        // Discard only the main window's geometry before SwiftUI creates it.
        NSWindow.removeFrame(usingName: "main")
    }

    var body: some Scene {
        // The transcript toolbar is 52 pt tall; onboarding's title bar is 32 pt.
        // Both scenes open with the same 300 pt total window height.
        let contentHeight: CGFloat = model.permissions.canCreateConversation ? 248 : 268
        Window("Relay", id: "main") {
            Group {
                if model.permissions.canCreateConversation {
                    RelayWindow(model: model)
                } else {
                    RelayPermissionOnboarding(permissions: model.permissions)
                }
            }
                .frame(minWidth: 740, minHeight: contentHeight)
                .onAppear { delegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.permissions.refresh()
                }
                .onChange(of: model.permissions.isReady) { _, ready in
                    if !ready { model.handlePermissionRevocation() }
                }
                .onChange(of: model.service.state) { _, _ in
                    model.permissions.refresh()
                    if model.permissions.isReady { model.handleServiceFailure() }
                    else { model.handlePermissionRevocation() }
                }
                .background(WindowCapture { delegate.mainWindow = $0 }.frame(width: 0, height: 0))
        }
        .defaultSize(width: 740, height: contentHeight)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            let display = context.defaultDisplay
            return WindowPlacement(
                CGPoint(x: display.bounds.midX - 370, y: display.visibleRect.minY),
                size: CGSize(width: 740, height: contentHeight))
        }
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .appSettings) { }
            CommandGroup(replacing: .newItem) {
                Button("New Relay", systemImage: "square.and.pencil") { model.newSession() }
                    .keyboardShortcut("n")
                    .disabled(!model.canRequestNewSession)
                Button("Open…", systemImage: "folder") { model.chooseTranscript() }
                    .keyboardShortcut("o")
                    .disabled(!model.permissions.canCreateConversation)
            }
            CommandMenu("Transcription") {
                Button(transcriptionActionTitle) {
                    if model.isSelectedPreparing {
                        Task { await model.endSession() }
                    } else {
                        model.toggleRecording()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canToggleRecording)
                Divider()
                Button("Copy Transcript", systemImage: "doc.on.doc") { model.copyTranscript() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
                Button("Export Transcript…", systemImage: "square.and.arrow.up") { model.exportTranscript() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!model.canExport)
            }
        }
    }

    private var transcriptionActionTitle: String {
        if model.isSelectedPreparing { return "Cancel Transcription" }
        if model.isSelectedPausing { return "Pausing Transcription…" }
        if model.isSelectedStopping { return "Finishing Transcription…" }
        if model.isSelectedRecording { return "Pause Transcription" }
        return model.selectedSession == nil ? "Start Transcription" : "Resume Transcription"
    }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RelayModel? {
        didSet {
            guard let model else { return }
            for url in pendingOpenURLs { model.openTranscript(at: url) }
            pendingOpenURLs.removeAll()
        }
    }
    private var pendingOpenURLs: [URL] = []

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let model else { pendingOpenURLs.append(contentsOf: urls); return }
        for url in urls { model.openTranscript(at: url) }
        mainWindow?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
    }
    // Retain the main window so a failed save or cancelled quit can restore it
    // even when termination was triggered by closing its final window.
    var mainWindow: NSWindow?
    private var terminationPending = false


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        guard model.requiresTerminationWork else { return .terminateNow }
        if model.isBusy && !model.isStopping {
            let alert = NSAlert()
            alert.messageText = "Pause this Relay and quit?"
            alert.informativeText = "Relay will save the transcript before quitting. You can resume it later."
            alert.addButton(withTitle: "Pause and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                mainWindow?.makeKeyAndOrderFront(nil)
                return .terminateCancel
            }
        }
        terminationPending = true
        Task {
            let saved = await model.prepareToQuit()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: saved)
            if !saved {
                mainWindow?.makeKeyAndOrderFront(nil)
                sender.activate(ignoringOtherApps: true)
                if model.notice == nil {
                    model.notice = RelayNotice(title: "Transcript hasn’t been saved",
                        message: "Your transcript is still available in Relay. Export a copy or try saving again before quitting.")
                }
            }
        }
        return .terminateLater
    }
}

private struct WindowCapture: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowCaptureView { WindowCaptureView(onWindow: onWindow) }
    func updateNSView(_ nsView: WindowCaptureView, context: Context) { }
}

private final class WindowCaptureView: NSView {
    let onWindow: @MainActor (NSWindow) -> Void
    init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow(window)
        }
    }
}
