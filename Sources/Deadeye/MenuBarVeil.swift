//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import CoreGraphics

final class MenuBarVeil {
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

	func reassert() {
		guard isUp else { return }
		setAlpha(0)
	}
}
