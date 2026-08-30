//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import Darwin
import Foundation

enum Wine {
	static let systemPrefix = "c:\\windows\\"

	static let systemExecutables: Set<String> = [
		"services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
		"wineboot.exe", "winewrapper.exe", "winemenubuilder.exe", "wineconsole.exe",
		"explorer.exe", "start.exe", "conhost.exe", "cmd.exe", "reg.exe",
		"rundll32.exe", "regsvr32.exe", "msiexec.exe", "taskmgr.exe", "control.exe",
		"notepad.exe", "winecfg.exe", "uninstaller.exe", "cxsetup.exe",
	]

	static let ignored: Set<String> = [
		"steam.exe", "steamwebhelper.exe", "steamerrorreporter.exe", "gameoverlayui.exe",
		"epicgameslauncher.exe", "epicwebhelper.exe",
		"battle.net.exe", "battle.net helper.exe", "agent.exe",
		"rockstarservice.exe", "rockstarerrorhandler.exe", "socialclubhelper.exe",
		"launcher.exe", "eadesktop.exe", "eabackgroundservice.exe",
		"upc.exe", "uplaybrowser.exe", "ubisoftconnect.exe",
		"galaxyclient.exe", "galaxyclienthelper.exe", "gog galaxy.exe",
		"origin.exe", "originwebhelperservice.exe",
		"msedgewebview2.exe", "crashpad_handler.exe", "crashreporter.exe",
		"winecfg.exe", "wineconsole.exe", "uninstaller.exe", "cxsetup.exe",
		"explorer.exe", "winemenubuilder.exe", "start.exe", "cmd.exe",
		"conhost.exe", "reg.exe", "msiexec.exe", "rundll32.exe", "taskmgr.exe",
	]

	static let ignoredApplications: Set<String> = [
		"winscp.exe", "putty.exe", "pscp.exe", "psftp.exe", "plink.exe",
		"filezilla.exe", "notepad++.exe", "7zfm.exe", "7zg.exe", "winrar.exe",
		"acrobat.exe", "acrord32.exe", "excel.exe", "winword.exe", "powerpnt.exe",
		"outlook.exe", "iexplore.exe", "firefox.exe", "chrome.exe",
	]

	private static var userIgnoredCache: (mtime: Date, names: Set<String>)?

	static var userIgnored: Set<String> {
		let url = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".config/deadeye/ignored-exes.conf")

		guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
		      let mtime = attrs[.modificationDate] as? Date
		else { return [] }

		if let cache = userIgnoredCache, cache.mtime == mtime { return cache.names }

		guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		let names = Set(text
			.split(separator: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
			.filter { !$0.isEmpty && !$0.hasPrefix("#") })

		userIgnoredCache = (mtime, names)
		return names
	}

	static func runningGames() -> [String] {
		var found: [String] = []
		var seen = Set<String>()

		for pid in allPIDs() {
			guard let argv0 = firstArgument(of: pid) else { continue }
			guard let name = gameName(fromArgv0: argv0) else { continue }
			if seen.insert(name.lowercased()).inserted { found.append(name) }
		}
		for name in helperGames() where seen.insert(name.lowercased()).inserted {
			found.append(name)
		}
		return found.sorted()
	}

	static func helperGames() -> [String] {
		NSWorkspace.shared.runningApplications.compactMap { app in
			guard let bundle = app.bundleIdentifier?.lowercased(),
			      bundle.hasPrefix("com.codeweavers.crossoverhelper.")
			else { return nil }
			guard let name = app.localizedName, !name.isEmpty else { return nil }

			let bare = name.lowercased()
			let exe = bare.hasSuffix(".exe") ? bare : bare + ".exe"
			for candidate in [bare, exe] {
				if systemExecutables.contains(candidate) || ignored.contains(candidate)
					|| ignoredApplications.contains(candidate) || userIgnored.contains(candidate) {
					return nil
				}
			}
			return name
		}
	}

	static func gameName(fromArgv0 argv0: String) -> String? {
		let lower = argv0.lowercased()
		guard lower.hasSuffix(".exe") else { return nil }

		guard !lower.hasPrefix("/") else { return nil }

		let chars = Array(lower)
		let isWindowsPath = chars.count > 3 && chars[1] == ":" && chars[2] == "\\"
		if isWindowsPath, lower.hasPrefix(systemPrefix) { return nil }

		let base = argv0
			.split(whereSeparator: { $0 == "\\" || $0 == "/" })
			.last.map(String.init) ?? argv0
		let baseLower = base.lowercased()

		guard !systemExecutables.contains(baseLower),
		      !ignored.contains(baseLower),
		      !ignoredApplications.contains(baseLower),
		      !userIgnored.contains(baseLower)
		else { return nil }
		return base
	}

	static func classify(_ argv0: String) -> String {
		let lower = argv0.lowercased()
		guard lower.hasSuffix(".exe") else { return "not an .exe" }
		guard !lower.hasPrefix("/") else { return "Wine machinery (Unix path)" }

		let chars = Array(lower)
		let isWindowsPath = chars.count > 3 && chars[1] == ":" && chars[2] == "\\"
		if isWindowsPath, lower.hasPrefix(systemPrefix) { return "Wine system executable" }

		let base = (argv0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? argv0).lowercased()
		if systemExecutables.contains(base) { return "Wine system executable" }
		if ignored.contains(base) { return "store launcher / utility" }
		if ignoredApplications.contains(base) { return "known non-game application" }
		if userIgnored.contains(base) { return "excluded by ignored-exes.conf" }
		return "GAME"
	}

	private static func allPIDs() -> [Int32] {
		var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
		var size = 0
		guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

		let stride = MemoryLayout<kinfo_proc>.stride
		var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
		guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

		return procs[0 ..< (size / stride)].map { $0.kp_proc.p_pid }.filter { $0 > 0 }
	}

	static func firstArgument(of pid: Int32) -> String? {
		var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
		var size = 0
		guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

		var buf = [UInt8](repeating: 0, count: size)
		guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

		var i = 4
		while i < size, buf[i] != 0 { i += 1 }
		while i < size, buf[i] == 0 { i += 1 }
		let start = i
		while i < size, buf[i] != 0 { i += 1 }
		guard i > start else { return nil }

		return String(decoding: buf[start ..< i], as: UTF8.self)
	}
}
