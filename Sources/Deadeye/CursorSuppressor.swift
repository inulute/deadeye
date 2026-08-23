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

	/// Whether we are currently holding a hide. Tracked because hide and show are a
	/// balanced pair: calling show without a matching hide pushes the window server's
	/// count below zero and forces the cursor visible even when the game wants it gone.
	private var holding = false

	/// Whether the game itself is keeping the cursor hidden, as of the last peek.
	///
	/// This is the whole reason the class is not simply "hide while a game is focused".
	/// Cursor visibility is a shared count and any connection holding a hide wins, so a
	/// permanent hide from here silently outranks the game: RDR2's map, settings and
	/// inventory screens ask for their cursor and never get it. Measured against a
	/// harness that toggles the way a real game does, the cursor stayed hidden through
	/// every menu.
	private var gameHidesCursor = true

	private var loggedIntent: Bool?

	/// A peek releases the hide and reads back 30ms later, so overlapping peeks would
	/// release twice and unbalance the window server's count.
	private var peekInFlight = false

	var cursorIsVisible: Bool { Self.cursorIsVisible?() ?? true }

	private func declareBackgroundCursorOnce() {
		guard !declaredBackgroundCursor, let connection,
		      let setter = Self.setConnectionProperty else { return }
		declaredBackgroundCursor = true
		let err = setter(connection, connection,
		                 "SetsCursorInBackground" as CFString, kCFBooleanTrue)
		Log.write("CURSOR SetsCursorInBackground -> \(err)")
	}

	private func hold() {
		guard !holding, let connection else { return }
		holding = true
		let err = Self.hideCursor?(connection) ?? -999
		CGDisplayHideCursor(CGMainDisplayID())
		if err != 0, !loggedFailure {
			loggedFailure = true
			Log.write("CURSOR SLSHideCursor failed err=\(err)")
		}
	}

	private func release() {
		guard holding, let connection else { return }
		holding = false
		_ = Self.showCursor?(connection)
		CGDisplayShowCursor(CGMainDisplayID())
	}

	func raise() {
		guard !isUp, Self.isSupported else { return }
		declareBackgroundCursorOnce()
		isUp = true
		reassert()
		Log.write("CURSOR suppression armed, following the game's own cursor")
	}

	func lower() {
		guard isUp else { return }
		isUp = false
		release()
		loggedIntent = nil
		Log.write("CURSOR restored")
	}

	/// Asks the game what it wants, and holds the cursor down only if the game is
	/// already hiding it.
	///
	/// The hide has to be released before reading, because while we hold one the
	/// reading reflects our own hide rather than the game's intent. It also has to be
	/// released for a moment first: measured against a game that toggles its cursor,
	/// reading at 0ms and 2ms after the release always came back "hidden" whatever the
	/// game was doing, while 10ms and 30ms tracked it correctly every time. So the read
	/// is deferred, and 30ms is used for margin.
	///
	/// Letting go for 30ms does not flash the cursor. During play the game is holding
	/// its own hide, which is independent of ours, so the cursor stays hidden while we
	/// are not looking. It only becomes visible if the game wanted it visible, which is
	/// exactly what this is trying to find out. Deferred rather than slept, so the run
	/// loop is not blocked for 30ms out of every poll.
	func reassert() {
		guard isUp, !peekInFlight else { return }
		peekInFlight = true
		release()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
			guard let self else { return }
			self.peekInFlight = false
			guard self.isUp else { return }

			self.gameHidesCursor = !self.cursorIsVisible
			if self.gameHidesCursor { self.hold() }

			if self.loggedIntent != self.gameHidesCursor {
				self.loggedIntent = self.gameHidesCursor
				Log.write(self.gameHidesCursor
					? "CURSOR game is hiding its cursor, so the macOS arrow is suppressed too"
					: "CURSOR game is showing its own cursor, so suppression stands down")
			}
		}
	}

	/// Called from the event tap just before a strip click is handed to the game.
	///
	/// A processed click at the top of the screen reveals the macOS arrow, so it has to
	/// be put back. Only when the game is hiding its cursor: during a menu the arrow
	/// *is* the game's cursor and hiding it is the bug this guards against.
	func armForImminentReveal() {
		guard isUp, gameHidesCursor else { return }
		// The reveal happens after the tap returns, so the correction is dispatched
		// rather than applied inline.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.isUp, self.gameHidesCursor else { return }
			self.holding = false          // the reveal defeated our hide; re-take it
			self.hold()
		}
	}
}
