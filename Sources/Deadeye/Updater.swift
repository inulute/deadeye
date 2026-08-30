//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit

enum Updater {
	static let repo = "inulute/deadeye"

	private static let lastCheckKey = "updateLastCheck"
	private static let seenVersionKey = "updateSeenVersion"

	private static let interval: TimeInterval = 60 * 60 * 24

	static var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
	}

	private(set) static var availableVersion: String?

	static var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

	enum Result {
		case upToDate
		case available(String)
		case couldNotCheck(String)
	}

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
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

		URLSession.shared.dataTask(with: request) { data, response, error in
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

	static func shouldAnnounce(_ version: String) -> Bool {
		UserDefaults.standard.string(forKey: seenVersionKey) != version
	}

	static func markAnnounced(_ version: String) {
		UserDefaults.standard.set(version, forKey: seenVersionKey)
	}
}
