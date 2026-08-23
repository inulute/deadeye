//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Counting what Deadeye actually did for you.
//

import Foundation

/// Tracks the work the app has done, so its value is visible rather than assumed.
///
/// This exists for a specific reason. Deadeye is invisible when it works — nothing
/// happens, which is the whole point — so a user has no way of knowing whether it
/// ever did anything. A plain "Support this project" asks someone to pay for a
/// benefit they cannot see. A count of clicks actually intercepted turns an
/// invisible service into a concrete one, and that is what makes a funding ask
/// reasonable rather than presumptuous.
enum Stats {
	private static let sessionsKey = "statsSessions"
	private static let clicksKey = "statsClicksBlocked"
	private static let askedKey = "statsAskedForSupport"
	private static let deliveredKey = "statsClicksDelivered"
	private static let firstLaunchKey = "statsFirstLaunch"
	private static let asked2DayKey = "statsAskedSupport2Day"
	private static let asked7DayKey = "statsAskedSupport7Day"

	/// Number of game sessions Deadeye has protected.
	static var sessions: Int {
		get { UserDefaults.standard.integer(forKey: sessionsKey) }
		set { UserDefaults.standard.set(newValue, forKey: sessionsKey) }
	}

	/// Clicks that landed on the menu bar and were pushed into the game instead.
	///
	/// The stored key still says "blocked" from when these were discarded rather than
	/// redirected. Renaming it would reset everyone's counter to zero on upgrade,
	/// which is a worse outcome than a slightly stale key name.
	static var clicksBlocked: Int {
		get { UserDefaults.standard.integer(forKey: clicksKey) }
		set { UserDefaults.standard.set(newValue, forKey: clicksKey) }
	}

	/// Retired. The key is still read once by `migrateLegacySupportFlag()` to work
	/// out whether an existing install already had the old single ask, and is never
	/// written again.

	/// Strip clicks handed to the game rather than discarded, which is possible only
	/// while the veil and the cursor suppressor are both up. Counted separately
	/// because it is a materially better outcome — the player kept the shot — and
	/// collapsing the two would hide whether that path is working at all.
	static var clicksDelivered: Int {
		get { UserDefaults.standard.integer(forKey: deliveredKey) }
		set { UserDefaults.standard.set(newValue, forKey: deliveredKey) }
	}

	static func recordSession() { sessions += 1 }
	static func recordBlockedClick() { clicksBlocked += 1 }
	static func recordDeliveredClick() { clicksDelivered += 1 }

	/// A human summary for the menu, or nil when there is nothing worth claiming.
	/// Saying "0 clicks across 0 sessions" would undercut the app rather than sell it.
	///
	/// Wording has been through two corrections, both from real misreadings:
	///
	/// * "1 session protected" read as a *live* status — as though a session were
	///   running right then — when these are lifetime totals.
	/// * "Protected 7 games" read as seven *different* games. It is not: the counter
	///   increments once per launch, so playing one game seven times counts seven.
	///
	/// "game launches" is what it actually counts, and cannot be read either way.
	///
	/// It no longer claims clicks were *blocked*, because they are not: they are sent
	/// to the game instead of the menu bar. "Kept out of the menu bar" is the part
	/// that is true and is also the part the player cares about.
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

	// MARK: - The support ask

	/// Which of the two asks is due, if either.
	enum SupportAsk {
		/// Two days after install: a nudge, and it says another will follow.
		case early
		/// A week after install: the last one, and it says so.
		case final
	}

	/// Recorded on first launch and never overwritten, because the whole schedule
	/// hangs off it. Existing installs have no such date, so they get one now — which
	/// delays their remaining ask rather than firing it immediately, and erring toward
	/// asking late is the only safe direction here.
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

	/// Earlier versions asked once, after five sessions, and the alert promised it was
	/// the only time. Anyone carrying that flag has already had the early ask, so they
	/// get the final one and nothing else — otherwise that promise becomes a lie, and
	/// breaking it is a worse outcome than one fewer donation.
	static func migrateLegacySupportFlag() {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: asked2DayKey) == nil else { return }
		guard defaults.bool(forKey: askedKey) else { return }
		defaults.set(true, forKey: asked2DayKey)
		Log.write("SUPPORT legacy ask flag found — counting the early ask as already done")
	}

	/// Timed from installation rather than from a session count, so someone who plays
	/// heavily for one evening is not asked before the app has had a chance to be
	/// useful, and someone who plays weekly still gets asked.
	///
	/// Gated on `sessions >= 1` because the alert leads with what Deadeye actually
	/// did: asking someone who has never launched a game would show them an empty
	/// boast. Nagging is how goodwill — the only real currency a free tool has — gets
	/// spent, so there are exactly two asks, ever.
	static var dueSupportAsk: SupportAsk? {
		guard let days = daysSinceInstall else { return nil }
		return dueAsk(daysSinceInstall: days, sessions: sessions,
		              askedEarly: askedEarly, askedFinal: askedFinal)
	}

	/// The decision, as pure arithmetic, so the schedule can be tested without
	/// fabricating install dates in a real user's preferences. Getting this wrong is
	/// close to invisible in normal use — it either nags or never asks, and both take
	/// days to notice — which is exactly why it is worth testing directly.
	static func dueAsk(daysSinceInstall days: Int, sessions: Int,
	                   askedEarly: Bool, askedFinal: Bool) -> SupportAsk? {
		guard sessions >= 1 else { return nil }
		if days >= 7, !askedFinal { return .final }
		if days >= 2, !askedEarly { return .early }
		return nil
	}

	/// Marking the final ask also marks the early one. Someone who installs, does not
	/// play for nine days, and then finishes a session is due both at once — they get
	/// the final wording and are never shown the early one retroactively.
	static func markAsked(_ ask: SupportAsk) {
		switch ask {
		case .early: askedEarly = true
		case .final: askedEarly = true; askedFinal = true
		}
	}
}
