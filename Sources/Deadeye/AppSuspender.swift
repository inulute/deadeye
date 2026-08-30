//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit

final class AppSuspender {
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
		NotchBox
		TopNotch
		Thaw
		Bartender
		Ice
		Hidden Bar
		Dozer
		Vanilla
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

	private static func installedBundle(named name: String) -> URL? {
		let home = FileManager.default.homeDirectoryForCurrentUser
		let candidates = [
			URL(fileURLWithPath: "/Applications/\(name).app"),
			home.appendingPathComponent("Applications/\(name).app"),
			URL(fileURLWithPath: "/System/Applications/\(name).app"),
		]
		return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
	}

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
		guard !FileManager.default.fileExists(atPath: stateURL.path) else { return }

		let wanted = Set(configuredNames().map { $0.lowercased() })
		guard !wanted.isEmpty else { return }

		var record: [Suspended] = []
		for app in NSWorkspace.shared.runningApplications {
			guard let name = app.localizedName, wanted.contains(name.lowercased()) else { continue }
			guard let bundleURL = app.bundleURL else { continue }
			record.append(Suspended(name: name, bundlePath: bundleURL.path))
			app.terminate()
		}

		guard !record.isEmpty else { return }

		if let data = try? JSONEncoder().encode(record) {
			try? data.write(to: stateURL, options: .atomic)
		}
		suspendedNames = record.map(\.name)
		Log.write("SUSPEND quit while gaming: \(suspendedNames.joined(separator: ", "))")
	}

	func restore() {
		guard let data = try? Data(contentsOf: stateURL) else { suspendedNames = []; return }

		guard let record = try? JSONDecoder().decode([Suspended].self, from: data) else {
			Log.write("SUSPEND state file unreadable — discarding")
			try? FileManager.default.removeItem(at: stateURL)
			suspendedNames = []
			return
		}

		for entry in record {
			let recorded = URL(fileURLWithPath: entry.bundlePath)

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
			Log.write("SUSPEND relaunch attempted after gaming: \(record.map(\.name).joined(separator: ", "))")
		}
		suspendedNames = []
	}
}
