# Doorstep 0.7: one app

## Problem
Doorstep grew from 0.2 to 0.6 one feature at a time. Each arrived as its own window or settings section, so it does a lot but feels like a toolbox. It is also dark only.

## Goal
Someone opening Doorstep for the first time understands where everything is in ten seconds, in light or dark.

## Decisions
1. **One window, called Doorstep.** A rail on the left switches sections: Live, History, Map, Radar, Insights. "Command Centre" and the separate History window are gone as names and as windows. Shortcuts ⌘1 to ⌘5.
2. **The menu bar popover stays the quick look.** Its buttons open the one window at the right section.
3. **History doesn't wake cameras.** Only sections that show live video keep cameras connected.
4. **Light, dark, or match the Mac.** Settings › General › Appearance. Every colour token has a day and a night value; nothing else in the code names a colour.
5. **Text on video is always light.** Tiles, the doorbell pop-up picture and floating cameras ignore the theme, because video is dark whatever the time of day.
6. **Amber stays the only accent,** deeper by day (#B8780A) so it reads on paper, brighter at night (#F5B544).

## Still to do in 0.7
- Check Map, Radar, Insights, Parcels, Settings and sign-in in light mode and fix what's off.
- Settings diet: fewer, clearer groups; advanced options tucked away.
- First-run guide.
- Icon, menu bar glyph and banner refresh against the final look.
- New README screenshots and guide wording (no more "Command Centre").

## Screens
Live (light): `docs/design/0.7/live-light.png` · Menu bar (light): `pop-light.png` · History (dark): `hist-dark.png`
