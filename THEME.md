# Edge Switch theme

Chosen by the user on 2026-11-12: **Tahoe Glass**. It is the default. Slate Rail and Aurora Capsule stay available in Settings; their tokens are in `mockups/edge-switch.html`.

## Design philosophy

Tahoe Glass follows Apple's glass language: clarity, deference, depth.

- **Clarity**: app names and icons are readable at a glance over any app behind the list, light or dark.
- **Deference**: the list is a quiet floating layer. The apps are the content; the list never looks like a second Dock.
- **Depth**: real frosting of what is behind the panel, a light rim, a soft top sheen and one shadow. No flat fills.

The one bold element is the accent-tinted row for the app in use. Everything else stays quiet.

## Tokens

Font: the system font (SF Pro) at every size. Monospace is not used in the app.

| Token | Dark | Light |
|---|---|---|
| Text | `#F5F6F8` | `#14161A` |
| Secondary text | text at 76% | text at 72% |
| Glass tint | `rgba(24,26,32,.70)` | `rgba(246,247,250,.72)` |
| Frosting | blur 36, saturation 170%, brightness 80% | blur 36, saturation 170%, brightness 112% |
| Rim (1 px border) | `rgba(255,255,255,.20)` | `rgba(255,255,255,.75)` |
| Top sheen | white 13% fading to 0 at 38% height | white 55% fading to 0 at 38% height |
| Hairline divider | `rgba(255,255,255,.14)` | `rgba(0,0,0,.11)` |
| Field / group fill | `rgba(255,255,255,.07)` | `rgba(0,0,0,.05)` |
| Hover fill | `rgba(255,255,255,.10)` | `rgba(0,0,0,.07)` |
| Row in use | accent at 36% | accent at 26% |
| Shadow | `0 18px 50px rgba(0,0,0,.42)` | `0 18px 50px rgba(20,30,60,.26)` |

Accent colours (user picks one, default Blue): Blue `#0A84FF`, Purple `#8E5CF6`, Pink `#F2478B`, Orange `#F08A24`, Green `#2FB65A`, Graphite `#8A8F98`.

Shape and size:

| Token | Value |
|---|---|
| List width | 256 pt with names, 72 pt icons only |
| List inset from screen edges | 10 pt, full height |
| List corner radius | 22 pt |
| Row corner radius | 14 pt |
| Row height | at least 52 pt |
| App icon | 36 pt, 9 pt radius |
| App name | 14 pt semibold |
| Secondary line | 12 pt regular |
| Settings sheet radius | 24 pt |
| Gap between rows | 3 pt |
| Window row (one window listed under its app) | 30 pt high, indented 46 pt, 12.5 pt text |
| Close and minimize buttons on a row | 28 pt square, 8 pt radius, close on the left |

Motion: the list slides in over 210 ms (ease out) and leaves in 140 ms (ease in). Switching apps is instant. With Reduce Motion on, nothing animates.

In the native app, use `NSVisualEffectView` (or the system glass material on macOS 27) for the frosting rather than a hand-made blur, and add the tint, rim and sheen on top.

## Do

- Read every colour, radius and size from one central theme file.
- Keep every surface frosted and translucent: list, settings window, menus, alerts, empty states.
- Keep text at 4.5:1 contrast or better against the worst case behind the glass (a white page in dark mode, a black terminal in light mode).
- Use the accent only as a tint, a selection border or a switch fill. Text stays in the text colour.
- Apply any theme change to every window and pop-up in the same pass.

## Don't

- No solid black or gray boxes behind groups, fields or rows.
- No text on top of a full-strength accent fill (orange and graphite fail contrast).
- No hard-coded colours or sizes in views.
- No emoji as icons.
- No red outlines or highlight switches to mark new or changed UI.
