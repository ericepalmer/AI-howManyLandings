#!/usr/bin/env python3
"""Generate the Pattern Watcher app icon (1024×1024 PNG)."""

from pathlib import Path
import struct
import subprocess
import zlib

SIZE = 1024
NAVY = (14, 28, 48)
NAVY_LIGHT = (28, 52, 82)
AMBER = (232, 168, 56)
AMBER_BRIGHT = (255, 214, 90)
CYAN = (72, 196, 220)
WHITE = (245, 246, 248)
RUNWAY = (58, 68, 78)
RUNWAY_DARK = (42, 48, 56)
YELLOW = (255, 214, 90)

ROOT = Path(__file__).resolve().parents[1]
ICON_PATH = ROOT / "PatternWatcher" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"


def lerp(a: int, b: int, t: float) -> int:
    return int(a + (b - a) * t)


def main() -> None:
    pixels = [[NAVY for _ in range(SIZE)] for _ in range(SIZE)]

    def set_pixel(x: int, y: int, color: tuple[int, int, int]) -> None:
        if 0 <= x < SIZE and 0 <= y < SIZE:
            pixels[y][x] = color

    def fill_rect(x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int]) -> None:
        for y in range(max(0, y0), min(SIZE, y1)):
            for x in range(max(0, x0), min(SIZE, x1)):
                pixels[y][x] = color

    def fill_circle(cx: int, cy: int, radius: int, color: tuple[int, int, int]) -> None:
        r2 = radius * radius
        for y in range(max(0, cy - radius), min(SIZE, cy + radius + 1)):
            dy = y - cy
            for x in range(max(0, cx - radius), min(SIZE, cx + radius + 1)):
                dx = x - cx
                if dx * dx + dy * dy <= r2:
                    pixels[y][x] = color

    def stroke_line(x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int], width: int = 3) -> None:
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(steps + 1):
            t = i / steps
            x = int(x0 + (x1 - x0) * t)
            y = int(y0 + (y1 - y0) * t)
            fill_circle(x, y, width, color)

    # Subtle radial vignette
    for y in range(SIZE):
        for x in range(SIZE):
            dx = (x - SIZE / 2) / SIZE
            dy = (y - SIZE / 2) / SIZE
            t = max(0.0, 1.0 - (dx * dx + dy * dy) * 1.4)
            r, g, b = pixels[y][x]
            pixels[y][x] = (
                lerp(r, NAVY_LIGHT[0], t * 0.45),
                lerp(g, NAVY_LIGHT[1], t * 0.45),
                lerp(b, NAVY_LIGHT[2], t * 0.45),
            )

    # Runway through center
    fill_rect(470, 160, 546, 840, RUNWAY)
    fill_rect(488, 160, 526, 840, RUNWAY_DARK)
    for y in range(190, 810, 58):
        fill_rect(502, y, 518, y + 26, YELLOW)

    # Traffic pattern loop (left traffic) — amber path
    pattern = [
        (360, 620),
        (360, 380),
        (620, 380),
        (620, 620),
        (512, 720),
        (360, 620),
    ]
    for i in range(len(pattern) - 1):
        stroke_line(*pattern[i], *pattern[i + 1], AMBER, width=5)

    # Small aircraft on downwind
    ax, ay = 620, 500
    fill_circle(ax, ay, 10, WHITE)
    fill_rect(ax - 22, ay - 4, ax + 22, ay + 4, AMBER_BRIGHT)

    # Stylized "watcher" eye — upper right
    eye_cx, eye_cy = 760, 300
    fill_circle(eye_cx, eye_cy, 118, WHITE)
    fill_circle(eye_cx, eye_cy, 100, NAVY_LIGHT)
    fill_circle(eye_cx + 8, eye_cy - 6, 52, CYAN)
    fill_circle(eye_cx + 18, eye_cy - 10, 22, NAVY)
    fill_circle(eye_cx + 28, eye_cy - 18, 8, WHITE)

    ppm_path = Path("/tmp/pattern-watcher-icon.ppm")
    ppm_path.write_bytes(
        f"P6 {SIZE} {SIZE} 255\n".encode("ascii")
        + bytes(c for row in pixels for pixel in row for c in pixel)
    )

    # Prefer sips on macOS; fall back to raw PNG writer.
    try:
        subprocess.run(
            ["sips", "-s", "format", "png", str(ppm_path), "--out", str(ICON_PATH)],
            check=True,
            capture_output=True,
        )
        print(f"Wrote {ICON_PATH}")
        return
    except (subprocess.CalledProcessError, FileNotFoundError):
        write_png(ICON_PATH, pixels)
        print(f"Wrote {ICON_PATH} (PNG fallback)")


def write_png(path: Path, pixels: list[list[tuple[int, int, int]]]) -> None:
    """Minimal RGB PNG encoder (no external deps)."""
    height = len(pixels)
    width = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b in row:
            raw.extend((r, g, b))

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


if __name__ == "__main__":
    main()
