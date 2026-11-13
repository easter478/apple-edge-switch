# Edge Switch (working name)

## What it is

A macOS app switcher for a user coming from Windows who finds Stage Manager and the Dock in the way. Every app fills the screen with no extra click. Moving the cursor to the left screen edge slides out a list of open apps; a click jumps to one, a right-click puts two apps side by side 50/50. The Dock and menu bar stay hidden.

Status on 2026-11-12: **built and installed.** The app is `~/Applications/Edge Switch.app` (bundle id `local.easter.edgeswitch`, version 1.2.0). It has no Dock icon and no menu bar icon; its settings open from the gear at the bottom of the list, or by opening the app again while it runs.

Target machine: Mac mini (Apple silicon), macOS 27.2, one 2560 x 1440 display at 144 Hz.

## Technologies

- Swift 6.4.2 compiled in Swift 5 language mode, AppKit only. No SwiftUI: the Command Line Tools on this Mac do not ship the SwiftUI macro plugin, so `@State` does not compile without full Xcode.
- macOS Accessibility API (`AXUIElement`, `AXObserver`) to move, resize and raise other apps' windows.
- `NSVisualEffectView` for the frosting, with a theme tint, rim and sheen on top.
- `ServiceManagement` (`SMAppService.mainApp`) for Start at login.
- No third-party dependencies, no network use, nothing hosted.
- Built with `swiftc` and a shell script; signed ad hoc. No Xcode project.
- Mockup: one self-contained HTML file, `mockups/edge-switch.html`.

## How to run, test and deploy

Build, install to `~/Applications` and start:

```bash
/Users/easter/Claude/apple-edge-switch/build.sh
```

Build and install without starting it:

```bash
/Users/easter/Claude/apple-edge-switch/build.sh --no-run
```

Gotcha: the app is signed ad hoc, so **every rebuild is a new app to macOS and Accessibility has to be switched on again** (System Settings > Privacy & Security > Accessibility; remove the old Edge Switch entry if the switch does nothing).

Checks from Terminal (the binary run this way borrows the terminal's own Accessibility permission):

```bash
"$HOME/Applications/Edge Switch.app/Contents/MacOS/EdgeSwitch" --cli status
```

Other `--cli` commands: `fill <app>`, `split <left app> <right app>`, `tweaks`, `warp <x> <y>`, `click <x> <y>`, `rightclick <x> <y>`, `own`.

Render the list or the settings sheet to a picture without touching the screen (theme, appearance, list style and accent are optional):

```bash
"$HOME/Applications/Edge Switch.app/Contents/MacOS/EdgeSwitch" --snapshot panel /tmp/panel.png tahoe dark names
```

Snapshot kinds: `panel`, `panel-pick`, `panel-locked`, `settings`.

Open the mockup in Chrome:

```bash
open -a "Google Chrome" /Users/easter/Claude/apple-edge-switch/mockups/edge-switch.html
```

## How it works

Files in `Sources/`:

- `main.swift`: entry point and `AppDelegate`. Starts as an accessory app (no Dock icon), quits any older copy, applies the system settings, shows Settings on the first run.
- `Prefs.swift`: settings in the app's own preferences. Keys: `mode` (`row`, `pick`, `last`), `theme`, `look`, `accent`, `list`, `hideDock`, `hideMenuBar`, `stageManagerOff`, `fillOnOpen`, `excluded` (bundle ids never resized; no screen for it, set with `defaults write local.easter.edgeswitch excluded -array ...`). `orig.*` keys remember what the Mac was set to before the app changed it.
- `Theme.swift`: every colour, radius and size (`struct Theme`), the three themes in dark and light, and `GlassView`, the one frosted surface every window uses.
- `WindowControl.swift`: Accessibility calls, always on a background queue. `place(pid:slot:areas:on:)` lays out all normal windows of an app as full, left half or right half. `WindowWatcher` reports new and newly focused windows.
- `AppModel.swift`: the list of open apps (regular apps, in launch order), the app in use, the most-recently-used order, the split state, and the actions `show`, `splitScreen`, `minimize`, `rightClick`.
- `Panel.swift`: `PanelController` opens the list when the cursor reaches the left 1 pt of a screen and closes it when the cursor moves 56 pt past it. `ListView` draws the rows itself and handles clicks by position.
- `SettingsWindow.swift`: the settings sheet, drawn by one `walk(draw:)` pass that both lays out and paints.
- `SystemTweaks.swift`: Dock auto-hide (`com.apple.dock autohide`, then the Dock is restarted), menu bar auto-hide (`_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen` in the global domain, then the `AppleInterfaceMenuBarHidingChangedNotification` distributed notification), Stage Manager (`com.apple.WindowManager GloballyEnabled`).
- `Tools.swift`: icon drawing, snapshots and the `--cli` checks. Not used in normal running.

Rules the code follows:

- An app's windows are filled when it becomes active, when it opens a window and when its front window changes. Only windows with the standard subrole are touched; dialogs, sheets and panels are left alone.
- An app with two or more normal windows gets one row per window under it (Chrome profile windows show as "Profile: page title"). Windows are listed oldest first, using the private `_AXUIElementGetWindow` call for a stable order. Only windows on the current desktop are seen; a hidden app reports none.
- Clicking a window row brings that window forward and fills the screen. Right-clicking it (or picking it in "Right-click, then pick") puts it on the right half; if it belongs to the app in use, that app's front window takes the left half and the other windows of the app are not moved.
- In the icons-only list there are no window rows: a badge shows the window count, and clicking the app in use steps to its next window.
- Each app row has a close button (quits the app, as Cmd-Q would; the app asks about unsaved work) to the left of minimize. Each window row has a close button that closes that window.
- A window that cannot be resized is left alone. A window that cannot grow to the target is centred at the size it reached (System Settings does this).
- A window in macOS full screen is left alone, except for a split, where it is taken out of full screen first.
- Minimize hides the whole app (as Cmd-H does). It stays in the list as "Minimized".
- Clicking an app in the list always ends a split. Switching to a third app any other way also ends it.
- Switching apps works without Accessibility; resizing does not.
- Switching a Screen option off puts that macOS setting back to what it was before.

## Rules from the user

- Any app that opens fills the screen. No extra button or shortcut.
- "Fill the screen" means the window is resized to cover the display. Do not use macOS native full screen (separate Spaces).
- The Dock and the menu bar are hidden.
- The app list is on the left edge.
- All three right-click split behaviours ship in the app as a setting; the user picks.
- Theme is Tahoe Glass (`THEME.md`). Surfaces are frosted and translucent, never solid black or gray boxes.
- Mockup first for new features; build only after the user approves.
- Nothing goes to GitHub unless the user says so at that moment.

## Change log

### 2026-11-13, build 1.2.0

- The user's Chrome windows did not appear as window rows. Cause: both were in macOS full screen on their own desktops, and the public Accessibility window list only returns windows on the current desktop.
- `WindowControl.windowList(of:)` now also finds windows elsewhere: it checks `CGWindowListCopyWindowInfo` for sizeable windows the public list missed and, only then, tries the app's first 1000 element ids through the private `_AXUIElementCreateWithRemoteToken` (the method AltTab uses). About 75 ms for Chrome. Window reading moved to its own queue (`readQueue`) so it never delays moving a window.
- Clicking such a row jumps to that window's desktop (set main, raise, activate). It stays in macOS full screen; it is taken out only for a split.
- Windows are grouped by profile when the app puts the profile in the title. Chrome's format is `<page> - Google Chrome – <profile>` (hyphen, then en dash); `AppModel.parseTitle` handles hyphen, en dash and em dash on both sides. The profile name is a small heading above its windows.
- Optional debug lines on stderr with `EDGESWITCH_DEBUG=1` (`dlog` in `Prefs.swift`).
- GitHub CLI 2.104.0 downloaded from github.com/cli/cli (checksum verified) to `~/.local/bin/gh`. Not signed in yet, nothing pushed.
- Tested live: both full-screen Chrome windows listed under the heading "Your Chrome"; clicking each row brought that window on screen and made Chrome frontmost; clicking Claude returned. Later repeat runs were unreliable because the user was moving the mouse and had switched theme, which moved the rows away from the scripted click points; the debug log showed the list opening every time the cursor reached the edge.
- Not tested: two different Chrome profiles (both windows reported the same profile name), splitting with a full-screen Chrome window, the icons-only list.

### 2026-11-13, build 1.1.0

- The user could not reach a second Chrome window or profile: every window of an app was filled to the same full-screen frame, so the others sat hidden behind the front one. Added a row per window under any app with two or more windows; click to switch, right-click to split, including two windows of the same app side by side.
- Added a close button to the left of minimize on app rows (quits the app) and a close button on window rows (closes that window), as the user asked.
- How: `WindowInfo`, `windowList(of:)`, `focus(window:pid:)`, `close(window:)` and a per-window `place` in `WindowControl.swift`; `Target` (app plus optional window) for each split side, `listedWindows`, `splitWith`, `showNextWindow`, `quit`, `close(window:of:)` in `AppModel.swift`; `ListView` in `Panel.swift` now lays out a flat list of app and window items.
- Fixed: the capsule-style list did not grow when window rows loaded during its slide-in (the resize now waits for the slide to finish). Finder, which has no launch date, now sorts first instead of last. A subtitle equal to the app name is no longer shown.
- `build.sh` now runs `tccutil reset Accessibility local.easter.edgeswitch` after installing, so macOS asks for the permission again instead of showing a switch that is on but dead.
- Tested live (direct run of the app, Aurora Capsule dark, which the user had selected): five Finder windows listed; clicking a window row made it the front window; right-click put two Finder windows at 1279 pt each with the list showing Left and Right; the window close button closed one window; the app close button quit Calculator; close sits left of minimize.
- Not tested: real Chrome profile windows (Chrome had no open windows during testing, so the "Profile: page" title format is unverified), the icons-only badge and window stepping, picking a window in "Right-click, then pick", minimized windows in the list.
- During the test one of the user's own Finder windows ("build") was closed.
- Local git repository created and committed. Not pushed: this Mac has no GitHub login (no `gh`, no SSH key, no saved credential).

### 2026-11-12, build 1.0.0

- Built the Mac app after the user approved the mockup and chose Tahoe Glass.
- How: eight Swift files in `Sources/`, compiled by `build.sh` with `swiftc`, bundled by hand, icon drawn by the app itself (`--make-icon`) and converted with `sips` and `iconutil`.
- Dock hiding first used the private `CoreDockSetAutoHideEnabled`; it had no effect on macOS 27.2, so it now writes the preference and restarts the Dock.
- Changed on this Mac, with the user's OK: Dock auto-hide on, menu bar auto-hide on, Stage Manager off. Before: Dock shown, menu bar shown, Stage Manager on (saved as `orig.dock`, `orig.menubar`, `orig.stage`).
- Tested on the real screen through `--cli` and a direct run of the app: menu bar and Dock no longer take space (usable area 2560 x 1440); fill on Notes, Safari, Chrome; System Settings centred at its fixed width; split Notes/Safari and Chrome/Safari at 1279 pt each; the list opens at the left edge with real frosting; clicking a row switches app and closes the list; right-click split in `row` mode; minimize; Done in Settings; returning to Claude. Screen captures checked for the list, the split and the settings sheet.
- Not tested: `pick` and `last` modes in the live app (only in the mockup and in a snapshot), Slate Rail and Aurora Capsule live, light appearance live, icons-only list live, Start at login, a second display, the first-run Accessibility prompt of the installed copy, whether Stage Manager really disappears (the preference is off; not confirmed by eye).
- Earlier the same day: created the project, the interactive mockup and `THEME.md`.

## Open items

- The installed copy needs the user to switch on Accessibility for Edge Switch once. Until then it switches apps but cannot resize them.
- GitHub push is waiting for the user to sign in (`~/.local/bin/gh auth login`). Then: create a private repo, wait 5 minutes, push.
- Asked for on 2026-11-13, not built: pinned apps at the bottom of the list, a Home Assistant button beside Settings that opens light/switch controls in the list, more look options.
- The mockup (`mockups/edge-switch.html`) does not show window rows or the close buttons.
- The permission resets on every rebuild (ad hoc signing). A stable self-signed certificate would fix that; not set up.
- No VoiceOver labels and no keyboard control of the list or the settings sheet (custom-drawn views). Esc, Return and Cmd-W close Settings.
- No hover delay or edge-sensitivity setting; the list opens the moment the cursor touches the edge.
- The Dock still appears when the cursor rests on the bottom edge (macOS auto-hide behaviour).
- Decide the app's real name ("Edge Switch" is a placeholder).
- Theme checks (theme-monitor and theme-philosophy-reviewer) were started after the build; apply their findings.
