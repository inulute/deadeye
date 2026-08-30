//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {
	private var hotKeyRef: EventHotKeyRef?
	private var handlerRef: EventHandlerRef?
	private var action: (() -> Void)?

	private var lastFired = Date.distantPast
	private let debounce: TimeInterval = 0.3

	private var identifier: UInt32 = 1

	static let keyG = UInt32(kVK_ANSI_G)
	static let keyC = UInt32(kVK_ANSI_C)
	static let keyF2 = UInt32(kVK_F2)

	static let noModifiers: UInt32 = 0

	static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

	static let controlOption = UInt32(controlKey | optionKey)

	@discardableResult
	func register(keyCode: UInt32, modifiers: UInt32, identifier: UInt32 = 1,
	              action: @escaping () -> Void) -> Bool {
		self.action = action
		self.identifier = identifier

		var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
		                              eventKind: UInt32(kEventHotKeyPressed))

		let installed = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, event, userData -> OSStatus in
				guard let userData else { return OSStatus(eventNotHandledErr) }
				let target = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()

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

		let id = EventHotKeyID(signature: OSType(0x4358_474D), id: identifier)
		let registered = RegisterEventHotKey(keyCode, modifiers, id,
		                                     GetApplicationEventTarget(), 0, &hotKeyRef)
		guard registered == noErr else {
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
