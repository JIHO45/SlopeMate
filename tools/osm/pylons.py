#!/usr/bin/env python3
"""공중 리프트(체어·곤돌라 등)의 지주 좌표를 OSM에서 받아 osm-<리조트>.json의 lift에 pylons로 넣는다 (R50, K).

사용: python3 tools/osm/pylons.py [리조트 ID ...]   (없으면 osm 파일이 있는 전체)
- 리프트 way의 노드 중 aerialway=pylon인 것만, way 순서대로. 선 방향(아래→위, orient_lifts.py)에 맞춰 뒤집는다.
- 승·하차장(선 양 끝)은 넣지 않는다. 지주가 없으면 키를 넣지 않는다(앱은 지면을 따라 그린다).
- OSM API(way/full)로 리프트마다 한 번 받는다. tools/osm/build.py가 끝에 이걸 부르므로 다시 받아도 유지된다.
- 데이터: © OpenStreetMap contributors, ODbL.
"""
import json, math, subprocess, sys, time
from pathlib import Path

MAPS = Path(__file__).resolve().parents[2] / "SlopeMate/Resources/maps"
AERIAL = {"chair_lift", "gondola", "cable_car", "mixed_lift"}
API = "https://api.openstreetmap.org/api/0.6/way/{}/full.json"


def fetch(way_id):
    for i in range(4):
        out = subprocess.run(["curl", "-s", "-A", "SlopeMate-osm-tool", API.format(way_id)], capture_output=True, text=True).stdout
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            time.sleep(3 * 2 ** i)
    return None


def meters(a, b):
    return math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 111320 * math.cos(math.radians(a[0])))


def pylons_of(doc, line):
    els = doc["elements"]
    way = next(e for e in els if e["type"] == "way")
    nodes = {e["id"]: e for e in els if e["type"] == "node"}
    pts = [[round(nodes[n]["lat"], 6), round(nodes[n]["lon"], 6)] for n in way["nodes"]
           if nodes[n].get("tags", {}).get("aerialway") == "pylon"]
    # 앱 선(아래→위)의 시작점에 가까운 쪽이 먼저 오게
    if pts and meters(pts[0], line[0]) > meters(pts[-1], line[0]):
        pts.reverse()
    return pts


def add(rid):
    path = MAPS / f"osm-{rid}.json"
    doc = json.loads(path.read_text())
    n = 0
    for l in doc["lifts"]:
        l.pop("pylons", None)
        if l["kind"] not in AERIAL:
            continue
        got = fetch(l["osm_id"].split("/")[1])
        p = pylons_of(got, l["line"]) if got else []
        if p:
            l["pylons"] = p
            n += 1
        time.sleep(1)
    path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{rid}: 지주 있는 리프트 {n}/{sum(l['kind'] in AERIAL for l in doc['lifts'])}")


if __name__ == "__main__" and sys.argv[1:] == ["--test"]:   # 자체 확인
    doc = {"elements": [{"type": "way", "nodes": [1, 2, 3, 4]},
                        {"type": "node", "id": 1, "lat": 37.0, "lon": 128.0},
                        {"type": "node", "id": 2, "lat": 37.001, "lon": 128.0, "tags": {"aerialway": "pylon"}},
                        {"type": "node", "id": 3, "lat": 37.002, "lon": 128.0, "tags": {"aerialway": "pylon"}},
                        {"type": "node", "id": 4, "lat": 37.003, "lon": 128.0}]}
    assert pylons_of(doc, [[37.003, 128.0], [37.0, 128.0]]) == [[37.002, 128.0], [37.001, 128.0]]
    assert pylons_of(doc, [[37.0, 128.0], [37.003, 128.0]]) == [[37.001, 128.0], [37.002, 128.0]]
    print("ok")
elif __name__ == "__main__":
    for rid in sys.argv[1:] or sorted(p.stem[4:] for p in MAPS.glob("osm-*.json")):
        add(rid)
