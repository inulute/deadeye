//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import CoreGraphics

final class MenuBarShield {
	private var tap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?

	private var strips: [CGRect] = []

	private(set) var isUp = false

	var gameNames: [String] = []

	var veilIsUp = false
	var cursorSuppressed = false

	var afterDelivering: (() -> Void)?

	var gameWindowRects: [CGRect] = []

	private var fallbackStripHeight: CGFloat { max(NSStatusBar.system.thickness, 24) + 12 }

	@discardableResult
	static func ensureAccessibility(prompt: Bool) -> Bool {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
		return AXIsProcessTrustedWithOptions(options as CFDictionary)
	}

	private var hasPrompted = false
	private var loggedPermissionRefusal = false

	func raise() {
		guard !isUp else { return }

		recomputeStrips()

		let mask = (1 << CGEventType.leftMouseDown.rawValue)
			| (1 << CGEventType.rightMouseDown.rawValue)
			| (1 << CGEventType.otherMouseDown.rawValue)

		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,
			eventsOfInterest: CGEventMask(mask),
			callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
				guard let userInfo else { return Unmanaged.passUnretained(event) }
				let shield = Unmanaged<MenuBarShield>.fromOpaque(userInfo).takeUnretainedValue()
				return shield.handle(type: type, event: event)
			},
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else {
			if !loggedPermissionRefusal {
				loggedPermissionRefusal = true
				let trusted = AXIsProcessTrusted()
				Log.write("SHIELD tapCreate FAILED (AXIsProcessTrusted=\(trusted)). "
					+ "If already granted, macOS may need a logout to apply it to an "
					+ "ad-hoc signed app.")
				if !trusted, !hasPrompted {
					hasPrompted = true
					Self.ensureAccessibility(prompt: true)
				}
			}
			return
		}
		loggedPermissionRefusal = false

		self.tap = tap
		runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
		CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
		CGEvent.tapEnable(tap: tap, enable: true)

		isUp = true
		let heights = strips.map { Int($0.height) }.map(String.init).joined(separator: ",")
		Log.write("SHIELD tap up, strips=\(strips.count), heights=[\(heights)]pt")
	}

	func lower() {
		guard isUp else { return }
		isUp = false

		if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
		if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
		if let tap { CFMachPortInvalidate(tap) }
		runLoopSource = nil
		tap = nil

		Log.write("SHIELD tap down")
	}

	func screensChanged() {
		guard isUp else { return }
		recomputeStrips()
		Log.write("SHIELD strips recomputed: \(strips.count)")
	}

	private func recomputeStrips() {
		guard let primary = NSScreen.screens.first else { strips = []; return }
		strips = MenuBarGeometry.strips(screenFrames: NSScreen.screens.map(\.frame),
		                               primaryMaxY: primary.frame.maxY,
		                               menuBars: menuBarRects(),
		                               fallbackHeight: fallbackStripHeight)
	}

	private func menuBarRects() -> [CGRect] {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
			as? [[String: Any]] else { return [] }

		return list.compactMap { window in
			guard window[kCGWindowLayer as String] as? Int == 24,
			      let bounds = window[kCGWindowBounds as String] as? NSDictionary
			else { return nil }
			var rect = CGRect.zero
			guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { return nil }
			return rect
		}
	}

	func refreshGameWindows() {
		if strips.isEmpty { recomputeStrips() }
		guard let game = gameIsFrontmost() else { gameWindowRects = []; return }
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
			as? [[String: Any]] else { gameWindowRects = []; return }

		gameWindowRects = list.compactMap { window in
			guard window[kCGWindowOwnerPID as String] as? pid_t == game.processIdentifier,
			      let bounds = window[kCGWindowBounds as String] as? NSDictionary
			else { return nil }
			var rect = CGRect.zero
			guard CGRectMakeWithDictionaryRepresentation(bounds, &rect) else { return nil }
			return rect
		}

		let covers = gameCoversStrip
		if loggedCoverage != covers {
			loggedCoverage = covers
			let shapes = gameWindowRects
				.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" }
				.joined(separator: " ")
			Log.write("SHIELD \(game.localizedName ?? "game") pid=\(game.processIdentifier) "
				+ "windows=[\(shapes)] covering the menu bar strip: "
				+ (covers ? "YES — strip clicks go to the game"
				          : "NO — strip clicks must still be discarded"))
		}
	}

	private var loggedCoverage: Bool?

	var gameCoversStrip: Bool {
		guard let primary = strips.first, !gameWindowRects.isEmpty else { return false }
		return gameWindowRects.contains { $0.intersects(primary) }
	}

	private func gameIsFrontmost() -> NSRunningApplication? {
		guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
		if let bundle = front.bundleIdentifier?.lowercased(), bundle.hasPrefix("com.codeweavers") {
			return front
		}
		guard let name = front.localizedName else { return nil }
		return gameNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? front : nil
	}

	private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			Log.write("SHIELD tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
			return Unmanaged.passUnretained(event)
		}

		guard let game = gameIsFrontmost() else {
			if strips.contains(where: { $0.contains(event.location) }) {
				let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing"
				Log.write("SHIELD strip click passed through untouched:"
					+ " frontmost was \(front), not a game")
			}
			return Unmanaged.passUnretained(event)
		}

		let location = event.location
		guard let strip = strips.first(where: { $0.contains(location) }) else {
			return Unmanaged.passUnretained(event)
		}

		_ = strip

		if veilIsUp, cursorSuppressed, strips.first?.contains(location) == true,
		   gameWindowRects.contains(where: { $0.contains(location) }) {
			Stats.recordDeliveredClick()
			if let afterDelivering { DispatchQueue.main.async(execute: afterDelivering) }
			Log.write("SHIELD delivered click to \(game.localizedName ?? "game")"
				+ " at CG(\(Int(location.x)), \(Int(location.y)))")
			return Unmanaged.passUnretained(event)
		}

		Stats.recordBlockedClick()
		Log.write("SHIELD blocked click at CG(\(Int(location.x)), \(Int(location.y)))"
			+ " while \(game.localizedName ?? "game") was frontmost")
		return nil
	}
}
