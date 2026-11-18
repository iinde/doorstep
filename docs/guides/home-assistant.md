# Home Assistant and Homebridge

Doorstep can send what it works out (who came, parcels, the mode, battery) to **Home Assistant** through an MQTT broker you already run, such as the Mosquitto add-on. Everything appears in Home Assistant by itself, with no YAML needed. Homebridge users can do the same with an MQTT plugin.

It's optional, it only talks to your own broker, and nothing goes anywhere else.

## Set it up
1. In Home Assistant, install the **Mosquitto broker** add-on and the **MQTT** integration (Settings › Devices & services › Add integration › MQTT). Create a Home Assistant user for Doorstep.
2. In Doorstep: **Settings › Automations › Home Assistant (MQTT)**. Enter your broker's address (for example `homeassistant.local`), port `1883` (or `8883` with TLS), and the user's name and password. Click **Connect**.
3. In Home Assistant, open **Settings › Devices & services › MQTT**. You'll see a **Doorstep** device and one device per camera.

## What appears
For each camera:
- **Person** (on when someone's seen, off after a minute)
- **Doorbell** (on when it rings, off after 30 seconds)
- **Last visitor** (DPD, Royal Mail, Mum, Person…)
- **Last event** (when)
- **Parcel** (left or taken)
- **Battery** (battery cameras)
- **Snapshot** (a picture of the latest event)

And for Doorstep itself:
- **Mode**: Home, Away, Night or Quiet. You can change it from Home Assistant, and Doorstep follows.
- **Parcels due today**

## Ideas
- Turn the hall light on when **Last visitor** is a courier after dark.
- Set Doorstep to **Away** when everyone's phone leaves home.
- Show the **Snapshot** on a wall tablet when the **Doorbell** turns on.
- Announce *"Mum's here"* on your smart speakers.

## Topics, for the curious
Everything lives under `doorstep/` (state) and `homeassistant/` (discovery). The full list is in the source: [`HomeAssistantDiscovery.swift`](../../app/OpenRingPackage/Sources/OpenRingFeature/Integrations/MQTT/HomeAssistantDiscovery.swift).
