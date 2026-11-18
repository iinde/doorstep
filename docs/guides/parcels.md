# Parcels

Doorstep keeps track of what's coming, reminds you on the day, shows you the door when someone arrives, and matches each delivery to the clip of it arriving.

## "I'm expecting a parcel"
Click the **box icon** at the top of the Wall (or **I'm expecting a parcel** in History › Parcels, or **⌘N** there).

- **Tracking number**: paste it in. Doorstep recognises Royal Mail, UPS, Amazon, DHL, Yodel and Evri numbers from their shape; otherwise pick the carrier.
- **From**: the shop, so it reads *"Your ASOS parcel"*.
- **I know which day it's coming**: tick it and choose the day.

On the day:
- You get **one reminder** (*"Your ASOS parcel is out for delivery"*) with a **Watch door** button.
- The Wall shows an **Expecting** line with **Track** and **Watch door**.
- **Delivery watch**: if someone walks up to your doorbell while a parcel is due, the doorbell pops up live even if they don't ring.

## Getting updates on where it is
- **Track** opens the carrier's own tracking page in your browser. Always works, nothing to set up.
- **Live status in Doorstep**: get a free API key from [17TRACK](https://www.17track.net/en/api) and paste it into **Settings › Parcels**. Doorstep then checks your parcels every 30 minutes and fills in the carrier's expected delivery day.
- **Delivery emails**: drag emails from Mail or Outlook onto the box in **History › Parcels**, or paste one in with **Paste email**. Doorstep reads the tracking number, the carrier, the shop and the status ("out for delivery", "delivered", "sorry we missed you").
- **Automatically from Outlook** (optional): in **Settings › Parcels**, connect an Outlook.com or Microsoft 365 mailbox. It's read-only and only delivery emails are looked at. Microsoft asks every app to register, so you'll need a free "Application (client) ID": the steps are in Settings.

## When it arrives
When a parcel is delivered (from tracking, an email, or Doorstep seeing a parcel left on your step), Doorstep links it to the **visit that brought it**. Open the parcel in **History › Parcels** to see its timeline (added, on its way, out for delivery, who came, delivered) and click **Watch** to see it arrive.

## Rain warning
If a parcel's been left on your step and it starts raining, you'll get *"It's raining on your parcel"*. This asks the free Open-Meteo weather service about the weather near you (your position rounded to about 1 km). Turn it off in **Settings › Parcels**.

## Add to Calendar
For a parcel with a due day, use the **⋯** menu › **Add to Calendar**. Doorstep asks to add events only; it can't read your calendar.
