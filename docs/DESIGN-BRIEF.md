# Doorstep: design brief

Working name. Built on the open-ring core (Ring client, WebRTC streams, event history), rebuilt from the UI up as our own app. No Ring blue, no Ring-app look.

## 1. The soul

Doorstep is a quiet window onto the outside of your home that lives in the Mac menu bar. It answers one question fast: **what happened out there today, and what is happening right now?** It is calm by default and only raises its voice when a person is at the door. It reads like a page of your day, not a control panel.

## 2. The signature element: the Day Strip

One thin horizontal band per camera covering the last 24 hours, stacked under the live wall. Every event is a mark on its band. The right-hand edge of every band is *now*, and it touches the live tile above it.

- Hover a mark: the tile above shows that moment (clip thumbnail), with the time in mono.
- Click a mark: the tile plays the clip in place. Move off: the tile returns to live.
- Read at a glance: a quiet day is a nearly empty strip, a busy afternoon is visibly dense, and a doorbell press is the only amber mark.

This is the screenshot moment: four live views sitting on top of your whole day.

## 3. Surfaces

| Surface | Job |
|---|---|
| **Wall** (menu bar popover) | All cameras live at once, the Day Strip, and the last few Moments. The 5-second check. |
| **Focus** (inside the popover) | One camera large: talk, light, siren, zoom. Click a tile to enter; Esc to leave. |
| **Review** (a real Mac window) | Full history: calendar, Moments queue with reviewed state, scrubbable timeline, search, export. |
| **Doorbell call** (floating panel) | Someone rang: live view and talk, front and centre, dismissed when answered or ignored. |

## 4. Intelligence (earned, private, cheap)

1. **Moments, not clips.** Events on one camera within 3 minutes of each other merge into one Moment (idea from Frigate's review items). The feed shows Moments.
2. **Three tiers, each with a job:** *Doorbell* (someone rang), *People* (a person was seen), *Activity* (other motion). Uses Ring's own `cv_properties.person_detected` when present.
3. **On-device detection** (phase 3): Apple Vision runs over a few frames of each downloaded clip to tag person, vehicle, animal, package. Free, private, no tokens.
4. **Reviewed state.** A Moment is unreviewed until you open it. The menu bar icon only signals unreviewed Doorbell or People Moments, never plain motion.
5. **Ask** (optional, a button, never automatic): natural-language search and descriptions through Claude with the user's own key, in keeping with token-conscious AI.

## 5. Type

- **SF Pro Text** for everything you read. Sizes: 11 (meta), 13 (body), 15 (titles). No all-caps section labels.
- **SF Mono, tabular digits** for every time and duration, so times line up and read as data.
- **SF Pro Display, 22 semibold** for exactly one thing per screen: the current time on the Wall, the date in Review.

## 6. Palette (each colour has one job)

| Token | Value | Job |
|---|---|---|
| `night` | #0E0F11 | The background. Warm near-black, like looking out at dusk. |
| `slate` | #1A1C20 | Raised surfaces: tiles before video arrives, the strip track. |
| `paper` | #F2EFE9 | Primary text, and People marks on the strip. |
| `ash` | #8A8D93 | Secondary text, Activity marks. |
| `porchlight` | #F5B544 | The only accent. Doorbell presses and unreviewed People. If it's amber, a human needs your attention. |
| `ember` | #E5484D | Errors and the siren. Nothing else. |

No green/yellow/red status pills. Connection state is shown by the tile itself (video, a still, or a quiet line of text).

## 7. Motion: "settle"

Things arrive and settle: spring(response 0.35, damping 0.85). Scrubbing is immediate, with no animation, because it's direct manipulation. Live tiles crossfade (0.25s) from still to video. Nothing bounces or pulses except the *now* edge of the strip, which breathes slowly (2.4s) while live video is flowing.

## 8. Layout

- Wall popover: 640pt wide, 16pt outer margin, 8pt gutters, an 8pt grid throughout.
- Tiles are 16:9 with a 10pt radius and no borders. The camera name is typeset straight onto the video (bottom-left, over a soft gradient), not in a chip.
- 1 camera: full width. 2: side by side. 3 or 4: 2×2. 5 or more: 3 across.
- The doorbell's portrait feed is centre-cropped to 16:9 on the Wall, and shown full portrait in Focus.

## 9. What we're removing

The bottom drawer, the always-visible AI text box, the zoom percentage footer, the pager dots, the arrow-to-switch camera model, and the Ring-blue accent.

## 10. Constraints, said plainly

- **Battery cameras:** four simultaneous live sessions drain batteries (Ring's own multi-cam view is also capped at four). Phase 2: battery cameras show a refreshed snapshot on the Wall and go live on hover or click; wired cameras stay live.
- **Event thumbnails:** Ring's `snapshot_url` came back empty in our data, so thumbnails mean downloading the clip and grabbing a frame. Cached locally, fetched lazily, newest first.
- **Recordings and history length** depend on the user's Ring plan.
- Ring's API is private and can change. Every decode stays tolerant, as fixed this week.

## 11. Phases

1. **Wall + Day Strip** in the popover: this brief's one fully resolved screen.
2. Focus rebuilt, snapshot mode for battery cameras, Moments feed with reviewed state.
3. Review window: calendar with per-day markers, timeline scrubbing, Moments queue, export.
4. On-device detection tags, daily digest, Ask, and the doorbell call panel.
