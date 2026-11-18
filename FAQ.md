# Questions and answers

**Getting it going**
- [Why does macOS say it can't check Doorstep?](#why-does-macos-say-it-cant-check-doorstep)
- [Where is it? I opened it and nothing happened.](#where-is-it-i-opened-it-and-nothing-happened)
- [Ring's code isn't arriving / sign-in says something went wrong](#rings-code-isnt-arriving--sign-in-says-something-went-wrong)
- [Which Macs does it run on?](#which-macs-does-it-run-on)
- [Does it work with my camera?](#does-it-work-with-my-camera)
- [How do I try it without a Ring account?](#how-do-i-try-it-without-a-ring-account)

**Money and accounts**
- [Is it really free? What's the catch?](#is-it-really-free-whats-the-catch)
- [Do I need Ring Protect (the subscription)?](#do-i-need-ring-protect-the-subscription)
- [Do I need an account with you?](#do-i-need-an-account-with-you)

**Privacy and safety**
- [Is my Ring password safe?](#is-my-ring-password-safe)
- [Does my video go anywhere?](#does-my-video-go-anywhere)
- [Why is my microphone not in use? Shouldn't it be for talking?](#why-isnt-my-microphone-in-use)
- [Is it allowed? Will Ring ban my account?](#is-it-allowed-will-ring-ban-my-account)
- [Is it legal to record the street?](#is-it-legal-to-record-the-street)
- [How do I know an update is really from you?](#how-do-i-know-an-update-is-really-from-you)

**Features**
- [Does it do everything Ring Protect does?](#does-it-do-everything-ring-protect-does)
- [How do modes work?](#how-do-modes-work)
- [How do familiar faces work?](#how-do-familiar-faces-work)
- [Can I get Doorstep's alerts on my phone?](#can-i-get-doorsteps-alerts-on-my-phone)
- [Can I stop the pavement setting off alerts?](#can-i-stop-the-pavement-setting-off-alerts)
- [How does it know it was DPD?](#how-does-it-know-it-was-dpd)
- [It got it wrong. How do I correct it?](#it-got-it-wrong-how-do-i-correct-it)
- [How does recording without a subscription work?](#how-does-recording-without-a-subscription-work)
- [Does it drain my battery cameras?](#does-it-drain-my-battery-cameras)
- [Will the recorder drain my battery cameras?](#will-the-recorder-drain-my-battery-cameras)
- [How does parcel tracking work without an account?](#how-does-parcel-tracking-work-without-an-account)
- [How do I turn my porch light on when someone arrives?](#how-do-i-turn-my-porch-light-on-when-someone-arrives)
- [What is "Ask Claude" and do I need it?](#what-is-ask-claude-and-do-i-need-it)
- [Can I use it on more than one Mac?](#can-i-use-it-on-more-than-one-mac)
- [Can I hide some cameras, like a shared location?](#can-i-hide-some-cameras-like-a-shared-location)

**Problems**
- [A camera says "No picture"](#a-camera-says-no-picture)
- [Live view is slow to start](#live-view-is-slow-to-start)
- [The doorbell window came a few seconds late](#the-doorbell-window-came-a-few-seconds-late)
- [How do I uninstall it?](#how-do-i-uninstall-it)

**Everything else**
- [Windows? iPhone? Android?](#windows-iphone-android)
- [How can I help?](#how-can-i-help)

---

## Getting it going

### Why does macOS say it can't check Doorstep?
Apple checks apps from the internet for a stamp called notarisation. Getting that stamp needs a paid Apple Developer account, which Doorstep doesn't have yet. The app is still signed, and every update is checked against Doorstep's own signature.

To open it the first time: open Doorstep from Applications, click **Done** on the warning, then go to **System Settings › Privacy & Security**, scroll to the bottom and click **Open Anyway**. You won't be asked again, and updates install without this step.

### Where is it? I opened it and nothing happened.
Doorstep lives in the **menu bar** at the top of your screen, not the Dock. Look for a small doorway icon near the clock. If your menu bar is full, it may be hidden behind the notch: try closing a few other menu bar apps, or hold ⌘ and drag icons to make room. You can also press **⌘`** (Command and the key above Tab) to open it from anywhere.

### Ring's code isn't arriving / sign-in says something went wrong
Ring texts (or emails) a six-digit code after your password. Codes expire after a few minutes, so if one fails, go back and sign in again for a fresh one rather than retrying the old code. If you use an authenticator app with Ring, use its current code. If sign-in keeps failing, check you can sign in to the Ring app on your phone with the same email and password.

### Which Macs does it run on?
Any Mac with **macOS 14 Sonoma or later**, Apple silicon or Intel. The command centre and recorder are happiest on Apple silicon.

### Does it work with my camera?
It's been used with:
- Ring Video Doorbell (wired and battery models)
- Floodlight Cam
- Spotlight Cam
- Stick Up Cam Mini

Most Ring doorbells and cameras use the same system, so others should work too. Ring Alarm, Chime and lights aren't shown. If a camera doesn't work, please [send a camera report](https://github.com/iinde/doorstep/issues/new?template=camera_report.yml).

### How do I try it without a Ring account?
Open Terminal and run:
```
open -a Doorstep --args -DoorstepDemo YES
```
You'll get a made-up home with drawn cameras, two weeks of visits, parcels and the full command centre. Nothing is saved, and nothing is sent anywhere. Quit Doorstep and open it normally to go back.

## Money and accounts

### Is it really free? What's the catch?
It's free and open source (MIT licence). There's no subscription, no ads, no account, no data collection, and no server. It's a side project built because Ring has no Mac app. The only costs are optional and paid by you to someone else: a Claude key if you want the cloud check, for example.

### Do I need Ring Protect (the subscription)?
No. Without it you still get live view on every camera, the doorbell pop-up, talking, the timeline of what happened, and **Doorstep's own recorder**, which saves visits on your Mac. With Ring Protect you also get Ring's recorded clips inside History.

### Do I need an account with you?
No. There's nothing to sign up to. You sign in to Ring, the same as in Ring's own app.

## Privacy and safety

### Is my Ring password safe?
Your password goes only to Ring, over the same secure connection Ring's apps use, and is used once to get a sign-in token. That token is kept in your Mac's **Keychain** (where Safari keeps your passwords). Doorstep doesn't store your password and has no server to send it to. The code that does this is in [`RingClient`](app/OpenRingPackage/Sources/RingClient) if you'd like to check.

### Does my video go anywhere?
Live video comes from Ring to your Mac and nowhere else. Recognising people, couriers and sounds happens on your Mac using Apple's built-in Vision and Sound Analysis. The only exception is if **you** switch on "Ask Claude" and add your own key: then three still frames of a visitor go to Anthropic when your Mac can't tell who it was. The full list is on the [privacy page](docs/guides/privacy.md).

### Why isn't my microphone in use?
Because you're not talking. Doorstep only turns the microphone on while you **hold Talk**, and turns it off when you leave that camera. Watching and recording never use it, so you won't see the orange microphone dot unless you're speaking to someone.

### Is it allowed? Will Ring ban my account?
Doorstep signs in to your own account and does what Ring's own apps do: shows live video, lists events, plays clips. It isn't approved by Ring, though, and uses Ring's private interface, so we can't promise how Ring will feel about it. We're not aware of any accounts being banned for using unofficial Ring apps, which have existed for years. Use it at your own risk; it's your account.

### Is it legal to record the street?
Recording your own property is generally fine. If your cameras can see beyond it (the street, a neighbour's garden), privacy law may apply to you. In the UK the ICO has [clear guidance for home CCTV](https://ico.org.uk/for-the-public/domestic-cctv-systems-guidance-for-people-using-cctv/). Doorstep keeps everything on your Mac, and number plate reading is off by default for this reason.

### How do I know an update is really from you?
Every update is signed with Doorstep's private key, and the app checks that signature (and Apple's code signature) before installing anything. A tampered or fake update is refused.

## Features

### Does it do everything Ring Protect does?
Nearly. Recording (including 24/7), smart alerts, modes, video descriptions, single event alerts, video search, familiar faces, unusual activity alerts, the daily summary, picture-in-picture and sharing clips are all in Doorstep, worked out on your Mac. What it can't do: Ring's guard response and alarm services (they need people and alarm hardware), and recording while your Mac is switched off (Ring records in its cloud). There's a full comparison in the [README](README.md#doorstep-vs-ring-protect).

### How do modes work?
Turn on **Settings › Alerts › Use modes**. There are four: **Home**, **Away**, **Night** and **Quiet**. For each one you tick which cameras alert you and which record. Switch modes from the menu on the Wall, let Doorstep switch to Night and back on a schedule, or ask Siri: *"Set Doorstep to Away"*. Doorbell rings always come through except in Quiet. You can also switch modes from a Shortcut, for example when you leave home.

### How do familiar faces work?
It's off until you switch it on in **Settings › Alerts › Familiar faces**. Open a visit in History, choose **Find faces in this clip**, and type a name under the face (*"Mum"*). From then on Doorstep compares faces in new clips with the ones you've named, on your Mac, and tells you *"Mum is at the front door"*. Only faces you name are kept; nobody else's face is stored. It's a beta: it's cautious, so it may miss someone rather than mistake them.

### Can I get Doorstep's alerts on my phone?
Yes. **Settings › Alerts › On your phone** sends them, picture included, through ntfy (free, no account), Pushover or Telegram, with your own topic or keys. The Ring app on your phone still sends Ring's own alerts as usual; Doorstep's say *who* it was.

### Can I stop the pavement setting off alerts?
Yes: draw a **zone**. In **Settings › General › Cameras** click **Zone…**, then click round your path or drive. People outside it won't alert you or start a recording.

### How does it know it was DPD?
It reads. When a clip has a person or vehicle in it, Doorstep looks at a few frames and reads any writing (van sides, jackets, bags), then matches it against carrier names like DPD, Royal Mail, Amazon, Evri, DHL, UPS, FedEx, Yodel and the supermarkets. It also knows a few liveries by colour. All on your Mac. At night the cameras see in black and white and writing is harder to read, so it may say "Delivery driver" instead.

### It got it wrong. How do I correct it?
Open the visit in History and use the **Who was it?** button. Pick the right company (or "Not a delivery"). Doorstep remembers what that clip looked like and uses it to recognise similar visits next time.

### How does recording without a subscription work?
Switch it on in **Settings › Recording** and choose which cameras. Doorstep keeps those cameras live in the background and watches the picture itself. It's always holding the last few seconds in memory, so when it sees a person (or any movement, if you prefer) it saves the visit *including the moments before*. Clips go into a folder on your Mac (or a network drive), sorted by day, and are tidied away after the number of days you choose. Your Mac must be on: Doorstep stops it sleeping while recording, but closing a laptop lid will pause it.

### Does it drain my battery cameras?
No. Doorstep only streams while you're looking, like the Ring app's live view, and with **Battery saver** (on by default, Settings › General) battery cameras don't stream at all when you open Doorstep: they show their latest picture with "Click to go live". The rest of the time Doorstep reads Ring's list of events, which doesn't wake the camera. If a live session drops or the picture freezes, Doorstep reconnects by itself; a camera that never sends a picture (a closed privacy cover) shows "Try again" instead of retrying forever.

### Will the recorder drain my battery cameras?
Streaming all day would, so Doorstep only records **wired** cameras by default and labels battery ones clearly. For battery cameras, switch on **Time-lapse** instead: a still picture every few minutes, which uses almost no battery, and History can turn a day of them into a video.

### How does parcel tracking work without an account?
Three ways, all optional:
1. **Paste or drag in** a tracking number or a delivery email. Doorstep works out the carrier and the status.
2. **Add your own free [17TRACK](https://www.17track.net/en/api) key** in Settings › Parcels for live status every 30 minutes.
3. **Connect an Outlook.com or Microsoft 365 mailbox** (read-only) so delivery emails are picked up automatically.

Whichever you use, the Track button always opens the carrier's own page.

### How do I turn my porch light on when someone arrives?
Make a Shortcut that turns the light on (Shortcuts app › New Shortcut › Home › Control Home, pick the light). Then in **Settings › Automations**, add *"Someone walks up to the door → run Porch light on, only after dark"*. "After dark" uses sunset where your cameras are. There are more recipes in the [automations guide](docs/guides/automations.md).

### What is "Ask Claude" and do I need it?
You don't need it. It's an optional extra for when Doorstep can't tell from the picture who someone is: it sends three still frames to Claude (an AI by Anthropic) and asks. It uses **your own** Anthropic key, so it's billed to you (fractions of a penny per visit), has a daily limit you set, and is off until you switch it on.

### Can I use it on more than one Mac?
Yes. Install it on each Mac and sign in. Each Mac keeps its own history of who came and its own recordings.

### Can I hide some cameras, like a shared location?
Yes. **Settings › General › Cameras** lists every camera on your Ring account, grouped by location, with a switch for each (and **Hide all** for a whole location, like a family member's house that's shared with you). Hidden cameras don't appear anywhere in Doorstep, don't stream, and don't send alerts. Switch them back on whenever you like; nothing changes in your Ring account.

## Problems

### A camera says "No picture"
The camera connected but didn't send video. Common causes: an indoor camera's privacy cover is closed, a battery camera has gone to sleep, or the camera has poor Wi-Fi. Click **Try again**. If it never works, check the camera's live view in the Ring app.

### Live view is slow to start
Live video comes from Ring's servers and usually starts in one or two seconds. Battery cameras can take longer because they need to wake up. Starting all cameras at once can make the first one slow; Doorstep starts them a moment apart to help.

### The doorbell window came a few seconds late
Doorstep receives Ring's push alerts the same way Ring's phone app does, so rings should appear within a second or two. If the push connection drops (no internet, the Mac waking from sleep), Doorstep falls back to checking every few seconds until it reconnects. You can switch instant alerts off with `defaults write com.openring.app instantAlerts -bool NO` if you ever need to.

### How do I uninstall it?
Quit Doorstep (click it in the menu bar, then the gear, then Quit, or press ⌘Q while it's open), then drag it from Applications to the Bin. To remove everything it saved too, delete `~/Library/Application Support/Doorstep`, `~/Library/Caches/Doorstep` and, if you used the recorder, your recordings folder (by default `~/Movies/Doorstep Recordings`).

## Everything else

### Windows? iPhone? Android?
Mac only for now. Doorstep is built with Apple's own tools (SwiftUI, Vision, Sound Analysis) to feel at home on a Mac.

### How can I help?
Use it and tell us what's broken or confusing. [Report bugs](https://github.com/iinde/doorstep/issues/new?template=bug_report.yml), [report how your camera works](https://github.com/iinde/doorstep/issues/new?template=camera_report.yml), suggest features, or send code. See [CONTRIBUTING.md](CONTRIBUTING.md).
