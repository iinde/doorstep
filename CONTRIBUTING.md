# Contributing to Doorstep

Thanks for wanting to help. Doorstep is a small project and every report, idea and fix makes a difference.

## Ways to help (no code needed)
- **Report a bug.** Use the [bug report form](https://github.com/iinde/doorstep/issues/new?template=bug_report.yml). Say what you did, what you expected and what happened. A crash report (Console › Crash Reports › OpenRing) is gold.
- **Tell us about your camera.** Ring makes a lot of models. A [camera report](https://github.com/iinde/doorstep/issues/new?template=camera_report.yml) saying what works and what doesn't helps everyone with that camera.
- **Suggest a feature** with the [feature form](https://github.com/iinde/doorstep/issues/new?template=feature_request.yml), or start a [discussion](https://github.com/iinde/doorstep/discussions).
- **Improve the guides.** Spotted something confusing in the [guides](docs/guides/README.md) or [FAQ](FAQ.md)? Pull requests to the docs are very welcome.
- **Couriers outside the UK.** Doorstep recognises UK carriers. Adding your country's carriers (names on vans, email domains, tracking number formats) to [`Carrier.swift`](app/OpenRingPackage/Sources/OpenRingFeature/Intelligence/Carrier.swift) is a great first contribution.

## Working on the code
See [Building Doorstep yourself](docs/guides/building.md) for setup. Demo mode (`-DoorstepDemo YES`) lets you work on most of the app without a Ring account.

1. **Open an issue first** for anything bigger than a small fix, so we can agree the approach.
2. **Fork, then branch** from `main`.
3. **Keep to the design.** Doorstep has a deliberate look and voice: see [DESIGN-BRIEF.md](docs/DESIGN-BRIEF.md) and [BRAND.md](docs/BRAND.md). One accent colour (porchlight amber) for things that need a human; plain, calm, British wording; no exclamation marks.
4. **Privacy rules are hard rules.**
   - Nothing about a user's home leaves their Mac unless they switch it on, and anything that does uses *their own* key or account.
   - No analytics, no tracking, no Doorstep servers.
   - Never use the microphone except while the user holds Talk.
   - Never commit real camera footage, screenshots of real homes, number plates, tracking numbers or account details. Use demo mode for screenshots.
5. **Test it.** `swift test` in `app/OpenRingPackage`, and run the app. For anything that plays video, also test a **Release** build: some SwiftUI pieces behave differently there (we learnt this the hard way with `VideoPlayer`).
6. **Write a clear pull request**: what changed, why, and how you checked it. Screenshots from demo mode for UI changes.

## Code style
- Swift 6, SwiftUI, Swift concurrency. Follow the patterns around you.
- Comments explain *why*, not *what*.
- User-facing text: plain English, sentence case, no jargon, no em dashes.

## Licence
By contributing you agree your work is released under the [MIT licence](LICENSE).

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
