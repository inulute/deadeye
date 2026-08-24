//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Quitting overlay apps while a game runs.
//

import AppKit

/// Quits chosen apps while a game is running and brings them back afterwards.
///
/// Notch overlays are the reason this exists. Blocking menu bar clicks stops them
/// being *activated*, but it does not stop them *drawing* over a fullscreen game —
/// so for those, quitting is the only real answer.
///
/// Tied to a game **running**, not to a game being focused. Quitting and
/// relaunching apps on every Cmd-Tab would be unusable.
final class AppSuspender {
	/// What we quit, and where to find it again. The bundle URL is captured before
	/// terminating, because once the app is gone `NSWorkspace` can no longer tell us
	/// where it lived.
	private struct Suspended: Codable {
		let name: String
		let bundlePath: String
	}

	private let stateURL: URL
	private let configURL: URL

	private(set) var suspendedNames: [String] = []

	init() {
		let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Deadeye", isDirectory: true)
		try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		stateURL = support.appendingPathComponent("suspended-apps.json")

		configURL = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".config/deadeye/suspend-apps.conf")
	}

	// MARK: - Config

	/// Shared with the standalone shell watcher, so one file governs both and a user
	/// who prefers the script gets identical behaviour.
	func configuredNames() -> [String] {
		ensureConfigExists()
		guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
		return text
			.split(separator: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && !$0.hasPrefix("#") }
	}

	func revealConfig() {
		ensureConfigExists()
		NSWorkspace.shared.open(configURL)
	}

	private func ensureConfigExists() {
		guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
		try? FileManager.default.createDirectory(
			at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let template = """
		# Apps Deadeye quits while a game is running, and relaunches afterwards.
		# One name per line, exactly as it appears in /Applications (no .app suffix).
		# Comment a line out with # to keep an app running.
		#
		# Notch overlays draw on top of a fullscreen game. Blocking menu bar clicks
		# stops them being clicked but not from being drawn, so they are quit outright.
		NotchBox
		TopNotch
		#
		# Menu bar managers. These install their OWN event handler over the menu bar
		# region and open their own menu from it, so neither blocking the click nor
		# making the system menu bar click-through can stop them: measured with Thaw,
		# which opened its menu at the exact cursor position (layer 101) while the
		# click was simultaneously delivered to the game. Quitting is the only thing
		# that works, because the handler belongs to another process.
		Thaw
		Bartender
		Ice
		Hidden Bar
		Dozer
		Vanilla
		# Other menu bar utilities, left running by default. They do not take over
		# the bar, so click handling deals with them. Uncomment any you want gone.
		#Hot
		#Shottr
		#Cursorcerer
		#BetterDisplay
		#LocalSend
		#KDE Connect
		#Bitwarden
		"""
		try? template.write(to: configURL, atomically: true, encoding: .utf8)
		Log.write("SUSPEND created default config at \(configURL.path)")
	}

	/// Where an app of this name is actually installed, for when the path it was
	/// running from has gone.
	private static func installedBundle(named name: String) -> URL? {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let candidates = [
			URL(fileURLWithPath: "/Applications/\(name).app"),
			home.appendingPathComponent("Applications/\(name).app"),
			URL(fileURLWithPath: "/System/Applications/\(name).app"),
		]
		return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
	}

	// MARK: - Suspend / restore

	/// A leftover state file means a previous run was killed before it could
	/// relaunch anything. Replay it, or the user silently loses their apps.
	/// Decides what a state file found at launch means.
	///
	/// With no game running it is debris from a crash or a `kill -9`, and the apps
	/// have to come back. With a game still running it is not leftover at all: the app
	/// was replaced or restarted mid-session, and the managers are meant to stay down.
	/// Relaunching them there is actively harmful — they come back asynchronously, the
	/// next poll cannot see them yet, and one of them is a menu bar manager that
	/// undoes the veil.
	func recoverIfNeeded(gameIsRunning: Bool) {
		guard FileManager.default.fileExists(atPath: stateURL.path) else { return }

		if gameIsRunning {
			if let data = try? Data(contentsOf: stateURL),
			   let record = try? JSONDecoder().decode([Suspended].self, from: data) {
				suspendedNames = record.map(\.name)
			}
			Log.write("SUSPEND state found at launch with a game still running — "
				+ "leaving \(suspendedNames.isEmpty ? "them" : suspendedNames.joined(separator: ", "))"
				+ " suspended")
			return
		}

		Log.write("SUSPEND found leftover state at launch — restoring")
		restore()
	}

	func suspend() {
		// A present state file means this session already suspended, and the record of
		// what to bring back lives in it.
		guard !FileManager.default.fileExists(atPath: stateURL.path) else { return }

		let wanted = Set(configuredNames().map { $0.lowercased() })
		guard !wanted.isEmpty else { return }

		var record: [Suspended] = []
		for app in NSWorkspace.shared.runningApplications {
			guard let name = app.localizedName, wanted.contains(name.lowercased()) else { continue }
			guard let bundleURL = app.bundleURL else { continue }
			record.append(Suspended(name: name, bundlePath: bundleURL.path))
			app.terminate()   // graceful; forceTerminate would risk data loss
		}

		// Nothing matched, so there is nothing to remember. An empty file used to be
		// written here to stop the scan repeating, and that latched the wrong thing:
		// replace the app mid-session and the relaunch of the suspended managers is
		// still in flight when the next poll arrives, so the scan finds nothing, writes
		// an empty file, and every later attempt is blocked by it for the rest of the
		// session. Thaw then runs all game long resetting the menu bar's alpha, which
		// puts the veil down and makes the bar clickable again — the original bug.
		// Re-scanning costs one pass over `runningApplications`, which the game
		// detector already makes every poll anyway.
		guard !record.isEmpty else { return }

		if let data = try? JSONEncoder().encode(record) {
			try? data.write(to: stateURL, options: .atomic)
		}
		suspendedNames = record.map(\.name)
		Log.write("SUSPEND quit while gaming: \(suspendedNames.joined(separator: ", "))")
	}

	func restore() {
		guard let data = try? Data(contentsOf: stateURL) else { suspendedNames = []; return }

		// Drop an undecodable file rather than leaving it to block future suspends.
		guard let record = try? JSONDecoder().decode([Suspended].self, from: data) else {
			Log.write("SUSPEND state file unreadable — discarding")
			try? FileManager.default.removeItem(at: stateURL)
			suspendedNames = []
			return
		}

		for entry in record {
			let recorded = URL(fileURLWithPath: entry.bundlePath)

			// A translocated bundle path — what Gatekeeper hands an app that was opened
			// straight from a DMG — exists only while that app runs, so it can be gone
			// by the time we relaunch. Measured with Thaw: the recorded path under
			// AppTranslocation had vanished, the relaunch silently failed, and the app
			// stayed dead for the rest of the session while the log claimed success.
			// Fall back to the real install before giving up.
			let url: URL
			if FileManager.default.fileExists(atPath: recorded.path) {
				url = recorded
			} else if let installed = Self.installedBundle(named: entry.name) {
				Log.write("SUSPEND \(entry.name) was running from a path that no longer"
					+ " exists (translocated?); relaunching \(installed.path) instead")
				url = installed
			} else {
				Log.write("SUSPEND cannot relaunch \(entry.name): neither"
					+ " \(recorded.path) nor an installed copy exists")
				continue
			}

			NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
				if let error {
					Log.write("SUSPEND could not relaunch \(entry.name): \(error.localizedDescription)")
				} else if app == nil {
					Log.write("SUSPEND relaunch of \(entry.name) reported no app")
				}
			}
		}

		try? FileManager.default.removeItem(at: stateURL)
		if !record.isEmpty {
			// "attempted", not "relaunched": the launches above are asynchronous, so at
			// this point their outcome is genuinely not known yet. The old wording
			// claimed success and hid exactly the failure described above.
			Log.write("SUSPEND relaunch attempted after gaming: \(record.map(\.name).joined(separator: ", "))")
		}
		suspendedNames = []
	}
}
