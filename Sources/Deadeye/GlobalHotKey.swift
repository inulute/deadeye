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

	/// Which of this app's hot keys this instance owns. The Carbon handler is
	/// installed on the shared application target, so every instance's handler is
	/// called for every press and has to recognise its own.
	private var identifier: UInt32 = 1

	/// Virtual key codes, from `Carbon/HIToolbox/Events.h`.
	static let keyG = UInt32(kVK_ANSI_G)
	static let keyC = UInt32(kVK_ANSI_C)
	static let keyF2 = UInt32(kVK_F2)

	/// No modifiers at all. Only valid for a key nothing else claims, which F2 is
	/// once the keyboard is sending function keys rather than brightness.
	static let noModifiers: UInt32 = 0

	/// Carbon modifier masks, which are not the same values as `NSEvent`'s.
	static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

	/// One fewer key than the on/off combination, for the one a player reaches for
	/// mid-game. Command is left out on purpose: CrossOver forwards Command combos
	/// into the bottle, so the game would see it too.
	static let controlOption = UInt32(controlKey | optionKey)

	@discardableResult
	func register(keyCode: UInt32, modifiers: UInt32, identifier: UInt32 = 1,
	              action: @escaping () -> Void) -> Bool {
		self.action = action
		self.identifier = identifier

		var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
		                              eventKind: UInt32(kEventHotKeyPressed))

		// A C callback cannot capture context, so `self` travels through userData.
		let installed = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, event, userData -> OSStatus in
				guard let userData else { return OSStatus(eventNotHandledErr) }
				let target = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

				// Every instance's handler sees every press, so without this the
				// second hot key registered would fire the first one's action too.
				var pressed = EventHotKeyID()
				let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
				                             EventParamType(typeEventHotKeyID), nil,
				                             MemoryLayout<EventHotKeyID>.size, nil, &pressed)
				guard read == noErr, pressed.id == target.identifier else {
					return OSStatus(eventNotHandledErr)
				}

				target.fire()
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
		let id = EventHotKeyID(signature: OSType(0x4358_474D), id: identifier)
		let registered = RegisterEventHotKey(keyCode, modifiers, id,
		                                     GetApplicationEventTarget(), 0, &hotKeyRef)
		guard registered == noErr else {
			// Most likely another app already owns this combination.
			Log.write("HOTKEY RegisterEventHotKey failed: \(registered) — combination may be taken")
			return false
		}

		Log.write("HOTKEY registered (keyCode=\(keyCode), modifiers=\(modifiers), id=\(identifier))")
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
			Log.write("HOTKEY ignored (debounced, id=\(identifier))")
			return
		}
		lastFired = now
		Log.write("HOTKEY fired (id=\(identifier))")
		DispatchQueue.main.async { [weak self] in self?.action?() }
	}
}
