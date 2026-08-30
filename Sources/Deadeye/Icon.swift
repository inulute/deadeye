//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//

import AppKit

enum Icon {
	enum State {
		case idle
		case active
	}

	private static let leftCorner = CGPoint(x: 0.9, y: 8)
	private static let rightCorner = CGPoint(x: 15.1, y: 8)

	private static let shutOuterTop: CGFloat = 7.62
	private static let shutOuterBottom: CGFloat = 8.38
	private static let shutInner: CGFloat = 8

	private static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
		from + (to - from) * t
	}

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

	private static func activeUpperLid(closed t: CGFloat) -> NSBezierPath {
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

	static func menuBar(_ state: State, pointSize: CGFloat = 18, lidClose: CGFloat = 0) -> NSImage {
		let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
		                    flipped: true) { _ in
			let scale = pointSize / 16
			let transform = AffineTransform(scale: scale)
			NSColor.black.setFill()

			for shape in [state == .active ? activeUpperLid(closed: lidClose)
			                              : idleUpperLid(closed: lidClose),
			              lowerLid(closed: lidClose)] {
				shape.transform(using: transform)
				shape.fill()
			}

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

		image.isTemplate = true
		return image
	}
}
