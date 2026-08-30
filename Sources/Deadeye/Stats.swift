//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import Foundation

enum Stats {
	private static let sessionsKey = "statsSessions"
	private static let clicksKey = "statsClicksBlocked"
	private static let askedKey = "statsAskedForSupport"
	private static let deliveredKey = "statsClicksDelivered"
	private static let firstLaunchKey = "statsFirstLaunch"
	private static let asked2DayKey = "statsAskedSupport2Day"
	private static let asked7DayKey = "statsAskedSupport7Day"

	static var sessions: Int {
		get { UserDefaults.standard.integer(forKey: sessionsKey) }
		set { UserDefaults.standard.set(newValue, forKey: sessionsKey) }
	}

	static var clicksBlocked: Int {
		get { UserDefaults.standard.integer(forKey: clicksKey) }
		set { UserDefaults.standard.set(newValue, forKey: clicksKey) }
	}

	static var clicksDelivered: Int {
		get { UserDefaults.standard.integer(forKey: deliveredKey) }
		set { UserDefaults.standard.set(newValue, forKey: deliveredKey) }
	}

	static func recordSession() { sessions += 1 }
	static func recordBlockedClick() { clicksBlocked += 1 }
	static func recordDeliveredClick() { clicksDelivered += 1 }

	static var summary: String? {
		guard sessions > 0 else { return nil }
		let s = sessions == 1 ? "game launch" : "game launches"
		let total = clicksBlocked + clicksDelivered
		if total == 0 {
			return "Protected \(sessions) \(s) so far"
		}
		let c = total == 1 ? "click" : "clicks"
		return "\(total) stray \(c) caught · \(sessions) \(s)"
	}

	enum SupportAsk {
		case early
		case final
	}

	static func recordFirstLaunchIfNeeded() {
		guard UserDefaults.standard.object(forKey: firstLaunchKey) == nil else { return }
		UserDefaults.standard.set(Date(), forKey: firstLaunchKey)
	}

	static var firstLaunch: Date? {
		UserDefaults.standard.object(forKey: firstLaunchKey) as? Date
	}

	static var daysSinceInstall: Int? {
		guard let firstLaunch else { return nil }
		return Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day
	}

	private static var askedEarly: Bool {
		get { UserDefaults.standard.bool(forKey: asked2DayKey) }
		set { UserDefaults.standard.set(newValue, forKey: asked2DayKey) }
	}

	private static var askedFinal: Bool {
		get { UserDefaults.standard.bool(forKey: asked7DayKey) }
		set { UserDefaults.standard.set(newValue, forKey: asked7DayKey) }
	}

	static func migrateLegacySupportFlag() {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: asked2DayKey) == nil else { return }
		guard defaults.bool(forKey: askedKey) else { return }
		defaults.set(true, forKey: asked2DayKey)
		Log.write("SUPPORT legacy ask flag found — counting the early ask as already done")
	}

	static var dueSupportAsk: SupportAsk? {
		guard let days = daysSinceInstall else { return nil }
		return dueAsk(daysSinceInstall: days, sessions: sessions,
		              askedEarly: askedEarly, askedFinal: askedFinal)
	}

	static func dueAsk(daysSinceInstall days: Int, sessions: Int,
	                   askedEarly: Bool, askedFinal: Bool) -> SupportAsk? {
		guard sessions >= 1 else { return nil }
		if days >= 7, !askedFinal { return .final }
		if days >= 2, !askedEarly { return .early }
		return nil
	}

	static func markAsked(_ ask: SupportAsk) {
		switch ask {
		case .early: askedEarly = true
		case .final: askedEarly = true; askedFinal = true
		}
	}
}
