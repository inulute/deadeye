//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Where the menu bar actually is, as pure geometry.
//

import CoreGraphics

/// Works out the strip of each screen that belongs to the menu bar, in
/// CoreGraphics global coordinates (origin top-left).
///
/// Split out from `MenuBarShield` with no AppKit or system-state dependency so the
/// arithmetic can be tested against real multi-display layouts. Getting it wrong is
/// invisible in normal use — the strip is simply the wrong height and clicks leak
/// through the rows it misses — so it is worth testing directly.
enum MenuBarGeometry {
	/// - Parameters:
	///   - screenFrames: `NSScreen.frame` values, bottom-left origin.
	///   - primaryMaxY: the primary screen's `frame.maxY`, used to flip y.
	///   - menuBars: candidate menu bar window bounds, already top-left origin.
	///   - fallbackHeight: used for any screen with no matching menu bar window.
	static func strips(screenFrames: [CGRect],
	                   primaryMaxY: CGFloat,
	                   menuBars: [CGRect],
	                   fallbackHeight: CGFloat) -> [CGRect] {
		screenFrames.map { frame in
			// Only y needs converting: CGEvent locations count downwards from the top
			// of the primary screen, NSScreen frames upwards from its bottom.
			let top = CGRect(x: frame.minX,
			                 y: primaryMaxY - frame.maxY,
			                 width: frame.width,
			                 height: fallbackHeight)

			// Each display carries its own menu bar and they are not the same height
			// (30pt on a built-in and 33pt on an external display, measured), so the
			// match is per screen rather than one height applied to all of them.
			let match = menuBars.first {
				abs($0.minY - top.minY) < 2 && $0.width >= top.width * 0.9
			}
			guard let match else { return top }

			// Never shrink below a sane minimum: a menu bar window reported as a
			// sliver would leave the bar effectively unguarded.
			return CGRect(x: top.minX, y: top.minY,
			              width: top.width, height: max(match.height, 24))
		}
	}
}
