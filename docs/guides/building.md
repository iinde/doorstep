# Building Doorstep yourself

## You'll need
- macOS 14 or later
- Xcode 16 or later
- An Apple ID signed in to Xcode (a free one is fine for building and running)

## Build and run
```bash
git clone https://github.com/iinde/doorstep.git
cd doorstep
./scripts/build.sh
open app/build/Build/Products/Debug/OpenRing.app
```
`build.sh` builds a Debug copy and signs it with your first "Apple Development" certificate if you have one (so the Keychain doesn't ask for permission after every rebuild), or ad-hoc otherwise. Set `DOORSTEP_SIGN_CERT` to choose a certificate.

Or open `app/OpenRing.xcodeproj` in Xcode and press Run.

## Try it without a Ring account
```bash
open app/build/Build/Products/Debug/OpenRing.app --args -DoorstepDemo YES -DoorstepDebugWindow YES
```
Demo mode uses made-up cameras (drawn in code), visits and parcels, and reads and writes nothing of yours. It's how the screenshots are made.

## Tests
```bash
cd app/OpenRingPackage && swift test
```

## Project layout
| Folder | What's in it |
|---|---|
| `app/OpenRing` | The app target: menu bar, windows, settings, Siri intents |
| `app/OpenRingPackage/Sources/RingClient` | Talking to Ring: sign-in, devices, events, clips, live video (WebRTC) |
| `app/OpenRingPackage/Sources/OpenRingFeature/Wall` | The menu bar Wall, focus view, doorbell panel, brand mark |
| `.../History` | History, thumbnails, on-device tagging |
| `.../Intelligence` | Couriers, teaching, hearing, number plates, search, daily brief, optional Claude |
| `.../Parcels` | Parcels, email parsing, tracking, Outlook |
| `.../Recorder` | Live analysis and the on-Mac recorder |
| `.../CommandCentre` | Live, map, radar, insights, floating cameras |
| `.../Integrations` | Shortcuts automations, announcements |
| `.../Updates` | Sparkle updates |
| `.../Demo` | Demo mode and its drawn cameras |
| `docs/` | Design briefs, brand, guides, release notes |
| `scripts/` | Build, release, brand and installer artwork |

The design rules (colours, type, motion) are in [docs/DESIGN-BRIEF.md](../DESIGN-BRIEF.md) and [docs/BRAND.md](../BRAND.md).

## Useful launch flags
| Flag | Does |
|---|---|
| `-DoorstepDemo YES` | Demo mode |
| `-DoorstepDebugWindow YES` | Show the Wall in a normal window (for screenshots) |
| `-DoorstepCommandCentre YES` | Open the Doorstep window at launch (add `-mainSection History`, `-appearance light`) |
| `-DoorstepTestCall YES` | Show the doorbell panel |
| `-DoorstepRecordTest YES` | Force a short recording on each recorded camera |
| `-DoorstepFeedURL <url>` | Use a different update feed (updates must still be signed) |

## Releases
Releases are made with `scripts/release.sh <version>`, which builds a universal app, makes the installer, signs the update with the project's private key and writes the update feed. Only maintainers can publish, because only they have that key.
