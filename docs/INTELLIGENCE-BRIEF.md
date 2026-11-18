# Doorstep Intelligence: brief

Extends DESIGN-BRIEF.md. Same palette, type and motion. Nothing here adds a new colour.

## 1. The promise

Doorstep tells you **who** it was, not just that something moved, and ties what the cameras saw to the parcels you are expecting. Everything runs on this Mac first. The cloud is a backup you switch on, never the default.

## 2. "Who was it" (on-device first)

Every clip already gets three frames read on this Mac. On top of Person / Vehicle / Animal / Parcel, each clip now gets an **identity**:

| Signal | How | Strength |
|---|---|---|
| Writing | Apple text recognition reads "DHL", "Royal Mail", "DPD", "Evri", "Amazon", "UPS", "FedEx", "Yodel", "Parcelforce", "InPost" on vans, jackets, bags | Strong in daylight, close up |
| Livery colour | Dominant colours inside the person and vehicle boxes, matched to each carrier's livery | Supporting only, daytime only (IR at night is grey) |
| Your corrections | "That was Royal Mail" on any clip stores the frame's feature print; later clips are matched against what you taught it | Gets better every week |
| Claude (optional) | Three frames to Claude vision when the above can't decide | Off by default, your own key, daily cap |

Output: a Moment title like **"Royal Mail at Front Door"**, a carrier mark on the card, and a confidence the UI uses quietly (below 0.6 we say "Delivery driver", never a guessed brand).

## 3. Parcels

- **Sources:** Microsoft sign-in (Graph, Mail.Read, read only, device-code sign-in, works with Outlook.com and work accounts) and **Paste**: paste a tracking number or the whole delivery email.
- **Parsing:** carrier from sender and number shape; status from wording ("out for delivery", "delivered", "attempted", "collected"); retailer from the sender name.
- **Matching:** a "delivered" email within 20 minutes of a Front Door Moment that shows a person (or the same carrier) links the two. The parcel card then shows the clip.
- **Expecting today** line on the Wall, and a Parcels section in History.
- Only delivery-looking mail is read for parsing; nothing is stored except the parcel facts.

## 4. Doorstep zone: parcel left / taken

Compare the bottom third of the doorbell frame at the start and end of each Front Door clip. A new box-like object that stays = **Parcel left**. A box that was there and is gone = **Parcel taken** (alert, ember). Labelled "Looks like" because it is a heuristic.

## 5. Telling you

- Notifications carry the snapshot and say who: "DPD left a parcel at Front Door".
- **Daily brief** at the top of History and as an optional 8pm notification: deliveries, callers, first and last activity, quiet overnight or not. Written on-device from Moments.
- **Archive:** optional, copies People and Doorbell clips to a folder you pick (a NAS share works) so they outlive Ring's history window.

## 7. "I'm expecting a parcel"

One button, on the Wall and in Parcels. Enter the tracking number (carrier is worked out from its shape, or picked), optionally the shop and the day it's due.

- **Status:** every carrier gets a "Track" link that opens its own tracking page in your browser. For status inside Doorstep, add your own free 17TRACK API key in Settings: it checks every 30 minutes and reads the status and the carrier's delivery estimate. No key, no background checking; delivery emails still update it.
- **Reminder:** when a parcel is due today or goes out for delivery, one notification: "Your ASOS parcel is out for delivery. Doorstep will show you the door when someone arrives." The Wall shows an Expecting line with **Watch door** and **Track**.
- **Delivery watch:** while a parcel is out for delivery, a person at the doorbell opens the live call panel ("Possible delivery at Front Door") without anyone needing to ring.
- **Ties it together:** each parcel has a timeline: added, dispatched, out for delivery, who came (from the clip), parcel left, delivered. Tap the clip to watch it arrive.

## 8. Not in this round

Ring push (instant events), MobileCLIP text search, familiar faces, widgets and Siri. Each is its own phase with its own brief. Familiar faces only ever for people you name, inside your own boundary (UK GDPR).
