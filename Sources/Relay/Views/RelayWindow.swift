import AppKit
import SwiftUI

struct RelayWindow: View {
    @Bindable var model: RelayModel
    @State private var renaming: TranscriptSession?
    @State private var newTitle = ""
    @State private var deleting: TranscriptSession?
    @State private var audioSourcesRequest: AudioSourcesRequest?
    @State private var presentedNewSessionPrompt: NewSessionPrompt?
    @State private var presentedResumeSessionPrompt: ResumeSessionPrompt?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectionCopiedLocation: CGPoint?
    @State private var selectionFeedbackTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 195, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let session = model.selectedSession {
                    transcript(session)
                } else {
                    startView
                }
            }
            .background(.background)
            .navigationTitle("Relay")
            .toolbar {
                sessionControls
                if model.selectedSession != nil {
                    ToolbarItem(placement: .primaryAction) { audioSourcesControl }
                    ToolbarItem(placement: .primaryAction) { conversationLanguageControl }
                }
                if model.canExport {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Copy Transcript", systemImage: "doc.on.doc", action: model.copyTranscript)
                            .help("Copy the full transcript (⇧⌘C)")
                            .accessibilityIdentifier("relay.copyTranscript")
                        Menu {
                            Button("Plain Text (.txt)") { model.exportTranscript() }
                            Button("Markdown (.md)") { model.exportTranscript(markdown: true) }
                        } label: { Label("Export Transcript", systemImage: "square.and.arrow.up") }
                        .menuIndicator(.hidden)
                        .help("Export the full transcript")
                        .accessibilityIdentifier("relay.exportTranscript")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.newSessionPrompt) { _, prompt in
            presentedNewSessionPrompt = prompt
        }
        .onChange(of: model.resumeSessionPrompt) { _, prompt in
            presentedResumeSessionPrompt = prompt
        }
        .onChange(of: model.selectedID) { _, selectedID in
            clearSelectionFeedback()
            if let request = audioSourcesRequest, selectedID != request.sessionID, !model.isChangingSources {
                audioSourcesRequest = nil
            }
        }
        .onDisappear(perform: clearSelectionFeedback)
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $renaming) { session in
            VStack(alignment: .leading, spacing: 20) {
                Text("Rename Transcript").font(.headline)
                TextField("Transcript name", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.rename(session, to: newTitle); renaming = nil }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { renaming = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { model.rename(session, to: newTitle); renaming = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
        .confirmationDialog("Delete this transcript?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            if let session = deleting {
                Button("Delete Transcript", role: .destructive) { model.delete(session); deleting = nil }
            }
        } message: {
            if let session = deleting, session.id == model.activeID, !model.isPaused {
                Text("Transcription will stop, and the file will be moved to the Trash.")
            } else {
                Text("The transcript file will be moved to the Trash.")
            }
        }
    }

    private enum SessionControlState { case none, preparing, finishing, recording, paused, completed }

    private var sessionControlState: SessionControlState {
        if model.isSelectedPreparing { return .preparing }
        if model.isSelectedStopping { return .finishing }
        if model.isSelectedRecording { return .recording }
        if model.isSelectedPaused { return .paused }
        if model.selectedSession?.endedAt != nil { return .completed }
        return .none
    }

    @ToolbarContentBuilder
    private var sessionControls: some ToolbarContent {
        if sessionControlState == .preparing { preparationToolbar }
        if sessionControlState == .finishing { finishingToolbar }
        if sessionControlState == .recording { recordingToolbar }
        if sessionControlState == .paused { pausedToolbar }
        if sessionControlState == .completed { completedToolbar }
    }

    private var preparationToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { cancelControl }
    }

    private var finishingToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { finishingControl }
    }

    private var recordingToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { pauseControl }
    }

    private var pausedToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { resumeControl }
    }

    private var completedToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { resumeControl }
    }

    private func transportLabel(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .labelStyle(.iconOnly)
    }

    private var cancelControl: some View {
        Button {
            Task { _ = await model.endSession() }
        } label: {
            transportLabel("Cancel", symbol: "xmark")
        }
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .help("Cancel preparation")
        .accessibilityIdentifier("relay.cancelPreparation")
    }

    private var finishingControl: some View {
        Button(action: { }) {
            transportLabel(finishingTitle, symbol: finishingSymbol)
        }
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .disabled(true)
        .help(finishingTitle)
        .accessibilityIdentifier("relay.finishing")
    }

    private var finishingTitle: String { model.isSelectedPausing ? "Pausing…" : "Finishing…" }
    private var finishingSymbol: String { model.isSelectedPausing ? "pause.fill" : "hourglass" }

    private var pauseControl: some View {
        Button {
            Task { _ = await model.pauseSession() }
        } label: {
            transportLabel("Pause", symbol: "pause.fill")
        }
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .disabled(!model.canPauseSelectedSession)
        .help("Pause transcription (⌘R). Resume to continue in the same file.")
        .accessibilityIdentifier("relay.pause")
    }

    private var resumeControl: some View {
        Button(action: model.resumeSelectedSession) {
            transportLabel("Resume", symbol: "play.fill")
        }
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .disabled(!model.canResumeSelectedSession)
        .help("Resume this transcription in the same file (⌘R)")
        .accessibilityIdentifier("relay.resume")
        .alert(item: $presentedResumeSessionPrompt) { prompt in
            Alert(title: Text("Resume this Relay?"),
                  message: Text("“\(prompt.activeTitle)” is recording. Pause it to resume “\(prompt.targetTitle)”."),
                  primaryButton: .default(Text("Pause and Resume")) {
                      Task { _ = await model.confirmResumeSessionRequest(prompt.id) }
                  }, secondaryButton: .cancel(Text("Cancel")) {
                      model.cancelResumeSessionRequest(prompt.id)
                  })
        }
    }

    private var audioSourcesControl: some View {
        Button(action: showAudioSources) {
            transportLabel("Audio Sources", symbol: "waveform")
        }
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .disabled(!model.canEditSelectedSources)
        .help(model.canEditSelectedSources ? "Choose audio sources for this transcript" : "Audio sources can be changed when transcription is ready.")
        .accessibilityLabel("Audio Sources")
        .accessibilityIdentifier("relay.audioSources")
        .popover(item: $audioSourcesRequest, arrowEdge: .top) { request in
            AudioSourcesEditor(request: request,
                               canEdit: model.canEditSelectedSources && model.selectedID == request.sessionID,
                               apply: { requestedSources in
                                   guard model.selectedID == request.sessionID else { return false }
                                   return await model.updateSelectedSources(requestedSources)
                               },
                               close: { audioSourcesRequest = nil })
        }
    }

    private func showAudioSources() {
        guard model.canEditSelectedSources, let session = model.selectedSession else { return }
        audioSourcesRequest = AudioSourcesRequest(sessionID: session.id, initialSources: session.sources,
                                                 wasRecording: model.isSelectedRecording)
    }

    private var conversationLanguageControl: some View {
        Menu {
            Picker("Language", selection: Binding(
                get: { model.selectedLanguageID ?? "en-US" },
                set: { language in
                    guard let sessionID = model.selectedID else { return }
                    Task {
                        guard model.selectedID == sessionID else { return }
                        _ = await model.updateSelectedLanguage(language)
                    }
                }
            )) {
                RelayLanguageOptions(languages: model.supportedLanguages, languageName: model.languageName)
            }
            .pickerStyle(.inline)
        } label: {
            transportLabel("Language", symbol: "character.bubble")
        }
        .menuIndicator(.hidden)
        .disabled(!model.canEditSelectedLanguage)
        .help("Transcription language: \(model.languageName(model.selectedLanguageID ?? "en-US"))")
        .accessibilityLabel("Transcription language")
        .accessibilityValue(model.selectedLanguageID ?? "en-US")
        .accessibilityIdentifier("relay.conversationLanguage")
    }

    private func newSessionAlert(_ prompt: NewSessionPrompt) -> Alert {
        let message = "“\(prompt.title)” is still recording. Pause it to create a new relay. The transcript will be saved."
        return Alert(title: Text("Pause the current relay?"), message: Text(message),
                     primaryButton: .default(Text("Pause and Create New")) {
                         Task { _ = await model.confirmNewSessionRequest(prompt.id) }
                     },
                     secondaryButton: .cancel(Text("Cancel"), action: model.cancelNewSessionRequest))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcripts").font(.headline)
                Spacer()
                Button(action: model.newSession) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New Relay (⌘N)")
                    .disabled(!model.canRequestNewSession)
                    .accessibilityLabel("New Relay")
                    .accessibilityIdentifier("relay.newSession")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)

            List(selection: $model.selectedID) {
                ForEach(model.filteredSessions) { session in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if session.id == model.activeID && !model.isPaused {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                    .accessibilityLabel("Recording")
                            }
                            Text(session.displayTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(session.segments.first?.text ?? (session.endedAt == nil ? "Listening for speech…" : "No speech transcribed"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename…") { newTitle = session.displayTitle; renaming = session }
                        Button("Delete…", role: .destructive) { deleting = session }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { deleting = session } label: {
                            Label {
                                Text("Delete")
                            } icon: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(.red)
                        .help("Delete transcript")
                        .accessibilityIdentifier("relay.swipe.delete")
                        Button { newTitle = session.displayTitle; renaming = session } label: {
                            Label {
                                Text("Rename")
                            } icon: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .medium))
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(.gray)
                        .help("Rename transcript")
                        .accessibilityIdentifier("relay.swipe.rename")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollIndicators(.never)
            .searchable(text: $model.search, prompt: "Search transcripts")
            .accessibilityIdentifier("relay.sessionList")
            .overlay {
                if model.isLoaded && model.sessions.isEmpty {
                    Text("Your transcripts will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else if !model.search.isEmpty && model.filteredSessions.isEmpty {
                    Text("No matching transcripts")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button(action: model.revealStorageFolder) {
                    Label(model.storageDescription, systemImage: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the Relay folder in Finder")
                Spacer()
            }
            .padding(14)
        }
        .alert(item: $presentedNewSessionPrompt, content: newSessionAlert)
    }

    private var startView: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(alignment: .trailing, spacing: 24) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                            GridRow {
                                Text("Audio sources")
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                HStack(spacing: 18) {
                                    ForEach(TranscriptSource.allCases, id: \.self) { source in
                                        Toggle(source.displayName, isOn: Binding(
                                            get: { model.sources.contains(source) },
                                            set: { _ in model.toggleSource(source) }))
                                            .toggleStyle(.checkbox)
                                            .fixedSize()
                                            .accessibilityIdentifier("relay.source.\(source.rawValue)")
                                            .help(source == .microphone
                                                  ? "Transcribe speech captured by your microphone."
                                                  : "Transcribe audio playing on your Mac.")
                                    }
                                }
                                .frame(minHeight: 26)
                            }
                            GridRow {
                                Text("Language")
                                    .foregroundStyle(.secondary)
                                RelayLanguagePicker(model: model)
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .fixedSize()
                            }
                        }
                        .font(.system(size: 13))
                        .controlSize(.regular)

                        Button("Start Transcription", action: model.toggleRecording)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.canToggleRecording)
                            .accessibilityIdentifier("relay.start")
                    }
                    .disabled(model.isBusy)
                    .frame(maxWidth: 380)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.never)
        }
    }

    private func transcript(_ session: TranscriptSession) -> some View {
        VStack(spacing: 0) {
            if model.isShowingLive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("Live Transcription")
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.3)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 7) {
                                Circle().fill(model.isSelectedRecording ? .red : .secondary).frame(width: 6, height: 6)
                                Text(model.isSelectedPreparing ? "Preparing…" : model.isSelectedPausing ? "Pausing…" : model.isSelectedStopping ? "Finishing…" :
                                    TranscriptFormatting.timeLabel(model.duration(for: session, at: context.date)))
                                    .monospacedDigit()
                                    .accessibilityIdentifier("relay.elapsedTime")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        Spacer(minLength: 8)
                        if model.service.isRunning && model.isSelectedRecording {
                            AudioLevelView(level: model.service.level)
                        }
                    }
                    .frame(minHeight: 25)
                    if let status = model.service.statusMessage, model.isSelectedRecording,
                       !session.segments.isEmpty {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(status)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                        .lineLimit(1)
                        .help(session.displayTitle)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(session.startedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                        Text("·")
                        Text(TranscriptFormatting.timeLabel(session.duration)).monospacedDigit()
                        Spacer()
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
            }
            Divider()
            transcriptContent(session)
        }
    }

    private func transcriptContent(_ session: TranscriptSession) -> some View {
        Group {
            if session.segments.isEmpty {
                VStack(spacing: 14) {
                    if model.isSelectedPreparing || model.isSelectedStopping { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isSelectedPaused ? "pause.circle" : "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor) }
                    Text(emptyTranscriptMessage(session))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptTextView(attributedText: TranscriptPresentation.attributedText(for: session),
                                   autoCopySelection: model.autoCopySelection,
                                   followsTail: model.isShowingLive,
                                   sessionID: session.id,
                                   onSelectionStarted: clearSelectionFeedback,
                                   onSelectionCopied: showSelectionCopied)
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if model.toast == nil, let location = selectionCopiedLocation {
                    CopyFeedbackBadge(title: "Copied", width: 92)
                        .accessibilityIdentifier("relay.selectionCopied")
                        .position(selectionFeedbackPosition(near: location, in: geometry.size))
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if let toast = model.toast {
                CopyFeedbackBadge(title: toast)
                    .accessibilityIdentifier("relay.transcriptToast")
                    .padding(16)
                    .transition(reduceMotion ? .identity : .opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func selectionFeedbackPosition(near location: CGPoint, in viewport: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 46
        let halfHeight: CGFloat = 17
        let margin: CGFloat = 12
        let above = location.y - margin - halfHeight
        let preferredY = above >= margin + halfHeight ? above : location.y + margin + halfHeight
        let minX = margin + halfWidth
        let maxX = viewport.width - margin - halfWidth
        let minY = margin + halfHeight
        let maxY = viewport.height - margin - halfHeight
        return CGPoint(x: maxX < minX ? viewport.width / 2 : min(max(location.x + margin + halfWidth, minX), maxX),
                       y: maxY < minY ? viewport.height / 2 : min(max(preferredY, minY), maxY))
    }

    private func showSelectionCopied(at location: CGPoint) {
        selectionFeedbackTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            selectionCopiedLocation = location
        }
        selectionFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1500))
                try Task.checkCancellation()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    selectionCopiedLocation = nil
                }
            } catch { }
        }
    }

    private func clearSelectionFeedback() {
        selectionFeedbackTask?.cancel()
        selectionFeedbackTask = nil
        selectionCopiedLocation = nil
    }

    private func emptyTranscriptMessage(_ session: TranscriptSession) -> String {
        if model.isSelectedPaused { return "Resume to continue this transcription." }
        if model.isShowingLive {
            return model.service.statusMessage ?? (model.isSelectedPreparing ? "Preparing…" : "Listening for speech…")
        }
        return "No speech was transcribed."
    }

}

/// One presentation path keeps the native live surface and its regression
/// coverage consistent about provisional and confirmed timing.
@MainActor
enum TranscriptPresentation {
    static func attributedText(for session: TranscriptSession) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, segment) in session.segments.enumerated() {
            let header = NSMutableParagraphStyle()
            header.paragraphSpacing = 7
            header.paragraphSpacingBefore = index == 0 ? 0 : 24
            result.append(NSAttributedString(string: "\(segment.metadataLabel)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: header,
                .relayTranscriptMetadata: true,
                .relayTranscriptSegmentID: segment.id.uuidString
            ]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 0
            result.append(NSAttributedString(string: segment.text + (index == session.segments.count - 1 ? "" : "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 17),
                .foregroundColor: segment.isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
                .relayTranscriptSegmentID: segment.id.uuidString
            ]))
        }
        return result
    }
}

/// System glass keeps transient confirmation legible over either appearance
/// without reserving space in the transcript or intercepting text selection.
private struct CopyFeedbackBadge: View {
    let title: String
    var width: CGFloat?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 13)
        .frame(width: width, height: 34)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private struct AudioSourcesRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let initialSources: Set<TranscriptSource>
    let wasRecording: Bool
}

/// Each presentation owns its draft from the immutable request. An item-driven
/// popover avoids presenting an old draft before several parent states update.
private struct AudioSourcesEditor: View {
    let request: AudioSourcesRequest
    let canEdit: Bool
    let apply: @MainActor (Set<TranscriptSource>) async -> Bool
    let close: @MainActor () -> Void
    @State private var draftSources: Set<TranscriptSource>
    @State private var isApplying = false

    init(request: AudioSourcesRequest, canEdit: Bool,
         apply: @escaping @MainActor (Set<TranscriptSource>) async -> Bool,
         close: @escaping @MainActor () -> Void) {
        self.request = request
        self.canEdit = canEdit
        self.apply = apply
        self.close = close
        _draftSources = State(initialValue: request.initialSources)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio Sources").font(.headline)
            VStack(alignment: .leading, spacing: 13) {
                ForEach(TranscriptSource.allCases, id: \.self) { source in
                    Toggle(isOn: sourceBinding(source)) {
                        Label(source.displayName, systemImage: source.systemImage)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("relay.editSource.\(source.rawValue)")
                }
            }
            .disabled(isApplying)
            VStack(alignment: .leading, spacing: 6) {
                Text("Changes apply to new audio.")
                if request.wasRecording {
                    Text("Transcription pauses briefly while the sources change.")
                }
                if draftSources.isEmpty {
                    Text("Select at least one audio source.")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            if isApplying {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Updating audio sources…").font(.system(size: 12))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                    .accessibilityIdentifier("relay.sources.cancel")
                Button("Apply", action: applySources)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isApplying || draftSources.isEmpty || !canEdit)
                    .accessibilityIdentifier("relay.sources.apply")
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .interactiveDismissDisabled(isApplying)
    }

    private func sourceBinding(_ source: TranscriptSource) -> Binding<Bool> {
        Binding(get: { draftSources.contains(source) }, set: { selected in
            if selected { draftSources.insert(source) } else { draftSources.remove(source) }
        })
    }

    private func applySources() {
        guard !isApplying, !draftSources.isEmpty, canEdit else { return }
        let requestedSources = draftSources
        isApplying = true
        Task {
            _ = await apply(requestedSources)
            isApplying = false
            close()
        }
    }
}

struct RelayLanguagePicker: View {
    @Bindable var model: RelayModel
    var body: some View {
        Picker("Language", selection: $model.defaultLanguageID) {
            RelayLanguageOptions(languages: model.supportedLanguages, languageName: model.languageName)
        }
        .accessibilityIdentifier("relay.language")
        .disabled(model.isBusy)
    }
}

private struct RelayLanguageOptions: View {
    let languages: [Locale]
    let languageName: (String) -> String

    var body: some View {
        ForEach(languages, id: \.identifier) { locale in
            Text(languageName(locale.identifier))
                .tag(locale.identifier.replacingOccurrences(of: "_", with: "-"))
        }
        Divider()
        Text("Auto Detect").tag("auto")
    }
}

private struct AudioLevelView: View {
    let level: Double
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule().fill(Color.accentColor)
                    .frame(width: 3, height: 3 + CGFloat(level) * CGFloat([8, 13, 18, 22, 16, 11, 7][index]))
            }
        }
        .frame(width: 39, height: 25)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
