#!/usr/bin/env python3
"""리프트 선을 고도 낮은 끝 → 높은 끝으로 맞춘다 (R50, K). 앱은 리프트 선이 아래→위라고 본다(MapProjection.angle).

사용: python3 tools/dem/orient_lifts.py [리조트 ID ...]   (없으면 dem 파일이 있는 전체)
- osm-<리조트>.json의 lift line만 뒤집는다. 양 끝 고도는 dem-<리조트>.json 격자의 가장 가까운 칸.
- tools/osm/build.py가 끝에 이걸 부르므로 OSM을 다시 받아도 유지된다.
"""
import array, base64, json, sys
from pathlib import Path

MAPS = Path(__file__).resolve().parents[2] / "SlopeMate/Resources/maps"


def orient(rid):
    osm, dem = MAPS / f"osm-{rid}.json", MAPS / f"dem-{rid}.json"
    if not (osm.exists() and dem.exists()):
        return
    g = json.loads(dem.read_text())
    h = array.array("h", base64.b64decode(g["heights"]))
    if sys.byteorder != "little":
        h.byteswap()

    def z(p):
        r = min(max(round((g["north"] - p[0]) / g["step"]), 0), g["rows"] - 1)
        c = min(max(round((p[1] - g["west"]) / g["step"]), 0), g["cols"] - 1)
        return h[r * g["cols"] + c] / 10

    doc = json.loads(osm.read_text())
    flipped = []
    for l in doc["lifts"]:
        a, b = z(l["line"][0]), z(l["line"][-1])
        if b < a:
            l["line"].reverse()
            flipped.append(f"{l['id']} {l.get('name')} {a:.0f}→{b:.0f}m")
    if flipped:
        osm.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{rid}: 뒤집음 {len(flipped)}/{len(doc['lifts'])}" + "".join(f"\n  {f}" for f in flipped))


def main():
    for rid in sys.argv[1:] or sorted(p.stem[4:] for p in MAPS.glob("dem-*.json")):
        orient(rid)


if __name__ == "__main__":
    main()
