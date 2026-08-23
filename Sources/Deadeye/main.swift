//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Deadeye
//
//  A menu bar app that disables the Dock while a CrossOver/Wine game is running,
//  and restores it exactly as it was afterwards.
//
//  The Dock keeps its screen-edge tracking zones armed over any window that is
//  not a *true* native fullscreen window. Wine deliberately avoids native
//  fullscreen (it would put the game in its own Space and break Wine's window
//  management), so the Dock keeps stealing the pointer and tearing down the
//  cursor capture that relative-mouse games depend on. Result: the macOS cursor
//  escapes the game, and trackpad gestures freeze.
//
//  Setting autohide-delay to 100000 seconds means the Dock never slides out, so
//  those zones never fire.
//

import AppKit
import Darwin
import ServiceManagement

// MARK: - Shell

enum Sh {
	/// Runs a tool and returns (exitStatus, trimmedStdout).
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

// MARK: - Dock state

/// A `defaults` key has three distinct states — absent, present-and-false,
/// present-and-true — and `defaults delete` is not the same as
/// `defaults write -bool false`. Recording which one we saw is the whole reason
/// this type exists; collapsing them is how the original shell guide loses a
/// user's custom autohide-delay permanently.
struct DockState: Codable {
	var autohide: String?          // nil == key absent
	var autohideDelay: String?
	var corners: [String: String?] // "topleft" -> value, nil == absent
	/// Retired. Kept only so state files written by an earlier version still
	/// decode; nothing reads or writes it now. Setting NSGlobalDomain
	/// `_HIHideMenuBar` turned out to be a system-wide footgun: it is read by
	/// HIToolbox at app launch, so it never applied to an already-running game,
	/// while a crash between enable and restore left EVERY app on the machine
	/// hiding its menu bar with no state file left to repair it.
	var menuBarAutohide: String?

	/// macOS names the hot corners `tl`, `tr`, `bl`, `br` — not `topleft` and friends,
	/// which is what this used to write.
	///
	/// The consequence was worse than the feature not working. `defaults write` creates
	/// whatever key it is given, so every session wrote four keys macOS has never read
	/// (`wvous-topleft-corner` and so on) while the real corners stayed armed. The
	/// feature reported success, did nothing, and left junk in the user's Dock
	/// preferences. `cleanUpLegacyCornerKeys()` removes it.
	static let cornerNames = ["tl", "tr", "bl", "br"]

	/// The misspelled keys written by earlier versions.
	static let legacyCornerNames = ["topleft", "topright", "bottomleft", "bottomright"]

	static func capture() -> DockState {
		var corners: [String: String?] = [:]
		for name in cornerNames {
			corners[name] = Dock.read("wvous-\(name)-corner")
		}
		return DockState(
			autohide: Dock.read("autohide"),
			autohideDelay: Dock.read("autohide-delay"),
			corners: corners
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

	// The menu bar lives in NSGlobalDomain, not com.apple.dock. It owns the top
	// screen edge the same way the Dock owns the bottom one, which is what an
	// escaped cursor hits when a game pans the view upward.

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

// MARK: - Game mode

final class GameMode {
	/// Dock changes run here, never on the main thread.
	///
	/// Applying or restoring spawns several `defaults` processes and a `killall
	/// Dock`, which together take a few hundred milliseconds. Run on the main thread
	/// that blocks the run loop, so the activation blink — a main-thread Timer —
	/// could not draw a frame until the work finished. Serial, so an enable can never
	/// interleave with a restore.
	private let dockQueue = DispatchQueue(label: "com.deadeye.dockwork", qos: .userInitiated)

	private let stateURL: URL
	private(set) var isActive = false

	/// On by default, like the other three hold-backs. A hot corner fires from the
	/// same escaped pointer that everything else here defends against — throwing you
	/// into Mission Control mid-fight — and it is restored when the game exits, so the
	/// cost of having it on is nothing and the cost of having it off is a lost session.
	///
	/// Kept as a `Bool?` read rather than `bool(forKey:)` so that "absent" means
	/// "default" instead of "off", which is what made this silently off for everyone.
	var disableHotCorners: Bool {
		UserDefaults.standard.object(forKey: "disableHotCorners") as? Bool ?? true
	}

	/// Whether to hold the Dock down while a game runs. On by default, because it is
	/// the reason this class exists — the Dock's screen-edge tracking stays armed over
	/// a fullscreen game and steals the pointer mid-aim.
	///
	/// It had no switch at all until now, which made the menu quietly inconsistent:
	/// the menu bar, hot corners and overlay apps could each be turned off, and the
	/// most invasive of the four could not.
	var holdDock: Bool {
		UserDefaults.standard.object(forKey: "holdDock") as? Bool ?? true
	}

	init() {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Deadeye", isDirectory: true)
		try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		stateURL = support.appendingPathComponent("dock-state.json")
	}

	/// `autohide-delay` of 100000 is a value no human sets: it is this app's marker
	/// and nothing else. If it is present when no state file exists, a previous run
	/// was interrupted between applying and restoring, and the record of what to
	/// restore to is gone. Absent that record, the safe assumption is the macOS
	/// default — the Dock's delay simply should not exist.
	///
	/// This is the lesson from stranding `_HIHideMenuBar` across an entire machine:
	/// a restore that depends on a file, and then deletes that file, has no way back
	/// if it is interrupted. A setting worth changing is worth being able to detect
	/// as wrong without any bookkeeping.
	/// Deletes the four keys earlier versions invented. They are inert — macOS never
	/// reads them — but they are ours, they are wrong, and leaving litter in someone
	/// else's preferences is not acceptable just because it is harmless.
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

	/// A leftover state file means a previous run was killed before it could
	/// restore — SIGKILL, a panic, or power loss. Replay it now, because
	/// nothing else ever will.
	func recoverIfNeeded() -> Bool {
		guard FileManager.default.fileExists(atPath: stateURL.path) else { return false }
		restore(synchronously: true)
		return true
	}

	func enable() {
		guard !isActive else { return }
		// Claim immediately. Applying takes ~65ms of `defaults` subprocesses, and an
		// app-activation notification can drive a second poll inside that window;
		// setting this at the end let enable() re-enter itself.
		isActive = true

		Stats.recordSession()
		let corners = disableHotCorners
		let dock = holdDock
		let url = stateURL

		// Nothing to apply and nothing to capture: skip the subprocesses and the Dock
		// restart entirely rather than writing a state file that restores to itself.
		guard dock || corners else {
			Log.write("DOCK enable: nothing to hold back (dock and hot corners both off)")
			return
		}

		dockQueue.async {
			// Capturing reads six defaults keys, so it belongs off the main thread too.
			// It must run before the writes below, which the serial queue guarantees.
			//
			// Only capture if no session is already recorded, otherwise a second
			// enable would save the *disabled* Dock as the state to return to.
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

			if corners {
				for name in DockState.cornerNames {
					Dock.write("wvous-\(name)-corner", int: "0")
				}
			}
			Dock.restart()
		}
	}

	/// Safe to call repeatedly and from a terminate handler; a missing state file
	/// means there is nothing to undo.
	func restore(synchronously: Bool = false) {
		guard let data = try? Data(contentsOf: stateURL),
		      let state = try? JSONDecoder().decode(DockState.self, from: data)
		else {
			// Drop an unreadable or corrupt file rather than leaving it in place:
			// enable() skips capturing state whenever a file exists, so a file we
			// cannot decode would otherwise make every later session restore to
			// nothing.
			Log.write("DOCK state file unreadable — self-healing instead of discarding it")
			try? FileManager.default.removeItem(at: stateURL)
			Self.selfHeal()
			isActive = false
			return
		}

		// Flip the flag first and on this thread, so the caller sees the state change
		// immediately and can start the blink. Everything below is subprocess work.
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
				// Only act on corners this state file actually recorded. A file written
				// by a version that used the misspelled key names has nothing to say
				// about "tl", and treating that silence as "there was no value" would
				// delete a hot corner the user had configured.
				guard let recorded = state.corners[name] else { continue }
				if let value = recorded {
					Dock.write("wvous-\(name)-corner", int: value)
				} else {
					Dock.delete("wvous-\(name)-corner")
				}
			}

			Dock.restart()
			try? FileManager.default.removeItem(at: url)
			Log.write("DOCK restored: autohide=\(Dock.read("autohide") ?? "absent") "
				+ "delay=\(Dock.read("autohide-delay") ?? "absent")")
		}
		// On quit or a signal there is no later run loop to service an async block, so
		// the work has to finish before this returns.
		//
		// `dockQueue.sync` rather than calling `work()` directly: enable() queues its
		// writes on this same serial queue, and running the restore off-queue let it
		// overtake them. A quit ~40ms after arming did exactly that — the restore wrote
		// the Dock back and deleted the state file, then the queue drained and enable's
		// `autohide=true` + `autohide-delay=100000` landed on top, leaving the Dock
		// hidden with nothing left to undo it. The next launch then captured that as
		// the user's own preference and "restored" their Dock to auto-hiding for good.
		// Going through the queue keeps the two in the order they were requested.
		if synchronously { dockQueue.sync(execute: work) } else { dockQueue.async(execute: work) }
	}
}

// MARK: - Bottle inspection

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

	/// Registry lines look like: "GrabFullscreen"="Y"
	private static func value(of key: String, in text: String) -> String? {
		for line in text.split(separator: "\n") where line.hasPrefix("\"\(key)\"=") {
			let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
			if parts.count >= 4 { return String(parts[3]) }
		}
		return nil
	}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private let gameMode = GameMode()
	private let cursorGuard = CursorGuard()
	private let hotKey = GlobalHotKey()
	private let shield = MenuBarShield()
	private let veil = MenuBarVeil()
	private let cursorSuppressor = CursorSuppressor()
	private let suspender = AppSuspender()

	/// On by default: notch overlays draw over the game and redirecting clicks cannot
	/// stop that, so quitting them is the only real fix.
	private var suspendApps: Bool {
		get { UserDefaults.standard.object(forKey: "suspendApps") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "suspendApps") }
	}

	/// On by default: unlike cursor confinement, the shield never touches pointer
	/// movement, so it cannot affect aiming.
	private var shieldMenuBar: Bool {
		get { UserDefaults.standard.object(forKey: "shieldMenuBar") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "shieldMenuBar") }
	}
	private var statusItem: NSStatusItem!
	private var timer: Timer?
	private var signalSources: [DispatchSourceSignal] = []

	private var detectedGames: [String] = []
	/// Set when *we* turned game mode on because a game appeared, so that a
	/// manual toggle is never undone by the watcher.
	private var enabledAutomatically = false

	/// Set when the user switches Deadeye off by hand *while a game is running*, and
	/// cleared when that game exits.
	///
	/// Without it, "Activate automatically" fought the user: turning Deadeye off
	/// mid-game meant the next poll saw a running game and an inactive app and
	/// switched it straight back on, about a second later. A manual decision has to
	/// outrank the automation for as long as the thing it was made about is still
	/// true — so the override lasts for that game session and no longer. The next
	/// game launch arms automatically again, which is what the setting promises.
	private var manualOverrideThisSession = false

	private let updateMenuItem = NSMenuItem(
		title: "", action: nil, keyEquivalent: "")
	private let permissionMenuItem = NSMenuItem(
		title: "⚠︎  Needs Accessibility (click to fix)", action: nil, keyEquivalent: "")
	private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let statsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	private let cursorStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
	/// Control-Option-Command-G rather than a plain ⌘G: games bind bare
	/// Command-letter combinations, and CrossOver forwards them into the bottle.
	private let toggleMenuItem = NSMenuItem(title: "Turn Deadeye Off", action: #selector(toggle), keyEquivalent: "g")

	/// Held rather than looked up by tag. The toggles live in a submenu now, and
	/// `menu.item(withTag:)` only searches one level — a tag lookup would silently
	/// stop finding them and the checkmarks would quietly stop updating.
	private let autoItem = NSMenuItem(title: "Activate automatically",
	                                  action: #selector(toggleAutoEnable), keyEquivalent: "")
	private let shieldItem = NSMenuItem(title: "Menu bar clicks",
	                                    action: #selector(toggleShield), keyEquivalent: "")
	private let dockItem = NSMenuItem(title: "The Dock",
	                                  action: #selector(toggleDock), keyEquivalent: "")
	private let cornersItem = NSMenuItem(title: "Hot corners",
	                                     action: #selector(toggleHotCorners), keyEquivalent: "")
	private let suspendItem = NSMenuItem(title: "Overlay apps",
	                                     action: #selector(toggleSuspend), keyEquivalent: "")
	private let loginItem = NSMenuItem(title: "Launch at login",
	                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

	private var autoEnable: Bool {
		get { UserDefaults.standard.object(forKey: "autoEnable") as? Bool ?? true }
		set { UserDefaults.standard.set(newValue, forKey: "autoEnable") }
	}

	/// Off, and it should stay off. Measured at 311 clamps in one play session:
	/// confining the cursor confines the aim, because in this game the cursor
	/// position *is* the aim input. See the Cursor Guard section of the README.
	private var guardCursor: Bool {
		get { UserDefaults.standard.object(forKey: "guardCursor") as? Bool ?? false }
		set { UserDefaults.standard.set(newValue, forKey: "guardCursor") }
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		// Mouse association is system-wide, so a lock left behind by a previous
		// run that was killed would freeze the cursor for every app. Always
		// release before doing anything else.
		CursorGuard.releaseStaleLock()

		// The support schedule is measured from installation, so the date has to exist
		// before anything can be due. Migration runs alongside it, once.
		GameMode.cleanUpLegacyCornerKeys()
		Stats.recordFirstLaunchIfNeeded()
		Stats.migrateLegacySupportFlag()
		Log.write("=== launched, released any stale lock ===")

		GameMode.selfHeal()
		suspender.recoverIfNeeded()
		let recovered = gameMode.recoverIfNeeded()

		buildMenu()
		installSignalHandlers()

		hotKey.register(keyCode: GlobalHotKey.keyG,
		                modifiers: GlobalHotKey.controlOptionCommand) { [weak self] in
			self?.toggle()
		}

		timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
			self?.poll()
		}

		// React to focus changes immediately rather than up to a poll late: after
		// Cmd-Tab the shield must come down at once or the menu bar feels dead.
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
		shield.lower()
		veil.lower()
		cursorSuppressor.lower()
		cursorGuard.stop()
		// Synchronous: the process is going away, so a queued async block would never
		// run and the Dock would be left suppressed.
		gameMode.restore(synchronously: true)
	}

	// MARK: Menu

	// MARK: Menu chrome

	/// SF Symbol at a consistent size, or nil.
	///
	/// Nil rather than a placeholder on purpose: `NSImage(systemSymbolName:)` returns
	/// nil for a symbol that does not exist on the running macOS, and an item with no
	/// icon reads as perfectly ordinary while a question-mark box reads as a bug. That
	/// makes it safe to use symbols added after macOS 13 without gating each one.
	private func symbol(_ name: String) -> NSImage? {
		guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		else { return nil }
		return image.withSymbolConfiguration(
			NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
	}

	/// A group label. macOS 14 has a real API for these; on 13 the same effect is
	/// drawn by hand rather than dropping the grouping entirely, because the grouping
	/// is what stops the settings block reading as one long undifferentiated list.
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

	/// The app's own name and version, so the menu identifies itself the way a real
	/// app's does rather than opening straight into a list of checkboxes.
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

	/// A status line led by a coloured dot.
	///
	/// The dot carries the state at a glance; the words carry the detail. Colour alone
	/// would be unreadable to anyone who cannot distinguish it, which is why the text
	/// always says the same thing the colour does.
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

		// Hidden unless they apply, and first because they are the only rows that need
		// acting on rather than reading.
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

		// The one verb, alone, so it cannot be mistaken for a setting.
		toggleMenuItem.target = self
		toggleMenuItem.keyEquivalentModifierMask = [.control, .option, .command]
		menu.addItem(toggleMenuItem)

		menu.addItem(.separator())

		// Everything configurable lives one level down. The app's promise is that you
		// never have to configure it, and a flat list of six switches in the front menu
		// contradicts that before you have read a word of it.
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

	/// Grouped by what each switch actually scopes to, which is the distinction that
	/// was missing: four of them describe what macOS is held back from doing while a
	/// game runs, and two describe how Deadeye itself behaves.
	private func buildSettingsMenu() -> NSMenu {
		let m = NSMenu()
		m.delegate = self

		m.addItem(sectionHeader("Hold back while playing"))
		for item in [shieldItem, dockItem, cornersItem, suspendItem] {
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

		// A single way back to the shipped configuration. Named for what it does
		// rather than presented as a "preset", because one restore point is not a
		// preset system and calling it one would imply switching between several.
		let reset = NSMenuItem(title: "Reset to recommended",
		                       action: #selector(resetToRecommended), keyEquivalent: "")
		reset.target = self
		m.addItem(reset)

		// The Dock and hot-corner settings are read when Deadeye arms, not applied
		// live, and silently doing nothing until the next game would look broken.
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
		// The lifetime totals sit here rather than in the front menu: it is the longest
		// string the app produces and it was setting the width of the whole menu.
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
		// Lock state changes faster than the 1.5s poll, so recompute on open or
		// the status lines would show stale information at the moment they are read.
		refreshStatus()

		// Every menu that can show these shares the same item objects, so the state is
		// synced once regardless of which menu is opening.
		autoItem.state = autoEnable ? .on : .off
		shieldItem.state = shieldMenuBar ? .on : .off
		dockItem.state = gameMode.holdDock ? .on : .off
		cornersItem.state = gameMode.disableHotCorners ? .on : .off
		suspendItem.state = suspendApps ? .on : .off
		loginItem.state = launchAtLogin ? .on : .off

		if let summary = Stats.summary {
			statsMenuItem.title = summary
			statsMenuItem.isHidden = false
		} else {
			statsMenuItem.isHidden = true
		}
		toggleMenuItem.title = gameMode.isActive ? "Turn Deadeye Off" : "Turn Deadeye On"
	}

	/// True when click redirection is switched on but macOS has not granted the
	/// Accessibility permission it needs, so the headline feature is silently inert.
	private var accessibilityMissing: Bool {
		shieldMenuBar && !MenuBarShield.ensureAccessibility(prompt: false)
	}

	/// The icon stays the brand mark in every state, including when a permission is
	/// missing. Swapping it for a warning symbol would mean users never learn to
	/// recognise the app in their menu bar. The missing permission is surfaced by the
	/// warning row at the top of the menu and by the status line instead.
	private func icon(active: Bool) -> NSImage? {
		Icon.menuBar(active ? .active : .idle, pointSize: 18)
	}

	// MARK: Watcher

	private var lastLoggedGames: [String] = []

	/// Tracks the play → stopped transition, which is the only safe moment to show
	/// anything on screen.
	private var wasPlaying = false

	/// Tracks the inactive → active edge, so the blink fires on engaging rather than
	/// on every poll while a game runs.
	private var wasActive = false

	private var pulseTimer: Timer?
	private var pulseTarget: Bool?

	private func poll() {
		detectedGames = Wine.runningGames()

		if detectedGames != lastLoggedGames {
			lastLoggedGames = detectedGames
			Log.write("games detected -> \(detectedGames)  guardPref=\(guardCursor)")
		}

		// A game exiting ends any manual override: the decision was about that
		// session, so it must not silently disable automation for every future one.
		if detectedGames.isEmpty, manualOverrideThisSession {
			manualOverrideThisSession = false
			Log.write("MANUAL override cleared — game exited, automation resumes")
		}

		if autoEnable {
			if !detectedGames.isEmpty, !gameMode.isActive, !manualOverrideThisSession {
				setActive(true, automatic: true)
			} else if detectedGames.isEmpty, gameMode.isActive, enabledAutomatically {
				// Only auto-disable what we auto-enabled, so a manual toggle
				// survives the game exiting.
				setActive(false, automatic: false)
			}
		}

		// Safety net only: catches a state change made anywhere that bypassed
		// setActive, such as launch-time recovery. Normally a no-op.
		if gameMode.isActive != wasActive {
			pulse(to: gameMode.isActive)
			wasActive = gameMode.isActive
		}

		syncCursorGuard()
		refreshStatus()
	}

	/// One blink on activation, ~450ms.
	///
	/// This is the only feedback that Deadeye engaged. Everything else it does is by
	/// design invisible, so without this a user has no way to tell it worked — which
	/// is exactly the confusion that made the menu bar bug so hard to pin down.
	///
	/// Deliberately confined to the menu bar icon. A full-screen flourish would mean
	/// drawing over a game at the very moment it is taking the display, which is the
	/// thing this whole app exists to prevent.
	private func pulse(to target: Bool) {
		// Already mid-blink toward this very state: leave it running rather than
		// restarting from frame one, which reads as a stutter.
		if pulseTimer != nil, pulseTarget == target { return }
		pulseTarget = target
		Log.write("BLINK start -> \(target ? "active" : "idle")")
		pulseTimer?.invalidate()
		let start = Date()
		let duration = 0.45

		// Close in the state being left, open in the state being entered.
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

			// sin gives 0 → 1 → 0 across the duration: lids close, then open again.
			let progress = elapsed / duration
			let lidClose = CGFloat(sin(progress * .pi))

			// The shape swaps at the midpoint, while the eye is shut. That hides the
			// change entirely — the smooth idle lid and the angular hunter wedge are
			// too dissimilar to interpolate into one another without looking broken.
			let state = progress < 0.5 ? leaving : entering
			self.statusItem.button?.image = Icon.menuBar(state, pointSize: 18, lidClose: lidClose)
		}
	}

	private func refreshStatus() {
		// The pulse owns the image while it runs.
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

		// Surfaced because the lock is otherwise invisible: it engages only while
		// the game holds focus, so "is it actually on right now?" is a question
		// worth being able to answer without guessing.
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
		// Kept deliberately terse: this line and the one above set the menu's minimum
		// width, and a long status made every other row look cramped.
		if !shieldMenuBar {
			bar = "Menu bar unguarded"; barColour = .tertiaryLabelColor
		} else if accessibilityMissing {
			bar = "Needs Accessibility"; barColour = .systemRed
		} else if shield.isUp {
			// Which of the two is happening matters: one keeps the shot, one loses it.
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

	// MARK: Actions

	@objc private func toggle() {
		let turningOn = !gameMode.isActive

		// Switching off while a game is running is the case the override exists for.
		// Switching on by hand clears it, so the user can undo their own decision
		// without waiting for the game to exit.
		if turningOn {
			manualOverrideThisSession = false
		} else if !detectedGames.isEmpty {
			manualOverrideThisSession = true
			Log.write("MANUAL off while \(detectedGames.joined(separator: ", ")) running"
				+ " — automation held off until it exits")
		}

		setActive(turningOn, automatic: false)
	}

	/// The single place Deadeye turns on or off.
	///
	/// It animates in the same turn of the run loop as the state change and syncs
	/// `wasActive`, so `poll()` cannot fire a second, late blink for the same
	/// transition. Every caller must come through here rather than touching
	/// `gameMode` directly.
	private func setActive(_ active: Bool, automatic: Bool) {
		guard active != gameMode.isActive else { return }

		if active { gameMode.enable() } else { gameMode.restore() }
		enabledAutomatically = automatic

		pulse(to: active)
		wasActive = active      // claim the edge so poll() does not re-animate it
		refreshStatus()
	}

	@objc private func toggleAutoEnable() {
		autoEnable = !autoEnable
	}

	@objc private func toggleHotCorners() {
		let now = !gameMode.disableHotCorners
		UserDefaults.standard.set(now, forKey: "disableHotCorners")
	}

	@objc private func toggleDock() {
		UserDefaults.standard.set(!gameMode.holdDock, forKey: "holdDock")
	}

	/// Back to the shipped configuration in one step: everything macOS does that can
	/// interrupt a game is held back, and Deadeye arms itself.
	///
	/// Deliberately does not touch **Launch at login**. That one is a login item
	/// registered with the system rather than a preference of ours, so silently
	/// adding or removing it under the word "reset" would be a surprise with an
	/// effect outside the app.
	@objc private func resetToRecommended() {
		let defaults = UserDefaults.standard
		defaults.set(true, forKey: "shieldMenuBar")
		defaults.set(true, forKey: "holdDock")
		defaults.set(true, forKey: "disableHotCorners")
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

	/// Shown once, after five protected sessions, and never again either way.
	/// Shown at most twice in a lifetime — two days after install and a week after —
	/// and only when a game has just finished, never mid-session and never at launch.
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

	/// Manual check: always reports back, including "you are up to date", because a
	/// button that silently does nothing reads as broken.
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

	/// Announced at most once per version, and never while a game is running — an
	/// update dialog over a fullscreen game is exactly the interruption this app
	/// exists to prevent.
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

	/// Sharing is the ask that costs a user nothing and grows the audience that any
	/// future funding comes from, so it sits alongside the money one rather than
	/// being an afterthought.
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

	/// The guard is tied to a game being *detected*, not to Dock suppression, so
	/// it protects the cursor even when auto-enable is off. Tying it to a live
	/// game process is also the safety property that matters: if detection ever
	/// stops working, the guard releases the cursor rather than trapping it.
	private func syncCursorGuard() {
		// gameNames must be assigned before anything reads it, including the
		// frontmost logging, or the log reports an empty game list on first poll.
		cursorGuard.gameNames = detectedGames
		cursorGuard.logFrontmostIfChanged()
		if guardCursor, !detectedGames.isEmpty {
			cursorGuard.start()
		} else {
			cursorGuard.stop()
		}

		// The shield follows game focus, not merely a game running: it must come
		// down the moment you Cmd-Tab out, or your own menu bar would be dead.
		if suspendApps, !detectedGames.isEmpty {
			suspender.suspend()
		} else {
			suspender.restore()
		}

		if detectedGames.isEmpty, wasPlaying {
			wasPlaying = false
			Updater.check { [weak self] _ in
				self?.refreshStatus()
				self?.announceUpdateIfAppropriate()
			}
			maybeAskForSupport()
		} else if !detectedGames.isEmpty {
			wasPlaying = true
		}

		shield.gameNames = detectedGames
		if shieldMenuBar, !detectedGames.isEmpty, gameIsFrontmost() {
			// Order matters. The game's window bounds decide whether a click can be
			// handed over; the veil and the suppressor decide whether doing so is
			// safe. All three are settled before the tap goes up.
			shield.refreshGameWindows()
			if shield.gameCoversStrip {
				veil.raise()
				cursorSuppressor.raise()
				// Menu bar managers reset the alpha, and a processed click re-reveals
				// the arrow, so both are re-applied every poll.
				veil.reassert()
				cursorSuppressor.reassert()
			} else {
				veil.lower()
				cursorSuppressor.lower()
			}
			shield.veilIsUp = veil.isUp
			shield.cursorSuppressed = cursorSuppressor.isUp
			shield.afterDelivering = { [weak self] in self?.cursorSuppressor.reassert() }
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

	/// Same test the guard uses: the game runs as its own regular app named after
	/// the executable, with no bundle identifier.
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

	/// Kept as a constant rather than inline so the funding link lives in exactly
	/// one place alongside the README badge.
	static let donateURL = URL(string: "https://support.inulute.com")!

	/// Opens the exact pane, because "Privacy & Security > Accessibility" is several
	/// clicks deep and easy to land in the wrong list.
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

	// MARK: Teardown

	/// A DispatchSourceSignal handler runs on a normal queue, unlike a raw
	/// signal(2) handler, so it is safe to spawn `defaults` from here.
	private func installSignalHandlers() {
		for sig in [SIGTERM, SIGINT, SIGHUP] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [weak self] in
				self?.shield.lower()
				// Both come back on their own when the connection dies, but doing it
				// here means the bar and the cursor are restored before the process
				// exits rather than a frame later.
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
