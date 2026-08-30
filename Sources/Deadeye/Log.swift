//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
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
