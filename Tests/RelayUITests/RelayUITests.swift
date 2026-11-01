import AppKit
import ApplicationServices
import CoreGraphics
import XCTest

/// UI checks use an isolated, fictional transcript library. They do not start
/// audio capture, request permissions, or access the user's saved sessions.
@MainActor
final class RelayUITests: XCTestCase {
    private func launch(fixture: Bool = false, fixtureState: String? = nil,
                        history: Bool = false, permissionsFixture: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["RELAY_UI_TESTING"] = "1"
        if fixture { app.launchEnvironment["RELAY_FIXTURE"] = "1" }
        if fixture, let fixtureState { app.launchEnvironment["RELAY_FIXTURE_STATE"] = fixtureState }
        if fixture, history { app.launchEnvironment["RELAY_FIXTURE_HISTORY"] = "1" }
        if let permissionsFixture { app.launchEnvironment["RELAY_PERMISSIONS_FIXTURE"] = permissionsFixture }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        activateMainWindow(in: app)
        return app
    }

    @discardableResult
    private func activateMainWindow(in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        app.activate()
        // Use the normal Launch Services open event for the test-hosted app,
        // so a running process with no presented scene exposes its main window.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.asherbloom.Relay").first,
           let url = running.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                      "Relay must be foreground before native interface interaction.", file: file, line: line)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), file: file, line: line)
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed,
                       "The real main window must be visible in the current Space before interaction.", file: file, line: line)
        return window
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func transcript(in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(identifier: "relay.transcript").firstMatch
    }

    private func isChecked(_ checkbox: XCUIElement) -> Bool {
        if let value = checkbox.value as? String { return value == "1" || value.lowercased() == "on" }
        if let value = checkbox.value as? NSNumber { return value.boolValue }
        return checkbox.isSelected
    }

    private func chooseMenuItem(_ title: String, from control: XCUIElement, in app: XCUIApplication,
                                keyboardPrefix: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(control.isEnabled, file: file, line: line)
        control.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line)
        if let keyboardPrefix {
            // Native menu type-selection avoids a moving hit point when the
            // last item in a long language list scrolls during activation.
            app.typeText(keyboardPrefix)
            app.typeKey(.return, modifierFlags: [])
        } else {
            item.click()
        }
    }

    private func assertConversationLanguage(_ identifier: String, in window: XCUIElement,
                                            file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let control = window.descendants(matching: .any).matching(identifier: "relay.conversationLanguage").firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", identifier), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed, file: file, line: line)
        return control
    }

    private func verifyPermissionOnboarding(fixture: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(permissionsFixture: fixture)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let onboarding = window.descendants(matching: .any).matching(identifier: "relay.permissions.onboarding").firstMatch
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertFalse(window.buttons["relay.start"].exists, file: file, line: line)
        XCTAssertFalse(window.textViews["relay.transcript"].exists, file: file, line: line)

        app.menuBars.menuBarItems["File"].click()
        let newRelay = app.menuItems["New Relay"].firstMatch
        let open = app.menuItems["Open…"].firstMatch
        XCTAssertTrue(newRelay.exists && !newRelay.isEnabled,
                      "The native New command remains gated while access is missing.", file: file, line: line)
        XCTAssertTrue(open.exists && !open.isEnabled, file: file, line: line)
        window.typeKey(.escape, modifierFlags: [])
        window.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(onboarding.exists, file: file, line: line)
        XCTAssertFalse(window.buttons["relay.start"].exists, file: file, line: line)

        // These are explicit fictional grants supplied by the DEBUG provider;
        // neither action can open System Settings or a native TCC prompt.
        let microphone = window.buttons["relay.permissions.microphone"]
        let systemAudio = window.buttons["relay.permissions.systemAudio"]
        XCTAssertTrue(microphone.isEnabled && systemAudio.isEnabled, file: file, line: line)
        microphone.click()
        XCTAssertTrue(onboarding.exists, "One grant cannot bypass the remaining required access.", file: file, line: line)
        XCTAssertFalse(window.buttons["relay.start"].exists, file: file, line: line)
        XCTAssertTrue(systemAudio.isEnabled, file: file, line: line)
        systemAudio.click()
        XCTAssertTrue(onboarding.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(window.buttons["relay.start"].isEnabled, file: file, line: line)
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "relay.language").firstMatch.exists,
                      file: file, line: line)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New Relay"].firstMatch.isEnabled, file: file, line: line)
        XCTAssertTrue(app.menuItems["Open…"].firstMatch.isEnabled, file: file, line: line)
        window.typeKey(.escape, modifierFlags: [])
    }

    private func selectTranscript(_ title: String, in app: XCUIApplication) {
        let library = element("relay.sessionList", in: app)
        let item = library.staticTexts[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The saved transcript remains in the library.")
        item.click()
    }

    private func assertResumeConfirmation(in window: XCUIElement,
                                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(sheet.staticTexts["Resume this Relay?"].exists, file: file, line: line)
        let bothFiles = NSPredicate(
            format: "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)",
            "“Design Review”", "“Design Review”", "“Project Notes”", "“Project Notes”")
        XCTAssertTrue(sheet.staticTexts.matching(bothFiles).firstMatch.exists,
                      "The confirmation names the recording that will pause and the file that will resume.",
                      file: file, line: line)
        XCTAssertTrue(sheet.buttons["Pause and Resume"].exists, file: file, line: line)
        XCTAssertTrue(sheet.buttons["Cancel"].exists, file: file, line: line)
        return sheet
    }

    private func assertNoSaveError(in window: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let sheet = window.sheets.firstMatch
        let saveError = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "Transcript couldn’t be saved", "Transcript couldn’t be saved")
        XCTAssertFalse(sheet.staticTexts.matching(saveError).firstMatch.exists,
                       "Applying audio sources must not leave a save error alert.", file: file, line: line)
        XCTAssertFalse(sheet.exists, "Applying audio sources should finish without an error sheet.", file: file, line: line)
    }

    private func openDeleteConfirmation(for title: String, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let window = app.windows.firstMatch
        let library = window.descendants(matching: .any).matching(identifier: "relay.sessionList").firstMatch
        let row = library.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        row.rightClick()
        let delete = app.menuItems["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5),
                      "Every transcript offers Delete, including the recording or paused file.", file: file, line: line)
        XCTAssertTrue(delete.isEnabled, file: file, line: line)
        delete.click()
        // Restrict destructive actions to the real window, excluding virtual
        // Touch Bar controls with matching labels.
        let confirm = window.buttons["Delete Transcript"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(confirm.isEnabled, file: file, line: line)
        return confirm
    }

    private func verifySelectedTranscriptCanBeDeleted(fixtureState: String?,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(fixture: true, fixtureState: fixtureState, history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), file: file, line: line)
        if fixtureState == "recording" {
            XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5), file: file, line: line)
        } else {
            XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5), file: file, line: line)
        }
        let library = window.descendants(matching: .any).matching(identifier: "relay.sessionList").firstMatch
        let deletedRow = library.staticTexts["Design Review"].firstMatch
        let confirm = openDeleteConfirmation(for: "Design Review", in: app, file: file, line: line)
        let explanation = fixtureState == "recording"
            ? "Transcription will stop, and the file will be moved to the Trash."
            : "The transcript file will be moved to the Trash."
        let message = NSPredicate(format: "label == %@ OR value == %@", explanation, explanation)
        XCTAssertTrue(window.staticTexts.matching(message).firstMatch.exists, file: file, line: line)
        if fixtureState == "recording" {
            let beforeCancel = text.value as? String
            window.buttons["Cancel"].firstMatch.click()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), file: file, line: line)
            XCTAssertTrue(window.buttons["relay.pause"].isEnabled,
                          "Canceling deletion must not pause the recording.", file: file, line: line)
            XCTAssertEqual(text.value as? String, beforeCancel, file: file, line: line)
            openDeleteConfirmation(for: "Design Review", in: app, file: file, line: line).click()
        } else {
            confirm.click()
        }
        XCTAssertTrue(deletedRow.waitForNonExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10),
                      "Deleting the selected file releases its recording controls and returns to Ready.", file: file, line: line)
        XCTAssertFalse(window.buttons["relay.pause"].exists, file: file, line: line)
        XCTAssertFalse(window.sheets.firstMatch.exists,
                       "Successful deletion leaves no error dialog or extra pause confirmation.", file: file, line: line)
        let survivor = library.staticTexts["Project Notes"].firstMatch
        XCTAssertTrue(survivor.exists, "Deleting one transcript preserves the other saved file.", file: file, line: line)
        survivor.click()
        XCTAssertTrue(text.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue((text.value as? String ?? "").contains("The next review is scheduled for Friday."),
                      file: file, line: line)
        XCTAssertTrue(window.buttons["relay.resume"].isEnabled, file: file, line: line)
    }

    private func recordSwipeFailure(in app: XCUIApplication, named name: String) {
        let window = app.windows.firstMatch
        if window.exists {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // A Space/focus interruption can remove every visible window from
        // automation. Keep that evidence without asking a missing window for
        // screenshot data and masking the original failure.
        print("Relay fictional fixture swipe failure:\n\(app.debugDescription)")
    }

    private func revealTranscriptSwipeActions(in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let window = activateMainWindow(in: app, file: file, line: line)
        let library = window.descendants(matching: .any).matching(identifier: "relay.sessionList").firstMatch
        let row = library.staticTexts["Design Review"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        // Capture the row position once, then anchor to the stable window.
        // Revealing actions can clip its StaticText during the gesture, making
        // a coordinate that continually resolves that text inaccessible.
        let rowFrame = row.frame
        let windowFrame = window.frame
        let point = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: rowFrame.midX - windowFrame.minX, dy: rowFrame.midY - windowFrame.minY))
        let beforeGesture = XCTAttachment(screenshot: window.screenshot())
        beforeGesture.name = "Fictional transcript before native swipe"
        beforeGesture.lifetime = .deleteOnSuccess
        add(beforeGesture)
        // The public Mac coordinate API sends the swipe, not a mouse drag or
        // wheel event. Brief continuation permits a post-failure screenshot;
        // the recorded gesture failure remains a failure and stops this flow.
        let failuresBeforeGesture = testRun?.failureCount ?? 0
        let previousContinuation = continueAfterFailure
        continueAfterFailure = true
        point.swipeLeft()
        continueAfterFailure = previousContinuation
        if (testRun?.failureCount ?? 0) > failuresBeforeGesture {
            recordSwipeFailure(in: app, named: "Fictional transcript native swipe gesture failure")
            XCTFail("The native row swipe must complete before action controls can be tested.", file: file, line: line)
            return
        }
        let rename = window.buttons["relay.swipe.rename"].firstMatch
        let delete = window.buttons["relay.swipe.delete"].firstMatch
        let renameAppeared = rename.waitForExistence(timeout: 5)
        if !renameAppeared {
            recordSwipeFailure(in: app, named: "Fictional transcript swipe reveal failure")
        }
        XCTAssertTrue(renameAppeared,
                      "A horizontal trackpad gesture reveals Rename.", file: file, line: line)
        XCTAssertTrue(delete.exists, "The same gesture reveals Delete.", file: file, line: line)
        XCTAssertTrue(rename.isHittable && rename.isEnabled, file: file, line: line)
        XCTAssertTrue(delete.isHittable && delete.isEnabled, file: file, line: line)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Native Rename and Delete swipe actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func verifySwipeActions(fixtureState: String?,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(fixture: true, fixtureState: fixtureState, history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), file: file, line: line)
        let content = text.value as? String
        let control = fixtureState == "recording" ? window.buttons["relay.pause"] : window.buttons["relay.resume"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)

        revealTranscriptSwipeActions(in: app, file: file, line: line)
        window.buttons["relay.swipe.rename"].firstMatch.click()
        let renameSheet = window.sheets.firstMatch
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(renameSheet.staticTexts["Rename Transcript"].exists, file: file, line: line)
        XCTAssertEqual(renameSheet.textFields.firstMatch.value as? String, "Design Review", file: file, line: line)
        renameSheet.buttons["Cancel"].click()
        XCTAssertTrue(renameSheet.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(text.value as? String, content, file: file, line: line)
        XCTAssertTrue(control.isEnabled, "Canceling Rename preserves the current capture state.", file: file, line: line)

        revealTranscriptSwipeActions(in: app, file: file, line: line)
        window.buttons["relay.swipe.delete"].firstMatch.click()
        let confirm = window.buttons["Delete Transcript"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), file: file, line: line)
        window.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(text.value as? String, content, file: file, line: line)
        XCTAssertTrue(control.isEnabled, "Canceling Delete preserves the transcript and capture state.", file: file, line: line)

        revealTranscriptSwipeActions(in: app, file: file, line: line)
        window.buttons["relay.swipe.delete"].firstMatch.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), file: file, line: line)
        confirm.click()
        let library = window.descendants(matching: .any).matching(identifier: "relay.sessionList").firstMatch
        XCTAssertTrue(library.staticTexts["Design Review"].firstMatch.waitForNonExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(library.staticTexts["Project Notes"].firstMatch.exists, file: file, line: line)
        XCTAssertFalse(window.sheets.firstMatch.exists, file: file, line: line)
    }

    private func chooseMicrophoneOnly(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let sources = window.buttons["relay.audioSources"]
        XCTAssertTrue(sources.isEnabled)
        sources.click()
        let systemAudio = window.checkBoxes["relay.editSource.systemAudio"]
        let microphone = window.checkBoxes["relay.editSource.microphone"]
        XCTAssertTrue(systemAudio.waitForExistence(timeout: 5))
        XCTAssertTrue(microphone.exists)
        if isChecked(systemAudio) { systemAudio.click() }
        if !isChecked(microphone) { microphone.click() }
        let apply = window.buttons["relay.sources.apply"]
        XCTAssertTrue(apply.isEnabled)
        apply.click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertNoSaveError(in: window)
    }

    private func assertNewRelayConfirmation(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(window.buttons["relay.newSession"].isEnabled)
        let before = text.value as? String
        // Target the real window for keyboard input and exclude virtual
        // Touch Bar buttons from all confirmation queries.
        text.click()
        window.typeKey("n", modifierFlags: [.command])
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let confirm = sheet.buttons["Pause and Create New"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Pause the current relay?"].exists)
        let statusText = "is still recording"
        let message = NSPredicate(format: "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)",
                                  "Design Review", "Design Review", statusText, statusText)
        XCTAssertTrue(sheet.staticTexts.matching(message).firstMatch.exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, before)
        XCTAssertTrue(window.buttons["relay.pause"].exists)
        XCTAssertFalse(window.buttons["relay.stop"].exists)
        XCTAssertFalse(window.buttons["relay.start"].exists)

        window.buttons["relay.newSession"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.start"].isEnabled)
        XCTAssertFalse(window.buttons["relay.stop"].exists)
        XCTAssertFalse(window.buttons["relay.pause"].exists)
        XCTAssertTrue(window.staticTexts["Design Review"].firstMatch.exists, "Pausing before New keeps the saved transcript in history.")
    }

    func testIdleLaunchAndAudioSourceValidation() {
        let app = launch()
        defer { app.terminate() }
        let start = app.buttons["relay.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.buttons["relay.stop"].exists)
        let language = element("relay.language", in: app)
        XCTAssertTrue(language.exists)
        XCTAssertTrue((language.value as? String ?? language.label).contains("English"))

        let systemAudio = element("relay.source.systemAudio", in: app)
        let microphone = element("relay.source.microphone", in: app)
        XCTAssertTrue(systemAudio.exists)
        XCTAssertTrue(microphone.exists)
        systemAudio.click()
        microphone.click()
        XCTAssertFalse(start.isEnabled, "Starting requires at least one selected audio source.")
        microphone.click()
        XCTAssertTrue(start.isEnabled, "Selecting the microphone enables transcription again.")
        XCTAssertFalse(app.buttons["relay.copyTranscript"].exists)
        XCTAssertFalse(element("relay.exportTranscript", in: app).exists)
    }

    func testSettingsMenuAndKeyboardShortcutAreRemoved() {
        let app = launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Relay"].click()
        let settings = NSPredicate(format: "label BEGINSWITH %@", "Settings")
        XCTAssertFalse(app.menuItems.matching(settings).firstMatch.exists)
        window.typeKey(.escape, modifierFlags: [])
        let windowCount = app.windows.count
        window.typeKey(",", modifierFlags: [.command])
        XCTAssertEqual(app.windows.count, windowCount, "Command-comma cannot open a removed Settings window.")
        XCTAssertTrue(window.buttons["relay.start"].isHittable)
        XCTAssertFalse(app.windows["Relay Settings"].exists)
    }

    func testConversationLanguageDoesNotChangeTheNewRelayDefaultOrOtherFiles() {
        let app = launch(fixture: true, history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let showSidebar = window.buttons["Show Sidebar"].firstMatch
        if showSidebar.exists { showSidebar.click() }
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let originalWords = text.value as? String
        window.buttons["relay.newSession"].click()
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 5))
        let readyLanguage = window.descendants(matching: .any).matching(identifier: "relay.language").firstMatch
        chooseMenuItem("Auto Detect", from: readyLanguage, in: app)
        XCTAssertTrue((readyLanguage.value as? String ?? readyLanguage.label).contains("Auto Detect"))
        chooseMenuItem("English (United States)", from: readyLanguage, in: app)
        XCTAssertTrue((readyLanguage.value as? String ?? readyLanguage.label).contains("English"))

        selectTranscript("Design Review", in: app)
        let conversation = assertConversationLanguage("en-US", in: window)
        chooseMenuItem("Auto Detect", from: conversation, in: app, keyboardPrefix: "auto")
        _ = assertConversationLanguage("auto", in: window)
        XCTAssertEqual(text.value as? String, originalWords, "Choosing a language preserves the existing transcript.")

        window.buttons["relay.newSession"].click()
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 5))
        XCTAssertTrue((readyLanguage.value as? String ?? readyLanguage.label).contains("English"),
                      "Changing one conversation does not replace the Ready language default.")
        selectTranscript("Project Notes", in: app)
        _ = assertConversationLanguage("en-US", in: window)
        selectTranscript("Design Review", in: app)
        _ = assertConversationLanguage("auto", in: window)
        XCTAssertEqual(text.value as? String, originalWords)
    }

    func testFirstLaunchRequiresBothPermissionsBeforeNewRelay() {
        verifyPermissionOnboarding(fixture: "missing")
    }

    func testDeniedPermissionsCanCompleteOnboardingThroughExplicitActions() {
        verifyPermissionOnboarding(fixture: "denied")
    }

    func testPermissionControlsRemainAccessibleAtMinimumWindowSize() {
        let app = launch(permissionsFixture: "denied")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let microphone = window.buttons["relay.permissions.microphone"]
        let systemAudio = window.buttons["relay.permissions.systemAudio"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 740, accuracy: 2)
        XCTAssertEqual(window.frame.height, 300, accuracy: 2)
        XCTAssertTrue(microphone.isHittable)
        XCTAssertTrue(systemAudio.isHittable)
        XCTAssertTrue(window.staticTexts["Set up Relay"].isHittable)
        XCTAssertTrue(window.staticTexts["Speech is processed on this Mac. Audio isn’t saved."].isHittable)
    }

    func testLiveTranscriptScrollChoiceSurvivesBackgroundAndReturnsToLatest() {
        let app = launch(fixture: true, fixtureState: "recording")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = transcript(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.height, 300, accuracy: 2)
        let jump = window.buttons["relay.jumpToLatest"].firstMatch
        XCTAssertFalse(jump.exists, "A recording initially follows the latest text.")

        // Use a native scroll gesture inside the visible transcript viewport,
        // rather than the offscreen bounds of its complete NSTextView document.
        let readingPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.72))
        readingPoint.scroll(byDeltaX: 0, deltaY: 240)
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "Reading earlier content reveals Jump to Latest.")
        let initialArrow = XCTAttachment(screenshot: window.screenshot())
        initialArrow.name = "Relay return arrow in compact window"
        initialArrow.lifetime = .keepAlways
        add(initialArrow)
        XCTAssertTrue(jump.isEnabled)
        XCTAssertEqual(jump.label, "Jump to Latest")
        XCTAssertEqual(jump.frame.width, jump.frame.height, accuracy: 2,
                       "The floating control should retain a circular shape.")
        XCTAssertGreaterThanOrEqual(jump.frame.width, 30)
        XCTAssertLessThanOrEqual(jump.frame.width, 56)
        XCTAssertTrue(window.frame.contains(jump.frame), "The return control fits the compact window.")

        app.typeKey("h", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        activateMainWindow(in: app)
        XCTAssertTrue(jump.waitForExistence(timeout: 5),
                      "Reactivating Relay must preserve the user's choice to read earlier text.")
        XCTAssertTrue(window.buttons["relay.pause"].isEnabled, "Reading earlier text leaves transcription running.")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Relay Jump to Latest after background and reactivation"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Click the visible viewport coordinate. XCTest's automatic scroll-to-
        // element behavior must not scroll the transcript on our behalf first.
        let jumpPoint = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: jump.frame.midX - window.frame.minX, dy: jump.frame.midY - window.frame.minY))
        jumpPoint.click()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "The button returns to the tail without waiting for new speech.")
        readingPoint.scroll(byDeltaX: 0, deltaY: 240)
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        readingPoint.scroll(byDeltaX: 0, deltaY: -1_000)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Manually scrolling back to the tail also resumes following.")
    }

    func testCompletedTranscriptCanBeCopiedInFull() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        let text = transcript(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let content = text.value as? String ?? ""
        XCTAssertTrue(content.contains("The clearest ideas are often the ones we can explain simply."))
        XCTAssertTrue(content.contains("We can share the revised prototype on Thursday"))
        XCTAssertTrue(content.contains("I’ll bring the updated notes to the review."))
        let copy = app.buttons["relay.copyTranscript"]
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("System audio"))
        XCTAssertTrue(copied.contains("Microphone"))
        XCTAssertTrue(copied.contains("The clearest ideas are often the ones we can explain simply."))
        XCTAssertTrue(copied.contains("We can share the revised prototype on Thursday"))
        XCTAssertTrue(copied.contains("I’ll bring the updated notes to the review."))
    }

    func testExportCanBeCancelledWithoutChangingTheTranscript() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        let text = transcript(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let before = text.value as? String
        let export = element("relay.exportTranscript", in: app)
        XCTAssertTrue(export.isEnabled)
        export.click()
        let plainText = app.menuItems["Plain Text (.txt)"]
        XCTAssertTrue(plainText.waitForExistence(timeout: 3))
        plainText.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let cancel = sheet.buttons["Cancel"]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, before)
        XCTAssertTrue(export.isEnabled)
    }

    func testNewTranscriptionKeyboardShortcutReturnsToReadyState() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        XCTAssertTrue(transcript(in: app).waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: [.command])
        let start = app.buttons["relay.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.buttons["relay.copyTranscript"].exists)
        XCTAssertFalse(element("relay.exportTranscript", in: app).exists)
        XCTAssertTrue(element("relay.sessionList", in: app).exists, "A new transcription does not discard the saved library.")
    }

    func testSearchFiltersTheLibraryAndCanBeCleared() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        XCTAssertTrue(transcript(in: app).waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("NoMatchingTranscript987")
        XCTAssertTrue(app.staticTexts["No matching transcripts"].waitForExistence(timeout: 3))
        search.typeKey("a", modifierFlags: [.command])
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["No matching transcripts"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(element("relay.sessionList", in: app).exists)
    }

    func testRecordingTranscriptCanBeDeleted() {
        verifySelectedTranscriptCanBeDeleted(fixtureState: "recording")
    }

    func testPausedTranscriptCanBeDeleted() {
        verifySelectedTranscriptCanBeDeleted(fixtureState: "paused")
    }

    func testSavedTranscriptCanBeDeleted() {
        verifySelectedTranscriptCanBeDeleted(fixtureState: nil)
    }

    func testDeletingAnotherSavedFilePreservesTheLiveRecording() {
        let app = launch(fixture: true, fixtureState: "recording", history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        let recordingContent = text.value as? String
        let library = window.descendants(matching: .any).matching(identifier: "relay.sessionList").firstMatch
        let deletedRow = library.staticTexts["Project Notes"].firstMatch
        openDeleteConfirmation(for: "Project Notes", in: app).click()
        XCTAssertTrue(deletedRow.waitForNonExistence(timeout: 10))
        XCTAssertFalse(window.sheets.firstMatch.exists)
        let recordingRow = library.staticTexts["Design Review"].firstMatch
        XCTAssertTrue(recordingRow.exists)
        recordingRow.click()
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["relay.pause"].isEnabled,
                      "Deleting a different file leaves the original recording running.")
        XCTAssertEqual(text.value as? String, recordingContent)
        XCTAssertFalse(window.buttons["relay.resume"].exists)
    }

    func testSwipeActionsRenameAndDeleteRecordingTranscript() {
        verifySwipeActions(fixtureState: "recording")
    }

    func testSwipeActionsRenameAndDeletePausedTranscript() {
        verifySwipeActions(fixtureState: "paused")
    }

    func testSwipeActionsRenameAndDeleteSavedTranscript() {
        verifySwipeActions(fixtureState: nil)
    }

    private func assertMinimumTopCenteredFrame(_ window: XCUIElement,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = window.frame
        let primary = try XCTUnwrap(NSScreen.screens.first, file: file, line: line)
        // Accessibility uses a top-left origin. AppKit's global screen coordinates
        // use the primary display's bottom-left origin, including for other displays.
        let appKitCenter = CGPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(appKitCenter) },
                                  "Relay must open on a connected display.", file: file, line: line)
        XCTAssertEqual(frame.width, 740, accuracy: 2, file: file, line: line)
        XCTAssertEqual(frame.height, 300, accuracy: 2, file: file, line: line)
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 2,
                       "The complete window is horizontally centered on its display.", file: file, line: line)
        XCTAssertEqual(frame.minY, primary.frame.maxY - screen.visibleFrame.maxY, accuracy: 2,
                       "The title bar starts at the usable top edge, below any reserved menu bar.", file: file, line: line)
    }

    private func moveAndEnlargeWindow(_ window: XCUIElement,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let original = window.frame
        // Exercise native window resizing and dragging. No app fixture or test-only
        // production hook writes the frame, so a launch-restoration regression stays visible.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: 100, dy: 130)))
        let enlarged = window.frame
        XCTAssertGreaterThan(enlarged.width, original.width + 60, file: file, line: line)
        XCTAssertGreaterThan(enlarged.height, original.height + 90, file: file, line: line)
        let title = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 150, dy: 20))
        title.click(forDuration: 0.15, thenDragTo: title.withOffset(CGVector(dx: -100, dy: 150)))
        XCTAssertGreaterThan(window.frame.minY, original.minY + 80,
                             "The test must actually move the window away from its launch position.", file: file, line: line)
        XCTAssertLessThan(window.frame.minX, original.minX - 50, file: file, line: line)
    }

    func testLaunchPlacementResetsAfterMovingResizingAndQuitting() throws {
        let app = launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10))
        try assertMinimumTopCenteredFrame(window)
        moveAndEnlargeWindow(window)
        let changedFrame = window.frame

        app.typeKey("h", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        activateMainWindow(in: app)
        XCTAssertEqual(window.frame, changedFrame,
                       "Returning to an already running Relay preserves the user's size and position.")

        app.typeKey("q", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Quit normally so macOS can save window state.")
        app.launch()
        let reopened = activateMainWindow(in: app)
        XCTAssertTrue(reopened.buttons["relay.start"].waitForExistence(timeout: 10))
        try assertMinimumTopCenteredFrame(reopened)
        let attachment = XCTAttachment(screenshot: reopened.screenshot())
        attachment.name = "Relay minimum window after resize, move, quit, and relaunch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchPlacementResetsAfterClosingLastWindow() throws {
        let app = launch(fixture: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.textViews["relay.transcript"].waitForExistence(timeout: 10))
        try assertMinimumTopCenteredFrame(window)
        moveAndEnlargeWindow(window)

        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Closing Relay's last window quits the app.")
        app.launch()
        let reopened = activateMainWindow(in: app)
        XCTAssertTrue(reopened.textViews["relay.transcript"].waitForExistence(timeout: 10))
        try assertMinimumTopCenteredFrame(reopened)
        XCTAssertTrue(reopened.buttons["relay.resume"].isHittable)
    }

    func testReadyControlsRemainUsableAtMinimumWindowSize() {
        let app = launch()
        defer { app.terminate() }
        let start = app.buttons["relay.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.width, 740, accuracy: 2)
        XCTAssertEqual(window.frame.height, 300, accuracy: 2)
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(element("relay.language", in: app).isHittable)
        XCTAssertTrue(element("relay.source.systemAudio", in: app).isHittable)
        XCTAssertTrue(element("relay.source.microphone", in: app).isHittable)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Relay minimum window"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testSelectedPassagesOmitMetadataWhileFullCopyKeepsIt() {
        let app = launch(fixture: true, fixtureState: "paused")
        defer { app.terminate() }
        let text = transcript(in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let visible = text.value as? String ?? ""
        XCTAssertTrue(visible.contains("System audio"))
        XCTAssertTrue(visible.contains("Microphone"))

        text.click()
        app.typeKey("a", modifierFlags: [.command])
        let selectedPassage = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(selectedPassage.contains("The clearest ideas are often the ones we can explain simply."))
        XCTAssertTrue(selectedPassage.contains("We can share the revised prototype on Thursday"))
        XCTAssertTrue(selectedPassage.contains("I’ll bring the updated notes to the review."))
        XCTAssertFalse(selectedPassage.contains("System audio"))
        XCTAssertFalse(selectedPassage.contains("Microphone"))
        XCTAssertFalse(selectedPassage.contains("0:00"))

        // Replace the automatically copied value to prove Command-C performs
        // its own filtered write rather than inheriting the previous result.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Before native copy", forType: .string)
        app.typeKey("c", modifierFlags: [.command])
        let nativeCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(nativeCopy, selectedPassage)
        XCTAssertFalse(nativeCopy.contains("System audio"))
        XCTAssertFalse(nativeCopy.contains("Microphone"))
        XCTAssertFalse(nativeCopy.contains("0:00"))

        app.buttons["relay.copyTranscript"].click()
        let fullCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(fullCopy.contains("System audio"))
        XCTAssertTrue(fullCopy.contains("Microphone"))
        XCTAssertTrue(fullCopy.contains("The clearest ideas are often the ones we can explain simply."))
        XCTAssertTrue(fullCopy.contains("We can share the revised prototype on Thursday"))
        XCTAssertTrue(fullCopy.contains("I’ll bring the updated notes to the review."))
    }

    func testCompletedHistoryCanResumeWithoutShowingEnd() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        XCTAssertTrue(transcript(in: app).waitForExistence(timeout: 10))
        let showSidebar = app.buttons["Show Sidebar"]
        let restoreSidebar = showSidebar.exists
        if restoreSidebar { showSidebar.click() }
        let resume = app.buttons["relay.resume"]
        XCTAssertTrue(resume.exists)
        XCTAssertTrue(resume.isEnabled)
        XCTAssertFalse(app.buttons["relay.stop"].exists, "A completed transcript has no live session to end.")
        XCTAssertFalse(app.buttons["relay.pause"].exists)

        app.buttons["relay.newSession"].click()
        XCTAssertTrue(app.buttons["relay.start"].waitForExistence(timeout: 5))
        XCTAssertFalse(resume.exists)
        let historyTitle = app.staticTexts["Design Review"].firstMatch
        XCTAssertTrue(historyTitle.exists)
        historyTitle.click()
        XCTAssertTrue(transcript(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(resume.exists)
        XCTAssertTrue(resume.isEnabled)
        XCTAssertFalse(app.buttons["relay.stop"].exists, "Reselecting history must not show another session’s End action.")
        XCTAssertFalse(app.buttons["relay.pause"].exists)
        XCTAssertTrue(app.buttons["relay.copyTranscript"].isEnabled)
        XCTAssertTrue(element("relay.exportTranscript", in: app).isEnabled)

        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.width, 740, accuracy: 2)
        XCTAssertEqual(window.frame.height, 300, accuracy: 2)
        XCTAssertTrue(resume.isHittable)
        XCTAssertTrue(app.buttons["relay.copyTranscript"].isHittable)
        XCTAssertTrue(element("relay.exportTranscript", in: app).isHittable)
        XCTAssertFalse(app.buttons["relay.stop"].exists)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Relay completed transcript minimum window"
        attachment.lifetime = .keepAlways
        add(attachment)
        if restoreSidebar { app.buttons["Hide Sidebar"].click() }
    }

    func testCompletedTranscriptAudioSourcesValidateAndPersist() {
        let app = launch(fixture: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let before = text.value as? String
        window.buttons["relay.audioSources"].click()
        let systemAudio = window.checkBoxes["relay.editSource.systemAudio"]
        let microphone = window.checkBoxes["relay.editSource.microphone"]
        XCTAssertTrue(systemAudio.waitForExistence(timeout: 5))
        XCTAssertTrue(isChecked(systemAudio))
        XCTAssertTrue(isChecked(microphone))
        XCTAssertTrue(window.staticTexts["Changes apply to new audio."].exists)
        let apply = window.buttons["relay.sources.apply"]
        XCTAssertTrue(apply.isEnabled, "Applying valid sources also allows retrying a previous save.")
        systemAudio.click()
        microphone.click()
        XCTAssertFalse(apply.isEnabled, "A transcript needs at least one audio source.")
        XCTAssertTrue(window.staticTexts["Select at least one audio source."].exists)
        microphone.click()
        XCTAssertTrue(apply.isEnabled)
        apply.click()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10))
        assertNoSaveError(in: window)
        XCTAssertEqual(text.value as? String, before)
        XCTAssertTrue(window.buttons["relay.resume"].exists)
        XCTAssertFalse(window.buttons["relay.pause"].exists, "Changing a completed transcript’s sources does not start recording.")
        XCTAssertFalse(window.buttons["relay.stop"].exists)

        window.buttons["relay.audioSources"].click()
        XCTAssertTrue(systemAudio.waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(systemAudio))
        XCTAssertTrue(isChecked(microphone))
        systemAudio.click()
        window.buttons["relay.sources.cancel"].click()
        window.buttons["relay.audioSources"].click()
        XCTAssertTrue(systemAudio.waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(systemAudio), "Cancel does not change the saved sources.")
        XCTAssertTrue(isChecked(microphone))
        window.buttons["relay.sources.cancel"].click()
        XCTAssertEqual(text.value as? String, before)
    }

    func testChangingLiveAudioSourcesKeepsTheTranscriptRecording() {
        let app = launch(fixture: true, fixtureState: "recording")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        let before = text.value as? String
        chooseMicrophoneOnly(in: app)
        XCTAssertEqual(text.value as? String, before)
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["relay.stop"].exists)
        XCTAssertFalse(window.buttons["relay.resume"].exists)
        window.buttons["relay.audioSources"].click()
        XCTAssertTrue(window.checkBoxes["relay.editSource.microphone"].waitForExistence(timeout: 5))
        XCTAssertFalse(isChecked(window.checkBoxes["relay.editSource.systemAudio"]))
        XCTAssertTrue(isChecked(window.checkBoxes["relay.editSource.microphone"]))
        window.buttons["relay.sources.cancel"].click()
        window.buttons["relay.pause"].click()
        XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["relay.stop"].exists)
    }

    func testNewDuringRecordingRequiresConfirmation() {
        let app = launch(fixture: true, fixtureState: "recording")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.textViews["relay.transcript"].waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        assertNewRelayConfirmation(in: app)
    }

    func testNewWhilePausedReturnsToSetupWithoutConfirmation() {
        let app = launch(fixture: true, fixtureState: "paused")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5))
        let before = text.value as? String
        chooseMicrophoneOnly(in: app)
        XCTAssertEqual(text.value as? String, before)
        XCTAssertTrue(window.buttons["relay.resume"].exists)
        XCTAssertFalse(window.buttons["relay.pause"].exists, "Changing paused sources must not restart recording.")
        text.click()
        window.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(window.buttons["relay.start"].waitForExistence(timeout: 10))
        XCTAssertFalse(window.sheets.firstMatch.exists)
        XCTAssertFalse(window.buttons["relay.resume"].exists)
        XCTAssertFalse(window.buttons["relay.stop"].exists)
        XCTAssertTrue(window.staticTexts["Design Review"].firstMatch.exists)
    }

    func testResumingHistoryConfirmsBeforePausingTheRecording() {
        let app = launch(fixture: true, fixtureState: "recording", history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        let recordingContent = text.value as? String ?? ""
        XCTAssertTrue(recordingContent.contains("The clearest ideas are often the ones we can explain simply."))

        selectTranscript("Project Notes", in: app)
        let historyContent = text.value as? String ?? ""
        XCTAssertTrue(historyContent.contains("The next review is scheduled for Friday."))
        XCTAssertNotEqual(historyContent, recordingContent, "Each fixture represents a different saved transcript.")
        let resume = window.buttons["relay.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.isEnabled, "A history file can request Resume while another file records.")
        XCTAssertFalse(window.buttons["relay.pause"].exists, "History must not show the other file’s Pause action.")
        let copy = window.buttons["relay.copyTranscript"]
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        let savedHistoryCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(savedHistoryCopy.contains("The next review is scheduled for Friday."))

        resume.click()
        let firstSheet = assertResumeConfirmation(in: window)
        firstSheet.buttons["Cancel"].click()
        XCTAssertTrue(firstSheet.waitForNonExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, historyContent, "Cancel preserves the selected history file.")
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), savedHistoryCopy)
        selectTranscript("Design Review", in: app)
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5),
                      "Cancel leaves the original file recording.")
        XCTAssertTrue(window.buttons["relay.pause"].isEnabled)
        XCTAssertEqual(text.value as? String, recordingContent)

        selectTranscript("Project Notes", in: app)
        text.click()
        window.typeKey("r", modifierFlags: [.command])
        let keyboardSheet = assertResumeConfirmation(in: window)
        keyboardSheet.buttons["Pause and Resume"].click()
        XCTAssertTrue(keyboardSheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].isEnabled)
        XCTAssertFalse(window.buttons["relay.resume"].exists)
        XCTAssertEqual(text.value as? String, historyContent,
                       "Resuming appends to the chosen file without replacing its earlier words.")

        selectTranscript("Design Review", in: app)
        XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["relay.resume"].isEnabled)
        XCTAssertFalse(window.buttons["relay.pause"].exists)
        XCTAssertEqual(text.value as? String, recordingContent,
                       "The recording that was paused remains intact in history.")
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        let savedRecordingCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(savedRecordingCopy.contains("The clearest ideas are often the ones we can explain simply."))
        XCTAssertTrue(savedRecordingCopy.contains("I’ll bring the updated notes to the review."))
        selectTranscript("Project Notes", in: app)
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5),
                      "Browsing the old file does not change which file is recording.")
        XCTAssertEqual(text.value as? String, historyContent)
    }

    func testResumingHistoryFromPausedFileSwitchesWithoutConfirmation() {
        let app = launch(fixture: true, fixtureState: "paused", history: true)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5))
        let pausedContent = text.value as? String ?? ""
        XCTAssertTrue(pausedContent.contains("The clearest ideas are often the ones we can explain simply."))

        selectTranscript("Project Notes", in: app)
        let historyContent = text.value as? String ?? ""
        XCTAssertTrue(historyContent.contains("The next review is scheduled for Friday."))
        XCTAssertNotEqual(historyContent, pausedContent)
        let resume = window.buttons["relay.resume"]
        XCTAssertTrue(resume.isEnabled)
        window.buttons["relay.copyTranscript"].click()
        let savedHistoryCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(savedHistoryCopy.contains("The next review is scheduled for Friday."))
        resume.click()
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["relay.pause"].isEnabled)
        XCTAssertFalse(window.sheets.firstMatch.exists,
                       "Switching away from an already paused file needs no interruption confirmation.")
        XCTAssertEqual(text.value as? String, historyContent)

        selectTranscript("Design Review", in: app)
        XCTAssertTrue(window.buttons["relay.resume"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["relay.resume"].isEnabled)
        XCTAssertFalse(window.buttons["relay.pause"].exists)
        XCTAssertEqual(text.value as? String, pausedContent,
                       "Starting the other saved file preserves the original paused transcript.")
        XCTAssertTrue(window.buttons["relay.copyTranscript"].isEnabled)
        window.buttons["relay.copyTranscript"].click()
        let savedPausedCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(savedPausedCopy.contains("We can share the revised prototype on Thursday"))
        selectTranscript("Project Notes", in: app)
        XCTAssertTrue(window.buttons["relay.pause"].waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, historyContent)
    }

    func testDraggingAcrossSourceLabelsCopiesOnlySpokenWordsInBothDirections() throws {
        guard CGPreflightPostEventAccess() else {
            throw XCTSkip("Native passage dragging requires existing macOS event-posting permission for the UI test runner.")
        }
        let app = launch(fixture: true, fixtureState: "paused")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))

        // All three passages must fit before dragging, so this regression
        // exercises selection across headers independently of autoscrolling.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: 300)))
        XCTAssertGreaterThanOrEqual(window.frame.height, 550)
        let visible = try XCTUnwrap(text.value as? String) as NSString

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func findTranscript(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 24 else { return nil }
            if attribute(element, kAXIdentifierAttribute) as? String == "relay.transcript" { return element }
            if attribute(element, kAXRoleAttribute) as? String == kAXMenuBarRole { return nil }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let match = findTranscript(child, depth: depth + 1) { return match }
            }
            return nil
        }
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.asherbloom.Relay").first)
        let nativeText = try XCTUnwrap(findTranscript(AXUIElementCreateApplication(running.processIdentifier)),
                                      "Resolve the actual native text surface before synthesizing the drag.")

        func bounds(for range: NSRange) throws -> CGRect {
            XCTAssertNotEqual(range.location, NSNotFound)
            var nativeRange = CFRange(location: range.location, length: range.length)
            let parameter = try XCTUnwrap(AXValueCreate(.cfRange, &nativeRange))
            var rawBounds: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(nativeText,
                kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &rawBounds)
            XCTAssertEqual(result, .success, "Use rendered glyph bounds, not hard-coded line positions.")
            let raw = try XCTUnwrap(rawBounds)
            XCTAssertEqual(CFGetTypeID(raw), AXValueGetTypeID())
            var rect = CGRect.zero
            XCTAssertTrue(AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgRect, &rect))
            XCTAssertFalse(rect.isEmpty)
            XCTAssertTrue(window.frame.contains(rect), "Every drag endpoint must be visible in the window.")
            return rect
        }
        let headerGlyph = try bounds(for: visible.range(of: "System audio"))
        let firstGlyph = try bounds(for: visible.range(of: "The clearest"))
        let lastGlyph = try bounds(for: visible.range(of: "review.", options: .backwards))
        let firstPoint = CGPoint(x: firstGlyph.minX + 0.25, y: firstGlyph.midY)
        let lastPoint = CGPoint(x: lastGlyph.maxX - 0.25, y: lastGlyph.midY)
        let expected = "The clearest ideas are often the ones we can explain simply. Let’s keep the next review focused on the experience.\n" +
            "Agreed. We can share the revised prototype on Thursday, then leave time for everyone to try it.\n" +
            "That gives us a useful starting point. I’ll bring the updated notes to the review."

        func postMouse(_ type: CGEventType, at point: CGPoint) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .left))
            event.post(tap: .cghidEventTap)
        }
        func waitForCopiedWords() -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            repeat {
                if NSPasteboard.general.string(forType: .string) == expected { return true }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return NSPasteboard.general.string(forType: .string) == expected
        }

        for reverse in [false, true] {
            let start = reverse ? lastPoint : firstPoint
            let end = reverse ? firstPoint : lastPoint
            // Begin a fresh selection instead of initiating native drag-and-
            // drop by pressing within the previous highlighted passage.
            let headerPoint = CGPoint(x: headerGlyph.midX, y: headerGlyph.midY)
            try postMouse(.leftMouseDown, at: headerPoint)
            try postMouse(.leftMouseUp, at: headerPoint)
            Thread.sleep(forTimeInterval: 0.1)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Before the passage drag", forType: .string)
            var mouseIsDown = false
            defer {
                if mouseIsDown {
                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            try postMouse(.mouseMoved, at: start)
            try postMouse(.leftMouseDown, at: start)
            mouseIsDown = true
            Thread.sleep(forTimeInterval: 0.1)
            for step in 1...24 {
                let fraction = CGFloat(step) / 24
                try postMouse(.leftMouseDragged, at: CGPoint(
                    x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction))
                Thread.sleep(forTimeInterval: 0.025)
            }
            let copiedDuringDrag = waitForCopiedWords()
            try postMouse(.leftMouseUp, at: end)
            mouseIsDown = false
            XCTAssertTrue(copiedDuringDrag,
                          "Both forward and reverse dragging must copy every selected body before mouse-up.")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = reverse ? "Reverse passage selection leaves source labels unhighlighted" :
                "Forward passage selection leaves source labels unhighlighted"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testMouseReleaseShowsFloatingCopiedFeedbackWithoutFooter() throws {
        guard CGPreflightPostEventAccess() else {
            throw XCTSkip("Mouse-release feedback requires existing macOS event-posting permission for the UI test runner.")
        }
        let app = launch(fixture: true, fixtureState: "paused")
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let text = window.textViews["relay.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertFalse(window.staticTexts["Selection copies automatically"].exists)
        XCTAssertFalse(window.staticTexts["Select text and press ⌘C to copy"].exists)

        // Resolve the native surface before beginning the gesture. XCTest's
        // drag helper waits several seconds for event quiescence, outlasting
        // this intentionally brief feedback. Native events followed by one
        // XCTest snapshot observe release without changing product timing.
        // XCTest handles the visibility query through its UI automation channel.
        let frame = text.frame
        let copiedLabel = NSPredicate(format: "label == %@ OR value == %@", "Copied", "Copied")
        let feedback = window.descendants(matching: .any).matching(copiedLabel).firstMatch

        func waitNatively(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            repeat {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return condition()
        }

        func postMouse(_ type: CGEventType, at point: CGPoint) throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .left))
            event.post(tap: .cghidEventTap)
        }

        XCTAssertFalse(feedback.exists)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Relay UI selection fixture", forType: .string)
        let start = CGPoint(x: frame.minX + 29, y: frame.minY + 56)
        let end = CGPoint(x: start.x + 211, y: start.y)
        var mouseIsDown = false
        defer {
            if mouseIsDown {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                        mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        try postMouse(.leftMouseDown, at: start)
        mouseIsDown = true
        Thread.sleep(forTimeInterval: 0.1)
        for step in 1...10 {
            let fraction = CGFloat(step) / 10
            try postMouse(.leftMouseDragged,
                          at: CGPoint(x: start.x + 211 * fraction, y: start.y))
            Thread.sleep(forTimeInterval: 0.025)
        }
        let copiedDuringDrag = waitNatively(timeout: 1) {
            (NSPasteboard.general.string(forType: .string) ?? "").contains("The clearest")
        }
        try postMouse(.leftMouseUp, at: end)
        mouseIsDown = false
        // Snapshot once, immediately: an existence check followed by a separate
        // frame query can otherwise consume the entire confirmation lifetime.
        let feedbackSnapshot = try? feedback.snapshot()
        let feedbackFaded = feedback.waitForNonExistence(timeout: 4)

        XCTAssertTrue(copiedDuringDrag, "The selected words are copied before the mouse is released.")
        let visibleFeedback = try XCTUnwrap(feedbackSnapshot, "A floating capsule briefly confirms the completed selection.")
        let visibleFeedbackFrame = visibleFeedback.frame
        XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(visibleFeedbackFrame),
                      "The confirmation stays inside the transcript viewport.")
        XCTAssertLessThanOrEqual(abs(visibleFeedbackFrame.midX - end.x), 160,
                                 "The confirmation appears near the finished selection.")
        XCTAssertLessThanOrEqual(abs(visibleFeedbackFrame.midY - end.y), 80)
        XCTAssertTrue(feedbackFaded, "Selection feedback fades instead of reserving space in the transcript.")
        XCTAssertEqual(text.frame, frame, "Transient feedback does not shift the transcript layout.")
        let wordCount = NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", " words", " words")
        XCTAssertFalse(window.staticTexts.matching(wordCount).firstMatch.exists,
                       "The transcript footer, including its word count, has been removed.")
        XCTAssertFalse(window.staticTexts["Selection copies automatically"].exists)
        XCTAssertFalse(window.staticTexts["Select text and press ⌘C to copy"].exists)
    }

}
