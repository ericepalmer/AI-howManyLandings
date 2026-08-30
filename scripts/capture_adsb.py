#!/usr/bin/env python3
"""Capture adsb.lol polls as JSONL for Pattern Watcher replay."""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import certifi

    SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except Exception:  # noqa: BLE001
    SSL_CONTEXT = ssl.create_default_context()

ENDPOINTS = [
    "https://opendata.adsb.fi/api/v2/lat/{lat}/lon/{lon}/dist/{dist}",
    "https://api.adsb.lol/v2/lat/{lat}/lon/{lon}/dist/{dist}",
]


def fetch_poll(lat: float, lon: float, dist_nm: float, timeout: float = 15.0) -> dict:
    headers = {
        "Accept": "application/json",
        "User-Agent": "PatternWatcher/1.0 (aviation traffic monitor)",
    }
    last_error: Exception | None = None
    for template in ENDPOINTS:
        url = template.format(lat=f"{lat:.5f}", lon=f"{lon:.5f}", dist=f"{dist_nm:.1f}")
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=SSL_CONTEXT) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                if isinstance(payload, dict):
                    return payload
                raise ValueError("unexpected JSON type")
        except Exception as exc:  # noqa: BLE001 — try next endpoint
            last_error = exc
    assert last_error is not None
    raise last_error


def capture_set(
    *,
    out_path: Path,
    lat: float,
    lon: float,
    dist_nm: float,
    duration_sec: float,
    interval_sec: float,
    set_index: int,
    total_sets: int,
) -> dict:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    ends_at = started + duration_sec
    polls = 0
    aircraft_samples = 0
    errors = 0

    print(
        f"SET_START {set_index}/{total_sets} file={out_path.name} "
        f"duration_min={duration_sec / 60:.0f} interval_s={interval_sec:.0f}",
        flush=True,
    )

    with out_path.open("w", encoding="utf-8") as fh:
        while True:
            now = time.time()
            if now >= ends_at:
                break
            try:
                poll = fetch_poll(lat, lon, dist_nm)
                # Stamp wall-clock capture time for debugging; keep API `now` for replay.
                poll["_capturedAt"] = datetime.now(timezone.utc).isoformat()
                fh.write(json.dumps(poll, separators=(",", ":")) + "\n")
                fh.flush()
                polls += 1
                ac = poll.get("ac") or poll.get("aircraft") or []
                if isinstance(ac, list):
                    aircraft_samples += len(ac)
                print(
                    f"POLL set={set_index} n={polls} aircraft={len(ac) if isinstance(ac, list) else 0} "
                    f"elapsed_s={now - started:.0f}",
                    flush=True,
                )
            except Exception as exc:  # noqa: BLE001
                errors += 1
                print(f"POLL_ERROR set={set_index} err={exc}", flush=True)

            remaining = ends_at - time.time()
            if remaining <= 0:
                break
            time.sleep(min(interval_sec, remaining))

    summary = {
        "set": set_index,
        "file": str(out_path),
        "polls": polls,
        "aircraftSamples": aircraft_samples,
        "errors": errors,
        "durationSec": round(time.time() - started, 1),
    }
    print(f"SET_DONE {json.dumps(summary)}", flush=True)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--icao", default="KAVQ")
    parser.add_argument("--lat", type=float, required=True)
    parser.add_argument("--lon", type=float, required=True)
    parser.add_argument("--dist-nm", type=float, default=10.0)
    parser.add_argument("--duration-min", type=float, default=30.0)
    parser.add_argument("--interval-sec", type=float, default=10.0)
    parser.add_argument("--sets", type=int, default=5)
    parser.add_argument("--outdir", type=Path, required=True)
    args = parser.parse_args()

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    print(
        f"CAPTURE_START icao={args.icao} sets={args.sets} "
        f"duration_min={args.duration_min} interval_s={args.interval_sec} "
        f"lat={args.lat} lon={args.lon} dist_nm={args.dist_nm}",
        flush=True,
    )

    summaries = []
    for i in range(1, args.sets + 1):
        out = args.outdir / f"{args.icao}_{stamp}_set{i:02d}.jsonl"
        summaries.append(
            capture_set(
                out_path=out,
                lat=args.lat,
                lon=args.lon,
                dist_nm=args.dist_nm,
                duration_sec=args.duration_min * 60.0,
                interval_sec=args.interval_sec,
                set_index=i,
                total_sets=args.sets,
            )
        )

    print(f"CAPTURE_ALL_DONE {json.dumps(summaries)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
