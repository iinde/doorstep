# Privacy

Doorstep is built so that nothing about your home leaves your Mac unless you've chosen it.

## No account, no server
There is no Doorstep account and no Doorstep server. The app talks to Ring (it's a Ring app), checks GitHub for updates, and talks to nobody else unless you switch on one of the optional extras below.

## Everything that can leave your Mac
| What | Where to | When | Can I turn it off? |
|---|---|---|---|
| Ring sign-in, live video, your event list and clips | Ring | While Doorstep is running | It's how Doorstep works |
| Update check (the app's version number) | GitHub | Every 6 hours | Settings › General › Updates |
| 3 still frames of a visitor | Anthropic (Claude), your key | Only if "Ask Claude" is on | Off by default |
| Tracking numbers you added | 17TRACK, your key | Every 30 min, only with a key | Remove the key |
| Delivery emails, read-only | Microsoft (your mailbox) | Every 15 min, only if connected | Disconnect |
| Your position, rounded to ~1 km | Open-Meteo (weather) | Only when a parcel's left outside | Settings › Parcels |

## What stays on your Mac
- **Who came, couriers, sounds, number plates, parcels**: worked out on your Mac with Apple's Vision and Sound Analysis, stored in `~/Library/Application Support/Doorstep`.
- **Thumbnails**: `~/Library/Caches/Doorstep` (clear it in Settings › Intelligence).
- **Recordings**: the folder you choose (default `~/Movies/Doorstep Recordings`).
- **Your Ring sign-in token and any keys you add**: your Mac's Keychain.

Your **Ring password** is sent to Ring once to sign in and is not stored.

## The microphone
Doorstep only uses your microphone while you **hold Talk**. Live view and recording are listen-only, so macOS's orange microphone dot only appears while you're actually talking.

## Cameras that see beyond your home
If your cameras capture the street or a neighbour's property, privacy law can apply to you as the person recording. In the UK, see the [ICO's guidance on home CCTV](https://ico.org.uk/for-the-public/domestic-cctv-systems-guidance-for-people-using-cctv/). Number plate reading is off by default, and everything Doorstep records stays on your Mac.

## Check for yourself
Doorstep is open source. The networking lives in [`RingClient`](../../app/OpenRingPackage/Sources/RingClient) and the optional extras in [`Intelligence`](../../app/OpenRingPackage/Sources/OpenRingFeature/Intelligence) and [`Parcels`](../../app/OpenRingPackage/Sources/OpenRingFeature/Parcels).
