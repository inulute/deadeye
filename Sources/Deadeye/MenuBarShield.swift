//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Blocking menu bar clicks without a window and without touching the cursor.
//

import AppKit
import CoreGraphics

/// Discards mouse-down events that land in a screen's menu bar strip while a game
/// is focused, so a stray click cannot open a status item's menu over the game.
///
/// ## The click is handed to the game when it safely can be
///
/// When `MenuBarVeil` and `CursorSuppressor` are both up, a strip click over the
/// game's own window is passed through: the bar refuses it, the game receives it, and
/// the arrow it would have revealed stays suppressed. Aim-down-sights at the top of
/// the screen works.
///
/// Otherwise it is discarded, which is what this class did for a long time and what
/// it still does whenever those two are not both up — on a macOS missing their
/// private symbols, or for a click that is not over the game's window, where handing
/// it over would drop it on the desktop and pull focus out of the game mid-fight.
///
/// ## Five ways of delivering it that did not work
///
/// Four of these fought the event — moving it, re-posting it, letting it through —
/// rather than the menu bar, and they are why the working answer attacks the bar
/// instead:
///
/// * **Move the event below the strip.** Delivery does follow the new location, but
///   the window server also *moves the pointer* to it. That warps the cursor out of
///   the menu bar on every click, which breaks Wine's pointer capture and makes the
///   macOS arrow appear over the game — the very bug this app exists around.
/// * **Move it only when the game is underneath.** Same cursor warp; the guard only
///   changed which clicks triggered it.
/// * **Pass it through when the game's window is in front.** The window server gives
///   the menu bar strip priority regardless of z-order: a status item's menu opened
///   even with the game's layer-26 window above the menu bar's layer 24. Being
///   visually in front does not win the click.
/// * **`postToPid` it straight to the game.** Delivers nothing. Measured: a
///   right-click posted to a process's own pid reached its views zero times, while
///   the same event posted normally arrived.
///
/// * **Make the menu bar refuse the click, and nothing else.** `MenuBarVeil` does
///   work — strip clicks were delivered to the window underneath — but on its own it
///   reveals the macOS arrow, because *any* top-of-screen click that gets processed
///   does, whoever receives it. That was worse than losing the click, and for a while
///   this class went back to discarding because of it. `CursorSuppressor` is what
///   removed the objection rather than working around it.
///
/// The third point above is also not quite right: a window at layer 26 *does* win a
/// strip click, measured directly. What it needs is to cover the strip, which a Wine
/// window sized to `visibleFrame` does not.
///
/// ## Why an event tap and not a window
///
/// The first version put an invisible window over the strip to swallow clicks. It
/// worked, and it made things **worse**: a window that accepts mouse events means
/// macOS considers the pointer to be over *that window* rather than the game, so it
/// draws the standard arrow the moment the pointer touches the top. The cursor
/// reappeared instantly instead of only on a click. Declaring a transparent cursor
/// for the window does not help, because a background app cannot set the system
/// cursor — the same limitation that made `CGAssociateMouseAndMouseCursorPosition`
/// silently no-op from here.
///
/// An event tap owns no screen real estate. The pointer is never "over" anything of
/// ours, so cursor behaviour is exactly as if this code did not exist, and only the
/// click is intercepted.
///
/// ## Why this cannot break aiming
///
/// It never moves the cursor. Cursor confinement was tried three times and always
/// fenced the aim along with the pointer (311 clamps in one session). This touches
/// only click delivery, never position.
final class MenuBarShield {
	private var tap: CFMachPort?
	private var runLoopSource: CFRunLoopSource?

	/// Menu bar strips in CoreGraphics global coordinates (origin top-left), one per
	/// screen. Recomputed on the main thread when displays change, and only read
	/// from the tap callback, which also runs on the main run loop.
	private var strips: [CGRect] = []

	private(set) var isUp = false

	/// Names of running games, set by the app's poll loop. Read inside the tap
	/// callback as a second gate: the tap is only *installed* while the game is
	/// focused, but if `lower()` ever failed to run, a stale tap would swallow menu
	/// bar clicks across the whole system. Re-checking per click makes that
	/// impossible rather than merely unlikely.
	var gameNames: [String] = []

	/// Both must be true before a click is handed over: the veil so the bar refuses
	/// it, the suppressor so the arrow it reveals stays invisible. Set by the poll
	/// loop. Delivering with the veil alone is the original bug.
	var veilIsUp = false
	var cursorSuppressed = false

	/// Called from inside the tap, just before a strip click is handed to the game.
	///
	/// Synchronous and before returning the event on purpose: whether the game is
	/// hiding its own cursor has to be read *before* the click is processed, because
	/// processing it is what reveals the arrow. What to do about that is the
	/// suppressor's decision, not this class's.
	var onDeliveringStripClick: (() -> Void)?

	/// On-screen window bounds of the frontmost game, in CoreGraphics coordinates,
	/// refreshed by the poll loop.
	///
	/// Gathered outside the tap callback deliberately: `CGWindowListCopyWindowInfo` is
	/// an out-of-process call, and macOS disables an event tap whose callback runs
	/// slowly, which would silently switch the whole shield off. A rect at most one
	/// poll stale is a much better trade than a tap that dies.
	var gameWindowRects: [CGRect] = []

	/// Used only when the menu bar's own geometry cannot be read. `NSStatusBar`
	/// reports 22pt, which is the *status item* height, not the bar: the real menu
	/// bar windows measured 30pt on a built-in display and 33pt on an external one,
	/// so a strip built from the old `thickness + 4` was 28pt and left the bottom
	/// rows of the bar unguarded.
	private var fallbackStripHeight: CGFloat { max(NSStatusBar.system.thickness, 24) + 12 }

	/// Creating a tap that can discard events requires Accessibility. Returns false
	/// if it has not been granted, having asked the system to prompt.
	@discardableResult
	static func ensureAccessibility(prompt: Bool) -> Bool {
		let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
		return AXIsProcessTrustedWithOptions(options as CFDictionary)
	}

	/// The poll retries `raise()` every 1.5s, so prompting on each attempt would
	/// bury the screen in permission dialogs. Ask once, then check silently.
	private var hasPrompted = false
	private var loggedPermissionRefusal = false

	func raise() {
		guard !isUp else { return }

		// Deliberately NOT gated on AXIsProcessTrusted. For an ad-hoc signed app
		// that API can keep reporting false after the user has genuinely granted
		// access, and gating on it meant the tap was never even attempted — while
		// re-prompting produced a permission dialog on every retry. The only
		// authoritative test is whether tapCreate succeeds, so just try it.

		recomputeStrips()

		// Downs only. A menu opens on mouse-down, so discarding the down keeps the menu
		// bar inert, and every extra event type is more traffic through this callback —
		// which macOS disables the tap for if it gets slow.
		let mask = (1 << CGEventType.leftMouseDown.rawValue)
			| (1 << CGEventType.rightMouseDown.rawValue)
			| (1 << CGEventType.otherMouseDown.rawValue)

		// A C callback cannot capture, so `self` travels through userInfo.
		guard let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .defaultTap,               // .defaultTap can discard; .listenOnly cannot
			eventsOfInterest: CGEventMask(mask),
			callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
				guard let userInfo else { return Unmanaged.passUnretained(event) }
				let shield = Unmanaged<MenuBarShield>.fromOpaque(userInfo).takeUnretainedValue()
				return shield.handle(type: type, event: event)
			},
			userInfo: Unmanaged.passUnretained(self).toOpaque()
		) else {
			// Only now is a permission problem the likely explanation — and prompt at
			// most once per launch, so a failing retry loop cannot spam dialogs.
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

	/// A no-op unless the tap is actually installed. Without the guard this fired on
	/// every display wake and sleep all day while the shield was switched off,
	/// filling the log with noise that hid the entries that mattered.
	func screensChanged() {
		guard isUp else { return }
		recomputeStrips()
		Log.write("SHIELD strips recomputed: \(strips.count)")
	}

	// MARK: - Internals

	/// `NSScreen` frames use a bottom-left origin on the primary screen; CGEvent
	/// locations use a top-left origin. Only y needs converting, against the
	/// primary screen's height.
	private func recomputeStrips() {
		guard let primary = NSScreen.screens.first else { strips = []; return }
		strips = MenuBarGeometry.strips(screenFrames: NSScreen.screens.map(\.frame),
		                               primaryMaxY: primary.frame.maxY,
		                               menuBars: menuBarRects(),
		                               fallbackHeight: fallbackStripHeight)
	}

	/// The menu bar's own windows, in CoreGraphics global coordinates.
	///
	/// Matched geometrically — layer 24, spanning a screen's full width at its top
	/// edge — rather than by window title. `kCGWindowName` needs Screen Recording
	/// permission to read on modern macOS, which this app deliberately never asks
	/// for, so a title match would silently return nothing in the shipped app while
	/// working perfectly when run from a terminal that happens to have the grant.
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

	/// The frontmost game's on-screen windows, in CoreGraphics coordinates, which
	/// `kCGWindowBounds` already uses — so unlike the strips there is no y to flip.
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

		// Logged on change only. This is the fact that decides whether a strip click
		// can be given to the game at all, and it is not knowable without a real game
		// running — measured on a real RDR launch, the window alternates between
		// covering the screen and small helper windows as focus moves.
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

	/// Only for the log line above, so it reports transitions rather than every poll.
	private var loggedCoverage: Bool?

	/// True when one of the game's windows covers the primary display's menu bar
	/// strip — the precondition for handing a click over at all. Restricted to the
	/// primary strip because `SLSSetMenuBarInsetAndAlpha` takes no display argument
	/// and its effect on a second display's bar has not been measured; guessing
	/// permissively there would pass a click to a bar that is still live.
	var gameCoversStrip: Bool {
		guard let primary = strips.first, !gameWindowRects.isEmpty else { return false }
		return gameWindowRects.contains { $0.intersects(primary) }
	}

	/// The game runs as its own regular app named after the executable
	/// ("RDR2.exe") with no bundle identifier.
	private func gameIsFrontmost() -> NSRunningApplication? {
		guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
		if let bundle = front.bundleIdentifier?.lowercased(), bundle.hasPrefix("com.codeweavers") {
			return front
		}
		guard let name = front.localizedName else { return nil }
		return gameNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? front : nil
	}

	private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
		// macOS disables a tap that takes too long or when the user forces input
		// through; it must be re-armed or the shield silently stops working.
		if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
			if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
			Log.write("SHIELD tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
			return Unmanaged.passUnretained(event)
		}

		// Never swallow a click unless a game genuinely has focus right now.
		guard let game = gameIsFrontmost() else {
			// Worth a line: the tap is only installed while a game is frontmost, so a
			// click arriving here means focus changed under us and this click is going
			// to the menu bar. That is correct behaviour, but it is also the single most
			// likely explanation for "the menu bar still opened during my game", so it
			// must be visible rather than inferred.
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

		// Hand it over only when the bar will refuse it AND the arrow it reveals will
		// stay hidden, and only over the game's own window on the primary display.
		// Any of those missing and the click is discarded, which is always safe.
		if veilIsUp, cursorSuppressed, strips.first?.contains(location) == true,
		   gameWindowRects.contains(where: { $0.contains(location) }) {
			Stats.recordDeliveredClick()
			onDeliveringStripClick?()
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
