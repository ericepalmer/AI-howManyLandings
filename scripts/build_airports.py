#!/usr/bin/env python3
"""Download OurAirports data and emit a compact Airports.json catalog."""

from __future__ import annotations

import csv
import io
import json
import math
import re
import urllib.request
from pathlib import Path

AIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
RUNWAYS_URL = "https://davidmegginson.github.io/ourairports-data/runways.csv"
# FAA NASR right-traffic runway ends, republished CC BY 4.0 from SkyReady.
RIGHT_TRAFFIC_URL = "https://skyready.app/data/right-traffic-airports.csv"

KEEP_TYPES = {
    "small_airport",
    "medium_airport",
    "large_airport",
    "seaplane_base",
}

METERS_PER_FOOT = 0.3048
EARTH_RADIUS_M = 6371000.0


def fetch(url: str) -> str:
    cache = Path("/tmp/ourairports") / Path(url).name
    if cache.exists():
        return cache.read_text(encoding="utf-8", errors="replace")
    req = urllib.request.Request(url, headers={"User-Agent": "HowManyLandings/1.0 (airport catalog)"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(text, encoding="utf-8")
    return text


def offset(lat: float, lon: float, heading_deg: float, distance_m: float) -> tuple[float, float]:
    if distance_m == 0:
        return lat, lon
    bearing = math.radians(heading_deg)
    lat1 = math.radians(lat)
    lon1 = math.radians(lon)
    ang = distance_m / EARTH_RADIUS_M
    lat2 = math.asin(
        math.sin(lat1) * math.cos(ang) + math.cos(lat1) * math.sin(ang) * math.cos(bearing)
    )
    lon2 = lon1 + math.atan2(
        math.sin(bearing) * math.sin(ang) * math.cos(lat1),
        math.cos(ang) - math.sin(lat1) * math.sin(lat2),
    )
    return math.degrees(lat2), math.degrees(lon2)


def r(value: float, digits: int = 5) -> float:
    return round(float(value), digits)


def parse_float(raw: str | None) -> float | None:
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def parse_int(raw: str | None) -> int | None:
    value = parse_float(raw)
    if value is None:
        return None
    return int(round(value))


def is_icao_like(code: str) -> bool:
    return len(code) == 4 and code.isalpha()


def normalize_runway_ident(ident: str) -> str:
    ident = ident.strip().upper()
    match = re.match(r"^0*(\d{1,2})([LCRWUE]?)$", ident)
    if match:
        return f"{int(match.group(1)):02d}{match.group(2)}"
    return ident


def load_right_traffic(text: str) -> tuple[dict[str, set[str]], set[str]]:
    """Map airport ident → right-traffic runway ends. Also airports where every end is right."""
    by_code: dict[str, set[str]] = {}
    all_right: set[str] = set()
    reader = csv.DictReader(io.StringIO(text))
    for row in reader:
        code = (row.get("code") or "").strip().upper()
        if not code:
            continue
        ends = {
            normalize_runway_ident(part)
            for part in (row.get("right_traffic_runway_ends") or "").split()
            if part.strip()
        }
        if ends:
            by_code[code] = ends
        flag = (row.get("all_ends_right_traffic") or "").strip().lower()
        if flag in {"yes", "true", "1"}:
            all_right.add(code)
    return by_code, all_right


def is_usable_code(code: str) -> bool:
    if not code:
        return False
    if any(ch.isspace() for ch in code):
        return False
    if len(code) < 2 or len(code) > 12:
        return False
    return all(ch.isalnum() or ch in "-_" for ch in code)


def main() -> None:
    dest = Path(__file__).resolve().parents[1] / "HowManyLandings" / "Resources" / "Airports.json"
    dest.parent.mkdir(parents=True, exist_ok=True)

    print("Downloading airports.csv …")
    airports_csv = fetch(AIRPORTS_URL)
    print("Downloading runways.csv …")
    runways_csv = fetch(RUNWAYS_URL)
    print("Downloading right-traffic runway ends …")
    try:
        right_csv = fetch(RIGHT_TRAFFIC_URL)
        right_by_code, all_right_codes = load_right_traffic(right_csv)
        print(f"  {len(right_by_code)} airports with published right traffic")
    except Exception as exc:  # noqa: BLE001
        print(f"  skipped ({exc})")
        right_by_code, all_right_codes = {}, set()

    by_ident: dict[str, dict] = {}
    aliases: dict[str, str] = {}

    reader = csv.DictReader(io.StringIO(airports_csv))
    for row in reader:
        if row.get("type") not in KEEP_TYPES:
            continue
        lat = parse_float(row.get("latitude_deg"))
        lon = parse_float(row.get("longitude_deg"))
        if lat is None or lon is None:
            continue

        ident = (row.get("ident") or "").strip().upper()
        icao = (row.get("icao_code") or "").strip().upper()
        gps = (row.get("gps_code") or "").strip().upper()
        local = (row.get("local_code") or "").strip().upper()
        codes = []
        for code in (icao, gps, ident, local):
            if is_usable_code(code) and code not in codes:
                codes.append(code)
        if not codes:
            continue

        if is_icao_like(icao):
            primary = icao
        elif is_icao_like(gps):
            primary = gps
        elif is_usable_code(ident):
            primary = ident
        else:
            primary = codes[0]
        elevation = parse_int(row.get("elevation_ft")) or 0
        record = {
            "icao": primary,
            "name": (row.get("name") or primary).strip(),
            "city": (row.get("municipality") or "").strip(),
            "lat": r(lat),
            "lon": r(lon),
            "elevFt": elevation,
            "runways": [],
            "ident": ident,
        }
        # Prefer ICAO-coded rows when duplicates exist.
        existing = by_ident.get(primary)
        if existing is None or (icao == primary and existing.get("ident") != existing.get("icao")):
            by_ident[primary] = record
        for code in codes:
            aliases[code] = primary

    reader = csv.DictReader(io.StringIO(runways_csv))
    for row in reader:
        if (row.get("closed") or "0") in {"1", "true", "TRUE"}:
            continue
        ident = (row.get("airport_ident") or "").strip().upper()
        icao = aliases.get(ident)
        if not icao or icao not in by_ident:
            continue
        length = parse_int(row.get("length_ft"))
        if not length or length < 200:
            continue
        le_hdg = parse_int(row.get("le_heading_degT"))
        he_hdg = parse_int(row.get("he_heading_degT"))
        if le_hdg is None and he_hdg is None:
            continue
        if le_hdg is None:
            le_hdg = (he_hdg + 180) % 360
        if he_hdg is None:
            he_hdg = (le_hdg + 180) % 360

        airport = by_ident[icao]
        le_lat = parse_float(row.get("le_latitude_deg"))
        le_lon = parse_float(row.get("le_longitude_deg"))
        he_lat = parse_float(row.get("he_latitude_deg"))
        he_lon = parse_float(row.get("he_longitude_deg"))
        half_m = length * METERS_PER_FOOT / 2.0
        if le_lat is None or le_lon is None:
            le_lat, le_lon = offset(airport["lat"], airport["lon"], le_hdg + 180, half_m)
        if he_lat is None or he_lon is None:
            he_lat, he_lon = offset(airport["lat"], airport["lon"], le_hdg, half_m)

        airport["runways"].append(
            {
                "le": (row.get("le_ident") or "").strip(),
                "he": (row.get("he_ident") or "").strip(),
                "hdg": le_hdg,
                "lenFt": length,
                "leLat": r(le_lat),
                "leLon": r(le_lon),
                "heLat": r(he_lat),
                "heLon": r(he_lon),
            }
        )

    def right_ends_for(record: dict) -> tuple[set[str], bool]:
        keys = {record["icao"], record.get("ident") or ""}
        ends: set[str] = set()
        all_right = False
        for key in keys:
            if not key:
                continue
            ends |= right_by_code.get(key, set())
            if key in all_right_codes:
                all_right = True
            if len(key) == 3:
                padded = f"K{key}"
                ends |= right_by_code.get(padded, set())
                if padded in all_right_codes:
                    all_right = True
        return ends, all_right

    airports = []
    right_flags = 0
    for icao, record in sorted(by_ident.items()):
        runways = record["runways"][:8]
        ends, all_right = right_ends_for(record)
        packed = []
        for rw in runways:
            le_right = 1 if all_right or normalize_runway_ident(rw["le"]) in ends else 0
            he_right = 1 if all_right or normalize_runway_ident(rw["he"]) in ends else 0
            right_flags += le_right + he_right
            packed.append(
                [
                    rw["le"],
                    rw["he"],
                    rw["hdg"],
                    rw["lenFt"],
                    rw["leLat"],
                    rw["leLon"],
                    rw["heLat"],
                    rw["heLon"],
                    le_right,
                    he_right,
                ]
            )
        airports.append(
            [
                icao,
                record["name"],
                record["city"],
                record["lat"],
                record["lon"],
                record["elevFt"],
                packed,
            ]
        )

    alias_pairs = sorted({(alias, primary) for alias, primary in aliases.items() if alias != primary})
    payload = {"airports": airports, "aliases": alias_pairs}
    dest.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {len(airports)} airports, {len(alias_pairs)} aliases -> {dest}")
    print(f"Right-traffic runway ends flagged: {right_flags}")
    print(f"Size: {dest.stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
