# 그린 슬로프 선(lines-<id>.json) 고침: 사용자가 앱 기준 대조 그림(review.py)으로 확인한 이름·난이도·연결·삭제·미운영·구간 (R9, R50, K).
# 대상은 앱이 보여 주는 슬로프 ID로 고른다: "s09" = 그 OSM 슬로프에 이어진 선 전부, "d01" = 어디에도 안 이어진 선(파일 순서, 고치기 전 기준).
# 묶음마다 한 번만 적용한다(파일 "fixes"에 묶음 표시를 남기고, 있으면 건너뜀). lines.py로 선을 다시 만들면 다시 적용한다.
# 사용: python3 tools/canopy/line_fixes.py            (자체 확인만)
#       python3 tools/canopy/line_fixes.py --write    (maps 폴더에 쓴다)
import json, math, sys
from pathlib import Path

MAPS = Path(__file__).resolve().parents[2] / "SlopeMate/Resources/maps"
STAMP = "2026-11-22"   # 첫 묶음(FIXES). 이후 묶음은 MORE

# 리조트: [(대상, 동작, 값)]. 동작: name 이름, difficulty 난이도, link 이 OSM 슬로프에 잇기(우리 ID 끝 sNN), delete 지우기,
# closed 이번 시즌 미운영(숨김, 선은 남김), cut 두 점 사이만 남기기, split 가장 남쪽 점에서 둘로(값: (동쪽 연결, 서쪽 연결)),
# right 지우기(두 선 중 서쪽 선 = 남쪽이 위인 그림의 오른쪽), add 이 OSM 슬로프의 선을 그린 선으로 더하기(값: 난이도)
FIXES = {
    "alpensia": [("s03", "cut", ((37.65040, 128.67279), (37.65246, 128.67165)))],   # 찰리: 그은 구간만(아래는 브라보와 합쳐짐)
    "edenvalley": [("d01", "delete", None), ("s02", "difficulty", "easy")],
    "high1": [("s01", "closed", True), ("s04", "closed", True), ("s14", "closed", True),
              ("d02", "link", "s05"), ("d03", "link", "s06")],                       # 아폴로4·아폴로3
    "jisan": [("s09", "name", "레몬"), ("s01", "name", "오렌지"), ("s02", "name", "뉴오렌지"),
              ("s03", "name", "실버6"), ("s06", "name", "블루"), ("s08", "name", "실버7")],
    "konjiam": [("d01", "name", "그램")],
    "muju": [("d01", "name", "서역기행"), ("d02", "link", "s22"),                     # 스피츠 하단(그림 20번으로 봄)
             ("d03", "split", ("s06", "s08"))],                                      # 커넥션(왼쪽)·루키힐(오른쪽)
    "o2": [("s08", "name", "패션1"), ("s13", "name", "글로리2"), ("s10", "name", "헤드"), ("s11", "name", "챌린지"),
           ("d01", "name", "드림"), ("d02", "delete", None), ("d03", "name", "글로리1"), ("d04", "name", "패션2"),
           ("d05", "name", "챌린지1"), ("d06", "name", "챌린지2")],
    "vivaldi": [("d01", "name", "테크노"), ("s11", "right", None), ("s10", "difficulty", "advanced"), ("s02", "add", "easy")],
    "yongpyong": [("d02", "link", "s02"), ("d02", "difficulty", "intermediate"), ("d03", "link", "s03"),   # 골드환타스틱·골드계곡
                  ("s27", "difficulty", "easy")],
}


# 이후 묶음: {표시: {리조트: [...]}}. 동작 join = 이 슬로프 선의 가까운 끝을 다른 슬로프(값) 선의 가까운 끝까지 곧게 잇는 선을 더함
MORE = {
    "2026-11-22b": {"yongpyong": [("s05", "join", "s34")]},   # 골드 파라다이스 끝 → 레드 파라다이스 위(그사이 숲에 막힌 길)
}


def cut(pts, a, b):
    """선 pts에서 점 a·b에 가장 가까운 선 위 지점 사이(양 끝은 그 지점)"""
    k = math.cos(math.radians(pts[0][0])) * 111320
    xy = [(p[1] * k, p[0] * 110540) for p in pts]
    def nearest(q):
        qx, qy = q[1] * k, q[0] * 110540
        best = (float("inf"), 0, 0.0)
        for i in range(len(xy) - 1):
            (ax, ay), (bx, by) = xy[i], xy[i + 1]
            L2 = (bx - ax) ** 2 + (by - ay) ** 2 or 1e-12
            t = min(max(((qx - ax) * (bx - ax) + (qy - ay) * (by - ay)) / L2, 0), 1)
            d = math.hypot(ax + t * (bx - ax) - qx, ay + t * (by - ay) - qy)
            if d < best[0]:
                best = (d, i, t)
        return best[1] + best[2]
    def at(u):
        i = min(int(u), len(pts) - 2); t = u - i
        return [round(pts[i][j] + t * (pts[i + 1][j] - pts[i][j]), 6) for j in (0, 1)]
    u0, u1 = sorted((nearest(a), nearest(b)))
    return [at(u0)] + [p for j, p in enumerate(pts) if u0 < j < u1] + [at(u1)]


def apply(rid, doc, osm, fixes):
    lines = doc["lines"]
    ids = {s["id"] for s in osm["slopes"]}
    first = {}
    for l in lines:
        if l["slope"] and len(l["line"]) > 1:
            first.setdefault(l["slope"], l["difficulty"])
    loose = [l for l in lines if len(l["line"]) > 1 and (not l["slope"] or l["slope"] not in ids or first.get(l["slope"]) != l["difficulty"])]
    def pick(target):
        if target.startswith("d"):
            return [loose[int(target[1:]) - 1]]
        sid = f"{rid}-{target}"
        return [l for l in lines if l["slope"] == sid and l["difficulty"] == first.get(sid)]
    picked = [(pick(t), op, v) for t, op, v in fixes if op not in ("add", "join")]   # 고치기 전 기준으로 모두 고른 뒤 적용
    gone = []
    for targets, op, v in picked:
        assert targets, (rid, op)
        for l in targets:
            if op in ("name", "difficulty", "closed"):
                l[op] = v
            elif op == "link":
                l["slope"] = f"{rid}-{v}"
            elif op == "delete":
                gone.append(l)
            elif op == "cut":
                l["line"] = cut(l["line"], *v)
        if op == "right":
            gone.append(min(targets, key=lambda l: sum(p[1] for p in l["line"]) / len(l["line"])))
        elif op == "split":
            l = targets[0]; i = min(range(len(l["line"])), key=lambda j: l["line"][j][0])
            a, b = l["line"][:i + 1], l["line"][i:]
            east, west = (a, b) if sum(p[1] for p in a) / len(a) > sum(p[1] for p in b) / len(b) else (b, a)
            l["line"], l["slope"] = east, f"{rid}-{v[0]}"
            lines.insert(next(j for j, x in enumerate(lines) if x is l) + 1, {**l, "line": west, "slope": f"{rid}-{v[1]}"})
    for t, op, v in fixes:
        if op == "join":
            a = [l for l in lines if l["slope"] == f"{rid}-{t}"]; b = [l for l in lines if l["slope"] == f"{rid}-{v}"]
            ends = lambda ls: [p for l in ls for p in (l["line"][0], l["line"][-1])]
            d = lambda p, q: math.hypot(p[0] - q[0], (p[1] - q[1]) * math.cos(math.radians(p[0])))
            p, q = min(((p, q) for p in ends(a) for q in ends(b)), key=lambda pq: d(*pq))
            lines.append({"slope": a[0]["slope"], "difficulty": a[0]["difficulty"], "line": [p, q]})
        if op == "add":
            s = next(s for s in osm["slopes"] if s["id"] == f"{rid}-{t}")
            lines += [{"slope": s["id"], "difficulty": v, "line": ln} for ln in s["lines"]]
    doc["lines"] = [l for l in lines if not any(l is g for g in gone)]
    return doc


def selftest():
    osm = {"slopes": [{"id": "r-s01", "lines": [[[0, 0], [1, 1]]]}, {"id": "r-s02", "lines": [[[5, 5], [6, 6]]]}]}
    doc = {"lines": [{"slope": "r-s01", "difficulty": "easy", "line": [[0, 0], [1, 1]]},
                     {"slope": None, "difficulty": "advanced", "line": [[0, 2], [-1, 3], [0, 4]]},
                     {"slope": None, "difficulty": "easy", "line": [[9, 9], [9, 10]]}]}
    out = apply("r", doc, osm, [("s01", "name", "가"), ("d01", "split", ("s01", "s02")), ("d02", "delete", None), ("s02", "add", "easy")])
    L = out["lines"]
    assert L[0]["name"] == "가" and len(L) == 4, L
    assert L[1]["line"] == [[-1, 3], [0, 4]] and L[1]["slope"] == "r-s01" and L[2]["line"] == [[0, 2], [-1, 3]] and L[2]["slope"] == "r-s02", L
    assert L[3]["line"] == [[5, 5], [6, 6]]
    j = apply("r", {"lines": [{"slope": "r-s01", "difficulty": "easy", "line": [[0, 0], [1, 0]]},
                              {"slope": "r-s02", "difficulty": "advanced", "line": [[3, 0], [4, 0]]}]}, osm, [("s01", "join", "s02")])
    assert j["lines"][-1] == {"slope": "r-s01", "difficulty": "easy", "line": [[1, 0], [3, 0]]}, j["lines"][-1]
    c = cut([[37.0, 128.0], [37.001, 128.0], [37.002, 128.0]], [37.0005, 128.0001], [37.0015, 128.0])
    assert c == [[37.0005, 128.0], [37.001, 128.0], [37.0015, 128.0]], c
    print("ok")


if __name__ == "__main__":
    selftest()
    if "--write" in sys.argv:
        for stamp, group in [(STAMP, FIXES)] + list(MORE.items()):
            for rid, fixes in group.items():
                p = MAPS / f"lines-{rid}.json"; doc = json.loads(p.read_text())
                done = (doc.get("fixes") or "").split(",")
                if stamp in done:
                    continue
                osm = json.loads((MAPS / f"osm-{rid}.json").read_text())
                before = len(doc["lines"])
                doc = apply(rid, doc, osm, fixes)
                doc["fixes"] = ",".join([x for x in done if x] + [stamp])
                p.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
                print(f"{rid} {stamp}: 선 {before} → {len(doc['lines'])}, 고침 {len(fixes)}")
