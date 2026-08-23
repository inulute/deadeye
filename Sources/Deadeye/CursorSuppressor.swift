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
		Log.write("CURSOR suppressed — the macOS arrow stays hidden while the game is focused")
	}

	func lower() {
		guard isUp else { return }
		isUp = false
		guard let connection else { return }
		_ = Self.showCursor?(connection)
		CGDisplayShowCursor(CGMainDisplayID())
		Log.write("CURSOR restored")
	}

	/// Re-applies the hide. Cheap, idempotent, and called both from the poll loop and
	/// immediately after a strip click is handed to the game.
	///
	/// Both are needed. A click at the top of the screen reveals the arrow as a
	/// *consequence* of being processed, which happens after the event tap has already
	/// returned — so the poll alone leaves a visible flicker of up to one poll
	/// interval, which measured as a real one on screen. Re-asserting straight after
	/// the click closes it to about a millisecond.
	func reassert() {
		guard isUp, let connection else { return }
		let err = Self.hideCursor?(connection) ?? -999
		CGDisplayHideCursor(CGMainDisplayID())
		if err != 0, !loggedFailure {
			loggedFailure = true
			Log.write("CURSOR SLSHideCursor failed err=\(err)")
		}
	}
}
