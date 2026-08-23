//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Making the menu bar refuse the click, so the game gets it.
//

import AppKit
import CoreGraphics

/// Makes the menu bar stop accepting clicks while a game is focused, so a click at
/// the top of the screen reaches the **game** instead of opening a menu over it or
/// being discarded.
///
/// `SLSSetMenuBarInsetAndAlpha` at alpha 0 is what the window server itself uses to
/// fade the bar. At zero it stops hit-testing: the click falls through to whatever
/// window is underneath, which for a fullscreen Wine game is the game.
///
/// ## This was once a dead end, and what changed
///
/// Measured on its own, the veil worked — strip clicks, left and right, were
/// delivered to the game — and it was still wrong to ship, because **delivering a
/// top-of-screen click reveals the macOS arrow**, whoever receives it. Two cursors
/// moving independently is the bug this app exists to prevent, so a delivered click
/// cost more than a lost one, and the shield went back to discarding.
///
/// `CursorSuppressor` is what changed. With the arrow suppressed from the background
/// the reveal is harmless, so delivery is no longer paid for with the thing the
/// player actually minded. The two only make sense together: **this class without
/// `CursorSuppressor` reintroduces the original bug**, which is why `MenuBarShield`
/// will not hand a click over unless the suppressor is up as well.
///
/// ## What was measured
///
/// A borderless window covering the screen, standing in for the window CrossOver's
/// Mac driver puts up, logging every `mouseDown` it received:
///
/// | game window level | veil | strip click reaches the game? |
/// |---|---|---|
/// | 0 (ordinary window) | down | no — the menu bar takes it |
/// | 0 (ordinary window) | **up** | **yes, left and right** |
/// | 26 (the layer measured on a real RDR window) | down | yes |
///
/// The last row disproves the "the window server gives the menu bar strip priority
/// regardless of z-order" conclusion recorded in `MenuBarShield`. Z-order does win.
/// What it needs is for the game's window to actually *cover* the strip: a window
/// sized to `visibleFrame` starts below the bar and received nothing even with the
/// veil up, because there was nothing under the strip to receive it. That is why
/// `MenuBarShield` checks the game's window bounds before handing anything over.
///
/// ## Why this is safe to leave applied
///
/// The alpha is scoped to this process's window server connection. `kill -9`
/// restored the menu bar immediately, with no bookkeeping — the opposite of the
/// `_HIHideMenuBar` footgun recorded in `main.swift`, which was a global preference
/// that outlived the app that set it. Nothing here can be stranded.
final class MenuBarVeil {
	/// Resolved at runtime, never linked: these are private symbols, present on every
	/// macOS this app supports today, but a future release can drop one and a missing
	/// symbol has to degrade to "discard the click" rather than fail to launch.
	private static let skyLight = dlopen(
		"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

	private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
		guard let skyLight, let pointer = dlsym(skyLight, name) else {
			Log.write("VEIL symbol missing: \(name)")
			return nil
		}
		return unsafeBitCast(pointer, to: type)
	}

	private typealias MainConnectionID = @convention(c) () -> Int32

	/// `CGError SLSSetMenuBarInsetAndAlpha(int cid, double, double, float alpha)`.
	/// The two doubles are the inset, unused here — (0, 1) is what the window server
	/// passes when it is only changing alpha.
	private typealias SetMenuBarInsetAndAlpha = @convention(c) (Int32, Double, Double, Float) -> Int32

	private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
	private static let setInsetAndAlpha = symbol("SLSSetMenuBarInsetAndAlpha", as: SetMenuBarInsetAndAlpha.self)

	static var isSupported: Bool { mainConnectionID != nil && setInsetAndAlpha != nil }

	private(set) var isUp = false
	private lazy var connection: Int32? = Self.mainConnectionID?()
	private var loggedFailure = false

	@discardableResult
	private func setAlpha(_ alpha: Float) -> Bool {
		guard let setter = Self.setInsetAndAlpha, let connection else { return false }
		let err = setter(connection, 0, 1, alpha)
		if err != 0, !loggedFailure {
			loggedFailure = true
			Log.write("VEIL SLSSetMenuBarInsetAndAlpha(\(alpha)) failed err=\(err)")
		}
		return err == 0
	}

	func raise() {
		guard !isUp, Self.isSupported else { return }
		guard setAlpha(0) else { return }
		isUp = true
		Log.write("VEIL up — menu bar is click-through, strip clicks go to the game")
	}

	func lower() {
		guard isUp else { return }
		isUp = false
		setAlpha(1)
		Log.write("VEIL down — menu bar restored")
	}

	/// Menu bar managers (Bartender, Ice, Thaw) drive the same machinery and can reset
	/// the bar's alpha underneath us. Idempotent and cheap, so the poll loop simply
	/// re-applies it rather than trying to detect who changed what.
	func reassert() {
		guard isUp else { return }
		setAlpha(0)
	}
}
