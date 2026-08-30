//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit

enum Install {
	static var applicationsCopy: URL {
		URL(fileURLWithPath: "/Applications/Deadeye.app")
	}

	static var isRunningFromDiskImage: Bool {
		let bundle = Bundle.main.bundleURL
		if bundle.path.contains("/AppTranslocation/") { return true }
		let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
		return values?.volumeIsReadOnly == true
	}

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
