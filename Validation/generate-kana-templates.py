#!/usr/bin/env python3
"""Generate offline kana stroke templates from pinned KanjiVG SVGs (CC BY-SA 3.0).

Uses only the Python standard library. Cached SVGs stay in /tmp; the derived
App/KanaTemplates.json is distributable under CC BY-SA 3.0, separately from code.
"""
import concurrent.futures
import json
import math
from pathlib import Path
import re
import urllib.request
import xml.etree.ElementTree as ET

REVISION = "70a0b7ae0c18ceb5cb358274b029cce0234a43bc"
ROOT = Path(__file__).resolve().parents[1]
CACHE = Path("/tmp/yohaku-kanjivg") / REVISION
ROWS = [
    ("あいうえお", "a i u e o"), ("かきくけこ", "ka ki ku ke ko"),
    ("さしすせそ", "sa shi su se so"), ("たちつてと", "ta chi tsu te to"),
    ("なにぬねの", "na ni nu ne no"), ("はひふへほ", "ha hi fu he ho"),
    ("まみむめも", "ma mi mu me mo"), ("やゆよ", "ya yu yo"),
    ("らりるれろ", "ra ri ru re ro"), ("わをん", "wa wo n"),
]


def sample_path(path):
    """Flatten SVG M/L/H/V/C/S commands, including implicit/relative segments."""
    tokens = re.findall(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?", path)
    points, current, previous_control, previous_command = [], (0, 0), None, None
    index, command = 0, None
    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        kind = command.upper()
        size = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4}.get(kind)
        if size is None:
            raise ValueError(f"Unsupported SVG command {command}: {path}")
        values = list(map(float, tokens[index:index + size]))
        index += size
        relative = command.islower()

        def pair(offset):
            return (values[offset] + (current[0] if relative else 0),
                    values[offset + 1] + (current[1] if relative else 0))

        if kind in ("C", "S"):
            if kind == "C":
                first, second, end = pair(0), pair(2), pair(4)
            else:
                first = (2 * current[0] - previous_control[0], 2 * current[1] - previous_control[1]) \
                    if previous_command in ("C", "S") else current
                second, end = pair(0), pair(2)
            for step in range(1, 41):
                t, u = step / 40, 1 - step / 40
                points.append(tuple(u**3 * current[d] + 3*u*u*t*first[d] + 3*u*t*t*second[d] + t**3*end[d] for d in (0, 1)))
            previous_control = second
        else:
            end = pair(0) if kind in ("M", "L") else \
                (values[0] + (current[0] if relative else 0), current[1]) if kind == "H" else \
                (current[0], values[0] + (current[1] if relative else 0))
            points.append(end)
            previous_control = None
        current, previous_command = end, kind
        if kind == "M":
            command = "l" if relative else "L"
    assert len(points) >= 2
    # Remove duplicate adjacent samples, then keep approximately 1 SVG unit spacing.
    filtered = [points[0]]
    for point in points[1:-1]:
        if math.dist(filtered[-1], point) >= 0.6:
            filtered.append(point)
    filtered.append(points[-1])
    return [{"x": round(x / 109, 6), "y": round(y / 109, 6)} for x, y in filtered]


def glyph(spec):
    alphabet, row, symbol, reading = spec
    filename = f"{ord(symbol):05x}.svg"
    cached = CACHE / filename
    if not cached.exists():
        url = f"https://raw.githubusercontent.com/KanjiVG/kanjivg/{REVISION}/kanji/{filename}"
        with urllib.request.urlopen(url, timeout=30) as response:
            cached.write_bytes(response.read())
    svg = ET.fromstring(cached.read_bytes())
    paths = [node.attrib["d"] for node in svg.iter("{http://www.w3.org/2000/svg}path")]
    assert paths, symbol
    return dict(alphabet=alphabet, row=row, symbol=symbol, reading=reading,
                strokes=[sample_path(path) for path in paths])


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    specs = []
    for alphabet in ("hiragana", "katakana"):
        for row, (symbols, readings) in enumerate(ROWS):
            for symbol, reading in zip(symbols, readings.split(), strict=True):
                if alphabet == "katakana":
                    symbol = chr(ord(symbol) + 0x60)
                specs.append((alphabet, row, symbol, reading))
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        glyphs = list(pool.map(glyph, specs))
    result = dict(source="https://kanjivg.tagaini.net", revision=REVISION,
                  copyright="Ulrich Apel and KanjiVG contributors",
                  license="CC BY-SA 3.0", licenseURL="https://creativecommons.org/licenses/by-sa/3.0/",
                  modifications="SVG cubic curves flattened and normalized to the 109-unit viewBox.", glyphs=glyphs)
    destination = ROOT / "App/KanaTemplates.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Generated {len(glyphs)} kana templates: {destination}")


if __name__ == "__main__":
    main()
