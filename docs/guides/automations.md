# Automations and Siri

Doorstep doesn't need to know about your lights, speakers or phone. It hands off to **Shortcuts**, the app built into your Mac, which already knows about all of them.

## How it works
In **Settings › Automations**, click **Add automation** and choose:
- **When**: the doorbell rings, a person is seen, someone walks up to the door, a delivery arrives, a parcel is left, or a parcel is taken.
- **At**: any camera, or one in particular.
- **Run**: one of your shortcuts.
- **Only after dark** (optional): uses sunset and sunrise where your cameras are.

Click **Test** to try it. Each automation runs at most once a minute. The shortcut receives a line of text describing what happened (for example *"Someone walks up to the door at Front Door."*), which you can use in a message or notification.

## Recipes

### Porch light on when someone arrives after dark
1. Open **Shortcuts** › **+** (new shortcut). Name it **Porch light on**.
2. Add the action **Control Home** (search "Home"). Choose your porch light and set it to **On**.
3. Optional: add **Wait** 120 seconds, then **Control Home** › porch light **Off**.
4. In Doorstep: *Someone walks up to the door* at *Front Door* › run **Porch light on** › **only after dark**.

### Pause the music when the doorbell rings
1. New shortcut **Pause music** with the action **Play/Pause** set to **Pause** (or **Set Volume** to 20%).
2. In Doorstep: *Doorbell rings* › run **Pause music**.

### Text yourself when a parcel arrives
1. New shortcut **Parcel text**. Add **Send Message**, choose yourself, and for the message use **Shortcut Input** (the text Doorstep sends).
2. In Doorstep: *A parcel is left* › run **Parcel text**.

### Flash the lights if a parcel is taken
1. New shortcut **Parcel alarm**: **Control Home** › living room lights **On**, **Wait** 1 second, **Off**, repeat a few times.
2. In Doorstep: *A parcel is taken* › run **Parcel alarm**.

## Say it out loud
**Settings › Automations › Say what's happening out loud** speaks short announcements in your Mac's British voice: *"Someone's at the door"*, *"DPD at the front door"*, *"A parcel was left"*.

## Siri and Shortcuts actions
Doorstep adds these to Siri and the Shortcuts app (no setup needed):
- **"Show my door in Doorstep"** / **Show Camera**: opens a camera live in the top-right panel.
- **"What happened at home in Doorstep"** / **What Happened at Home Today**: reads out today's summary.
- **"Any parcels today in Doorstep"** / **Parcels Due Today**.

Use them in your own shortcuts too: for example, a morning shortcut that reads out what's due today.
