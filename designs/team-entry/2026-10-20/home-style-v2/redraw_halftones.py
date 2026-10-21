"""Rebuild the ticket's vector dot artwork; no generated character art is involved."""

from dataclasses import dataclass
from math import cos, sin, radians, sqrt
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
DEST = ROOT / "entry/src/main/resources/rawfile/comic/decor"
DOT_PITCH = 15.0
GRID_ANGLE = -27.0


@dataclass(frozen=True)
class Patch:
    name: str
    color: str
    width: int
    height: int
    center_x: float
    center_y: float
    radius_x: float
    radius_y: float
    tilt: float
    max_dot_radius: float


PATCHES = [
    Patch("ink", "#11151A", 160, 280, 0, 132, 142, 142, -16, 5.4),
    Patch("lilac", "#AB7DE6", 160, 280, 162, 142, 144, 150, 19, 5.5),
    Patch("coral", "#FFB493", 200, 320, 106, 160, 72, 170, 31, 5.0),
    Patch("ink-corner", "#11151A", 180, 220, 5, 140, 160, 104, -29, 5.7),
    Patch("lilac-corner", "#AB7DE6", 180, 220, 5, 140, 160, 104, -29, 5.7),
    Patch("ink-cloud", "#11151A", 220, 200, 120, 108, 110, 86, -24, 5.2),
    Patch("lilac-cloud", "#AB7DE6", 180, 300, 98, 153, 89, 150, -12, 5.4),
]


def smoothstep(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def circles(patch: Patch):
    grid_angle = radians(GRID_ANGLE)
    tilt = radians(patch.tilt)
    for row in range(-36, 37):
        for col in range(-36, 37):
            u = (col + (row % 2) * 0.5) * DOT_PITCH
            v = row * DOT_PITCH * sqrt(3) / 2
            x = patch.width / 2 + u * cos(grid_angle) - v * sin(grid_angle)
            y = patch.height / 2 + u * sin(grid_angle) + v * cos(grid_angle)
            if not (0 <= x <= patch.width and 0 <= y <= patch.height):
                continue
            dx, dy = x - patch.center_x, y - patch.center_y
            a = dx * cos(tilt) + dy * sin(tilt)
            b = -dx * sin(tilt) + dy * cos(tilt)
            field = 1 - (a / patch.radius_x) ** 2 - (b / patch.radius_y) ** 2
            # Shrink individual dots into curved white space. The previous
            # linear row ramp ended with large dots at a rectangular image edge.
            edge = smoothstep(min(y / 28, (patch.height - y) / 28))
            if patch.name.endswith("cloud"):
                # Free-standing hero artwork has no paper border to hide a
                # cropped side, unlike patches printed flush to a ticket edge.
                edge *= smoothstep(min(x / 24, (patch.width - x) / 24))
            radius = patch.max_dot_radius * smoothstep(field) ** 0.78 * edge
            radius *= 1 + 0.035 * sin(col * 1.7 + row * 2.3)
            if radius >= 0.28:
                yield x, y, radius


def main():
    for patch in PATCHES:
        content = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{patch.width}" '
            f'height="{patch.height}" viewBox="0 0 {patch.width} {patch.height}">',
            f'  <g fill="{patch.color}">',
        ]
        for x, y, radius in circles(patch):
            content.append(f'    <circle cx="{x:.2f}" cy="{y:.2f}" r="{radius:.2f}"/>')
        content += ["  </g>", "</svg>", ""]
        (DEST / f"ticket-halftone-{patch.name}.svg").write_text("\n".join(content))


if __name__ == "__main__":
    main()
