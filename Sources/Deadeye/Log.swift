//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  A log file, because the interesting behaviour happens while a fullscreen game
//  has the display and nobody can watch a console.
//

import Foundation

enum Log {
	static let url: URL = {
		let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Logs", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("Deadeye.log")
	}()

	private static let queue = DispatchQueue(label: "com.deadeye.Deadeye.log")

	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	/// Only state *changes* should be logged from polling code — a 4 Hz tick
	/// writing every sample would bury the transitions that matter.
	static func write(_ message: String) {

		let line = "\(formatter.string(from: Date()))  \(message)\n"
		queue.async {
			guard let data = line.data(using: .utf8) else { return }
			if let handle = try? FileHandle(forWritingTo: url) {
				handle.seekToEndOfFile()
				handle.write(data)
				try? handle.close()
			} else {
				try? data.write(to: url)
			}
		}
	}
}
