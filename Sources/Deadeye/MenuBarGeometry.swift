//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import CoreGraphics

enum MenuBarGeometry {
	static func strips(screenFrames: [CGRect],
	                   primaryMaxY: CGFloat,
	                   menuBars: [CGRect],
	                   fallbackHeight: CGFloat) -> [CGRect] {
		screenFrames.map { frame in
			let top = CGRect(x: frame.minX,
			                 y: primaryMaxY - frame.maxY,
			                 width: frame.width,
			                 height: fallbackHeight)

			let match = menuBars.first {
				abs($0.minY - top.minY) < 2 && $0.width >= top.width * 0.9
			}
			guard let match else { return top }

			return CGRect(x: top.minX, y: top.minY,
			              width: top.width, height: max(match.height, 24))
		}
	}
}
