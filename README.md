# How Many Landings

A Mac and iPad app that counts **individual landings** at small airports from live OpenSky Network ADS-B — including each touch-and-go in the pattern, which FlightAware-style “one arrival per flight” feeds usually miss.

## What it does

- Sidebar of airports you add by ICAO (or name). Tracking runs while the app is open.
- Map centered on the selected field, with every ADS-B aircraft out to **10 NM** and the last **10 minutes** of in-range track.
- Hour and day landing counts, plus a log of each landing and takeoff by tail number and type.

A **landing** is recorded when an aircraft:

1. Descends through landing altitude (or arrives already on short final)
2. Gets low and slow near a runway — or hovers there for about a minute (helicopters)
3. Either climbs away (**touch-and-go**) or stays on the surface (**full-stop**)

High-speed overflights are ignored. The climb after a touch-and-go is not counted as a separate takeoff; a later departure after a full stop is.

## Open in Xcode

1. Open `HowManyLandings.xcodeproj`.
2. Choose an **iPad simulator** or **My Mac**.
3. Select your Development Team in the target’s Signing settings if you are running on a device.
4. Run.

Anonymous OpenSky access works, but the daily credit budget is small. For more than a short session, add OAuth2 client credentials:

1. Create an account at [opensky-network.org](https://opensky-network.org).
2. Account → API Client → create a client and copy the ID and secret.
3. In the app, open **Settings** (key icon, or macOS How Many Landings → Settings) and paste them.

Polling a 10 NM box costs **1 credit per airport per request**. The default interval is 10 seconds.

## ADS-B limits

OpenSky only sees aircraft that are broadcasting and within range of a feeder. Many light aircraft drop position reports on the ground, so a full-stop may be inferred when the target goes silent after a low pass near the runway. Coverage at some small fields is thin; a local feeder helps a lot.

Airport coordinates and runways come from [OurAirports](https://ourairports.com/data/) (public domain). Rebuild the catalog with:

```bash
curl -L -o /tmp/ourairports/airports.csv https://davidmegginson.github.io/ourairports-data/airports.csv
curl -L -o /tmp/ourairports/runways.csv https://davidmegginson.github.io/ourairports-data/runways.csv
python3 scripts/build_airports.py
```
