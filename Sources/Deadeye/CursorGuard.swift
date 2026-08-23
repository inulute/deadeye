//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Keeping the cursor out of the menu bar during a CrossOver game.
//

import AppKit
import CoreGraphics

/// Stops the macOS cursor reaching the menu bar while a CrossOver game is focused.
///
/// Wine's own cursor clipping is unreliable on a multi-display Mac — it applies the
/// clip rect to one screen while the game covers another
/// (ValveSoftware/wine#24) — so the pointer roams free. When it reaches the top of
/// the screen a right-click lands on a menu bar status item and opens that app's
/// menu over the game.
///
/// ## Two dead ends, both worth recording
///
/// **1. Pointer lock does not work from a background app.**
/// `CGAssociateMouseAndMouseCursorPosition(false)` is the textbook way to decouple
/// the cursor from the mouse, and it is what Wine itself uses. Called from this
/// app it returns `kCGErrorSuccess` and has **no effect whatsoever** — logging the
/// cursor position every 1.5s while "locked" showed it roaming the full screen.
/// macOS only honours the call for a process that owns the display or is
/// frontmost, and a menu bar accessory app while a game has focus is neither.
///
/// **2. Naive warping eats the player's input.**
/// The first clamping attempt polled at 120 Hz and warped on every sample.
/// `CGWarpMouseCursorPosition` triggers macOS's local events suppression state,
/// which filters out real hardware mouse events for roughly a quarter second
/// afterwards, so continuous warping continuously swallowed real mouse movement —
/// which is what "the movement is blocked" was. Fixed by permitting local events
/// during suppression, once, up front.
///
/// ## What this does
///
/// Clamps **only the top edge**, and only when the cursor is actually in the
/// forbidden strip. Everything else is left alone, deliberately:
///
/// * A warp only ever happens when the cursor is against the menu bar, so no warp
///   — and therefore no risk of suppression — occurs during ordinary aiming.
/// * Left, right and downward movement are never touched, which is what felt
///   broken when an earlier version clamped all four edges.
final class CursorGuard {
	private var timer: Timer?
	private(set) var isActive = false

	/// Names of currently running games, used to tell whether the game is the
	/// frontmost app. Updated by the app's poll loop.
	var gameNames: [String] = []

	private var lastLoggedFront = ""
	private var clampCount = 0

	/// The game's screen, captured when the guard arms and held for the session.
	///
	/// It must be captured rather than recomputed per tick: once the cursor has
	/// strayed onto the neighbouring display, "the screen the cursor is on" is the
	/// wrong screen, and clamping to it would strand the cursor there instead of
	/// pulling it home.
	private var gameScreen: CGRect?

	private let edgeInset: CGFloat = 1

	/// Height of the strip the cursor is kept out of. The menu bar reveals when the
	/// pointer touches the top row of pixels and then occupies roughly the top
	/// 24pt, so the cursor has to stay below both.
	private var forbiddenStripHeight: CGFloat {
		max(NSStatusBar.system.thickness, 24) + 2
	}

	/// Nothing to undo — this implementation never changes global mouse state — but
	/// kept as the single place that would need to release anything in future.
	static func releaseStaleLock() {
		CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
	}

	func start() {
		guard timer == nil else { return }
		isActive = true
		permitHardwareEventsDuringSuppression()
		captureGameScreen()

		// A display being plugged in, unplugged or rearranged invalidates the
		// captured frame.
		NotificationCenter.default.addObserver(
			self, selector: #selector(screensChanged),
			name: NSApplication.didChangeScreenParametersNotification, object: nil)

		// 120 Hz: the menu bar reveals on contact, so a slower poll lets it flash
		// into view before the cursor is pushed back out.
		timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
			self?.tick()
		}
		timer?.tolerance = 0
		Log.write("GUARD start  strip=\(forbiddenStripHeight)pt")
	}

	func stop() {
		guard timer != nil else { return }
		NotificationCenter.default.removeObserver(
			self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
		timer?.invalidate()
		timer = nil
		isActive = false
		gameScreen = nil
		Log.write("GUARD stop   (clamped \(clampCount)x)")
		clampCount = 0
	}

	/// `NSScreen.main` is the screen holding the window with keyboard focus, which
	/// while the game is frontmost is the screen the game is on. That is the right
	/// question to ask here, unlike `screens.first`, which is simply the display
	/// carrying the primary menu bar and is wrong whenever the game is elsewhere.
	private func captureGameScreen() {
		let screen = NSScreen.main ?? NSScreen.screens.first
		gameScreen = screen?.frame
		Log.write("GUARD screen = \(gameScreen.map { "\($0)" } ?? "none")  strip=\(forbiddenStripHeight)pt")
	}

	@objc private func screensChanged() {
		captureGameScreen()
		Log.write("GUARD display layout changed, re-captured game screen")
	}

	/// Pure geometry, kept separate so it can be tested against real display
	/// layouts without needing a game running and the app focused.
	///
	/// Confines to the game's screen on all four edges. With "Displays have separate
	/// Spaces" on — the macOS default — *every* display carries its own menu bar, so
	/// guarding only the top edge leaves the neighbouring display's menu bar
	/// reachable by moving down or sideways off the game screen.
	static func clamped(_ point: CGPoint, to frame: CGRect,
	                    topStrip: CGFloat, edgeInset: CGFloat) -> CGPoint {
		CGPoint(
			x: min(max(point.x, frame.minX + edgeInset), frame.maxX - edgeInset),
			y: min(max(point.y, frame.minY + edgeInset), frame.maxY - topStrip)
		)
	}

	private func tick() {
		guard !gameNames.isEmpty, gameIsFrontmost() else { return }
		guard let frame = gameScreen, let primary = NSScreen.screens.first else { return }

		let point = NSEvent.mouseLocation
		let target = Self.clamped(point, to: frame,
		                          topStrip: forbiddenStripHeight, edgeInset: edgeInset)
		let (x, y) = (target.x, target.y)

		guard abs(x - point.x) > 0.01 || abs(y - point.y) > 0.01 else { return }

		CGWarpMouseCursorPosition(CGPoint(x: x, y: primary.frame.maxY - y))

		clampCount += 1
		if clampCount == 1 || clampCount % 500 == 0 {
			Log.write("   clamped #\(clampCount): NS(\(Int(point.x)), \(Int(point.y))) -> (\(Int(x)), \(Int(y)))")
		}
	}

	/// The game runs as its own regular app whose `localizedName` is the executable
	/// ("RDR2.exe") and whose bundle identifier is nil, so match on either that
	/// name or any CrossOver bundle id.
	private func gameIsFrontmost() -> Bool {
		guard let front = NSWorkspace.shared.frontmostApplication else { return false }

		if let bundle = front.bundleIdentifier?.lowercased(), bundle.hasPrefix("com.codeweavers") {
			return true
		}
		guard let name = front.localizedName else { return false }
		return gameNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
	}

	func logFrontmostIfChanged() {
		let front = NSWorkspace.shared.frontmostApplication
		let describe = "\(front?.localizedName ?? "nil") [\(front?.bundleIdentifier ?? "no-bundle-id")]"
		guard describe != lastLoggedFront else { return }
		lastLoggedFront = describe
		Log.write("frontmost -> \(describe)  games=\(gameNames)  guarding=\(gameIsFrontmost())")
	}

	/// Without this, each warp above would suppress the player's real mouse input
	/// for the default suppression interval.
	/// `CGSetLocalEventsSuppressionInterval` would be the direct way to set the
	/// interval to zero, but it is unavailable on current macOS. Permitting local
	/// events during the suppression state is the supported equivalent.
	private func permitHardwareEventsDuringSuppression() {
		guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
		let permitEverything: CGEventFilterMask = [
			.permitLocalMouseEvents,
			.permitLocalKeyboardEvents,
			.permitSystemDefinedEvents,
		]
		source.setLocalEventsFilterDuringSuppressionState(
			permitEverything, state: .eventSuppressionStateSuppressionInterval)
		source.setLocalEventsFilterDuringSuppressionState(
			permitEverything, state: .eventSuppressionStateRemoteMouseDrag)
	}
}
