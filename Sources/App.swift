import AppKit
import Carbon
import ServiceManagement

private enum UpdateState {
    case idle, checking, current, available(GitHubRelease), failed
}

@main
@MainActor
final class WheresMyMouseApp: NSObject, NSApplicationDelegate {
    private var hotkeys = Dictionary(uniqueKeysWithValues: PointerAction.allCases.map { action in
        let saved = UserDefaults.standard.data(forKey: action.preferenceKey)
            .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
        return (action, saved ?? action.defaultHotkey)
    })
    private lazy var highlight = PointerHighlight()
    let pointerStyle = PointerStyleSettings(defaults: .standard)
    fileprivate private(set) var updateState = UpdateState.idle
    private let registration = GlobalHotkey()
    private var settings: SettingsWindow?
    private var terminationSignal: DispatchSourceSignal?
    private(set) var hotkeyErrors: [PointerAction: String] = [:]
    private(set) var cursorError: String?

    static func main() {
        let instance: InstanceLock
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.wheresmymouse.app",
                                                           isDirectory: true)
            guard let lock = try InstanceLock(directory: directory) else { return }
            instance = lock
        } catch {
            NSLog("wheresmymouse: Could not secure the instance lock: %@", error.localizedDescription)
            return
        }

        let app = NSApplication.shared
        let delegate = WheresMyMouseApp()
        app.delegate = delegate
        withExtendedLifetime((delegate, instance)) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let openedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem

        registration.onPress = { [weak self] action in self?.handleShortcut(action) }
        for action in PointerAction.allCases { _ = register(hotkey(for: action), for: action) }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
        checkForUpdates()
        if !openedAtLogin { showSettings() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settings?.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        registration.stop()
    }

    func hotkey(for action: PointerAction) -> Hotkey { hotkeys[action]! }

    func setHotkey(_ hotkey: Hotkey, for action: PointerAction) {
        guard register(hotkey, for: action) else { return }
        hotkeys[action] = hotkey
        UserDefaults.standard.set(try? JSONEncoder().encode(hotkey), forKey: action.preferenceKey)
    }

    private func register(_ hotkey: Hotkey, for action: PointerAction) -> Bool {
        let status = registration.register(hotkey, for: action)
        switch status {
        case noErr:
            hotkeyErrors[action] = nil
        case OSStatus(eventHotKeyExistsErr):
            hotkeyErrors[action] = "\(action.title): \(hotkey.title) is already in use."
        default:
            hotkeyErrors[action] = "\(action.title): could not register \(hotkey.title) (macOS error \(status))."
        }
        return status == noErr
    }

    private func handleShortcut(_ action: PointerAction) {
        if settings?.captureIfRecording(hotkey(for: action)) == true { return }
        switch action {
        case .grow:
            previewStyle()
        case .center, .nextDisplay:
            if let message = DisplayCenter.move(advance: action == .nextDisplay) {
                reportCursorError(message)
            } else {
                if cursorError != nil {
                    cursorError = nil
                    settings?.refresh()
                }
                highlight.show(colors: pointerStyle.colors, animated: false)
            }
        }
    }

    func previewStyle() {
        highlight.show(colors: pointerStyle.colors, animated: true)
    }

    func checkForUpdates() {
        if case .checking = updateState { return }
        updateState = .checking
        settings?.refresh()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Task { [weak self] in
            let state: UpdateState
            do {
                if let release = try await UpdateChecker.newerRelease(installedVersion: version) {
                    state = .available(release)
                } else {
                    state = .current
                }
            } catch {
                state = .failed
            }
            self?.updateState = state
            self?.settings?.refresh()
        }
    }

    private func reportCursorError(_ message: String) {
        NSLog("wheresmymouse: %@", message)
        cursorError = message
        settings?.refresh()
    }

    func settingsClosed() {
        settings = nil
    }

    private func showSettings() {
        if let settings {
            settings.refresh()
        } else {
            settings = SettingsWindow(app: self)
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}

private final class PointerSampleView: NSView {
    var colors = PointerStyle.defaultColors {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        PointerHighlightView.drawArrow(colors: colors, scale: 0.44, tip: NSPoint(x: 10, y: bounds.height - 5))
    }
}

private final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private unowned let app: WheresMyMouseApp
    private static let styles = PointerStyle.allCases
    private let stack = NSStackView()
    private var rows: [(action: PointerAction, value: NSTextField, button: NSButton)] = []
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let sample = PointerSampleView()
    private let style = NSPopUpButton()
    private let customStyleRow = NSStackView()
    private let borderColor = NSColorWell()
    private let fillColor = NSColorWell()
    private let checkUpdates = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let viewRelease = NSButton(title: "View Release…", target: nil, action: nil)
    private let updateDetails = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let loginDetails = NSTextField(wrappingLabelWithString: "")
    private let loginSettings = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private var loginError: String?
    private var recording: (action: PointerAction, monitor: Any)?

    init(app: WheresMyMouseApp) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Where's My Mouse"
        window.delegate = self
        window.isReleasedWhenClosed = false

        for label in [hint, status, loginDetails] {
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 392
        }
        updateDetails.textColor = .secondaryLabelColor
        updateDetails.font = .systemFont(ofSize: 12)
        updateDetails.lineBreakMode = .byTruncatingTail
        sample.setContentHuggingPriority(.required, for: .horizontal)
        style.addItems(withTitles: Self.styles.map(\.title))
        style.setAccessibilityLabel("Pointer style")
        style.target = self
        style.action = #selector(changeStyle)
        let preview = NSButton(title: "Preview", target: self, action: #selector(previewStyle))
        let styleRow = NSStackView(views: [sample, style, NSView(), preview])
        styleRow.alignment = .centerY
        styleRow.spacing = 10
        let borderLabel = NSTextField(labelWithString: "Border")
        let fillLabel = NSTextField(labelWithString: "Fill")
        borderLabel.textColor = .secondaryLabelColor
        fillLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
        for view in [borderLabel, borderColor, spacer, fillLabel, fillColor, NSView()] {
            customStyleRow.addArrangedSubview(view)
        }
        customStyleRow.alignment = .centerY
        customStyleRow.spacing = 8
        borderColor.setAccessibilityLabel("Pointer border color")
        fillColor.setAccessibilityLabel("Pointer fill color")
        for well in [borderColor, fillColor] {
            well.colorWellStyle = .minimal
            if #available(macOS 14.0, *) { well.supportsAlpha = false }
            well.target = self
            well.action = #selector(changeColor(_:))
        }
        checkUpdates.target = self
        checkUpdates.action = #selector(checkForUpdates)
        viewRelease.target = self
        viewRelease.action = #selector(openRelease)
        let updateRow = NSStackView(views: [updateDetails, NSView(), viewRelease, checkUpdates])
        updateRow.alignment = .centerY
        updateRow.spacing = 8
        login.target = self
        login.action = #selector(toggleLogin)
        loginSettings.target = self
        loginSettings.action = #selector(openLoginSettings)
        let quit = NSButton(title: "Quit Where's My Mouse", target: NSApp, action: #selector(NSApplication.terminate(_:)))

        let footer = NSStackView(views: [login, NSView(), quit])
        footer.alignment = .centerY
        stack.orientation = .vertical
        stack.addArrangedSubview(Self.sectionHeading("Pointer Shortcuts"))
        for action in PointerAction.allCases {
            let title = NSTextField(labelWithString: action.title)
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            value.textColor = .secondaryLabelColor
            let button = NSButton(title: "Change…", target: self, action: #selector(toggleRecording(_:)))
            button.tag = action.rawValue
            let row = NSStackView(views: [title, NSView(), value, button])
            row.alignment = .centerY
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append((action, value, button))
        }
        let shortcutSeparator = NSBox()
        shortcutSeparator.boxType = .separator
        let styleSeparator = NSBox()
        styleSeparator.boxType = .separator
        for view in [hint, status, shortcutSeparator, Self.sectionHeading("Pointer Style"), styleRow, customStyleRow,
                     styleSeparator, updateRow, footer, loginDetails, loginSettings] {
            stack.addArrangedSubview(view)
        }
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            shortcutSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            styleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            customStyleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            styleSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private static func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    func refresh() {
        for (action, value, button) in rows {
            value.stringValue = app.hotkey(for: action).title
            let active = recording?.action == action
            button.title = active ? "Cancel" : "Change…"
            button.setAccessibilityLabel(active ? "Cancel recording" : "Change shortcut: \(action.title)")
        }
        hint.stringValue = recording == nil ? "" : "Press a key combo or F-key. Esc cancels."
        hint.isHidden = hint.stringValue.isEmpty
        let errors = PointerAction.allCases.compactMap { app.hotkeyErrors[$0] }
        status.stringValue = ([app.cursorError].compactMap { $0 } + errors).joined(separator: "\n")
        status.isHidden = status.stringValue.isEmpty

        if let index = Self.styles.firstIndex(of: app.pointerStyle.style) {
            style.selectItem(at: index)
        }
        sample.colors = app.pointerStyle.colors
        customStyleRow.isHidden = app.pointerStyle.style != .custom
        if !customStyleRow.isHidden {
            let colors = app.pointerStyle.customColors
            borderColor.color = PointerColors.color(colors.border)
            fillColor.color = PointerColors.color(colors.fill)
        }
        checkUpdates.isEnabled = true
        viewRelease.isHidden = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionPrefix = version.isEmpty ? "Current version" : "Version \(version)"
        switch app.updateState {
        case .idle: updateDetails.stringValue = versionPrefix
        case .checking:
            checkUpdates.isEnabled = false
            updateDetails.stringValue = "Checking for updates…"
        case .current: updateDetails.stringValue = "\(versionPrefix) · Up to date"
        case .available(let release):
            updateDetails.stringValue = "Version \(release.version) is available"
            viewRelease.isHidden = false
        case .failed: updateDetails.stringValue = "Could not check for updates"
        }

        let loginStatus = SMAppService.mainApp.status
        login.state = loginStatus == .enabled || loginStatus == .requiresApproval ? .on : .off
        loginDetails.stringValue = loginError ?? (loginStatus == .requiresApproval
            ? "Allow Where's My Mouse in System Settings → Login Items." : "")
        loginDetails.isHidden = loginDetails.stringValue.isEmpty
        loginSettings.isHidden = loginStatus != .requiresApproval
        let size = NSSize(width: 440, height: stack.fittingSize.height + 40)
        if window?.contentView?.bounds.size != size { window?.setContentSize(size) }
    }

    func windowDidResignKey(_ notification: Notification) {
        finishRecording()
    }

    func windowWillClose(_ notification: Notification) {
        finishRecording()
        app.settingsClosed()
    }

    func captureIfRecording(_ hotkey: Hotkey) -> Bool {
        guard recording != nil else { return false }
        finishRecording(with: hotkey)
        return true
    }

    @objc private func toggleRecording(_ sender: NSButton) {
        guard let action = PointerAction(rawValue: sender.tag) else { return }
        let alreadyRecording = recording?.action == action
        finishRecording()
        if alreadyRecording { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let window, event.window === window || NSApp.keyWindow === window else { return event }
            if !event.isARepeat {
                if let hotkey = Hotkey(keyDown: event) {
                    finishRecording(with: hotkey)
                } else if event.keyCode == kVK_Escape {
                    finishRecording()
                }
            }
            return nil
        }) {
            recording = (action, monitor)
        }
        refresh()
    }

    private func finishRecording(with hotkey: Hotkey? = nil) {
        guard let recording else { return }
        NSEvent.removeMonitor(recording.monitor)
        self.recording = nil
        if let hotkey { app.setHotkey(hotkey, for: recording.action) }
        refresh()
    }

    @objc private func changeStyle() {
        let index = style.indexOfSelectedItem
        guard Self.styles.indices.contains(index) else { return }
        app.pointerStyle.style = Self.styles[index]
        refresh()
    }

    @objc private func changeColor(_ sender: NSColorWell) {
        guard let rgb = PointerColors.rgb(sender.color) else { return }
        let colors = app.pointerStyle.customColors
        app.pointerStyle.customColors = sender === borderColor
            ? PointerColors(border: rgb, fill: colors.fill)
            : PointerColors(border: colors.border, fill: rgb)
        sample.colors = app.pointerStyle.colors
    }

    @objc private func previewStyle() { app.previewStyle() }

    @objc private func checkForUpdates() { app.checkForUpdates() }

    @objc private func openRelease() {
        if case .available(let release) = app.updateState { NSWorkspace.shared.open(release.url) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        loginError = nil
        do {
            if login.state == .on { try service.register() } else { try service.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        refresh()
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
