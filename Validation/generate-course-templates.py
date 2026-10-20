#!/usr/bin/env python3
"""Extend the pinned KanjiVG templates for the offline course (CC BY-SA 3.0)."""
import argparse
import concurrent.futures
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("kana", ROOT / "Validation/generate-kana-templates.py")
kana = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kana)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--alphabet", choices=["hiragana", "katakana"])
    parser.add_argument("--kanji", default="")
    args = parser.parse_args()
    destination = ROOT / "App/CourseTemplates.json"
    result = json.loads(destination.read_text()) if destination.exists() else json.loads((ROOT / "App/KanaTemplates.json").read_text())
    glyphs = {g["symbol"]: g for g in result["glyphs"]}
    kana.CACHE.mkdir(parents=True, exist_ok=True)
    voiced = [("がぎぐげご", "ga gi gu ge go"), ("ざじずぜぞ", "za ji zu ze zo"),
              ("だぢづでど", "da ji zu de do"), ("ばびぶべぼ", "ba bi bu be bo"),
              ("ぱぴぷぺぽ", "pa pi pu pe po"), ("ゃゅょっ", "small-ya small-yu small-yo small-tsu")]
    jobs = []
    if args.alphabet:
        for row, (signs, readings) in enumerate(voiced, 10):
            for sign, reading in zip(signs, readings.split(), strict=True):
                if args.alphabet == "katakana":
                    sign = chr(ord(sign) + 0x60)
                if sign not in glyphs:
                    jobs.append((args.alphabet, row, sign, reading))
    for sign in dict.fromkeys(args.kanji):
        if sign not in glyphs:
            jobs.append((None, 0, sign, sign))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for glyph in pool.map(kana.glyph, jobs):
            glyphs[glyph["symbol"]] = glyph
    if args.alphabet:
        for base, prefix in [("き", "ky"), ("し", "sh"), ("ち", "ch"), ("に", "ny"),
                             ("ひ", "hy"), ("み", "my"), ("り", "ry"), ("ぎ", "gy"),
                             ("じ", "j"), ("び", "by"), ("ぴ", "py")]:
            for small, vowel in [("ゃ", "a"), ("ゅ", "u"), ("ょ", "o")]:
                left, right = base, small
                if args.alphabet == "katakana":
                    left, right = chr(ord(base) + 0x60), chr(ord(small) + 0x60)
                # Two writing cells compressed into one board; retain each glyph's
                # stroke order and the small kana's native relative proportions.
                strokes = [[{"x": round(p["x"] * 0.55, 6), "y": p["y"]} for p in s] for s in glyphs[left]["strokes"]]
                strokes += [[{"x": round(0.45 + p["x"] * 0.55, 6), "y": p["y"]} for p in s] for s in glyphs[right]["strokes"]]
                glyphs[left + right] = dict(alphabet=args.alphabet, row=20, symbol=left + right, reading=prefix + vowel, strokes=strokes)
    for glyph in glyphs.values():
        glyph["reading"] = glyph["reading"].replace("-", " ")
    result["glyphs"] = sorted(glyphs.values(), key=lambda g: g["symbol"])
    result["modifications"] = "SVG curves normalized to the 109-unit viewBox. Course combinations use two horizontal writing cells."
    destination.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Generated {len(glyphs)} course templates at pinned revision {kana.REVISION}")


if __name__ == "__main__":
    main()
