# Alerts and modes

## Choose what alerts you
**Settings › Alerts › Alert me about** lists everything Doorstep can tell you about:

| Kind | On by default | What it means |
|---|---|---|
| Doorbell rings | ✅ | Someone pressed the bell |
| People | ✅ | A person was seen |
| Parcels left or taken | ✅ | A parcel appeared on, or disappeared from, your step |
| Vehicles | | A car or van in view (parked cars are ignored once learnt) |
| Animals | | A dog, cat or fox, or barking was heard |
| Any other movement | | Everything else: trees, rain, shadows |
| Familiar faces | ✅ | Someone you've named (needs Familiar faces on) |
| Unusual activity | ✅ | A person at an hour that's rare for that camera |

## Zones
In **Settings › General › Cameras**, click **Zone…** next to a camera. You'll see a fresh picture from it. Click round the area that matters, like your path, drive or garden, then **Save**. People and movement outside the zone won't alert you or start a recording (a doorbell press still does). Leave it empty to watch the whole picture.

## Loitering
**Settings › Alerts › Loitering** tells you when someone stays in view for a while (20 seconds to 5 minutes): *"Someone's been hanging around Side Gate for 40 seconds."* It works on cameras Doorstep is recording or showing in the command centre, and respects zones. It's also an automation trigger, so you could turn the lights on.

## On your phone
**Settings › Alerts › On your phone** sends the same alerts, with the picture, to your phone:
- **ntfy** (no account): install the free ntfy app, click **Make a random topic** in Doorstep, and subscribe to that topic in the app. Anyone who knows the topic can read it, so keep it random.
- **Pushover**: paste your user key and an application token from pushover.net.
- **Telegram**: create a bot with @BotFather, paste its token and your chat ID.

Click **Send a test** to check. Only alert kinds you've switched on are sent, and modes apply.

## One alert per visit
A visit often makes several clips: walking up, ringing, waiting, leaving. With **One alert per visit** on, the first clip sends an alert and the rest quietly update it, so you get one notification that ends up describing the whole visit.

## What every alert says
Every alert has a picture and a plain sentence about what happened, worked out on your Mac:
- *"A DPD courier walked up to the front door, rang the doorbell and left a parcel."*
- *"Someone walked away from the front door. Dog barking could be heard."*
- *"Mum walked up to the front door and rang the doorbell."*
- *"Movement in the garden. Nobody was seen."*

The same sentence appears when you open the visit in History. With the optional Claude check switched on, a short description from Claude is added for visits your Mac couldn't work out.

## Modes
Like an alarm panel, modes decide what Doorstep does depending on whether you're in, out or asleep.

Turn on **Settings › Alerts › Use modes**, then for each mode tick which cameras **alert** you and which **record** (recording needs Settings › Recording on):

| Mode | Starts as |
|---|---|
| **Home** | Doorbell alerts only |
| **Away** | Every camera alerts and records |
| **Night** | Every camera alerts; switch on the schedule to use it automatically |
| **Quiet** | No alerts at all (recording carries on) |

Switch modes:
- From the **Home** menu at the top of the Wall.
- **Automatically**: "Switch to Night automatically" from, say, 23:00 until 07:00.
- With **Siri** or a **Shortcut**: *"Set Doorstep to Away"*. Combine it with a Shortcuts personal automation, like "When I leave home", to set Away for you.

Doorbell rings always come through, whatever the mode, except in Quiet.

## Familiar faces (beta)
Off unless you switch it on in **Settings › Alerts › Familiar faces**.

1. Open a visit with the person in it in **History**.
2. Click **Find faces in this clip**.
3. Type their name under their face, or pick an existing name.

From then on, alerts and History say *"Mum at Front Door"* instead of *"Person at Front Door"*. Name a few clips of the same person (different days, different light) and it gets better.

Only faces you name are kept, as numbers describing the face plus one small picture, in `~/Library/Application Support/Doorstep`. Recognition happens on your Mac. Remove someone any time with **Forget**. Please only name people who are happy to be recognised.
