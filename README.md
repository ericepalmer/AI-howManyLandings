# Pattern Watcher

A Mac and iPad app that counts **individual landings** at small airports from live OpenSky Network ADS-B — including each touch-and-go in the pattern, which FlightAware-style “one arrival per flight” feeds usually miss.

## What it does

- Sidebar of airports you add by ICAO (or name). Tracking runs while the app is open. Use the **−** control on a row to drop a field and stop tracking it.
- Map centered on the selected field, with every ADS-B aircraft out to **10 NM** (adjustable). Each tail keeps its full in-range path, altitude, and speed from ground ops until it leaves — or from entering until ground ops end — and engagement memory stays for **one hour** after the last update. After a landing, the trail stays on the map for **5 minutes** (full color when selected in the log, faintly visible otherwise).
- Hour and day landing counts, plus a log of each landing and takeoff by tail number and type.

A **landing** is recorded when an aircraft’s ADS-B `onGround` goes false→true **near this airport’s runway** (about 0.75 NM of a runway, or 1 NM of the field if runway data is missing). A **takeoff** is the opposite edge under the same proximity rule. Traffic at neighboring airports inside the coverage ring is ignored.

The right **Pattern** panel lists every **airborne** aircraft within **5 NM** and at or below **2,000 ft AGL**, closest first. Each gets a stable color for its track and swatch. The chip next to the callsign shows the inferred pattern leg and runway in the same slot as **Lost**. **Departure → Crosswind → Downwind** are sequential (each needs the previous status plus the matching profile), so a 360 or an ADS-B gap will not invent them. **Base, Final, and Flare** are profile-only: lined up, AGL, and speed are enough, with no prior-leg requirement. If none of those match, the chip is **Maneuvering**. Aircraft on the ground stay on the map (status **Ground**) but appear on the list only after they become airborne. Lost targets stay on the list for **5 minutes**. The landing/takeoff **log** lives in the lower two-thirds of the left airport pane.

## Open in Xcode

1. Open `HowManyLandings.xcodeproj` and select the **PatternWatcher** scheme.
2. Choose an **iPad simulator** or **My Mac**.
3. Select your Development Team in the target’s Signing settings if you are running on a device.
4. Run.

Anonymous OpenSky access works, but the daily credit budget is small. For more than a short session, add OAuth2 client credentials:

1. Create an account at [opensky-network.org](https://opensky-network.org).
2. Account → API Client → create a client and copy the ID and secret.
3. In the app, open **Settings** (key icon, or macOS Pattern Watcher → Settings) and paste them.

Polling a 10 NM box costs **1 credit per airport per request**. The default interval is 10 seconds.

## ADS-B limits

OpenSky only sees aircraft that are broadcasting and within range of a feeder. Many light aircraft drop position reports on the ground, so a full-stop may be inferred when the target goes silent after a low pass near the runway. Coverage at some small fields is thin; a local feeder helps a lot.

Airport coordinates and runways come from [OurAirports](https://ourairports.com/data/) (public domain). US traffic-pattern direction (left vs right per runway end) comes from FAA NASR `RIGHT_HAND_TRAFFIC_PAT_FLAG` data, via [SkyReady’s published CSV](https://skyready.app/data/right-traffic-airports.csv) (CC BY 4.0). Rebuild the catalog with:

```bash
python3 scripts/build_airports.py
```
