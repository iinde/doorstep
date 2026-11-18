# Doorstep: command centre and recorder

## Recorder (no Ring subscription needed)
Settings › Recording. Chosen cameras (default: everything not on batteries) stay live as pinned streams. Video goes into rolling 4-second segments; the last three are kept as pre-roll. When this Mac sees a person (or any movement, if chosen), or Ring logs an event, the segments are kept until 10 seconds after it ends, then joined into one MP4 in ~/Movies/Doorstep Recordings/<day>/. Retention 3 to 90 days. The Mac is kept from idle sleep while recording. Battery cameras get a still every few minutes instead; History turns a day of stills into a time-lapse.

## Microphone
Live sessions are listen-only. Hold to talk reconnects that one camera two-way (about 2 seconds); leaving the camera reconnects it listen-only and releases the mic.

## Live analysis
Twice a second per recorded or on-screen camera: a 64x36 greyscale difference for motion, Vision person boxes when something moved, "approaching" when the tallest person grows by a third over about 2 seconds. Approaching at the doorbell opens the live panel before anyone rings.

## Command centre (⌘K from the Wall)
- **Live**: every camera large, people boxed, approaching highlighted. Right-click to float a camera.
- **Map**: Apple satellite imagery centred on the home position Ring reports. Place each camera and set its heading; cones show what each sees. Moments on different cameras within 3 minutes of each other draw a trail.
- **Radar**: cameras as sectors from their map headings; live people as blips (angle from position across the picture, distance from size); the last hour as fading echoes.
- **Insights**: two weeks of history: moments by hour and by day, deliveries by time of day, busiest cameras, the postie's usual window, and visits at hours that are rare for that camera.
