//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Checking GitHub for a newer release.
//

import AppKit

/// Checks the repository's latest release and reports when a newer version exists.
///
/// It *notifies*, it never installs. Self-updating a binary safely needs a signed,
/// notarised app and something like Sparkle; a locally signed build replacing its
/// own bundle is a good way to break the code signature and, with it, the
/// Accessibility grant. Opening the release page is the honest limit of what this
/// can do well.
enum Updater {
	static let repo = "inulute/deadeye"

	private static let lastCheckKey = "updateLastCheck"
	private static let seenVersionKey = "updateSeenVersion"

	/// Once a day is plenty for a utility like this, and it keeps the app from
	/// hammering the API for people who leave it running for weeks.
	private static let interval: TimeInterval = 60 * 60 * 24

	static var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
	}

	/// The newest version seen on GitHub, if it is newer than what is installed.
	private(set) static var availableVersion: String?

	static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

	// MARK: - Checking

	enum Result {
		case upToDate
		case available(String)
		/// Offline, rate-limited, or no published release yet.
		case couldNotCheck(String)
	}

	/// - Parameter force: bypass the once-a-day limit, for the manual menu item.
	static func check(force: Bool = false, completion: @escaping (Result) -> Void) {
		let last = UserDefaults.standard.double(forKey: lastCheckKey)
		let due = force || Date().timeIntervalSince1970 - last > interval
		guard due else {
			completion(availableVersion.map { Result.available($0) } ?? .upToDate)
			return
		}

		UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

		guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
			completion(.couldNotCheck("Bad URL")); return
		}
		var request = URLRequest(url: api)
		request.timeoutInterval = 12
		// GitHub asks for an explicit Accept for the REST API.
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

		URLSession.shared.dataTask(with: request) { data, response, error in
			// Every failure path gets logged. An earlier version logged only transport
			// errors, so a 404 — the repo or its first release not existing yet — was
			// completely silent and looked identical to the check never running.
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			guard error == nil, let data,
			      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			      let tag = json["tag_name"] as? String
			else {
				let why: String
				if let error { why = error.localizedDescription }
				else if status == 404 { why = "no published release yet (HTTP 404)" }
				else if status == 403 { why = "rate limited by GitHub (HTTP 403)" }
				else { why = "unexpected response (HTTP \(status))" }
				Log.write("UPDATE could not check: \(why)")
				DispatchQueue.main.async { completion(.couldNotCheck(why)) }
				return
			}

			let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
			let newer = compare(latest, currentVersion) > 0
			availableVersion = newer ? latest : nil
			Log.write("UPDATE latest=\(latest) current=\(currentVersion) newer=\(newer)")

			DispatchQueue.main.async {
				completion(newer ? .available(latest) : .upToDate)
			}
		}.resume()
	}

	/// Compares dotted numeric versions. Returns >0 when `a` is newer than `b`.
	///
	/// Deliberately numeric per component rather than a string compare, because "10"
	/// sorts before "9" as text and would hide every release after 1.9.
	static func compare(_ a: String, _ b: String) -> Int {
		let x = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
		let y = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
		for i in 0 ..< max(x.count, y.count) {
			let l = i < x.count ? x[i] : 0
			let r = i < y.count ? y[i] : 0
			if l != r { return l > r ? 1 : -1 }
		}
		return 0
	}

	// MARK: - Telling the user, once

	/// True when this exact version has not been announced yet, so a user who
	/// declines is not asked again until there is something genuinely new.
	static func shouldAnnounce(_ version: String) -> Bool {
		UserDefaults.standard.string(forKey: seenVersionKey) != version
	}

	static func markAnnounced(_ version: String) {
		UserDefaults.standard.set(version, forKey: seenVersionKey)
	}
}
