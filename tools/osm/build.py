#!/usr/bin/env python3
"""OSM 슬로프·리프트를 받아 앱 내장 지도 파일로 만든다 (R9, R50, 05-design C).

사용: python3 tools/osm/build.py [리조트 ID ...]   (없으면 전체)
출력: SlopeMate/Resources/maps/osm-<리조트>.json

- 우리 ID(<리조트>-s01, -l01)는 이전 출력의 OSM ID로 이어 붙여 유지한다. 새 선만 다음 번호를 받는다.
- 선은 2m 기준으로 줄이고 좌표는 소수 5자리(약 1m)로 저장한다.
- 리프트 선은 끝에 tools/dem/orient_lifts.py로 아래→위로 맞춘다(dem 파일이 있을 때). 공중 리프트 지주는 tools/osm/pylons.py.
- 데이터: © OpenStreetMap contributors, ODbL.
"""
import json, math, subprocess, sys, time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/dem"))
from orient_lifts import orient  # noqa: E402
from pylons import add as add_pylons  # noqa: E402
RESORTS = ROOT / "SlopeMate/Resources/resorts.json"
AREAS = Path(__file__).with_name("areas.json")
OUT = ROOT / "SlopeMate/Resources/maps"
SERVER = "https://overpass-api.de/api/interpreter"
LIFTS = "chair_lift|gondola|cable_car|mixed_lift|drag_lift|t-bar|j-bar|platter|rope_tow|magic_carpet"
EPS_M = 2.0
# 슬로프 태그가 붙었지만 스키 슬로프가 아닌 OSM 요소. OSM 원본은 그대로 두고 여기서만 뺀다.
NOT_SLOPES = {
    "way/545967313": "비발디 스노위하우스(눈놀이 시설)",
    "way/1037974232": "웰리힐리 하프파이프 선, 면과 중복",
    "way/535718863": "지산 실버 정상→큰 슬로프 선, 공식 맵 5번(블루 정상 출발)과 같은 면에 겹침",
    "way/535718862": "지산 위 선과 5번을 잇는 짧은 선, 공식 맵에 없음",
}
# 공식 슬로프 맵과 난이도가 다른 OSM 선. 앱 단계(초급·중급·상급·최상급)로, 공식 '중상급'은 중급.
DIFFICULTY_FIXES = {
    "way/535718864": ("advanced", "지산 5번 상급"),
    "way/535718861": ("expert", "지산 6번 최상급"),
    "way/535718866": ("intermediate", "지산 7번 중상급"),
    "way/535718855": ("intermediate", "지산 2·3번 중급(오렌지·뉴오렌지)"),
    "way/535718856": ("intermediate", "지산 2·3번 중급(오렌지·뉴오렌지)"),
}


def overpass(query):
    # curl: python.org 빌드는 시스템 인증서를 못 써서 urllib이 실패한다
    for i in range(6):
        out = subprocess.run(["curl", "-s", "-A", "SlopeMate-osm-tool", "--data-urlencode",
                              f"data={query}", SERVER], capture_output=True, text=True).stdout
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            time.sleep(5 * 2 ** i)
    sys.exit("Overpass 응답 없음")


def query_for(resort, spec):
    if "area" in spec:
        kind, oid = spec["area"].split("/")
        scope, sel = f"{kind}({oid});map_to_area->.a;", "(area.a)"
    else:
        scope, sel = "", f"(around:{spec['around']},{resort['latitude']},{resort['longitude']})"
    return (f'[out:json][timeout:120];{scope}('
            f'way["piste:type"="downhill"]{sel};'
            f'relation["piste:type"="downhill"]{sel};'
            f'way["aerialway"~"^({LIFTS})$"]{sel};'
            f');out geom tags;')


def simplify(pts):
    """Ramer-Douglas-Peucker, 지역 평면 근사(m). 닫힌 도형은 반으로 나눠 줄인다."""
    if len(pts) < 3:
        return pts
    if pts[0] == pts[-1]:
        m = len(pts) // 2
        return simplify(pts[:m + 1])[:-1] + simplify(pts[m:])
    k = math.cos(math.radians(pts[0][0])) * 111320
    xy = [(p[1] * k, p[0] * 110540) for p in pts]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        (ax, ay), (bx, by) = xy[a], xy[b]
        L = math.hypot(bx - ax, by - ay) or 1e-9
        best, idx = 0.0, -1
        for i in range(a + 1, b):
            d = abs((bx - ax) * (ay - xy[i][1]) - (ax - xy[i][0]) * (by - ay)) / L
            if d > best:
                best, idx = d, i
        if best > EPS_M:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k_ in zip(pts, keep) if k_]


def line(geom):
    return [[round(a, 5), round(b, 5)] for a, b in simplify([(g["lat"], g["lon"]) for g in geom])]


KO_DIFFICULTY = [("최상급", "expert"), ("상급", "advanced"), ("중급", "intermediate"), ("초급", "easy")]


def difficulty_of(tags):
    if "piste:difficulty" in tags:
        return tags["piste:difficulty"]
    name = name_of(tags) or ""
    return next((v for k, v in KO_DIFFICULTY if k in name), None)


def name_of(tags):
    return tags.get("name:ko") or tags.get("name")


def build(resort, spec):
    data = overpass(query_for(resort, spec))
    els = data["elements"]
    slopes, lifts = [], []
    in_relation = set()
    for e in els:
        if e["type"] == "relation":
            ways = [m for m in e.get("members", []) if m["type"] == "way" and "geometry" in m]
            in_relation |= {m["ref"] for m in ways}
            # 구성 선 ID도 남겨, 선이 relation으로 묶이거나 풀려도 같은 우리 ID를 찾는다
            slopes.append({"osm_ids": [f"relation/{e['id']}"] + [f"way/{m['ref']}" for m in ways], "tags": e["tags"],
                           "lines": [line(m["geometry"]) for m in ways]})
    for e in els:
        if e["type"] != "way":
            continue
        t = e["tags"]
        if "aerialway" in t:
            lifts.append({"osm_id": f"way/{e['id']}", "name": name_of(t), "kind": t["aerialway"],
                          "line": line(e["geometry"])})
        elif e["id"] not in in_relation or name_of(t):
            slopes.append({"osm_ids": [f"way/{e['id']}"], "tags": t, "lines": [line(e["geometry"])],
                           "area": t.get("area") == "yes"})
    slopes = [s for s in slopes if not NOT_SLOPES.keys() & set(s["osm_ids"])]
    for s in slopes:
        t = s.pop("tags")
        s["name"] = name_of(t)
        s["difficulty"] = difficulty_of(t)
        fix = next((DIFFICULTY_FIXES[o][0] for o in s["osm_ids"] if o in DIFFICULTY_FIXES), None)
        if fix:
            s["difficulty"] = fix
        if not s.get("area"):
            s.pop("area", None)
    return slopes, lifts, data["osm3s"]["timestamp_osm_base"]


def assign_ids(rid, items, old, prefix):
    """우리 ID를 이어 준다. 기록·D3 표본이 이 ID를 쓰므로 한 번 준 번호는 다시 쓰지 않는다.

    1) OSM ID가 하나라도 겹치면 같은 ID  2) 아니면 이름·난이도가 같은 옛 항목이 하나뿐일 때 그 ID
       (OSM에서 지우고 다시 그린 경우)  3) 아니면 새 번호. 사라진 항목은 retired에 남긴다.
    """
    known = old["items"] + old["retired"]
    osm_of = lambda x: x.get("osm_ids") or [x.get("osm_id")]
    key_of = lambda x: (x.get("name"), x.get("difficulty")) if x.get("name") else None
    by_osm = {o: x["id"] for x in known for o in osm_of(x)}
    n = max([int(x["id"].rsplit("-", 1)[1][1:]) for x in known] or [0])
    taken = set()
    for it in items:
        it["id"] = next((by_osm[o] for o in osm_of(it) if o in by_osm and by_osm[o] not in taken), None)
        taken.add(it["id"])
    for it in items:
        if it["id"] is None and key_of(it):
            same = [x["id"] for x in known if key_of(x) == key_of(it) and x["id"] not in taken]
            if len(same) == 1:
                it["id"] = same[0]
                print(f"  = 이름으로 이어 줌: {it['id']} {it.get('name')}")
        if it["id"] is None:
            n += 1
            it["id"] = f"{rid}-{prefix}{n:02d}"
        taken.add(it["id"])
    retired = [{k: x[k] for k in ("id", "name", "difficulty", "osm_ids", "osm_id") if k in x}
               for x in known if x["id"] not in taken]
    for x in retired:
        if x["id"] not in {r["id"] for r in old["retired"]}:
            print(f"  ! OSM에서 사라진 ID: {x['id']} {x.get('name')} (번호는 다시 쓰지 않음)")
    items.sort(key=lambda x: x["id"])
    return [{"id": it.pop("id"), **it} for it in items], sorted(retired, key=lambda x: x["id"])


def main():
    resorts = {r["id"]: r for r in json.loads(RESORTS.read_text())}
    areas = {k: v for k, v in json.loads(AREAS.read_text()).items() if not k.startswith("_")}
    OUT.mkdir(parents=True, exist_ok=True)
    for rid in sys.argv[1:] or areas:
        path = OUT / f"osm-{rid}.json"
        old = json.loads(path.read_text()) if path.exists() else {}
        slopes, lifts, ts = build(resorts[rid], areas[rid])
        slopes, retired_s = assign_ids(rid, slopes, {"items": old.get("slopes", []), "retired": old.get("retired_slopes", [])}, "s")
        lifts, retired_l = assign_ids(rid, lifts, {"items": old.get("lifts", []), "retired": old.get("retired_lifts", [])}, "l")
        doc = {
            "resort_id": rid,
            "source": "© OpenStreetMap contributors, ODbL 1.0",
            "osm_timestamp": ts,
            "generated": date.today().isoformat(),
            "slopes": slopes,
            "lifts": lifts,
            "retired_slopes": retired_s,
            "retired_lifts": retired_l,
        }
        path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
        named = sum(1 for s in doc["slopes"] if s["name"])
        print(f"{rid}: 슬로프 {len(slopes)}(이름 {named}) 리프트 {len(lifts)} → {path.name} {path.stat().st_size // 1024}KB")
        orient(rid)
        add_pylons(rid)
        time.sleep(2)


if __name__ == "__main__":
    main()
