//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Getting out of the disk image before asking the user for anything.
//

import AppKit

/// Refuses to run from the disk image, and offers to install itself instead.
///
/// ## Why this exists
///
/// Opening the app straight out of the mounted image works well enough to be
/// tempting, and it costs the user every permission dialog twice. Gatekeeper treats
/// the copy in the image and the copy in Applications as two different apps, so both
/// are approved separately, and Accessibility is granted to a path that stops
/// existing the moment the image is ejected. The player's words for it: "the DMG also
/// asks for that privacy permission, and then after installing, the app asks again".
///
/// Nothing here strips quarantine. Being asked *once*, for the copy that will still
/// be there tomorrow, is the normal experience for an app that is signed but not
/// notarised, and that is what this restores. Getting it down to zero is what
/// notarisation is for.
enum Install {
	static var applicationsCopy: URL {
		URL(fileURLWithPath: "/Applications/Deadeye.app")
	}

	/// Whether this copy is somewhere it cannot sensibly live.
	///
	/// Two tests, because they catch different things. A read-only volume is the
	/// mounted disk image, measured on the published one: `hfs, local, read-only`.
	/// A translocated path is what Gatekeeper hands a quarantined app so it runs from
	/// a random directory that disappears afterwards.
	///
	/// Deliberately not "is the path under /Volumes": people keep applications on
	/// external drives, and those are writable and stay mounted.
	static var isRunningFromDiskImage: Bool {
		let bundle = Bundle.main.bundleURL
		if bundle.path.contains("/AppTranslocation/") { return true }
		let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
		return values?.volumeIsReadOnly == true
	}

	/// Asks to be installed, and does it. Returns true when the caller should stop
	/// setting up and let the process quit.
	///
	/// Called before anything that can put a dialog on screen. If the shield's event
	/// tap goes up first, the Accessibility prompt appears for the copy in the disk
	/// image, which is the whole thing being avoided.
	@discardableResult
	static func moveToApplicationsIfNeeded() -> Bool {
		guard isRunningFromDiskImage else { return false }
		Log.write("INSTALL running from \(Bundle.main.bundlePath) — not a place to live")

		let alert = NSAlert()
		alert.messageText = "Move Deadeye to your Applications folder"
		alert.informativeText = """
			Deadeye is running from the disk image. Left there it has to be approved \
			twice, once now and again once you install it, and the Accessibility \
			permission you grant would point at a copy that disappears when the image \
			is ejected.
			"""
		alert.addButton(withTitle: "Move to Applications")
		alert.addButton(withTitle: "Quit")
		NSApp.activate(ignoringOtherApps: true)

		guard alert.runModal() == .alertFirstButtonReturn else {
			Log.write("INSTALL declined, quitting")
			NSApp.terminate(nil)
			return true
		}

		install()
		return true
	}

	private static func install() {
		let destination = applicationsCopy
		let manager = FileManager.default

		// An existing install is left exactly as it is. It may well be newer than the
		// image this was opened from, and replacing it is not what "move to
		// Applications" promises.
		if manager.fileExists(atPath: destination.path) {
			Log.write("INSTALL \(destination.path) already exists, opening that instead")
			launch(destination)
			return
		}

		do {
			try manager.copyItem(at: Bundle.main.bundleURL, to: destination)
			Log.write("INSTALL copied to \(destination.path)")
			launch(destination)
		} catch {
			Log.write("INSTALL copy failed: \(error.localizedDescription)")
			let alert = NSAlert()
			alert.messageText = "Could not move Deadeye"
			alert.informativeText = "Drag it to your Applications folder by hand, then "
				+ "open it from there.\n\n\(error.localizedDescription)"
			alert.addButton(withTitle: "OK")
			NSApp.activate(ignoringOtherApps: true)
			alert.runModal()
			NSApp.terminate(nil)
		}
	}

	private static func launch(_ url: URL) {
		// Already running from Applications: opening it again would just make a second
		// menu bar icon. Step aside and let the one that is already there carry on.
		let running = NSWorkspace.shared.runningApplications.contains {
			$0.bundleURL?.standardizedFileURL == url.standardizedFileURL
		}
		if running {
			Log.write("INSTALL the installed copy is already running, quitting this one")
			NSApp.terminate(nil)
			return
		}

		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = true
		NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
			if let error {
				Log.write("INSTALL could not open the installed copy: \(error.localizedDescription)")
			}
			DispatchQueue.main.async { NSApp.terminate(nil) }
		}
	}
}
