//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import Darwin
import ServiceManagement

enum Sh {
	@discardableResult
	static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: path)
		proc.arguments = args

		let stdout = Pipe()
		proc.standardOutput = stdout
		proc.standardError = Pipe()

		do { try proc.run() } catch { return (-1, "") }

		let data = stdout.fileHandleForReading.readDataToEndOfFile()
		proc.waitUntilExit()

		let text = String(data: data, encoding: .utf8)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return (proc.terminationStatus, text)
	}
}

struct DockState: Codable {
	var autohide: String?
	var autohideDelay: String?
	var corners: [String: String?]
	var menuBarAutohide: String?

	var findCursorDisabled: String?

	static let cornerNames = ["tl", "tr", "bl", "br"]

	static let legacyCornerNames = ["topleft", "topright", "bottomleft", "bottomright"]

	static func capture() -> DockState {
		var corners: [String: String?] = [:]
		for name in cornerNames {
			corners[name] = Dock.read("wvous-\(name)-corner")
		}
		return DockState(
			autohide: Dock.read("autohide"),
			autohideDelay: Dock.read("autohide-delay"),
			corners: corners,
			findCursorDisabled: Dock.readGlobal(FindCursor.key)
		)
	}
}

enum Dock {
	static func read(_ key: String) -> String? {
		let (status, out) = Sh.run("/usr/bin/defaults", ["read", "com.apple.dock", key])
		return status == 0 ? out : nil
	}

	static func write(_ key: String, bool value: Bool) {
		Sh.run("/usr/bin/defaults", ["write", "com.apple.dock", key, "-bool", value ? "true" : "false"])
	}

	static func write(_ key: String, float value: String) {
		Sh.run("/usr/bin/defaults", ["write", "com.apple.dock", key, "-float", value])
	}

	static func write(_ key: String, int value: String) {
		Sh.run("/usr/bin/defaults", ["write", "com.apple.dock", key, "-int", value])
	}

	static func delete(_ key: String) {
		Sh.run("/usr/bin/defaults", ["delete", "com.apple.dock", key])
	}

	static func restart() {
		Sh.run("/usr/bin/killall", ["Dock"])
	}

	static func readGlobal(_ key: String) -> String? {
		let (status, out) = Sh.run("/usr/bin/defaults", ["read", "-g", key])
		return status == 0 ? out : nil
	}

	static func writeGlobal(_ key: String, bool value: Bool) {
		Sh.run("/usr/bin/defaults", ["write", "-g", key, "-bool", value ? "true" : "false"])
	}

	static func deleteGlobal(_ key: String) {
		Sh.run("/usr/bin/defaults", ["delete", "-g", key])
	}
}

enum FindCursor {
	static let key = "CGDisableCursorLocationMagnification"

	private static let skyLight = dlopen(
		"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

	private typealias MainConnectionID = @convention(c) () -> Int32
	private typealias DisableFindCursor = @convention(c) (Int32, Bool) -> Int32

	private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
		guard let skyLight, let p = dlsym(skyLight, name) else { return nil }
		return unsafeBitCast(p, to: type)
	}

	private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
	private static let disableFindCursor = symbol("SLSPackagesDisableFindCursor", as: DisableFindCursor.self)

	static var isSupported: Bool { mainConnectionID != nil && disableFindCursor != nil }

	@discardableResult
	static func setDisabled(_ disabled: Bool) -> Bool {
		guard let cid = mainConnectionID?(), let setter = disableFindCursor else { return false }
		let err = setter(cid, disabled)
		if err != 0 { Log.write("FINDCURSOR setDisabled(\(disabled)) failed err=\(err)") }
		return err == 0
	}

	static func restore(to recorded: String?) {
		if let recorded {
			setDisabled(recorded == "1")
		} else {
			setDisabled(false)
			Dock.deleteGlobal(key)
		}
	}
}

final class GameMode {
	private let dockQueue = DispatchQueue(label: "com.deadeye.dockwork", qos: .userInitiated)

	private let stateURL: URL
	private(set) var isActive = false

	var disableHotCorners: Bool {
		UserDefaults.standard.object(forKey: "disableHotCorners") as? Bool ?? true
	}

	var holdDock: Bool {
		UserDefaults.standard.object(forKey: "holdDock") as? Bool ?? true
	}

	var suppressFindCursor: Bool {
		UserDefaults.standard.object(forKey: "suppressFindCursor") as? Bool ?? true
	}

	init() {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Deadeye", isDirectory: true)
		try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		stateURL = support.appendingPathComponent("dock-state.json")
	}

	static func cleanUpLegacyCornerKeys() {
		var removed: [String] = []
		for name in DockState.legacyCornerNames {
			let key = "wvous-\(name)-corner"
			guard Dock.read(key) != nil else { continue }
			Dock.delete(key)
			removed.append(key)
		}
		guard !removed.isEmpty else { return }
		Log.write("DOCK removed junk keys written by an earlier version: "
			+ removed.joined(separator: ", "))
	}

	static func selfHeal() {
		guard Dock.read("autohide-delay") == "100000" else { return }
		Log.write("DOCK self-heal: stranded autohide-delay=100000 with no state file, clearing")
		Dock.delete("autohide-delay")
		Dock.restart()
	}

	func recoverIfNeeded() -> Bool {
		guard FileManager.default.fileExists(atPath: stateURL.path) else { return false }
		restore(synchronously: true)
		return true
	}

	func enable() {
		guard !isActive else { return }
		isActive = true

		Stats.recordSession()
		let corners = disableHotCorners
		let dock = holdDock
		let findCursor = suppressFindCursor
		let url = stateURL

		guard dock || corners || findCursor else {
			Log.write("DOCK enable: nothing to hold back (dock and hot corners both off)")
			return
		}

		dockQueue.async {
			if !FileManager.default.fileExists(atPath: url.path) {
				let state = DockState.capture()
				if let data = try? JSONEncoder().encode(state) {
					try? data.write(to: url, options: .atomic)
				}
			}

			Log.write("DOCK enable: saved autohide=\(Dock.read("autohide") ?? "absent") "
				+ "delay=\(Dock.read("autohide-delay") ?? "absent")")

			if dock {
				Dock.write("autohide", bool: true)
				Dock.write("autohide-delay", float: "100000")
			}

			if findCursor {
				FindCursor.setDisabled(true)
			}

			if corners {
				for name in DockState.cornerNames {
					Dock.write("wvous-\(name)-corner", int: "0")
				}
			}
			Dock.restart()
		}
	}

	func restore(synchronously: Bool = false) {
		guard let data = try? Data(contentsOf: stateURL),
		      let state = try? JSONDecoder().decode(DockState.self, from: data)
		else {
			Log.write("DOCK state file unreadable — self-healing instead of discarding it")
			try? FileManager.default.removeItem(at: stateURL)
			Self.selfHeal()
			isActive = false
			return
		}

		isActive = false

		let url = stateURL
		let work = {
			if let delay = state.autohideDelay {
				Dock.write("autohide-delay", float: delay)
			} else {
				Dock.delete("autohide-delay")
			}

			if let autohide = state.autohide {
				Dock.write("autohide", bool: autohide == "1")
			} else {
				Dock.delete("autohide")
			}

			for name in DockState.cornerNames {
				guard let recorded = state.corners[name] else { continue }
				if let value = recorded {
					Dock.write("wvous-\(name)-corner", int: value)
				} else {
					Dock.delete("wvous-\(name)-corner")
				}
			}

			FindCursor.restore(to: state.findCursorDisabled)

			Dock.restart()
			try? FileManager.default.removeItem(at: url)
			Log.write("DOCK restored: autohide=\(Dock.read("autohide") ?? "absent") "
				+ "delay=\(Dock.read("autohide-delay") ?? "absent")")
		}
		if synchronously { dockQueue.sync(execute: work) } else { dockQueue.async(execute: work) }
	}
}

enum Bottles {
	struct Info {
		let name: String
		let grabFullscreen: String?
		let retinaMode: String?
	}

	static var root: URL {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("CrossOver/Bottles", isDirectory: true)
	}

	static func all() -> [Info] {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		return names.sorted().compactMap { name in
			let reg = root.appendingPathComponent("\(name)/user.reg")
			guard let text = try? String(contentsOf: reg, encoding: .utf8) else { return nil }
			return Info(
				name: name,
				grabFullscreen: value(of: "GrabFullscreen", in: text),
				retinaMode: value(of: "RetinaMode", in: text)
			)
		}
	}

	private static func value(of key: String, in text: String) -> String? {
		for line in text.split(separator: "\n") where line.hasPrefix("\"\(key)\"=") {
			let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
			if parts.count >= 4 { return String(parts[3]) }
		}
		return nil
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private let gameMode = GameMode()
	private let cursorGuard = CursorGuard()
	private let hotKey = GlobalHotKey()

	private let cursorHotKey = GlobalHotKey()

	private let cursorFunctionKey = GlobalHotKey()
	private let shield = MenuBarShield()
	private let veil = MenuBarVeil()
	private let cursorSuppressor = CursorSuppressor()
	private let suspender = AppSuspender()

	private var suspendApps: Bool {
		get { UserDefaults.standard.object(forKey: "suspendApps") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "suspendApps") }
	}

	private var shieldMenuBar: Bool {
		get { UserDefaults.standard.object(forKey: "shieldMenuBar") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "shieldMenuBar") }
	}
	private var statusItem: NSStatusItem!
	private var timer: Timer?
	private var signalSources: [DispatchSourceSignal] = []

	private var detectedGames: [String] = []
	private var enabledAutomatically = false

	private var manualOverrideThisSession = false

	private let updateMenuItem = NSMenuItem(
		title: "", action: nil, keyEquivalent: "")
	private let permissionMenuItem = NSMenuItem(
		title: "⚠︎  Needs Accessibility (click to fix)", action: nil, keyEquivalent: "")
	private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let statsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let cursorStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let toggleMenuItem = NSMenuItem(title: "Turn Deadeye Off", action: #selector(toggle), keyEquivalent: "g")

	private let autoItem = NSMenuItem(title: "Activate automatically",
	                                  action: #selector(toggleAutoEnable), keyEquivalent: "")
	private let shieldItem = NSMenuItem(title: "Menu bar clicks",
	                                    action: #selector(toggleShield), keyEquivalent: "")
	private let dockItem = NSMenuItem(title: "The Dock",
	                                  action: #selector(toggleDock), keyEquivalent: "")
	private let cornersItem = NSMenuItem(title: "Hot corners",
	                                     action: #selector(toggleHotCorners), keyEquivalent: "")
	private let findCursorItem = NSMenuItem(title: "Shake to find the cursor",
	                                        action: #selector(toggleFindCursor), keyEquivalent: "")
	private let suspendItem = NSMenuItem(title: "Overlay apps",
	                                     action: #selector(toggleSuspend), keyEquivalent: "")
	private let loginItem = NSMenuItem(title: "Launch at login",
	                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

	private let cursorItem = NSMenuItem(title: "Show the macOS cursor",
	                                    action: #selector(toggleCursorVisible), keyEquivalent: "c")

	private var autoEnable: Bool {
		get { UserDefaults.standard.object(forKey: "autoEnable") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "autoEnable") }
	}

	private var guardCursor: Bool {
		get { UserDefaults.standard.object(forKey: "guardCursor") as? Bool ?? false }
		set { UserDefaults.standard.set(newValue, forKey: "guardCursor") }
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		if Install.moveToApplicationsIfNeeded() { return }

		CursorGuard.releaseStaleLock()

		GameMode.cleanUpLegacyCornerKeys()
		Stats.recordFirstLaunchIfNeeded()
		Stats.migrateLegacySupportFlag()
		Log.write("=== launched, released any stale lock ===")

		GameMode.selfHeal()
		suspender.recoverIfNeeded(gameIsRunning: !Wine.runningGames().isEmpty)
		let recovered = gameMode.recoverIfNeeded()

		buildMenu()
		installSignalHandlers()

		hotKey.register(keyCode: GlobalHotKey.keyG,
		                modifiers: GlobalHotKey.controlOptionCommand) { [weak self] in
			self?.toggle()
		}

		cursorHotKey.register(keyCode: GlobalHotKey.keyC,
		                      modifiers: GlobalHotKey.controlOption,
		                      identifier: 2) { [weak self] in
			self?.toggleCursorVisible()
		}

		cursorFunctionKey.register(keyCode: GlobalHotKey.keyF2,
		                           modifiers: GlobalHotKey.noModifiers,
		                           identifier: 3) { [weak self] in
			self?.toggleCursorVisible()
		}

		let poller = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
			self?.poll()
		}
		RunLoop.main.add(poller, forMode: .common)
		timer = poller

		NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification,
			object: nil, queue: .main) { [weak self] _ in self?.poll() }

		NotificationCenter.default.addObserver(
			forName: NSApplication.didChangeScreenParametersNotification,
			object: nil, queue: .main) { [weak self] _ in self?.shield.screensChanged() }

		poll()

		Updater.check { [weak self] _ in self?.refreshStatus() }

		if recovered {
			notify("Dock restored",
			       "A previous session ended without restoring the Dock, so it was repaired at launch.")
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		pulseTimer?.invalidate()
		hotKey.unregister()
		cursorHotKey.unregister()
		cursorFunctionKey.unregister()
		shield.lower()
		veil.lower()
		cursorSuppressor.lower()
		cursorGuard.stop()
		gameMode.restore(synchronously: true)
	}

	private func symbol(_ name: String) -> NSImage? {
		guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		else { return nil }
		return image.withSymbolConfiguration(
			NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
	}

	private func sectionHeader(_ title: String) -> NSMenuItem {
		if #available(macOS 14.0, *) {
			return NSMenuItem.sectionHeader(title: title)
		}
		let item = NSMenuItem()
		item.isEnabled = false
		item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
			.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
			.foregroundColor: NSColor.tertiaryLabelColor,
			.kern: 0.6,
		])
		return item
	}

	private func headerItem() -> NSMenuItem {
		let item = NSMenuItem()
		item.isEnabled = false
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
		let title = NSMutableAttributedString(string: "Deadeye", attributes: [
			.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
			.foregroundColor: NSColor.labelColor,
		])
		if !version.isEmpty {
			title.append(NSAttributedString(string: "  \(version)", attributes: [
				.font: NSFont.systemFont(ofSize: 11, weight: .regular),
				.foregroundColor: NSColor.tertiaryLabelColor,
			]))
		}
		item.attributedTitle = title
		item.image = Icon.menuBar(.idle, pointSize: 15)
		return item
	}

	private func statusText(_ text: String, _ colour: NSColor) -> NSAttributedString {
		let line = NSMutableAttributedString(string: "\u{25CF}  ", attributes: [
			.font: NSFont.systemFont(ofSize: 9),
			.foregroundColor: colour,
		])
		line.append(NSAttributedString(string: text, attributes: [
			.font: NSFont.systemFont(ofSize: 12, weight: .regular),
			.foregroundColor: NSColor.secondaryLabelColor,
		]))
		return line
	}

	private func buildMenu() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.image = icon(active: false)

		let menu = NSMenu()
		menu.delegate = self

		menu.addItem(headerItem())

		updateMenuItem.target = self
		updateMenuItem.action = #selector(openReleases)
		updateMenuItem.isHidden = true
		updateMenuItem.image = symbol("arrow.down.circle.fill")
		menu.addItem(updateMenuItem)

		permissionMenuItem.target = self
		permissionMenuItem.action = #selector(openAccessibilitySettings)
		permissionMenuItem.isHidden = true
		permissionMenuItem.image = symbol("exclamationmark.triangle.fill")
		menu.addItem(permissionMenuItem)

		statusMenuItem.isEnabled = false
		menu.addItem(statusMenuItem)
		cursorStatusMenuItem.isEnabled = false
		menu.addItem(cursorStatusMenuItem)

		menu.addItem(.separator())

		toggleMenuItem.target = self
		toggleMenuItem.keyEquivalentModifierMask = [.control, .option, .command]
		menu.addItem(toggleMenuItem)

		cursorItem.target = self
		cursorItem.keyEquivalent = String(UnicodeScalar(NSF2FunctionKey)!)
		cursorItem.keyEquivalentModifierMask = []
		menu.addItem(cursorItem)

		menu.addItem(.separator())

		let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
		settings.submenu = buildSettingsMenu()
		menu.addItem(settings)

		let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
		tools.submenu = buildToolsMenu()
		menu.addItem(tools)

		let support = NSMenuItem(title: "Support Deadeye", action: #selector(openDonate), keyEquivalent: "")
		support.target = self
		support.submenu = buildSupportMenu()
		menu.addItem(support)

		menu.addItem(.separator())

		let quit = NSMenuItem(title: "Quit Deadeye", action: #selector(quit), keyEquivalent: "q")
		quit.target = self
		quit.keyEquivalentModifierMask = [.control, .option, .command]
		menu.addItem(quit)

		statusItem.menu = menu
	}

	private func buildSettingsMenu() -> NSMenu {
		let m = NSMenu()
		m.delegate = self

		m.addItem(sectionHeader("Hold back while playing"))
		for item in [shieldItem, dockItem, cornersItem, findCursorItem, suspendItem] {
			item.target = self
			m.addItem(item)
		}

		let editList = NSMenuItem(title: "Edit app list…", action: #selector(editAppList), keyEquivalent: "")
		editList.target = self
		editList.indentationLevel = 1
		m.addItem(editList)

		m.addItem(sectionHeader("Deadeye"))
		for item in [autoItem, loginItem] {
			item.target = self
			m.addItem(item)
		}

		m.addItem(.separator())

		let reset = NSMenuItem(title: "Reset to recommended",
		                       action: #selector(resetToRecommended), keyEquivalent: "")
		reset.target = self
		m.addItem(reset)

		let note = NSMenuItem()
		note.isEnabled = false
		note.attributedTitle = NSAttributedString(
			string: "The Dock and hot corners apply next time Deadeye arms.",
			attributes: [.font: NSFont.systemFont(ofSize: 10),
			             .foregroundColor: NSColor.tertiaryLabelColor])
		m.addItem(note)
		return m
	}

	private func buildToolsMenu() -> NSMenu {
		let m = NSMenu()
		for (title, sel) in [("Check for Updates…", #selector(checkForUpdates)),
		                     ("Check Game Settings…", #selector(checkBottles)),
		                     ("Open CrossOver", #selector(launchCrossOver)),
		                     ("Show Log…", #selector(showLog))] {
			let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
			item.target = self
			m.addItem(item)
		}
		return m
	}

	private func buildSupportMenu() -> NSMenu {
		let m = NSMenu()
		statsMenuItem.isEnabled = false
		m.addItem(statsMenuItem)
		m.addItem(.separator())
		for (title, sel) in [("Buy me a coffee", #selector(openDonate)),
		                     ("Star on GitHub", #selector(openRepo)),
		                     ("Tell someone about it…", #selector(shareApp))] {
			let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
			item.target = self
			m.addItem(item)
		}
		return m
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		refreshStatus()

		autoItem.state = autoEnable ? .on : .off
		shieldItem.state = shieldMenuBar ? .on : .off
		dockItem.state = gameMode.holdDock ? .on : .off
		cornersItem.state = gameMode.disableHotCorners ? .on : .off
		findCursorItem.state = gameMode.suppressFindCursor ? .on : .off
		suspendItem.state = suspendApps ? .on : .off
		loginItem.state = launchAtLogin ? .on : .off
		cursorItem.title = cursorSuppressor.isPaused
			? "Hide the macOS Cursor" : "Show the macOS Cursor"
		cursorItem.isHidden = detectedGames.isEmpty

		if let summary = Stats.summary {
			statsMenuItem.title = summary
			statsMenuItem.isHidden = false
		} else {
			statsMenuItem.isHidden = true
		}
		toggleMenuItem.title = gameMode.isActive ? "Turn Deadeye Off" : "Turn Deadeye On"
	}

	private var accessibilityMissing: Bool {
		shieldMenuBar && !MenuBarShield.ensureAccessibility(prompt: false)
	}

	private func icon(active: Bool) -> NSImage? {
		Icon.menuBar(active ? .active : .idle, pointSize: 18)
	}

	private var lastLoggedGames: [String] = []

	private var wasPlaying = false

	private var wasActive = false

	private var pulseTimer: Timer?
	private var pulseTarget: Bool?

	private func poll() {
		detectedGames = Wine.runningGames()

		if detectedGames != lastLoggedGames {
			lastLoggedGames = detectedGames
			Log.write("games detected -> \(detectedGames)  guardPref=\(guardCursor)")
		}

		if detectedGames.isEmpty, manualOverrideThisSession {
			manualOverrideThisSession = false
			Log.write("MANUAL override cleared — game exited, automation resumes")
		}

		if autoEnable {
			if !detectedGames.isEmpty, !gameMode.isActive, !manualOverrideThisSession {
				setActive(true, automatic: true)
			} else if detectedGames.isEmpty, gameMode.isActive, enabledAutomatically {
				setActive(false, automatic: false)
			}
		}

		if gameMode.isActive != wasActive {
			pulse(to: gameMode.isActive)
			wasActive = gameMode.isActive
		}

		syncCursorGuard()
		refreshStatus()
	}

	private func pulse(to target: Bool) {
		if pulseTimer != nil, pulseTarget == target { return }
		pulseTarget = target
		Log.write("BLINK start -> \(target ? "active" : "idle")")
		pulseTimer?.invalidate()
		let start = Date()
		let duration = 0.45

		let leaving: Icon.State = target ? .idle : .active
		let entering: Icon.State = target ? .active : .idle

		pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
			guard let self else { timer.invalidate(); return }
			let elapsed = Date().timeIntervalSince(start)

			guard elapsed < duration else {
				timer.invalidate()
				self.pulseTimer = nil
				self.pulseTarget = nil
				self.statusItem.button?.image = self.icon(active: self.gameMode.isActive)
				return
			}

			let progress = elapsed / duration
			let lidClose = CGFloat(sin(progress * .pi))

			let state = progress < 0.5 ? leaving : entering
			self.statusItem.button?.image = Icon.menuBar(state, pointSize: 18, lidClose: lidClose)
		}
	}

	private func refreshStatus() {
		if pulseTimer == nil {
			statusItem.button?.image = icon(active: gameMode.isActive)
		}

		let games = detectedGames.isEmpty ? nil : detectedGames.joined(separator: ", ")
		switch (gameMode.isActive, games) {
		case (true, let g?):
			statusMenuItem.attributedTitle = statusText("Protecting \(g)", .systemGreen)
		case (true, nil):
			statusMenuItem.attributedTitle = statusText("On, no game yet", .systemGreen)
		case (false, let g?):
			statusMenuItem.attributedTitle = statusText("Off, \(g) running", .systemOrange)
		case (false, nil):
			statusMenuItem.attributedTitle = statusText("Idle", .tertiaryLabelColor)
		}

		let cursor: String
		if !guardCursor {
			cursor = "off"
		} else if cursorGuard.isActive {
			cursor = "guarding menu bar"
		} else {
			cursor = "idle, no game"
		}
		let bar: String
		let barColour: NSColor
		if !shieldMenuBar {
			bar = "Menu bar unguarded"; barColour = .tertiaryLabelColor
		} else if accessibilityMissing {
			bar = "Needs Accessibility"; barColour = .systemRed
		} else if shield.isUp {
			bar = veil.isUp && cursorSuppressor.isUp
				? "Clicks go to the game"
				: "Clicks discarded"
			barColour = .systemGreen
		} else {
			bar = "Armed, waiting"; barColour = .secondaryLabelColor
		}
		cursorStatusMenuItem.attributedTitle = statusText(bar, barColour)
		permissionMenuItem.isHidden = !accessibilityMissing

		if let v = Updater.availableVersion {
			updateMenuItem.title = "Update available: v\(v)"
			updateMenuItem.isHidden = false
		} else {
			updateMenuItem.isHidden = true
		}
		_ = cursor
	}

	@objc private func toggleCursorVisible() {
		guard !detectedGames.isEmpty else {
			Log.write("CURSOR toggle ignored — no game running")
			return
		}
		Log.write("CURSOR toggle requested (currently "
			+ (cursorSuppressor.isPaused ? "visible" : "hidden") + ")")
		cursorSuppressor.isPaused.toggle()
		refreshStatus()
	}

	@objc private func toggle() {
		let turningOn = !gameMode.isActive

		if turningOn {
			manualOverrideThisSession = false
		} else if !detectedGames.isEmpty {
			manualOverrideThisSession = true
			Log.write("MANUAL off while \(detectedGames.joined(separator: ", ")) running"
				+ " — automation held off until it exits")
		}

		setActive(turningOn, automatic: false)
	}

	private func setActive(_ active: Bool, automatic: Bool) {
		guard active != gameMode.isActive else { return }

		if active { gameMode.enable() } else { gameMode.restore() }
		enabledAutomatically = automatic

		pulse(to: active)
		wasActive = active
		refreshStatus()
	}

	@objc private func toggleAutoEnable() {
		autoEnable = !autoEnable
	}

	@objc private func toggleHotCorners() {
		let now = !gameMode.disableHotCorners
		UserDefaults.standard.set(now, forKey: "disableHotCorners")
	}

	@objc private func toggleFindCursor() {
		UserDefaults.standard.set(!gameMode.suppressFindCursor, forKey: "suppressFindCursor")
	}

	@objc private func toggleDock() {
		UserDefaults.standard.set(!gameMode.holdDock, forKey: "holdDock")
	}

	@objc private func resetToRecommended() {
		let defaults = UserDefaults.standard
		defaults.set(true, forKey: "shieldMenuBar")
		defaults.set(true, forKey: "holdDock")
		defaults.set(true, forKey: "disableHotCorners")
		defaults.set(true, forKey: "suppressFindCursor")
		defaults.set(true, forKey: "suspendApps")
		defaults.set(true, forKey: "autoEnable")
		Log.write("SETTINGS reset to recommended")
		syncCursorGuard()
		refreshStatus()
	}

	@objc private func showLog() {
		NSWorkspace.shared.selectFile(Log.url.path, inFileViewerRootedAtPath: "")
	}


	private var launchAtLogin: Bool {
		SMAppService.mainApp.status == .enabled
	}

	@objc private func toggleLaunchAtLogin() {
		do {
			if launchAtLogin {
				try SMAppService.mainApp.unregister()
				Log.write("LOGIN unregistered")
			} else {
				try SMAppService.mainApp.register()
				Log.write("LOGIN registered")
			}
		} catch {
			Log.write("LOGIN failed: \(error.localizedDescription)")
			let alert = NSAlert()
			alert.messageText = "Could not change the login item"
			alert.informativeText = error.localizedDescription
			alert.addButton(withTitle: "OK")
			NSApp.activate(ignoringOtherApps: true)
			alert.runModal()
		}
	}

	private func maybeAskForSupport() {
		guard let ask = Stats.dueSupportAsk else { return }
		Stats.markAsked(ask)

		let alert = NSAlert()
		alert.icon = NSApp.applicationIconImage
		alert.alertStyle = .informational

		switch ask {
		case .early:
			alert.messageText = "Deadeye has been earning its keep"
			alert.informativeText = """
			\(Stats.summary ?? "")

			It is free and always will be, and it has no analytics, no account and \
			nothing to upgrade. If it has saved you a ruined mission, a coffee helps, \
			and starring the repo or telling another Mac gamer helps just as much.
			"""
		case .final:
			alert.messageText = "Still here, still quiet"
			alert.informativeText = """
			\(Stats.summary ?? "")

			You have had Deadeye a week. If it has been worth having, a coffee keeps it \
			going; a star or a word to another Mac gamer is worth just as much.

			This is the last time it will ask.
			"""
		}

		alert.addButton(withTitle: "Buy me a coffee")
		alert.addButton(withTitle: "Star on GitHub")
		alert.addButton(withTitle: "Not now")
		NSApp.activate(ignoringOtherApps: true)

		switch alert.runModal() {
		case .alertFirstButtonReturn:  openDonate()
		case .alertSecondButtonReturn: openRepo()
		default: break
		}
		Log.write("SUPPORT \(ask) ask shown, \(Stats.daysSinceInstall ?? -1) days after install,"
			+ " \(Stats.sessions) sessions")
	}

	@objc private func openReleases() {
		NSWorkspace.shared.open(Updater.releasesURL)
	}

	@objc private func checkForUpdates() {
		Updater.check(force: true) { [weak self] result in
			self?.refreshStatus()
			let alert = NSAlert()
			switch result {
			case .couldNotCheck(let why):
				alert.messageText = "Could not check for updates"
				alert.informativeText = "GitHub did not answer: \(why)"
				alert.addButton(withTitle: "OK")
				NSApp.activate(ignoringOtherApps: true)
				alert.runModal()
				return
			case .available(let version):
				alert.messageText = "Deadeye v\(version) is available"
				alert.informativeText = "You have v\(Updater.currentVersion)."
				alert.addButton(withTitle: "Open Release Page")
				alert.addButton(withTitle: "Later")
				NSApp.activate(ignoringOtherApps: true)
				if alert.runModal() == .alertFirstButtonReturn { self?.openReleases() }
				Updater.markAnnounced(version)
			case .upToDate:
				alert.messageText = "Deadeye is up to date"
				alert.informativeText = "You are on v\(Updater.currentVersion)."
				alert.addButton(withTitle: "OK")
				NSApp.activate(ignoringOtherApps: true)
				alert.runModal()
			}
		}
	}

	private func announceUpdateIfAppropriate() {
		guard detectedGames.isEmpty, let version = Updater.availableVersion,
		      Updater.shouldAnnounce(version) else { return }
		Updater.markAnnounced(version)

		let alert = NSAlert()
		alert.messageText = "Deadeye v\(version) is available"
		alert.informativeText = "You are on v\(Updater.currentVersion). Release notes are on GitHub."
		alert.addButton(withTitle: "Open Release Page")
		alert.addButton(withTitle: "Later")
		NSApp.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertFirstButtonReturn { openReleases() }
	}

	@objc private func openRepo() {
		NSWorkspace.shared.open(URL(string: "https://github.com/inulute/deadeye")!)
	}

	@objc private func shareApp() {
		let text = """
		Deadeye: a free menu bar app that stops macOS interrupting Mac games. \
		It keeps stray clicks out of the menu bar, hides the Dock and quits notch overlays \
		while you play, then puts everything back.

		https://github.com/inulute/deadeye
		"""
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)

		let alert = NSAlert()
		alert.messageText = "Copied to your clipboard"
		alert.informativeText = "Paste it wherever Mac gamers hang out: r/macgaming, a Discord, anywhere. That helps more than money does at this stage."
		alert.addButton(withTitle: "OK")
		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}

	@objc private func toggleSuspend() {
		suspendApps = !suspendApps
		if !suspendApps { suspender.restore() }
	}

	@objc private func editAppList() {
		suspender.revealConfig()
	}

	@objc private func toggleShield() {
		shieldMenuBar = !shieldMenuBar
		syncCursorGuard()
	}

	@objc private func toggleGuard() {
		guardCursor = !guardCursor
		syncCursorGuard()
	}

	private func syncCursorGuard() {
		cursorGuard.gameNames = detectedGames
		cursorGuard.logFrontmostIfChanged()
		if guardCursor, !detectedGames.isEmpty {
			cursorGuard.start()
		} else {
			cursorGuard.stop()
		}

		if suspendApps, !detectedGames.isEmpty {
			suspender.suspend()
		} else {
			suspender.restore()
		}

		if detectedGames.isEmpty, wasPlaying {
			wasPlaying = false
			cursorSuppressor.isPaused = false
			Updater.check(force: true) { [weak self] _ in
				self?.refreshStatus()
				self?.announceUpdateIfAppropriate()
			}
			maybeAskForSupport()
		} else if !detectedGames.isEmpty {
			wasPlaying = true
		}

		shield.gameNames = detectedGames
		if shieldMenuBar, !detectedGames.isEmpty, gameIsFrontmost() {
			shield.refreshGameWindows()
			if shield.gameCoversStrip {
				veil.raise()
				cursorSuppressor.raise()
				veil.reassert()
				cursorSuppressor.reassert()
			} else {
				veil.lower()
				cursorSuppressor.lower()
			}
			shield.veilIsUp = veil.isUp
			shield.cursorSuppressed = cursorSuppressor.isUp
			shield.afterDelivering = { [weak self] in
				self?.cursorSuppressor.armForImminentReveal()
			}
			shield.raise()
		} else {
			shield.lower()
			veil.lower()
			cursorSuppressor.lower()
			shield.veilIsUp = false
			shield.cursorSuppressed = false
			shield.gameWindowRects = []
		}
	}

	private func gameIsFrontmost() -> Bool {
		guard let front = NSWorkspace.shared.frontmostApplication else { return false }
		if let bundle = front.bundleIdentifier?.lowercased(), bundle.hasPrefix("com.codeweavers") {
			return true
		}
		guard let name = front.localizedName else { return false }
		return detectedGames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
	}

	@objc private func checkBottles() {
		let bottles = Bottles.all()

		let alert = NSAlert()
		alert.messageText = "CrossOver Bottle Settings"

		if bottles.isEmpty {
			alert.informativeText = "No CrossOver bottles found in:\n\(Bottles.root.path)"
		} else {
			var lines: [String] = []
			for b in bottles {
				lines.append("\(b.name)\n    GrabFullscreen: \(b.grabFullscreen ?? "unset")"
					+ "    RetinaMode: \(b.retinaMode ?? "unset")")
			}
			lines.append("")
			lines.append("GrabFullscreen should be Y on a game bottle. It is winecfg > "
				+ "Graphics > “Automatically capture the mouse in full-screen windows”. "
				+ "N is normal and correct for non-game app profiles such as WinSCP.")
			alert.informativeText = lines.joined(separator: "\n")
		}

		alert.addButton(withTitle: "OK")
		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}

	@objc private func launchCrossOver() {
		let url = URL(fileURLWithPath: "/Applications/CrossOver.app")
		NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
	}

	static let donateURL = URL(string: "https://support.inulute.com")!

	@objc private func openAccessibilitySettings() {
		let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
		NSWorkspace.shared.open(url)
	}

	@objc private func openDonate() {
		NSWorkspace.shared.open(Self.donateURL)
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}

	private func installSignalHandlers() {
		for sig in [SIGTERM, SIGINT, SIGHUP] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [weak self] in
				self?.shield.lower()
				self?.veil.lower()
				self?.cursorSuppressor.lower()
				self?.cursorGuard.stop()
				self?.gameMode.restore(synchronously: true)
				exit(0)
			}
			source.resume()
			signalSources.append(source)
		}
	}

	private func notify(_ title: String, _ body: String) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = body
		alert.addButton(withTitle: "OK")
		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
