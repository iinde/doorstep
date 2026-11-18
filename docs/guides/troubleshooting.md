# Troubleshooting

### I can't find Doorstep after opening it
It's in the **menu bar** (top right, near the clock), not the Dock. If you have a notch, it might be hidden: press **⌘`** to open it, or make room by quitting another menu bar app.

### "Doorstep can't be opened because Apple cannot check it"
See [Getting started › Open it the first time](getting-started.md#3-open-it-the-first-time). Use **System Settings › Privacy & Security › Open Anyway**.

### Sign-in says the code is wrong
Codes expire quickly. Click **Use a different account**, sign in again, and use the newest code. Check the same email and password work in Ring's phone app.

### A camera shows "No picture from…"
The camera connected but sent no video. Indoor cameras with a closed privacy cover do this, as do battery cameras that are asleep or have weak Wi-Fi. Click **Try again**.

### "Connecting…" never finishes
Check your internet connection, then quit Doorstep (gear menu › Quit) and open it again. If one camera never connects, check it works in the Ring app.

### No sound from a camera
Click the speaker button in that camera's view. Only the camera you're looking at plays sound.

### Talk doesn't work
The first press on a camera takes a couple of seconds ("Connecting mic…"). Check **System Settings › Privacy & Security › Microphone** has Doorstep switched on.

### No notifications
**System Settings › Notifications › Doorstep**: allow notifications. In Doorstep, check **Settings › General › Alerts**.

### The recorder isn't saving anything
- Check **Settings › Recording** is on and the camera is ticked.
- Recording only saves when a **person** is seen, unless you tick "Record any movement".
- Your Mac must be awake. Closing a laptop lid pauses it.

### Courier names are wrong or missing
Use **Who was it?** in History to correct it; Doorstep learns. At night, names are often unreadable, so you may see "Delivery driver".

### It crashed
Sorry! Please send a report: open **Console** (in Applications › Utilities) › **Crash Reports**, find the newest **OpenRing** report, and attach it to a [bug report](https://github.com/iinde/doorstep/issues/new?template=bug_report.yml). The report contains no video or passwords.

### Start completely fresh
Quit Doorstep, then delete `~/Library/Application Support/Doorstep` and `~/Library/Caches/Doorstep`. To sign out instead, use **Settings › Account › Sign out**.
