//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  The Deadeye mark, drawn in code.
//

import AppKit

/// Draws the menu bar glyph as vector paths rather than shipping PNGs.
///
/// Two reasons. It stays sharp at any scale factor without needing @1x/@2x/@3x
/// assets, and as a template image macOS tints it automatically — black on a light
/// menu bar, white on a dark one — so no light/dark variants are needed either.
///
/// Geometry is on the same 16×16 grid as `assets/deadeye-*.svg`. The numbers are not
/// arbitrary:
///
/// * The mark spans 14.2 units wide of the 16-unit box. A first version filled only
///   80% × 54% and read as small and weak in the menu bar.
/// * Lids are ~2.5 units thick. A rejected candidate had 0.3-unit lids that
///   disappeared into a grey smudge at menu bar size.
/// * The pupil keeps at least 0.6 units of clearance from every lid, so the shapes
///   never blob together when drawn small.
enum Icon {
	/// Idle is a calm, symmetric open eye with a ring pupil. Active swaps the smooth
	/// upper lid for an angular hooded wedge — the "hunter eye" — and fills the pupil.
	/// The lower lid is identical in both, which is what keeps them the same mark.
	enum State {
		case idle
		case active
	}

	// Both lids meet at these two corners. An early draft let the paths overshoot
	// past each other, leaving a spike that read as a rendering glitch when small.
	private static let leftCorner = CGPoint(x: 0.9, y: 8)
	private static let rightCorner = CGPoint(x: 15.1, y: 8)

	/// Where the shapes converge mid-blink. Deliberately not y=8: collapsing fully
	/// makes both paths degenerate and the glyph vanishes entirely.
	private static let slitTop: CGFloat = 7.62
	private static let slitBottom: CGFloat = 8.38

	private static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
		from + (to - from) * t
	}

	// MARK: - Shapes

	/// Lower lid — the same in both states.
	private static func lowerLid(closed t: CGFloat) -> NSBezierPath {
		let outer = lerp(15.4, slitBottom, t)
		let inner = lerp(12.1, slitBottom, t)
		let path = NSBezierPath()
		path.move(to: leftCorner)
		path.curve(to: rightCorner,
		           controlPoint1: CGPoint(x: 4.2, y: outer),
		           controlPoint2: CGPoint(x: 11.8, y: outer))
		path.curve(to: leftCorner,
		           controlPoint1: CGPoint(x: 11.8, y: inner),
		           controlPoint2: CGPoint(x: 4.2, y: inner))
		path.close()
		return path
	}

	/// Idle upper lid — smooth mirror of the lower one.
	private static func idleUpperLid(closed t: CGFloat) -> NSBezierPath {
		let outer = lerp(0.6, slitTop, t)
		let inner = lerp(3.9, slitTop, t)
		let path = NSBezierPath()
		path.move(to: leftCorner)
		path.curve(to: rightCorner,
		           controlPoint1: CGPoint(x: 4.2, y: outer),
		           controlPoint2: CGPoint(x: 11.8, y: outer))
		path.curve(to: leftCorner,
		           controlPoint1: CGPoint(x: 11.8, y: inner),
		           controlPoint2: CGPoint(x: 4.2, y: inner))
		path.close()
		return path
	}

	/// Active upper lid — the angular hooded wedge.
	///
	/// A sharp peak near the left with a long shallow sweep to the right. It reads as
	/// a hooded, intent eye, and unlike a separate brow shape it is one connected
	/// form, so nothing has to survive a hairline gap at 18pt.
	///
	/// It intentionally overshoots the 16-unit box at both ends, which keeps the
	/// corners crisp rather than clipping them to a blunt edge.
	private static func activeUpperLid(closed t: CGFloat) -> NSBezierPath {
		func y(_ v: CGFloat) -> CGFloat { lerp(v, slitTop, t) }
		let path = NSBezierPath()
		path.move(to: CGPoint(x: 16.0357, y: y(8.09445)))
		path.line(to: CGPoint(x: 3.64752, y: y(5.98978)))
		path.line(to: CGPoint(x: 0.29390, y: y(8.36741)))
		path.line(to: CGPoint(x: 2.86391, y: y(4.13394)))
		path.curve(to: CGPoint(x: 3.51494, y: y(3.82216)),
		           controlPoint1: CGPoint(x: 3.04360, y: y(3.94164)),
		           controlPoint2: CGPoint(x: 3.22882, y: y(3.83966)))
		path.line(to: CGPoint(x: 16.0357, y: y(8.09445)))
		path.close()
		return path
	}

	// MARK: - Composing

	/// - Parameters:
	///   - state: which of the two marks to draw.
	///   - lidClose: 0 fully open, 1 a near-closed slit. Drives the blink.
	static func menuBar(_ state: State, pointSize: CGFloat = 18, lidClose: CGFloat = 0) -> NSImage {
		let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
		                    flipped: true) { _ in
			// `flipped: true` gives a top-left origin, matching the SVG grid, so the
			// coordinates here are the same numbers as in the asset files.
			let scale = pointSize / 16
			let transform = AffineTransform(scale: scale)
			NSColor.black.setFill()

			for shape in [state == .active ? activeUpperLid(closed: lidClose)
			                              : idleUpperLid(closed: lidClose),
			              lowerLid(closed: lidClose)] {
				shape.transform(using: transform)
				shape.fill()
			}

			// Past roughly halfway the lids have met, and a pupil showing through a
			// closed eye looks like a rendering fault.
			guard lidClose < 0.45 else { return true }

			let centre = CGPoint(x: 8 * scale, y: 8 * scale)
			switch state {
			case .active:
				let r = 2.375 * scale
				NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
				                            width: r * 2, height: r * 2)).fill()
			case .idle:
				let r = 1.8 * scale
				let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
				                                      width: r * 2, height: r * 2))
				ring.lineWidth = 1.15 * scale
				NSColor.black.setStroke()
				ring.stroke()
			}
			return true
		}

		// Template means macOS supplies the colour; without this the glyph would stay
		// black and disappear on a dark menu bar.
		image.isTemplate = true
		return image
	}
}
