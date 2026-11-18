# Who was it?

Doorstep looks at every visit on your Mac and tries to tell you *who* it was, not just that something moved. Nothing leaves your Mac for this unless you switch on the optional Claude check.

## People, couriers and parcels
For each clip with something in it, Doorstep reads a few frames and works out:
- **A person, a vehicle, an animal or a parcel.**
- **Which courier**, by reading the name off vans, jackets and bags: DPD, Royal Mail, Parcelforce, Amazon, Evri, DHL, UPS, FedEx, Yodel, InPost, and the supermarket vans (Tesco, Sainsbury's, Asda, Ocado, Waitrose). A few liveries are recognised by colour too.
- **Parcel left or taken.** On your doorbell, Doorstep compares the doorstep at the start and end of a clip. A box that appears is *Parcel left*; one that disappears is *Parcel taken*, and you'll be told.

So instead of "Motion at Front Door" you see **"DPD left a parcel"** or **"Royal Mail at Front Door"**.

At night the cameras see in black and white and writing is harder to read, so you may see **"Delivery driver"** instead of a name.

## Teach it
Open a visit in **History** and click **Who was it?**. Choose the company, or **Not a delivery**. Doorstep remembers what that visitor looked like and recognises similar visits next time. **Settings › Intelligence** shows how many you've taught it, and can forget them.

## Hearing
Doorstep listens to clips with people in them (or doorbell rings) using Apple's built-in sound recognition, and notices:
- **Knocking**: you'll see *"Someone knocked at Front Door"* even if nobody rang.
- **Dogs barking**, **breaking glass**, **alarms** and **shouting**.

Turn it off in **Settings › Intelligence › Hearing**.

## Number plates (off by default)
Switch on **Settings › Intelligence › Read number plates** and Doorstep reads UK plates from clips and live video. Give a plate a name (*"My car"*) and you'll get a notification when it arrives. Plates are kept on your Mac for 90 days.

Other people's number plates are their personal data. Only use this for your own drive. [More on the law](https://ico.org.uk/for-the-public/domestic-cctv-systems-guidance-for-people-using-cctv/).

## Search
In **History**, type in the search box at the top right. Plain English works:
- *DPD last week*
- *person at the garden yesterday evening*
- *knock*
- *postie* (finds Royal Mail)
- *parcel left this morning*
- *doorbell tuesday*
- a number plate, like *AB12 CDE*

## What was said
Switch on **Settings › Intelligence › Write down what visitors say** and Doorstep turns speech in doorbell and visitor clips into text, using Apple's on-device recognition (macOS asks for permission once). You'll see it in History under **What was said**, it's added to the alert's description, and it's searchable: try *"behind the bin"*.

## Local AI with Ollama
If you run [Ollama](https://ollama.com) on your Mac (or another computer at home), Doorstep can ask a vision model to describe each visit in a sentence, and to name the courier when it couldn't read one. Nothing leaves your home and it costs nothing.

1. Install Ollama, then in Terminal: `ollama pull gemma3` (or `qwen2.5vl`, `llava`).
2. **Settings › Intelligence › Local AI**: switch it on and pick the model.

Local AI is used before the optional Claude check.

## Search by what's in the picture
Switch it on in **Settings › Intelligence › Picture search** (a one-off download of about 108 MB of Apple's MobileCLIP model from Hugging Face). Doorstep then looks at each visit's picture on your Mac, so you can search for things that aren't written anywhere: *"red van"*, *"dog"*, *"man in a hat"*, *"pushchair"*, *"umbrella"*. Matches appear under **In the picture** in your search results.

It works best in daylight; at night the cameras see in black and white, so colours won't match. History fills in pictures for the last week in the background while it's open.

## Optional: Ask Claude
For visits your Mac can't work out, Doorstep can ask Claude, an AI by Anthropic. It sends **three still frames** (never the video or sound) and gets back who it was. It's **off by default**, uses **your own** Anthropic key (billed to you, usually well under a penny per visit), only for doorbell visits with a person in them, and stops at a daily limit you choose. Set it up in **Settings › Intelligence**.

## The daily brief
At the top of each day in History there's a one-line summary: deliveries (and from whom), rings, visits, first and last activity, and whether the night was quiet. Turn on **Settings › Parcels › Daily brief** to get it as an evening notification.
