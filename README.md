<div align="center">

<img src="assets/deadeye-lockup.svg" width="520" alt="Deadeye. Keeps macOS out of your game.">

### No second cursor. No lost clicks. No Dock sliding over your game.

**A game mode for Windows games on Mac that keeps macOS out of the way.**

<br>

[![Download](https://img.shields.io/github/v/release/inulute/deadeye?style=for-the-badge&label=Download&labelColor=2a2825&color=828282&logo=apple&logoColor=white)](https://github.com/inulute/deadeye/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-13%2B-828282?style=for-the-badge&labelColor=2a2825&logo=apple&logoColor=white)](#requirements)
[![License](https://img.shields.io/github/license/inulute/deadeye?style=for-the-badge&labelColor=2a2825&color=828282)](LICENSE)
[![Stars](https://img.shields.io/github/stars/inulute/deadeye?style=for-the-badge&label=Stars&labelColor=2a2825&color=828282&logo=github&logoColor=white)](https://github.com/inulute/deadeye/stargazers)
[![Support](https://img.shields.io/badge/Support-Buy%20me%20a%20coffee-C67C4E?style=for-the-badge&logo=buymeacoffee&logoColor=white&labelColor=2a2825)](https://support.inulute.com)

</div>

<br>

<p align="center">
  <a href="#-the-story">Story</a> ·
  <a href="#-install">Install</a> ·
  <a href="#-the-accessibility-permission">Permission</a> ·
  <a href="#-compatibility">Compatibility</a> ·
  <a href="#-settings">Settings</a> ·
  <a href="#-build-it-yourself">Build</a> ·
  <a href="#-requirements">Requirements</a> ·
  <a href="#-support">Support</a>
</p>

<br>

## 📖 The story

I used to play **Red Dead Redemption 2** on my Mac through CrossOver and honestly the game itself ran surprisingly well.

What didn't run well was macOS.

I lost count of how many times I'd be mid-mission, lining up a shot, only for the Mac cursor to pop up right over the game's cursor. A few missions were basically ruined because of it. 😅

I tried the usual fixes like cursor-hiding apps, keyboard macros, Wine settings, manual toggles but none of them stuck. I just wanted to **launch the game and play in peace**.

> **So I built Deadeye.**
>
> It watches for your Windows game and clears these interruptions out of your way.

Install it, grant Accessibility once, and forget it exists. When a supported Windows game launches, Deadeye activates automatically. Quit the game, and everything goes back exactly how it was.

- ✅ No per-game configuration needed
- ✅ Doesn't touch your FPS, resolution, graphics or input mapping
- ✅ Activates and deactivates on its own

<br>

## 📥 Install

1. Grab the latest **[release](https://github.com/inulute/deadeye/releases/latest)**.
2. Open the disk image and drag **Deadeye** into **Applications**.
3. Launch it. If macOS says the app isn't notarized, go to **System Settings → Privacy & Security → Open Anyway**.
4. Grant **Accessibility** when asked.

A small eye icon appears in your menu bar. That's it. 🎉

<details>
<summary><strong>macOS says the app is "damaged"?</strong></summary>
<br>

Some Macs show a damaged-app warning instead of offering **Open Anyway**.

If you downloaded Deadeye from the official GitHub release, clear the download quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Deadeye.app
```

Then open it again — or [build it yourself](#-build-it-yourself).

</details>

<br>

## 🔐 The Accessibility permission

It's the **only** permission Deadeye asks for.

It needs Accessibility so it can intercept mouse input before the menu bar grabs it — that's what lets clicks near the top of the screen reach your game instead.

> [!NOTE]
> Nothing about your mouse, your game, or you gets sent anywhere.

<br>

## 🎮 Compatibility

Deadeye is built and tested primarily against **CrossOver**.

Because it watches for Wine processes rather than a specific launcher, it should also work with Whisky, Wine, Porting Kit, Game Porting Toolkit (GPTK), etc.

Haven't been exhaustively tested yet. If you try one, **[open an issue](https://github.com/inulute/deadeye/issues/new)** and tell me which runner and game you used.

<br>

## ⚙️ Settings

Everything is on by default. The menu bar icon is mostly a status light, not a control panel you need to babysit.

You can turn off individual features if you want:

- Menu-bar click interception
- Dock edge tracking
- Hot Corners
- Shake-to-find cursor
- Overlay handling

**Activate automatically** is enabled by default. You can also enable **Launch at login** if you want Deadeye running whenever you start your Mac.

**Keyboard shortcut:** <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>G</kbd> toggles Deadeye from anywhere.

> If you turn it off during a game, it stays off for that session and resumes automatically the next time a game starts.

<br>

## 🛠 Build it yourself

No Xcode needed — just Apple's Command Line Tools.

```sh
git clone https://github.com/inulute/deadeye
cd deadeye
./create-signing-identity.sh   # once
./build.sh --install
```

The local signing identity keeps Accessibility permission stable across rebuilds.

Run the tests with:

```sh
./run-tests.sh
```

<br>

## 📋 Requirements

- macOS 13 Ventura or later
- Apple Silicon or Intel
- A Wine-based Windows game runner
- Accessibility permission

<br>

## 💛 Support

Deadeye is **free and open source under GPL-3.0**.

If it's useful to you:

- ⭐ **[Star the repository](https://github.com/inulute/deadeye)**
- 🐛 **[Report a bug](https://github.com/inulute/deadeye/issues)**
- 📣 Tell another Mac gamer who's tired of the Dock ambushing them
- ☕ **[Buy me a coffee](https://support.inulute.com)**

The first $99 goes toward an Apple Developer account so future releases can be notarized and skip the scary warning entirely.

<br>

<div align="center">

---

© 2026 inulute · Licensed under **[GPL-3.0](LICENSE)**

</div>
