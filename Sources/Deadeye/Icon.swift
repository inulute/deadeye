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
/// * With the eye open the pupil keeps at least 0.6 units of clearance from every
///   lid, so the shapes never blob together when drawn small. As the lids close they
///   paint over the pupil, rather than the pupil growing out of the eye.
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

	/// Where the shapes converge mid-blink.
	///
	/// The two lids meet on `shutInner` and their outer edges stop short of it, so a
	/// shut eye is one solid lens about 0.76 units thick. Lerping a lid's outer edge
	/// onto its inner edge instead gave both paths zero area, and the glyph vanished
	/// for a frame at the midpoint of every blink.
	private static let shutOuterTop: CGFloat = 7.62
	private static let shutOuterBottom: CGFloat = 8.38
	private static let shutInner: CGFloat = 8

	private static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
		from + (to - from) * t
	}

	// MARK: - Shapes

	/// Lower lid — the same in both states.
	private static func lowerLid(closed t: CGFloat) -> NSBezierPath {
		let outer = lerp(15.4, shutOuterBottom, t)
		let inner = lerp(12.1, shutInner, t)
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
		let outer = lerp(0.6, shutOuterTop, t)
		let inner = lerp(3.9, shutInner, t)
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
		// The wedge's lower boundary and its two corners ride the meeting line; the
		// peak and its controls ride the outer line. Sending every point to a single
		// line, as this did, flattened the wedge to zero area at full close.
		func inner(_ v: CGFloat) -> CGFloat { lerp(v, shutInner, t) }
		func outer(_ v: CGFloat) -> CGFloat { lerp(v, shutOuterTop, t) }
		let path = NSBezierPath()
		path.move(to: CGPoint(x: 16.0357, y: inner(8.09445)))
		path.line(to: CGPoint(x: 3.64752, y: inner(5.98978)))
		path.line(to: CGPoint(x: 0.29390, y: inner(8.36741)))
		path.line(to: CGPoint(x: 2.86391, y: outer(4.13394)))
		path.curve(to: CGPoint(x: 3.51494, y: outer(3.82216)),
		           controlPoint1: CGPoint(x: 3.04360, y: outer(3.94164)),
		           controlPoint2: CGPoint(x: 3.22882, y: outer(3.83966)))
		path.line(to: CGPoint(x: 16.0357, y: inner(8.09445)))
		path.close()
		return path
	}

	/// The gap between the lids — the white of the eye.
	///
	/// The pupil is clipped to this. Without it the pupil kept its full radius while the
	/// lids closed over it, and from about `lidClose` 0.25 it reached past them: an
	/// eyeball outside the eye for a third of every blink. Painting the lids over the
	/// pupil instead is not enough, because the lids grow thin as they close and stop
	/// covering the parts of the pupil that stick out beyond them.
	private static func aperture(_ state: State, closed t: CGFloat) -> NSBezierPath {
		func inner(_ v: CGFloat) -> CGFloat { lerp(v, shutInner, t) }
		let lowerInner = inner(12.1)
		let path = NSBezierPath()

		switch state {
		case .idle:
			let upperInner = inner(3.9)
			path.move(to: leftCorner)
			path.curve(to: rightCorner,
			           controlPoint1: CGPoint(x: 4.2, y: upperInner),
			           controlPoint2: CGPoint(x: 11.8, y: upperInner))
			path.curve(to: leftCorner,
			           controlPoint1: CGPoint(x: 11.8, y: lowerInner),
			           controlPoint2: CGPoint(x: 4.2, y: lowerInner))

		case .active:
			// Bounded above by the hood's inner edge, which is exactly where the hood
			// covers the pupil in assets/deadeye-active.svg. Clipping there rather than
			// relying on paint order gives the same open-eye mark and also holds once
			// the hood is too thin to cover anything.
			let leftTip = CGPoint(x: 0.29390, y: inner(8.36741))
			path.move(to: leftTip)
			path.line(to: CGPoint(x: 3.64752, y: inner(5.98978)))
			path.line(to: CGPoint(x: 16.0357, y: inner(8.09445)))
			path.curve(to: leftTip,
			           controlPoint1: CGPoint(x: 11.8, y: lowerInner),
			           controlPoint2: CGPoint(x: 4.2, y: lowerInner))
		}

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

			// Clipped, so the pupil is bounded by the lids at every point of the blink.
			NSGraphicsContext.saveGraphicsState()
			defer { NSGraphicsContext.restoreGraphicsState() }
			let gap = aperture(state, closed: lidClose)
			gap.transform(using: transform)
			gap.addClip()

			let centre = CGPoint(x: 8 * scale, y: 8 * scale)
			switch state {
			case .active:
				let r = 2.375 * scale
				NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r,
				                            width: r * 2, height: r * 2)).fill()
			case .idle:
				// A ring has a hole, and clipping a full-size one into a narrow gap leaves
				// slivers of that hole showing as gaps in the slit. Sizing it to the gap
				// keeps it whole, and once the gap is thinner than the stroke the ring
				// closes into a solid dot on its own. At lidClose 0 this is still 1.8.
				let halfGap = 0.375 * (lerp(12.1, shutInner, lidClose)
				                       - lerp(3.9, shutInner, lidClose))
				let r = min(1.8, max(0, halfGap - 0.575)) * scale
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
