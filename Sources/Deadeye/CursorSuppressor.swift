//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Keeping the macOS arrow invisible while a game is focused.
//

import AppKit
import CoreGraphics

/// Suppresses the system cursor from a background app, so the arrow a top-of-screen
/// click reveals never becomes visible over the game.
///
/// ## Why this is the piece that makes everything else work
///
/// The player's real complaint was never the lost click or the opened menu: it was
/// ending up with **two cursors**, the game's own and the macOS arrow, moving
/// independently. Measured with a game that hides its cursor the way Wine does,
/// *delivering* a top-of-screen click reveals the arrow — whoever receives it, the
/// game included. That is why the shield discarded the click for so long, and why
/// discarding cost the player their aim.
///
/// With the arrow suppressed, revealing it is harmless. The click can be handed to
/// the game (see `MenuBarVeil`) and the aim survives, because the thing that made
/// delivery unacceptable no longer happens.
///
/// ## `SetsCursorInBackground`, and why the old note was wrong
///
/// `CursorGuard.swift` records that a background app cannot set the system cursor,
/// and on the plain APIs that is true — measured here, `SLSHideCursor` and
/// `CGDisplayHideCursor` both return success and change nothing:
///
///     SLSHideCursor        -> 0
///     CGDisplayHideCursor  -> 0
///     cursor visible now: true      <- did nothing
///
/// Declaring `SetsCursorInBackground` on our own window server connection first
/// changes that completely:
///
///     SLSSetConnectionProperty(SetsCursorInBackground, true) -> 0
///     SLSHideCursor        -> 0
///     cursor visible now: false     <- honoured
///
/// This is the same mechanism cursor-hiding utilities such as Cursorcerer use. The
/// property has to be set before the hide, and it is set once per connection.
///
/// ## Why it cannot strand the user without a cursor
///
/// The hide is owned by this process's window server connection. `kill -9` restored
/// the cursor immediately with no bookkeeping, the same property that makes
/// `MenuBarVeil` safe. So the worst case is a cursor missing for as long as Deadeye
/// is alive and wrong about a game being focused — and `lower()` runs the moment the
/// game stops being frontmost, on quit, and on a signal.
final class CursorSuppressor {
	private static let skyLight = dlopen(
		"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

	private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
		guard let skyLight, let pointer = dlsym(skyLight, name) else {
			Log.write("CURSOR symbol missing: \(name)")
			return nil
		}
		return unsafeBitCast(pointer, to: type)
	}

	private typealias MainConnectionID = @convention(c) () -> Int32
	/// `CGError SLSSetConnectionProperty(int cid, int targetCid, CFStringRef, CFTypeRef)`
	private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
	private typealias CursorCall = @convention(c) (Int32) -> Int32
	private typealias CursorIsVisible = @convention(c) () -> Bool

	private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
	private static let setConnectionProperty = symbol("SLSSetConnectionProperty", as: SetConnectionProperty.self)
	private static let hideCursor = symbol("SLSHideCursor", as: CursorCall.self)
	private static let showCursor = symbol("SLSShowCursor", as: CursorCall.self)
	private static let cursorIsVisible = symbol("SLCursorIsVisible", as: CursorIsVisible.self)

	/// Diagnostics only, no behaviour hangs off these. `SLSCurrentCursorSeed` bumps
	/// when the cursor *image* changes, and measured here it ignores our own hide and
	/// show entirely: six cycles left it unmoved. So a bump means something else set a
	/// different cursor, which is the question worth answering — if a game draws its
	/// menu cursor by setting its own image rather than by asking for the system
	/// arrow, then suppression could one day key off which image is on screen instead
	/// of asking the player. Preliminary logs show two sizes in play, 4480 bytes and
	/// 4096, which is what that would look like. Not enough to build on yet.
	private typealias CursorSeed = @convention(c) () -> Int32
	private typealias CursorDataSize = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32

	/// `CGImageRef SLSCreateRegisteredCursorImage(int cid, char *name, CGPoint *hotSpot)`
	private typealias RegisteredCursorImage =
		@convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGPoint>) -> Unmanaged<CGImage>?

	private static let currentCursorSeed = symbol("SLSCurrentCursorSeed", as: CursorSeed.self)
	private static let globalCursorDataSize = symbol("SLSGetGlobalCursorDataSize", as: CursorDataSize.self)
	private static let registeredCursorImage =
		symbol("SLSCreateRegisteredCursorImage", as: RegisteredCursorImage.self)

	/// The window server's name for the plain macOS arrow.
	private static let arrowCursorName = "com.apple.coregraphics.Arrow"

	private var lastCursorSignature: (seed: Int32, bytes: Int32)?

	static var isSupported: Bool {
		mainConnectionID != nil && setConnectionProperty != nil && hideCursor != nil
	}

	private(set) var isUp = false
	private lazy var connection: Int32? = Self.mainConnectionID?()
	private var declaredBackgroundCursor = false
	private var loggedFailure = false

	/// True only when the window server currently considers the cursor visible. Used
	/// for logging, never for control flow — the suppressor re-asserts unconditionally
	/// because asking first would double the number of calls for no benefit.
	var cursorIsVisible: Bool { Self.cursorIsVisible?() ?? true }

	/// Hands the arrow back on request, without disarming anything.
	///
	/// ## Why this is a switch and not a guess
	///
	/// Games that draw their own menus want a cursor there and not during play, and
	/// deciding which is which automatically was tried twice. Reading the window
	/// server's cursor visibility does not work: it is a single shared flag, and
	/// anything on the system that reveals the arrow — a click at the top of the
	/// screen, the pointer reaching a screen edge — makes a game look like it asked
	/// for a cursor when it did not, stranding the arrow over play for as long as a
	/// minute. Reading the pointer's position does not work either: reveals do cluster
	/// at screen edges, but so does ordinary map use, because panning a map means
	/// pushing the pointer into the edges. Suppressing those took the cursor away from
	/// the one screen that needed it.
	///
	/// So the player says when. Hidden by default, which is right for play, and one
	/// hot key away from visible, which is right for a map. A switch cannot be
	/// wrong about intent the way both of those readings were.
	///
	/// Deliberately not cleared by `lower()`: Cmd-Tabbing out of a map and back should
	/// return to the map with its cursor. The poll clears it when the game exits.
	var isPaused = false {
		didSet {
			guard isPaused != oldValue, isUp else { return }
			if isPaused {
				stopTracking()
				release()
				Log.write("CURSOR handed back on request — the macOS arrow is visible")
			} else {
				reassert()
				Log.write("CURSOR hidden again on request")
			}
		}
	}

	/// Must be sent before any hide, or the hide is accepted and ignored.
	private func declareBackgroundCursorOnce() {
		guard !declaredBackgroundCursor, let connection,
		      let setter = Self.setConnectionProperty else { return }
		declaredBackgroundCursor = true
		let err = setter(connection, connection,
		                 "SetsCursorInBackground" as CFString, kCFBooleanTrue)
		Log.write("CURSOR SetsCursorInBackground -> \(err)")
	}

	func raise() {
		guard !isUp, Self.isSupported else { return }
		declareBackgroundCursorOnce()
		isUp = true
		reassert()
		Log.write("CURSOR watching — macOS's arrow gets held down, the game's own cursor does not")
	}

	func lower() {
		guard isUp else { return }
		isUp = false
		stopTracking()
		release()
		Log.write("CURSOR restored")
	}

	/// How many hides this connection is holding, tracked exactly.
	///
	/// `SLSHideCursor` is reference counted — measured directly: five hides needed
	/// five shows, and one show after five left the cursor hidden. The version this
	/// came from re-hid on every 1.5 second poll and never showed, so after a minute
	/// of play the count stood around forty. Handing the cursor back issued a single
	/// show against it and nothing happened, which is exactly what the player saw:
	/// press the key, no cursor, press it enough times and it eventually surfaces.
	///
	/// Counting is what makes the release exact. Draining instead — showing until the
	/// window server says visible — reads a value that lags, so the loop overshoots
	/// past zero, and a negative count forces the cursor visible over a game that
	/// wants it gone. Showing precisely as many times as we hid needs no reading.
	private var heldHides = 0

	private func hold() {
		guard let connection else { return }
		let err = Self.hideCursor?(connection) ?? -999
		heldHides += 1
		if err != 0, !loggedFailure {
			loggedFailure = true
			Log.write("CURSOR SLSHideCursor failed err=\(err)")
		}
	}

	private func release() {
		guard let connection else { return }
		while heldHides > 0 {
			_ = Self.showCursor?(connection)
			heldHides -= 1
		}
	}

	// MARK: - Telling the macOS arrow apart from the game's own cursor

	/// Byte size of the plain macOS arrow, read from the window server at start-up.
	///
	/// Derived rather than hardcoded because it tracks the accessibility cursor-size
	/// setting: on this machine the arrow is 28x40 at 4 bytes a pixel, so 4480, which
	/// is exactly the figure the logs show turning up whenever macOS puts its own
	/// pointer back.
	private var arrowBytes: Int32 = 0

	private var lastSeed: Int32 = -1
	private var lastVerdictWasArrow = false
	private var tracker: Timer?

	/// Whether the game wants its own cursor on screen, as of the last time it set one.
	///
	/// `nil` while that is still settling. This is the difference between a map and a
	/// screen edge, and it comes straight out of Wine's source rather than a guess:
	/// showing a cursor for a menu goes through `-setCursor`, which sets an image and
	/// *then* unhides, so it always moves the cursor seed. The edge case goes through
	/// `-updateCursor`'s other branch, which unhides without setting anything, so the
	/// seed does not move. A cursor that becomes visible with no new image behind it
	/// was therefore never asked for by the game.
	private var gameWantsVisible: Bool?

	/// Ticks to wait after the game changes cursor before reading what it wants. The
	/// visibility read lags a little, and reading it too early reports our own state
	/// back to us.
	private var settleTicks = 0

	private func measureArrow() {
		guard arrowBytes == 0, let connection, let make = Self.registeredCursorImage else { return }
		var hotspot = CGPoint.zero
		guard let image = Self.arrowCursorName
			.withCString({ make(connection, $0, &hotspot) })?.takeRetainedValue() else { return }
		arrowBytes = Int32(image.width * image.height * 4)
		Log.write("CURSOR the macOS arrow measures \(image.width)x\(image.height), \(arrowBytes)B")
	}

	/// Whether the cursor on screen right now is the macOS arrow rather than one the
	/// game set for itself.
	///
	/// Costs one round trip to the window server, about 50 microseconds, so it is only
	/// asked when the seed says the cursor actually changed.
	private var showingSystemArrow: Bool {
		guard arrowBytes > 0, let connection, let size = Self.globalCursorDataSize else { return false }
		var bytes: Int32 = 0
		guard size(connection, &bytes) == 0 else { return false }
		return bytes == arrowBytes
	}

	/// Watches the cursor at 30Hz and holds down only the macOS arrow.
	///
	/// ## Why a fast watcher instead of a 1.5 second poll
	///
	/// Wine's Mac driver re-sets the cursor constantly, and setting a cursor there
	/// *unhides* it — `cocoa_app.m` ends `-setCursor` with `[self unhideCursor]`. The
	/// game issues one of those on essentially every mouse move, which is why the
	/// cursor seed was seen climbing several times a second during play and why moving
	/// the mouse hard made the arrow appear: each set undid the hide, and a poll one
	/// and a half seconds later was far too slow to matter. Reading the seed is free,
	/// measured at 0.01 microseconds, so this can watch as fast as it likes.
	private func startTracking() {
		guard tracker == nil else { return }
		measureArrow()
		let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
		RunLoop.main.add(timer, forMode: .common)
		tracker = timer
	}

	private func stopTracking() {
		tracker?.invalidate()
		tracker = nil
		lastSeed = -1
		lastVerdictWasArrow = false
		gameWantsVisible = nil
		settleTicks = 0
	}

	private func tick() {
		guard isUp, !isPaused else { return }

		// Deadeye's own menu or alert is up, which means the game is not what the
		// player is looking at. The poll would normally have lowered us by now, but it
		// runs on the default run loop mode and a modal panel stops it dead, so this
		// says so directly rather than relying on being told.
		if NSApp.isActive {
			release()
			return
		}

		let seed = Self.currentCursorSeed?() ?? -1

		if seed != lastSeed {
			lastSeed = seed
			let isArrow = showingSystemArrow
			if isArrow != lastVerdictWasArrow {
				lastVerdictWasArrow = isArrow
				Log.write(isArrow
					? "CURSOR macOS put its own arrow up, holding it down"
					: "CURSOR the game set a cursor of its own")
			}
			if isArrow {
				gameWantsVisible = false
				hold()
			} else {
				// The game just set a cursor. Hand control back and find out in a
				// moment whether it meant to show it.
				release()
				gameWantsVisible = nil
				settleTicks = 2
			}
			return
		}

		// Same image as last tick, so nothing has *set* a cursor since.
		if lastVerdictWasArrow {
			reHideIfEscaped()
			return
		}

		if settleTicks > 0 { settleTicks -= 1; return }

		guard let wantsVisible = gameWantsVisible else {
			let visible = cursorIsVisible
			gameWantsVisible = visible
			Log.write(visible
				? "CURSOR the game wants its cursor on screen, leaving it alone"
				: "CURSOR the game is keeping its own cursor hidden")
			return
		}

		// The game hid its cursor and something put it back without setting a new one.
		// That is Wine unhiding at a screen edge, and it is the one the player sees.
		if !wantsVisible { reHideIfEscaped() }
	}

	/// Takes the hide back when the cursor is on screen despite us holding one.
	///
	/// Gives back everything it holds before taking one again, rather than zeroing the
	/// counter. Zeroing looked equivalent and leaked: the visibility read lags, so a
	/// tick can see "visible" when the hide has in fact landed, and each of those
	/// added a real hide to the window server while recording none. What is left over
	/// is never given back, and the cursor stays hidden after Deadeye has let go —
	/// under its own dialogs, with a game nowhere in sight.
	///
	/// Releasing first keeps the ledger true and the outstanding count at one.
	private func reHideIfEscaped() {
		guard cursorIsVisible else { return }
		release()
		hold()
	}

	/// Called by the poll. The watcher does the real work; this only makes sure it is
	/// running and takes one reading straight away.
	func reassert() {
		guard isUp, !isPaused else { return }
		startTracking()
		tick()
	}

	/// Called after a strip click has been handed to the game.
	///
	/// Processing a click at the top of the screen reveals the arrow, and it does so
	/// after the event tap has already returned. The re-hide has to be immediate:
	/// deferring it by even 30ms to read whether the reveal actually happened put a
	/// visible flash on screen for every top-of-screen click, which 1.0.2 did not
	/// have. So it hides straight away and asks nothing. The extra hide is harmless
	/// because `release()` counts.
	func armForImminentReveal() {
		guard isUp, !isPaused else { return }
		// A processed strip click puts macOS's own arrow up, so this does not wait for
		// the next tick to find out: 33ms of visible arrow is a flash on screen, which
		// is exactly what deferring this by 30ms produced last time.
		lastVerdictWasArrow = true
		hold()
	}
}
