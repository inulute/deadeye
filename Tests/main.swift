//
//  Deadeye. Copyright (C) 2026 inulute.
//  Licensed under the GNU General Public License v3.0. See LICENSE.
//
//  Tests for the Wine game-detection heuristic.
//
//  The "expected nil" cases marked (observed) are real argv[0] values captured
//  from a live CrossOver bottle, not invented ones.
//
//  Run with: ./run-tests.sh
//

import AppKit
import Darwin

var failures = 0

func expect(_ argv0: String, _ expected: String?, _ note: String = "") {
	let actual = Wine.gameName(fromArgv0: argv0)
	let ok = actual == expected
	if !ok { failures += 1 }
	let mark = ok ? "ok  " : "FAIL"
	let shown = actual.map { "\"\($0)\"" } ?? "nil"
	let want = expected.map { "\"\($0)\"" } ?? "nil"
	print("\(mark) \(argv0)")
	print("       got \(shown), want \(want)\(note.isEmpty ? "" : "   \(note)")")
}

print("=== Wine helpers must never trigger game mode ===")
expect("C:\\windows\\system32\\wineboot.exe", nil, "(observed)")
expect("C:\\windows\\system32\\services.exe", nil, "(observed)")
expect("C:\\windows\\system32\\winedevice.exe", nil, "(observed)")
expect("C:\\windows\\system32\\plugplay.exe", nil, "(observed)")
expect("C:\\windows\\system32\\rpcss.exe", nil)
expect("C:\\windows\\explorer.exe", nil)
expect("C:\\windows\\syswow64\\winemenubuilder.exe", nil)
expect("C:\\WINDOWS\\SYSTEM32\\SERVICES.EXE", nil, "(uppercase)")

print("\n=== Non-Wine processes must never trigger game mode ===")
expect("/var/folders/3v/T/winetemp-7844620/wineloader", nil, "(observed)")
expect("/Applications/CrossOver.app/Contents/MacOS/CrossOver", nil, "(observed)")
expect("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver", nil, "(observed)")
expect("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-windows/winewrapper.exe",
       nil, "(observed - Unix path ending in .exe)")
expect("/usr/bin/ssh", nil)
expect("", nil, "(empty)")
expect("C:", nil, "(truncated)")
expect("C:\\", nil, "(bare drive)")

print("\n=== bare argv[0]: CrossOver launches the game unqualified ===")
// This is how RDR2 actually appears. An earlier version of this heuristic
// required a drive letter and therefore detected no games at all.
expect("RDR2.exe", "RDR2.exe", "(observed - real RDR2 argv[0])")
expect("deadlock.exe", "deadlock.exe")
expect("Cyberpunk2077.exe", "Cyberpunk2077.exe")
expect("services.exe", nil, "(bare, but a Wine service)")
expect("explorer.exe", nil, "(bare, but a Wine service)")
expect("winedevice.exe", nil, "(bare, but a Wine service)")
expect("steam.exe", nil, "(bare, but a launcher)")

print("\n=== Launchers must not hold the Dock hostage ===")
expect("C:\\Program Files (x86)\\Steam\\steam.exe", nil)
expect("C:\\Program Files (x86)\\Steam\\steamwebhelper.exe", nil)
expect("C:\\Program Files\\Rockstar Games\\Launcher\\Launcher.exe", nil)
expect("C:\\Program Files\\Rockstar Games\\Launcher\\RockstarService.exe", nil)

print("\n=== Real games must trigger game mode ===")
expect("C:\\Program Files\\Rockstar Games\\Red Dead Redemption 2\\RDR2.exe", "RDR2.exe")
expect("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Deadlock\\deadlock.exe", "deadlock.exe")
expect("Z:\\Users\\player\\Games\\skyrim\\SkyrimSE.exe", "SkyrimSE.exe", "(Z: drive)")
expect("D:\\witcher3\\bin\\x64\\witcher3.exe", "witcher3.exe")
expect("C:\\Program Files\\Some Game\\game.exe", "game.exe")

print("\n=== argv[0] read-back against this very process ===")
// Proves the KERN_PROCARGS2 parsing works on a process whose argv[0] we know.
let selfArgv0 = Wine.firstArgument(of: getpid())
let selfOK = selfArgv0 != nil && selfArgv0!.contains("wine-detection-test")
if !selfOK { failures += 1 }
print("\(selfOK ? "ok  " : "FAIL") self argv[0] = \(selfArgv0 ?? "nil")")

// MARK: - Cursor confinement geometry
//
// Real layout observed on this machine: the external 1920x1080 is primary at the
// origin, and the built-in sits DIRECTLY BELOW it spanning y -956...0. With
// "Displays have separate Spaces" on (the macOS default) the built-in carries its
// own menu bar, whose strip is immediately below the external's bottom edge — so
// moving the cursor down off the game screen lands it in a menu bar. Guarding only
// the top edge left that wide open.

print("\n=== non-game applications in a bottle must NOT trigger game mode ===")
// A bottle is not games-only: this one was made for WinSCP and had RDR2 added later.
expect("C:\\Program Files (x86)\\WinSCP\\WinSCP.exe", nil, "(the bottle's own app!)")
expect("WinSCP.exe", nil, "(bare form)")
expect("C:\\Program Files\\PuTTY\\putty.exe", nil)
expect("C:\\Program Files\\Notepad++\\notepad++.exe", nil)
expect("C:\\Program Files\\7-Zip\\7zFM.exe", nil)
// ...while real games still are games.
expect("RDR2.exe", "RDR2.exe", "(still detected)")

print("\n=== cursor confinement geometry (game on external 1920x1080) ===")

let gameScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let builtIn = CGRect(x: 255, y: -956, width: 1470, height: 956)
let strip: CGFloat = 26
let inset: CGFloat = 1

func expectClamp(_ point: CGPoint, _ expected: CGPoint, _ note: String) {
	let got = CursorGuard.clamped(point, to: gameScreen, topStrip: strip, edgeInset: inset)
	let ok = abs(got.x - expected.x) < 0.01 && abs(got.y - expected.y) < 0.01
	if !ok { failures += 1 }
	print("\(ok ? "ok  " : "FAIL") NS(\(Int(point.x)), \(Int(point.y))) -> NS(\(Int(got.x)), \(Int(got.y)))"
		+ "  want NS(\(Int(expected.x)), \(Int(expected.y)))   \(note)")
}

// The menu bar of the game's own screen.
expectClamp(CGPoint(x: 960, y: 1080), CGPoint(x: 960, y: 1054), "top edge -> below menu bar")
expectClamp(CGPoint(x: 960, y: 1060), CGPoint(x: 960, y: 1054), "inside menu bar strip")
expectClamp(CGPoint(x: 960, y: 1054), CGPoint(x: 960, y: 1054), "exactly at ceiling, unchanged")

// The bug this test exists for: downward escape onto the built-in's menu bar.
expectClamp(CGPoint(x: 960, y: 0), CGPoint(x: 960, y: 1), "bottom edge of game screen")
expectClamp(CGPoint(x: 960, y: -20), CGPoint(x: 960, y: 1), "built-in's MENU BAR -> pulled back")
expectClamp(CGPoint(x: 960, y: -400), CGPoint(x: 960, y: 1), "deep on built-in -> pulled back")
expectClamp(CGPoint(x: 300, y: -900), CGPoint(x: 300, y: 1), "far corner of built-in")

// Sideways.
expectClamp(CGPoint(x: -50, y: 500), CGPoint(x: 1, y: 500), "left of game screen")
expectClamp(CGPoint(x: 1920, y: 500), CGPoint(x: 1919, y: 500), "right edge")
expectClamp(CGPoint(x: 5000, y: 500), CGPoint(x: 1919, y: 500), "far right")

// Untouched interior — the common case during aiming, where no warp must occur.
expectClamp(CGPoint(x: 960, y: 540), CGPoint(x: 960, y: 540), "centre, untouched")
expectClamp(CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1), "bottom-left corner, untouched")
expectClamp(CGPoint(x: 1919, y: 1053), CGPoint(x: 1919, y: 1053), "just inside top-right")

print("\n=== same geometry with the game on the BUILT-IN instead ===")
func expectClampBuiltIn(_ point: CGPoint, _ expected: CGPoint, _ note: String) {
	let got = CursorGuard.clamped(point, to: builtIn, topStrip: strip, edgeInset: inset)
	let ok = abs(got.x - expected.x) < 0.01 && abs(got.y - expected.y) < 0.01
	if !ok { failures += 1 }
	print("\(ok ? "ok  " : "FAIL") NS(\(Int(point.x)), \(Int(point.y))) -> NS(\(Int(got.x)), \(Int(got.y)))"
		+ "  want NS(\(Int(expected.x)), \(Int(expected.y)))   \(note)")
}
// builtIn spans x 255...1725, y -956...0; ceiling = 0 - 26 = -26
expectClampBuiltIn(CGPoint(x: 900, y: 500), CGPoint(x: 900, y: -26), "up onto the EXTERNAL -> pulled back")
expectClampBuiltIn(CGPoint(x: 900, y: -10), CGPoint(x: 900, y: -26), "built-in's own menu bar strip")
expectClampBuiltIn(CGPoint(x: 100, y: -500), CGPoint(x: 256, y: -500), "left of built-in")
expectClampBuiltIn(CGPoint(x: 900, y: -500), CGPoint(x: 900, y: -500), "interior, untouched")

// The strip used to be built from NSStatusBar.system.thickness + 4 = 28pt, but the
// real menu bar windows on this layout measure 30pt and 33pt. Anything clicking the
// bottom rows of the bar went straight past the shield.
print("\n=== menu bar strip geometry (built-in 1470x956 above external 1920x1080) ===")
let externalFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let builtInFrame = CGRect(x: 255, y: -956, width: 1470, height: 956)
// As reported by CGWindowListCopyWindowInfo on this machine, top-left origin.
let realMenuBars = [CGRect(x: 255, y: 1080, width: 1470, height: 33),
                    CGRect(x: 0, y: 0, width: 1920, height: 30)]

func expectStrip(_ got: CGRect, _ expected: CGRect, _ note: String) {
	let ok = abs(got.minX - expected.minX) < 0.01 && abs(got.minY - expected.minY) < 0.01
		&& abs(got.width - expected.width) < 0.01 && abs(got.height - expected.height) < 0.01
	if !ok { failures += 1 }
	print("\(ok ? "ok  " : "FAIL") \(NSStringFromRect(got))  want \(NSStringFromRect(expected))   \(note)")
}

var got = MenuBarGeometry.strips(screenFrames: [externalFrame, builtInFrame],
                                 primaryMaxY: 1080, menuBars: realMenuBars, fallbackHeight: 34)
expectStrip(got[0], CGRect(x: 0, y: 0, width: 1920, height: 30), "external takes its own 30pt bar")
expectStrip(got[1], CGRect(x: 255, y: 1080, width: 1470, height: 33), "built-in takes its own 33pt bar")

// A screen whose menu bar window cannot be read must still be guarded.
got = MenuBarGeometry.strips(screenFrames: [externalFrame, builtInFrame],
                             primaryMaxY: 1080, menuBars: [], fallbackHeight: 34)
expectStrip(got[0], CGRect(x: 0, y: 0, width: 1920, height: 34), "no window info -> fallback height")
expectStrip(got[1], CGRect(x: 255, y: 1080, width: 1470, height: 34), "no window info -> fallback height")

// A status item's own window is at the top of a screen but only tens of points wide;
// mistaking one for the menu bar would collapse the strip to that item's height.
got = MenuBarGeometry.strips(screenFrames: [externalFrame], primaryMaxY: 1080,
                             menuBars: [CGRect(x: 1763, y: 0, width: 157, height: 30)],
                             fallbackHeight: 34)
expectStrip(got[0], CGRect(x: 0, y: 0, width: 1920, height: 34), "narrow window ignored, not mistaken for the bar")

// A bar reported as a sliver must not leave the menu bar effectively unguarded.
got = MenuBarGeometry.strips(screenFrames: [externalFrame], primaryMaxY: 1080,
                             menuBars: [CGRect(x: 0, y: 0, width: 1920, height: 3)],
                             fallbackHeight: 34)
expectStrip(got[0], CGRect(x: 0, y: 0, width: 1920, height: 24), "sliver clamped up to the 24pt floor")

print("\n=== live scan (should be empty unless a game is running) ===")
print("runningGames() -> \(Wine.runningGames())")


// MARK: - The support ask schedule

print("")
print("=== support ask: two asks, timed from installation, never a third ===")

func expectAsk(_ days: Int, _ sessions: Int, early: Bool, final: Bool,
               _ expected: Stats.SupportAsk?, _ note: String) {
	let actual = Stats.dueAsk(daysSinceInstall: days, sessions: sessions,
	                          askedEarly: early, askedFinal: final)
	let ok = actual == expected
	if !ok { failures += 1 }
	let d = { (a: Stats.SupportAsk?) in a.map { "\($0)" } ?? "none" }
	print("\(ok ? "ok  " : "FAIL") day \(days), \(sessions) sessions, asked(early:\(early) final:\(final))"
		+ " -> \(d(actual))   want \(d(expected))   \(note)")
}

// Nothing before the app has been used, however long it has been installed.
expectAsk(0,  0, early: false, final: false, nil, "fresh install, never played")
expectAsk(30, 0, early: false, final: false, nil, "installed a month, never played — still silent")

// The early ask lands on day 2, not before.
expectAsk(0, 3, early: false, final: false, nil,     "day 0 — too soon")
expectAsk(1, 3, early: false, final: false, nil,     "day 1 — still too soon")
expectAsk(2, 1, early: false, final: false, .early,  "day 2 — the early ask")
expectAsk(4, 9, early: false, final: false, .early,  "day 4, not yet asked")

// Between the two, having had the early one, it stays quiet.
expectAsk(2, 5, early: true,  final: false, nil, "early already done")
expectAsk(6, 5, early: true,  final: false, nil, "day 6 — final not due yet")

// The final ask lands on day 7.
expectAsk(7,  5, early: true, final: false, .final, "day 7 — the final ask")
expectAsk(40, 5, early: true, final: false, .final, "late but still owed the final ask")

// Both due at once: the final wording wins, and the early one is never shown after.
expectAsk(9, 1, early: false, final: false, .final, "installed 9 days, first session — final only")

// Never a third time.
expectAsk(8,   50, early: true, final: true, nil, "both done")
expectAsk(400, 99, early: true, final: true, nil, "a year on — still never asks again")

print("\n\(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")")
exit(failures == 0 ? 0 : 1)
