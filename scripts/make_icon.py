#!/usr/bin/env python3
"""Write a 1024×1024 PPM and convert it to the app icon PNG."""

from pathlib import Path

SIZE = 1024
NAVY = (18, 32, 56)
AMBER = (232, 168, 56)
WHITE = (245, 246, 248)
YELLOW = (255, 214, 90)
GRAY = (90, 110, 140)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def main() -> None:
    pixels = [[NAVY for _ in range(SIZE)] for _ in range(SIZE)]

    def fill_rect(x0, y0, x1, y1, color):
        for y in range(max(0, y0), min(SIZE, y1)):
            row = pixels[y]
            for x in range(max(0, x0), min(SIZE, x1)):
                row[x] = color

    def fill_circle(cx, cy, radius, color):
        r2 = radius * radius
        for y in range(max(0, cy - radius), min(SIZE, cy + radius + 1)):
            dy = y - cy
            for x in range(max(0, cx - radius), min(SIZE, cx + radius + 1)):
                dx = x - cx
                if dx * dx + dy * dy <= r2:
                    pixels[y][x] = color

    # Subtle radial lightening
    for y in range(SIZE):
        for x in range(SIZE):
            dx = (x - SIZE / 2) / SIZE
            dy = (y - SIZE / 2) / SIZE
            t = max(0.0, 1.0 - (dx * dx + dy * dy) * 1.6)
            r, g, b = pixels[y][x]
            pixels[y][x] = (lerp(r, 36, t * 0.35), lerp(g, 58, t * 0.35), lerp(b, 88, t * 0.35))

    # Runway
    fill_rect(460, 140, 564, 900, GRAY)
    fill_rect(478, 140, 546, 900, (48, 54, 62))
    for y in range(170, 880, 56):
        fill_rect(504, y, 520, y + 28, YELLOW)

    # Threshold bars
    for i in range(6):
        fill_rect(468 + i * 14, 150, 476 + i * 14, 210, WHITE)
        fill_rect(468 + i * 14, 830, 476 + i * 14, 890, WHITE)

    # Airplane chevron
    cx, cy = 512, 430
    for i, width in enumerate(range(90, 8, -4)):
        y = cy + i * 5
        fill_rect(cx - width, y, cx + width, y + 6, AMBER)
    fill_rect(cx - 14, cy - 40, cx + 14, cy + 130, AMBER)
    fill_rect(cx - 70, cy + 70, cx + 70, cy + 88, AMBER)

    dest_ppm = Path("/tmp/howmanylandings-icon.ppm")
    dest_ppm.write_bytes(
        f"P6 {SIZE} {SIZE} 255\n".encode("ascii")
        + bytes(c for row in pixels for pixel in row for c in pixel)
    )
    print(f"Wrote {dest_ppm}")


if __name__ == "__main__":
    main()
