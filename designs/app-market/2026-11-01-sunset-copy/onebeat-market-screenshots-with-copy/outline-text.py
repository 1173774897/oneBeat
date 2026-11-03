#!/usr/bin/env python3
"""Build portable SVG glyph outlines from the typography layout."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parent


def rounded(value: float) -> float:
    return round(value, 5)


def svg_number(value: float) -> str:
    result = f"{value:.5f}".rstrip("0").rstrip(".")
    return "0" if result in ("", "-0") else result


class Outliner:
    def __init__(self, font_path: Path):
        self.font = TTFont(font_path)
        self.cmap = self.font.getBestCmap()
        self.units_per_em = self.font["head"].unitsPerEm
        self.glyph_sets = {}
        self.recordings = {}

    def glyph_set(self, weight: float):
        if weight not in self.glyph_sets:
            self.glyph_sets[weight] = self.font.getGlyphSet(location={"wght": weight})
        return self.glyph_sets[weight]

    def outline(self, text: str, style: dict) -> dict:
        size = float(style["fontSize"])
        weight = float(style["weight"])
        spacing = float(style["letterSpacing"])
        scale = size / self.units_per_em
        shear = math.tan(math.radians(float(style["slantDegrees"])))
        glyph_set = self.glyph_set(weight)
        path_pen = SVGPathPen(glyph_set, ntos=svg_number)
        bounds_pen = BoundsPen(glyph_set)
        advance = 0.0

        for index, char in enumerate(text):
            if ord(char) not in self.cmap:
                raise ValueError(f"Font lacks U+{ord(char):04X} ({char}) in {text!r}")
            glyph_name = self.cmap[ord(char)]
            glyph = glyph_set[glyph_name]
            key = (weight, glyph_name)
            if key not in self.recordings:
                recording = RecordingPen()
                glyph.draw(recording)
                self.recordings[key] = recording
            # Glyphs use an upward Y axis. The affine flips it for SVG, while
            # positive shear moves the glyph tops right without moving baselines.
            affine = (scale, 0, shear * scale, -scale, advance, 0)
            recording = self.recordings[key]
            recording.replay(TransformPen(path_pen, affine))
            recording.replay(TransformPen(bounds_pen, affine))
            advance += glyph.width * scale
            if index < len(text) - 1:
                advance += spacing

        left, top, right, bottom = bounds_pen.bounds or (0, 0, 0, 0)
        return {
            "text": text,
            "path": path_pen.getCommands(),
            "bounds": {
                "x": rounded(left),
                "y": rounded(top),
                "width": rounded(right - left),
                "height": rounded(bottom - top),
            },
            "advance": rounded(advance),
        }


def main() -> None:
    layout = json.loads((ROOT / "layout.json").read_text())
    font_path = Path(layout["font"]["path"])
    outliner = Outliner(font_path)
    styles = layout["styles"]
    pages = []
    for page in layout["pages"]:
        fields = {
            "eyebrow": (f"ONEBEAT / {page['id']}", "eyebrow"),
            "first": (page["headline"][0], page["headlineStyle"]),
            "second": (page["headline"][1], page["headlineStyle"]),
            "subtitle": (page["subtitle"], page["subtitleStyle"]),
        }
        if page.get("note"):
            fields["note"] = (page["note"], "note")
        texts = {
            name: outliner.outline(text, styles[style_name])
            for name, (text, style_name) in fields.items()
        }
        pages.append({"id": page["id"], "texts": texts})

    result = {
        "font": {
            "family": layout["font"]["family"],
            "path": str(font_path),
            "sha256": hashlib.sha256(font_path.read_bytes()).hexdigest(),
        },
        "pages": pages,
    }
    (ROOT / "text-paths.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    )
    print(json.dumps({
        "pages": len(pages),
        "textRuns": sum(len(page["texts"]) for page in pages),
        "glyphSets": sorted(outliner.glyph_sets),
        "cachedGlyphs": len(outliner.recordings),
        "missingGlyphs": 0,
        "headlineBounds": [
            {"page": page["id"], "first": page["texts"]["first"]["bounds"],
             "second": page["texts"]["second"]["bounds"]}
            for page in pages
        ],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
