<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Notcher icon">
</p>

<h1 align="center">Notcher</h1>

<p align="center">
  A Dynamic Island for the Mac. Notcher turns the MacBook notch into a live, interactive surface
  for what's playing, system controls and device notifications.
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-black">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-required-black">
  <img alt="Version" src="https://img.shields.io/badge/version-1.0.2-blue">
</p>

<p align="center">
  <img src="docs/demo.gif" width="660" alt="Notcher demo: opening the player, skipping a track with a swipe, the volume HUD, the AirPods popup and a charging alert">
</p>

---

## About

The notch sits at the top of every modern MacBook display and does nothing. Notcher makes it useful.
It draws a black island over the notch that blends in when idle, shows what's playing, and opens
into a full panel when you need it. Every movement is a spring animation, so the island stretches,
settles and responds like a physical object.

Notcher runs quietly in the menu bar and works on any display: Macs without a notch get a compact
pill instead.

## Features

- **Now Playing:** album artwork beside the notch with a live waveform in the artwork's colours,
  plus a quick peek at the title whenever the track changes.
- **Media player:** open the island for artwork, a scrubbable progress bar, playback controls,
  shuffle and output-device volume.
- **Smooth track changes:** the title blurs across, the artwork flips, and the skip arrows animate.
- **Trackpad gestures:** swipe to open, close, dismiss or skip tracks, with rubber-band resistance
  and haptic feedback.
- **Volume HUD:** a cleaner replacement for the macOS volume overlay that shows your output device,
  with 3D renders for AirPods.
- **AirPods popup:** your AirPods or other Bluetooth audio device, with its battery, the moment it
  connects.
- **Battery alerts:** charging, low battery and Low Power Mode.
- **Works everywhere:** the built-in display, external displays, or all of them, and it hides over
  fullscreen apps.

## Requirements

- macOS 15 Sequoia or later
- A Mac with Apple silicon

## Installation

1. Download the latest **Notcher-&lt;version&gt;.dmg** from
   [Releases](https://github.com/RishivikramN/notcher/releases).
2. Open it and drag **Notcher** into **Applications**.
3. Launch Notcher from Applications. Its icon appears in the menu bar.

Notcher is signed and notarized by Apple, so it opens without security warnings.

### Permissions

Notcher asks for each permission the first time a feature needs it. You can skip any of them; only
that feature is affected.

| Permission | What it's for |
|---|---|
| **Accessibility** | Reading the volume keys, so the volume HUD can replace the system one |
| **Automation** (Music, Spotify) | Showing artwork and playback position, and controlling playback |
| **Bluetooth** | Detecting AirPods and other audio devices and reading their battery |

To change them later, open **System Settings → Privacy & Security** and choose the matching
section.

## Using Notcher

### The island

| Action | Result |
|---|---|
| Move the pointer onto the notch | The island opens |
| Move the pointer away | It closes |
| Click the notch | Opens or closes it, when *Expand on hover* is off |
| Click the artwork in the player | Brings the playing app to the front |
| Click the output-device button | Shows a volume slider for the current output |

### Gestures

Use two fingers on the trackpad while the pointer is over the island.

| Gesture | Result |
|---|---|
| Swipe down on the closed island | Open it |
| Swipe up on the open island | Close it |
| Swipe up on the now-playing activity | Dismiss it until something new plays |
| Swipe right / left | Next / previous track |

A light haptic tap tells you when a swipe has gone far enough to count.

### Media keys

With Accessibility allowed, the volume keys show Notcher's HUD instead of the system overlay.
Hold **Option + Shift** while pressing them for finer steps.

### The menu bar icon

- **Settings…** (⌘,) opens Settings.
- **About Notcher** shows the version.
- **Quit Notcher** (⌘Q) quits.

If you hide the menu bar icon, open Notcher again from Applications to get back to Settings.

## Settings

| Tab | Options |
|---|---|
| **General** | Expand on hover and hover delay, haptic feedback, each gesture, natural movement, hide in fullscreen, hide the menu bar icon, launch at login |
| **Display** | Which display shows the island, a simulated notch for displays without one, and fine-tuning the notch width and height |
| **Now Playing** | Media source (Automatic, System, Music, Spotify), quick peek and its duration, and how long a paused track stays visible |
| **Sound** | The volume HUD, showing the output device or a speaker symbol, 3D AirPods, and how long the HUD stays |
| **Battery** | Charging, low battery (with a threshold) and Low Power Mode notifications, and how long they stay |
| **Connectivity** | The connect popup, 3D AirPods, the low-battery threshold and how long the popup stays |

## Troubleshooting

**The volume keys still show the macOS overlay.** Allow Notcher under **System Settings → Privacy &
Security → Accessibility**. If it's already listed but not working, remove it with **−**, then open
Notcher again and allow it when asked.

**No artwork or controls for Music or Spotify.** Allow Notcher under **Privacy & Security →
Automation**.

**The AirPods popup never appears.** Allow Notcher under **Privacy & Security → Bluetooth**, and
check that **Show connected devices** is on in the Connectivity tab.

**A video playing in the browser shows dimmed controls.** macOS only lets apps control the system's
current player. When another player is paused, Notcher can show what's playing elsewhere, but can
only control Music and Spotify.

**Something stopped working after a macOS update.** Some features use parts of macOS that Apple
can change between versions. Check [Releases](https://github.com/RishivikramN/notcher/releases)
for an update.

## Privacy

Notcher runs entirely on your Mac. It collects no data and has no analytics, and the only thing it
downloads is Spotify album artwork.

## License

Copyright © 2026 Rishivikram Nandakumar. All rights reserved.
