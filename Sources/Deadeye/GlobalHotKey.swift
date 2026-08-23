//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  A system-wide hot key.
//

import AppKit
import Carbon.HIToolbox

/// Registers a hot key that fires no matter which app has focus, including over a
/// fullscreen game.
///
/// An `NSMenuItem.keyEquivalent` on a status-bar menu only fires while that menu is
/// open, which makes it useless for toggling anything mid-game — the whole point.
/// `RegisterEventHotKey` is the real thing, and unlike an event tap or synthesised
/// events it needs no Accessibility permission.
final class GlobalHotKey {
	private var hotKeyRef: EventHotKeyRef?
	private var handlerRef: EventHandlerRef?
	private var action: (() -> Void)?

	/// Guards against the same press arriving twice — once from the menu item's key
	/// equivalent and once from this hot key — which would toggle twice and look
	/// like nothing happened.
	private var lastFired = Date.distantPast
	private let debounce: TimeInterval = 0.3

	/// Virtual key codes, from `Carbon/HIToolbox/Events.h`.
	static let keyG = UInt32(kVK_ANSI_G)

	/// Carbon modifier masks, which are not the same values as `NSEvent`'s.
	static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

	@discardableResult
	func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
		self.action = action

		var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
		                              eventKind: UInt32(kEventHotKeyPressed))

		// A C callback cannot capture context, so `self` travels through userData.
		let installed = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, _, userData -> OSStatus in
				guard let userData else { return OSStatus(eventNotHandledErr) }
				Unmanaged<GlobalHotKey>.fromOpaque(userData)
					.takeUnretainedValue()
					.fire()
				return noErr
			},
			1, &eventType,
			Unmanaged.passUnretained(self).toOpaque(),
			&handlerRef
		)
		guard installed == noErr else {
			Log.write("HOTKEY InstallEventHandler failed: \(installed)")
			return false
		}

		// Signature is an arbitrary four-char code identifying this app's hot keys.
		let id = EventHotKeyID(signature: OSType(0x4358_474D), id: 1)
		let registered = RegisterEventHotKey(keyCode, modifiers, id,
		                                     GetApplicationEventTarget(), 0, &hotKeyRef)
		guard registered == noErr else {
			// Most likely another app already owns this combination.
			Log.write("HOTKEY RegisterEventHotKey failed: \(registered) — combination may be taken")
			return false
		}

		Log.write("HOTKEY registered (keyCode=\(keyCode), modifiers=\(modifiers))")
		return true
	}

	func unregister() {
		if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
		if let handlerRef { RemoveEventHandler(handlerRef) }
		hotKeyRef = nil
		handlerRef = nil
	}

	private func fire() {
		let now = Date()
		guard now.timeIntervalSince(lastFired) > debounce else {
			Log.write("HOTKEY ignored (debounced)")
			return
		}
		lastFired = now
		Log.write("HOTKEY fired")
		DispatchQueue.main.async { [weak self] in self?.action?() }
	}
}
