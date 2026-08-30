//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import CoreGraphics

final class CursorGuard {
	private var timer: Timer?
	private(set) var isActive = false

	var gameNames: [String] = []

	private var lastLoggedFront = ""
	private var clampCount = 0

	private var gameScreen: CGRect?

	private let edgeInset: CGFloat = 1

	private var forbiddenStripHeight: CGFloat {
		max(NSStatusBar.system.thickness, 24) + 2
	}

	static func releaseStaleLock() {
		CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
	}

	func start() {
		guard timer == nil else { return }
		isActive = true
		permitHardwareEventsDuringSuppression()
		captureGameScreen()

		NotificationCenter.default.addObserver(
			self, selector: #selector(screensChanged),
			name: NSApplication.didChangeScreenParametersNotification, object: nil)

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

	private func captureGameScreen() {
		let screen = NSScreen.main ?? NSScreen.screens.first
		gameScreen = screen?.frame
		Log.write("GUARD screen = \(gameScreen.map { "\($0)" } ?? "none")  strip=\(forbiddenStripHeight)pt")
	}

	@objc private func screensChanged() {
		captureGameScreen()
		Log.write("GUARD display layout changed, re-captured game screen")
	}

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
