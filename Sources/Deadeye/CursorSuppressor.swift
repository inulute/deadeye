//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import CoreGraphics

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
	private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
	private typealias CursorCall = @convention(c) (Int32) -> Int32
	private typealias CursorIsVisible = @convention(c) () -> Bool

	private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
	private static let setConnectionProperty = symbol("SLSSetConnectionProperty", as: SetConnectionProperty.self)
	private static let hideCursor = symbol("SLSHideCursor", as: CursorCall.self)
	private static let showCursor = symbol("SLSShowCursor", as: CursorCall.self)
	private static let cursorIsVisible = symbol("SLCursorIsVisible", as: CursorIsVisible.self)

	private typealias CursorSeed = @convention(c) () -> Int32
	private typealias CursorDataSize = @convention(c) (Int32, UnsafeMutablePointer<Int32>) -> Int32

	private typealias RegisteredCursorImage =
		@convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGPoint>) -> Unmanaged<CGImage>?

	private static let currentCursorSeed = symbol("SLSCurrentCursorSeed", as: CursorSeed.self)
	private static let globalCursorDataSize = symbol("SLSGetGlobalCursorDataSize", as: CursorDataSize.self)
	private static let registeredCursorImage =
		symbol("SLSCreateRegisteredCursorImage", as: RegisteredCursorImage.self)

	private static let arrowCursorName = "com.apple.coregraphics.Arrow"

	private var lastCursorSignature: (seed: Int32, bytes: Int32)?

	static var isSupported: Bool {
		mainConnectionID != nil && setConnectionProperty != nil && hideCursor != nil
	}

	private(set) var isUp = false
	private lazy var connection: Int32? = Self.mainConnectionID?()
	private var declaredBackgroundCursor = false
	private var loggedFailure = false

	var cursorIsVisible: Bool { Self.cursorIsVisible?() ?? true }

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

	private var arrowBytes: Int32 = 0

	private var lastSeed: Int32 = -1
	private var lastVerdictWasArrow = false
	private var tracker: Timer?

	private var gameWantsVisible: Bool?

	private var settleTicks = 0

	private func measureArrow() {
		guard arrowBytes == 0, let connection, let make = Self.registeredCursorImage else { return }
		var hotspot = CGPoint.zero
		guard let image = Self.arrowCursorName
			.withCString({ make(connection, $0, &hotspot) })?.takeRetainedValue() else { return }
		arrowBytes = Int32(image.width * image.height * 4)
		Log.write("CURSOR the macOS arrow measures \(image.width)x\(image.height), \(arrowBytes)B")
	}

	private var showingSystemArrow: Bool {
		guard arrowBytes > 0, let connection, let size = Self.globalCursorDataSize else { return false }
		var bytes: Int32 = 0
		guard size(connection, &bytes) == 0 else { return false }
		return bytes == arrowBytes
	}

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
				release()
				gameWantsVisible = nil
				settleTicks = 2
			}
			return
		}

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

		if !wantsVisible { reHideIfEscaped() }
	}

	private func reHideIfEscaped() {
		guard cursorIsVisible else { return }
		release()
		hold()
	}

	func reassert() {
		guard isUp, !isPaused else { return }
		startTracking()
		tick()
	}

	func armForImminentReveal() {
		guard isUp, !isPaused else { return }
		lastVerdictWasArrow = true
		hold()
	}
}
