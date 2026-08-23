//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Detecting a running CrossOver/Wine game.
//

import AppKit
import Darwin
import Foundation

enum Wine {
	/// Wine's own services report argv[0] as a full Windows path under
	/// `C:\windows\system32\...`, so a path-prefix test excludes all of them at
	/// once, including helpers added by future versions.
	static let systemPrefix = "c:\\windows\\"

	/// Wine's system executables, matched on bare name as well as full path.
	///
	/// The path rule alone is not sufficient: CrossOver launches the *game* with
	/// a bare argv[0] — RDR2 reports simply `RDR2.exe` — so bare names have to be
	/// accepted, and once they are, a bare `services.exe` would otherwise slip
	/// through. Belt and braces.
	static let systemExecutables: Set<String> = [
		"services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
		"wineboot.exe", "winewrapper.exe", "winemenubuilder.exe", "wineconsole.exe",
		"explorer.exe", "start.exe", "conhost.exe", "cmd.exe", "reg.exe",
		"rundll32.exe", "regsvr32.exe", "msiexec.exe", "taskmgr.exe", "control.exe",
		"notepad.exe", "winecfg.exe", "uninstaller.exe", "cxsetup.exe",
	]

	/// Launchers and utilities that keep running alongside (or instead of) a game.
	/// Without these, leaving Steam open in a bottle would hold the Dock hostage.
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

	/// Non-game Windows applications people actually run in a bottle. A bottle is
	/// not a games-only container — this one was created for WinSCP and had a game
	/// installed into it later — so an ordinary app must not be mistaken for a game
	/// and trigger Dock suppression.
	static let ignoredApplications: Set<String> = [
		"winscp.exe", "putty.exe", "pscp.exe", "psftp.exe", "plink.exe",
		"filezilla.exe", "notepad++.exe", "7zfm.exe", "7zg.exe", "winrar.exe",
		"acrobat.exe", "acrord32.exe", "excel.exe", "winword.exe", "powerpnt.exe",
		"outlook.exe", "iexplore.exe", "firefox.exe", "chrome.exe",
	]

	/// Extra names the user never wants treated as a game, one per line, from
	/// `~/.config/deadeye/ignored-exes.conf`.
	///
	/// Read from disk rather than compiled in so that a wrong guess is fixable by
	/// editing a text file, with no rebuild and no restart. Cached on modification
	/// date, since this is consulted on every poll.
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

	/// Display names of Wine processes that look like actual games.
	///
	/// Two independent paths, because either one alone misses real launches:
	/// the argv[0] scan below, and `helperGames()`. Measured: an RDR2 session
	/// launched from a bottle shortcut ran for nine minutes with the argv[0] scan
	/// returning nothing at all, so Deadeye never armed. Union, not fallback — a
	/// game can show up in either.
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

	/// Games CrossOver is presenting as their own Mac apps.
	///
	/// A bottle app launched from a shortcut runs behind a generated helper bundle
	/// identified as `com.codeweavers.CrossOverHelper.<bottle>.<app>`, and it is that
	/// helper — not the Wine process — that owns the window and becomes frontmost.
	/// Measured on a real launch: frontmost was `RDR
	/// [com.codeweavers.CrossOverHelper.<bottle-id>.<app-id>]` while the argv[0] scan
	/// saw only `winedevice.exe`, which it correctly rejects. The scan cannot see
	/// these at all, which is why this is a second path rather than a tweak to it.
	///
	/// The main `com.codeweavers.CrossOver` bundle deliberately does not match: the
	/// launcher being open is not a game running, and treating it as one would hide
	/// the menu bar while somebody was browsing their bottles.
	static func helperGames() -> [String] {
		NSWorkspace.shared.runningApplications.compactMap { app in
			guard let bundle = app.bundleIdentifier?.lowercased(),
			      bundle.hasPrefix("com.codeweavers.crossoverhelper.")
			else { return nil }
			guard let name = app.localizedName, !name.isEmpty else { return nil }

			// A bottle is not a games-only container, and a helper is generated for
			// WinSCP as readily as for a game — so the same exclusions apply. The
			// helper's name has no ".exe" on it, so both forms are checked.
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

	/// Returns the executable's display name if `argv0` looks like a game, else nil.
	///
	/// Three argv[0] shapes turn up in a live bottle, and they mean different things:
	///
	///   `C:\windows\system32\services.exe`  Wine service        -> reject by path
	///   `/Applications/…/winewrapper.exe`   Wine machinery      -> reject, Unix path
	///   `RDR2.exe`                          the game itself     -> accept
	///
	/// The bare form is the one that matters: CrossOver launches the game with an
	/// unqualified argv[0], so requiring a drive letter would miss every game.
	static func gameName(fromArgv0 argv0: String) -> String? {
		let lower = argv0.lowercased()
		guard lower.hasSuffix(".exe") else { return nil }

		// A Unix absolute path is Wine's own machinery, never a Windows program.
		guard !lower.hasPrefix("/") else { return nil }

		// A Windows absolute path is a game only outside Wine's system directory.
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

	/// Same decision as `gameName(fromArgv0:)` but reporting *why*, for diagnostics.
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

	/// argv[0] of a process, via KERN_PROCARGS2.
	///
	/// Layout is: int argc, then the null-terminated exec path, then run-length
	/// null padding, then argv[0]. The exec path is the real Mach-O binary
	/// (wineloader) — it is argv[0] that carries the Windows path we want.
	static func firstArgument(of pid: Int32) -> String? {
		var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
		var size = 0
		guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }

		var buf = [UInt8](repeating: 0, count: size)
		guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

		var i = 4 // skip argc
		while i < size, buf[i] != 0 { i += 1 }  // skip exec path
		while i < size, buf[i] == 0 { i += 1 }  // skip padding
		let start = i
		while i < size, buf[i] != 0 { i += 1 }
		guard i > start else { return nil }

		return String(decoding: buf[start ..< i], as: UTF8.self)
	}
}
