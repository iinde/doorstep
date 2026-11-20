# What's changed

Full notes for each version are on the [releases page](https://github.com/iinde/doorstep-releases/releases).

## 0.8.0
- Other cameras (RTSP/ONVIF): live view, network search, person alerts.
- Ask your door (questions in History search), while-you-were-out card, quiet on calls, instant offline alerts, away-mode escalation (light, spoken warning).
- Postie routine, bin day reminders, UK bank holidays (GOV.UK).
- Desktop widget.

## 0.7.2
- Security: WebRTC updated from M125 to M158.
- The main window no longer redraws every second; spoken replies can't hang if the call never connects.

## 0.7.1
- Settings: a Replies tab, a shorter Alerts tab, and Account moved into General.
- The rail no longer shifts on History.

## 0.7.0
- One window: Live, History, Map, Radar and Insights together (⌘1 to ⌘5). The separate History and Command Centre windows are gone.
- Light mode, dark mode, or match your Mac (Settings › General › Appearance).
- A welcome screen the first time you open it. Settings reopens on the tab you last used.

## 0.6.0
- Say it at the door: type a reply (or pick a saved one) and the Mac says it through the doorbell, with the microphone off.
- Answer couriers for you (optional): one sentence of yours, said once, when a recognised courier rings.
- Say at Door action for Shortcuts and Siri.

## 0.5.2
- Security: hardened runtime, update feed can't be redirected in release builds, warning for guessable ntfy topics.

## 0.5.1
- Search by what's in the picture: "red van", "dog", "man in a hat", with Apple's MobileCLIP on your Mac (optional download).

## 0.5.0
- Instant alerts: Doorstep receives Ring's push alerts like Ring's own app, so rings pop up straight away.
- Battery saver: battery cameras show their latest picture until you click them (on by default).
- Home Assistant and Homebridge over MQTT (auto-discovered entities, two-way mode).
- Zones, loitering alerts, alerts on your phone (ntfy, Pushover, Telegram), transcripts of what visitors say, local AI descriptions with Ollama, camera health (Wi-Fi, battery, offline), chime snooze and test, and mirroring Doorstep's mode to Ring's.

## 0.4.0
- Everything Ring Protect does, on your Mac: choose what alerts you, one alert per visit, video descriptions in every alert, Home/Away/Night/Quiet modes, familiar faces (beta, opt in), unusual activity alerts, 24/7 recording, longer retention, and Share.

## 0.3.2
- **Choose which cameras to show.** Settings › General › Cameras, grouped by location, with Hide all for a shared location. Hidden cameras don't stream or alert. (Thanks to a Reddit user for asking.)

## 0.3.1
- **Try it without a Ring account**: demo mode with drawn cameras, visits and parcels.
- **Quit, Settings and Check for Updates** now live in the gear menu on the Wall.
- Tidier Parcels list, and the "I'm expecting a parcel" button stays visible when the window isn't in front.

## 0.3.0
- Record on your Mac without a Ring subscription; time-lapse for battery cameras.
- Command centre: live, map, radar, insights; float a camera.
- Someone walking up to the door opens the doorbell before they ring.
- Hearing (knocks, dogs, glass, alarms), number plates (opt in), plain-English search, "Your day in 60 seconds".
- "I'm expecting a parcel", live tracking with your own 17TRACK key, Add to Calendar, rain warning.
- Automations with Shortcuts, Siri actions, spoken announcements.
- The microphone is only on while you hold Talk.

## 0.2.0
- Couriers by name, teaching, parcel left and taken.
- Parcels from pasted or dropped emails, and optionally Outlook.
- Notifications with a picture and who it was; daily brief; keep clips.
- Automatic, signed updates. New look and icon.

## 0.1.1
- Fixed a crash when playing a clip.

## 0.1.0
- First version: every camera live, the day strip, History, the doorbell pop-up.
