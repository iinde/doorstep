# Recording without a subscription

Without Ring's subscription (Ring Protect), Ring doesn't keep any video: you get live view, but nothing to look back at. Doorstep can fill that gap by recording on your Mac.

## Switch it on
**Settings › Recording › Record on this Mac.** Then choose the cameras.

By default Doorstep chooses your **wired** cameras. Battery cameras are marked: streaming them all day would drain the battery quickly. Use time-lapse for those instead (below).

## How it works
- The chosen cameras stay live in the background, even when Doorstep's window is closed.
- Doorstep watches the picture itself, twice a second, for **people** (or **any movement**, if you switch that on).
- It always holds the last few seconds in memory, so each saved clip **starts before** the person appears.
- Each visit is saved as one video, in a folder per day: by default `~/Movies/Doorstep Recordings`. Choose another folder (a network drive works) in Settings.
- Old recordings are deleted after the number of days you choose (3 days to a year), or kept until you delete them.
- **History** shows recordings under *Recorded on this Mac*, and plays them when Ring has no clip.
- If you have the doorbell recording, Doorstep can also **show you the door when someone walks up**, before they ring.

Your Mac needs to be **on and awake**. Doorstep stops it falling asleep while recording (the screen can still turn off), but closing a laptop lid will pause recording.

The microphone is never used for recording. Recordings are video only.

## 24/7 recording
For wired cameras, **Settings › Recording › 24/7 recording** keeps *everything*, not just visits, in 10-minute files. It uses roughly 1 to 2 GB per camera per day, so point the recordings folder at a big drive (a NAS is ideal) and choose a sensible **Keep recordings for**: anything from 3 days to a year, or **Until I delete them**.

If you use modes, each mode decides which cameras record (Settings › Alerts › Modes).

## Time-lapse for battery cameras
**Settings › Recording › Time-lapse** takes a still picture from each battery camera every few minutes. In **History**, pick a day and click **Time-lapse** in the toolbar to turn that day's stills into a short video.

## Your day in 60 seconds
In **History**, pick a day and click **Day in 60 seconds** (the film icon). Doorstep stitches a few seconds of every visit into one short video, with the time and who it was written on each part, and opens it. Great for "what happened while I was away?".

## Keeping clips Ring has
With a Ring subscription, Ring deletes clips after a while. **Settings › Parcels › Keep clips** copies people and doorbell clips into a folder you choose, so they're kept for as long as you like.
