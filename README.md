# Relay

Relay transcribes audio playing on your Mac and speech from your microphone into a live, selectable transcript. Select any passage to copy the spoken words automatically; the clipboard keeps updating while you drag. Only spoken words are highlighted and copied; source labels and timestamps remain visible as context. Pause a Relay to copy the full transcript or export it as plain text or Markdown, retaining source labels and timestamps. Saved Relays can be resumed later.

## Using Relay

On first launch, Relay requests microphone and system-audio access and opens the relevant macOS Privacy settings when access needs to be enabled. Setup remains visible until both permissions are granted. Apple groups system-audio access under **Screen & System Audio Recording**; Relay consumes audio, without receiving or saving screen frames.

1. Choose **System audio**, **Microphone**, or both.
2. Choose a language. English is selected initially; your choice becomes the starting language for the next new Relay. **Auto Detect** identifies the initial spoken language from the audio; it does not continuously switch between languages during a session.
3. Click **Start Transcription**.
4. Select text at any point to copy it. Keep dragging to update the clipboard before releasing the mouse. A brief **Copied** confirmation appears when you release the mouse, then fades away.
5. Click **Pause** to stop capture and save the transcript. Click **Resume** to continue in the same file. The timer counts captured time, excluding preparation and pauses; a new Relay starts at **00:00** when capture is ready, and a resumed Relay continues from its saved duration.
6. Use **Copy Transcript** or **Export Transcript** in the toolbar to copy or export a paused or saved transcript.

Live transcripts follow the latest words, including while Relay is in the background. Scroll up to read earlier text without being pulled back down. Click the downward arrow, **Jump to Latest**, or scroll back to the bottom to resume following. Text stays steady while you select a passage.

Choose **Audio Sources** in a transcript’s toolbar to change the inputs for that file. Each file remembers its own selection. Applying a change while recording briefly pauses capture, saves the transcript, and continues in the same file. A paused or completed transcript uses the updated sources when resumed. Source changes apply to new audio; audio from an input that was previously disabled cannot be recovered.

Choose a language in the transcript’s toolbar to change recognition for that conversation. Each file remembers its language when reopened or resumed. A language change while recording saves the current words and continues in the same file with the new language; it applies to new speech. Toolbar changes preserve the starting language selected for future new Relays.

Choose **New Relay** or press **⌘N** to prepare another file. While recording, Relay offers **Pause and Create New** or **Cancel**. A paused transcript is saved before the next file opens. Paused and saved Relays remain available in the sidebar and can be resumed. To resume a different Relay while recording, select it and click **Resume**, then choose **Pause and Resume** to save and pause the current recording before switching. **Cancel** keeps the current recording running. If the current Relay is already paused, the selected Relay resumes directly.

Swipe left on a sidebar transcript to reveal **Rename** and **Delete**, or use its context menu. Deletion moves its file to the Trash, whether it is recording, paused, or saved. Deleting the recording transcript stops its capture; deleting another transcript leaves the current recording running.

Speaker echo reduction processes the microphone input to reduce playback picked up from the speakers, including when **Microphone** is the only selected source. It uses system audio locally as a cancellation reference; only selected sources are transcribed. Echo reduction and automatic selection copying are built into Relay. Relay reconnects the microphone when audio devices change. If no microphone is available, microphone capture waits while system audio continues. The source labels identify the audio input, rather than individual speakers.

## Files and privacy

Relay automatically creates its folder in **iCloud Drive** and uses it as the default location for `.relay` transcript files. Files can be renamed, moved, and reopened in Relay from Finder or **File → Open**. If iCloud Drive is unavailable, Relay uses its local folder, shown as **On My Mac**. Click the folder location at the bottom of the sidebar to open it in Finder.

Speech recognition and language detection run on the Mac. Audio exists in memory during transcription and is not saved. Language models may download before their first use. Transcript files follow the storage location you choose, including iCloud Drive; Relay has no service that receives your recordings or transcripts.

If Auto Detect cannot confidently identify the opening speech, select a language and start again. Choosing a language directly avoids the detection step and can start more quickly.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New Relay | ⌘N |
| Open a transcript | ⌘O |
| Start, pause, or resume transcription | ⌘R |
| Copy the full transcript | ⇧⌘C |
| Export a transcript | ⌘E |

## Development

Open `Relay.xcodeproj` in Xcode. The project contains the Mac app, Swift Testing unit tests, and XCTest interface tests. Development uses Xcode 27.1 and Swift 6; the application targets macOS 26 or later and requires a Mac supported by Apple's on-device SpeechTranscriber.

The approved layered icon lives in `Design/Relay.icon`. Xcode compiles it directly for the application. `Design/Relay.png` is its preview.

Build and test with:

```sh
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' build
xcodebuild -project Relay.xcodeproj -scheme Relay -destination 'platform=macOS' test
```

The **Relay Audio Integration** scheme enables the integration suite with `RELAY_AUDIO_INTEGRATION=1` in the test-process environment. It uses fictional synthesized English and Spanish fixtures, exercises the real on-device recognizers and language detector, and may download language models. It does not open the microphone or capture the computer's audio. Interface tests use a separate temporary library and fictional transcripts.

The mouse-release feedback interface test posts native drag events and runs when its test runner already has macOS event-posting access; otherwise XCTest reports it as skipped.

The **Relay Microphone Integration** scheme explicitly enables physical microphone checks with `RELAY_MICROPHONE_INTEGRATION=1`. It requires microphone permission and an available input device. These checks exercise the native audio engine and configuration recovery, observing buffer counts and timing without recording audio or saving a transcript. A spoken fixture also checks live labels and confirmed word timing through the actual speakers and microphone, with both sources and echo reduction enabled. It does not change system volume. The service lifecycle check also requires existing system-audio permission and exercises repeated switches among both sources, microphone only, and system audio only. Readiness requires actual microphone buffers. The capture service reuses one paused raw-microphone graph across source combinations. Speaker echo cancellation runs separately with an explicit system-audio reference. Run this scheme separately from interface tests.

The app uses Apple's Speech, ScreenCaptureKit, AVFoundation, SwiftUI, and AppKit frameworks. Automatic language detection uses the multilingual Whisper model through the vendored **Argmax OSS Swift 1.1.1** libraries. The local package is in `Dependencies/Argmax`, with its license, notices, release source, and archive checksum. The app bundles those acknowledgments as well.

Speaker echo reduction uses WebRTC AEC3 through the local `Dependencies/RelayAEC` package. It processes 10 ms frames of raw microphone audio against the system-audio reference, with bounded in-memory buffering for capture timing differences. The adapter preserves microphone timestamps and drains the final audio before recognition finishes. Processing happens before microphone transcription and automatic language detection; transcript text is not deduplicated or filtered. The package includes pinned sources, checksums, licenses, and a reproducible universal Mac build script.

Unfinished phrases show **Live** and stay at the current end of the transcript. Once recognition confirms a phrase and its word timing, Relay displays its timestamp and places it chronologically. This avoids treating the recognizer's provisional analysis range, which can include earlier silence, as an exact word time. Source-local activity estimates remain internal; they do not filter audio or recognized words. If an interrupted phrase has no confirmed timing, its words are preserved without displaying an invented timestamp.

The **Relay Echo Integration** scheme is a native voice-I/O diagnostic, separate from the app’s AEC3 processing path. It enables `RELAY_ECHO_INTEGRATION=1` for a physical speaker-processing comparison. It plays the bundled fictional fixture and compares bypassed, processed, and resumed capture using energy and count metadata only. Run it with Standard Mic Mode, an audible speaker output, and a quiet room; do not run other audio tests concurrently. It does not save microphone samples. Background noise must remain stable for the energy comparison to be meaningful. Use separate speaker-playback and near-end speech checks to verify transcription and source attribution in the production configuration.
