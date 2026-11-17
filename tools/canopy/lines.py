# 사용자가 그린 슬로프 선 → 앱용 슬로프 선 파일(R50, R9, K).
#   바탕 그림(paint/NN-<id>.png = 그 리조트 지형 질감, 위가 북쪽)에 슬로프마다 가운데 선을 난이도 색으로 그은 그림을 받는다
#   (크기가 달라도 비율이 같으면 맞춘다). 색: 초록 easy, 파랑 intermediate, 빨강 advanced, 보라·검정 expert.
#   1. 바탕과 달라진 채도 높은 칸을 색별로 모아 작은 부스러기를 버리고 가운데 한 칸 굵기로 깎는다(Zhang–Suen).
#   2. 깎은 선을 끝점·갈림길에서 나눠 꺾은선으로, 1텍셀 기준으로 줄인 뒤 Chaikin 두 번으로 부드럽게.
#   3. 선마다 가장 가까운 OSM 슬로프(평균 거리 60m 안, 난이도가 같으면 80m 안이고 25m 차이까지는 먼저)에 연결한다. 이름·우리 ID·하강 판정은 그 슬로프 것을 쓴다.
#   결과 lines-<id>.json: {"lines": [{"slope": "<우리 슬로프 ID>" 또는 null, "difficulty": "...", "line": [[위도, 경도], …]}]}
#   앱 SlopeMap.load가 이 파일이 있으면 OSM 선 대신 이 선을 쓴다(그리지 않은 OSM 슬로프는 숨김).
# 사용: tools/dem/.venv/bin/python tools/canopy/lines.py <그린 그림> <바탕 그림> <id> [확인용.png] [--swap]   (maps 폴더에 바로 쓴다)
#   --swap: 빨강·보라를 바꿔 그린 그림(빨강 = 최상급, 보라 = 상급)
import json, math, sys
from pathlib import Path
import numpy as np
import rasterio
from rasterio import features
from rasterio.enums import Resampling

MAPS = Path(__file__).resolve().parents[2] / "SlopeMate/Resources/maps"
NAMES = {1: "easy", 2: "intermediate", 3: "advanced", 4: "expert"}
LEVEL = {"novice": 1, "easy": 1, "intermediate": 2, "advanced": 3, "expert": 4, "freeride": 4, "extreme": 4}


def read(path, shape=None):
    with rasterio.open(path) as f:
        a = f.read([1, 2, 3], out_shape=None if shape is None else (3, *shape), resampling=Resampling.bilinear)
    return a.astype(np.int32)


def classify(painted, base):
    """칸마다 0 없음, 1~4 난이도"""
    r, g, b = painted
    hi, lo = painted.max(0), painted.min(0)
    on = (np.abs(painted - base).sum(0) > 90) & ((hi - lo) > 70)
    col = np.zeros(r.shape, np.uint8)
    col[on & (g >= r) & (g >= b)] = 1
    col[on & (b > g + 30) & (b > r + 40)] = 2
    col[on & (r > g + 60) & (r > b + 60)] = 3
    col[on & (r > g + 40) & (b > g + 40) & (np.abs(r - b) < 90)] = 4
    col[(col == 0) & (hi < 75) & (base.max(0) - hi > 60)] = 4   # 검정도 최상급(눈·숲보다 확 어두운 칸)
    return col


def thin(m):
    """Zhang–Suen 세선화(8이웃 한 칸 굵기)"""
    m = np.pad(m.astype(np.uint8), 1)
    while True:
        changed = False
        for step in (0, 1):
            p = [np.roll(np.roll(m, -dy, 0), -dx, 1) for dy, dx in ((-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1))]
            n = sum(p)
            a = sum((p[i] == 0) & (p[(i + 1) % 8] == 1) for i in range(8))
            c1 = p[0] * p[2] * (p[4] if step == 0 else p[6])
            c2 = p[2 if step == 0 else 0] * p[4] * p[6]
            kill = (m == 1) & (n >= 2) & (n <= 6) & (a == 1) & (c1 == 0) & (c2 == 0)
            if kill.any():
                m[kill] = 0; changed = True
        if not changed:
            return m[1:-1, 1:-1].astype(bool)


def close(m, n=2):
    """n칸 넓혔다 좁혀 선 안 작은 구멍·끊김을 메운다"""
    g = m.copy()
    for _ in range(n):
        g[1:] |= g[:-1]; g[:-1] |= g[1:]; g[:, 1:] |= g[:, :-1]; g[:, :-1] |= g[:, 1:]
    for _ in range(n):
        g[1:] &= g[:-1]; g[:-1] &= g[1:]; g[:, 1:] &= g[:, :-1]; g[:, :-1] &= g[:, 1:]
    return g | m


def prune(sk, short=12, rounds=3):
    """끝점에서 갈림길까지가 short칸보다 짧은 곁가지를 지운다(굵은 붓 선을 깎으면 생기는 잔가지)"""
    sk = sk.copy()
    for _ in range(rounds):
        pts = set(zip(*np.nonzero(sk)))
        nb = lambda p: [(p[0] + dy, p[1] + dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if (dy or dx) and (p[0] + dy, p[1] + dx) in pts]
        cut = False
        for e in [p for p in pts if len(nb(p)) == 1]:
            path, prev = [e], None
            while True:
                n = [q for q in nb(path[-1]) if q != prev and q not in path]
                if len(n) != 1 or len(nb(n[0])) >= 3:
                    break
                prev = path[-1]; path.append(n[0])
                if len(path) > short:
                    break
            n = [q for q in nb(path[-1]) if q not in path]
            if len(path) <= short and n and len(nb(n[0])) >= 3:   # 갈림길에 닿은 짧은 가지
                for p in path:
                    sk[p] = False
                cut = True
        if not cut:
            break
    return sk


def trace(sk):
    """한 칸 굵기 선 → 꺾은선들(끝점·갈림길에서 나눔). 갈림길·끝점은 둘레 8칸을 돌며 선→빈칸 바뀜 수(교차수)로
    판단한다(이웃 수로 보면 계단 모서리가 가짜 갈림길이 된다). 고리는 아무 점에서 시작"""
    pts = set(zip(*np.nonzero(sk)))
    ring = ((-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1))
    def cross(p):
        on = [(p[0] + dy, p[1] + dx) in pts for dy, dx in ring]
        return sum(on[i] and not on[(i + 1) % 8] for i in range(8))
    nb = lambda p: [(p[0] + dy, p[1] + dx) for dy, dx in ring if (p[0] + dy, p[1] + dx) in pts]
    nodes = {p for p in pts if cross(p) != 2}
    used, out = set(), []
    def walk(a, b):
        path = [a, b]
        used.add(b)
        while path[-1] not in nodes:
            # 다음 칸: 아직 안 쓴 이웃 중 가로·세로 이웃 먼저(대각선은 계단을 건너뛴다)
            cand = [q for q in nb(path[-1]) if q not in used and q not in path]
            if not cand:
                ends = [q for q in nb(path[-1]) if q in nodes and q != path[-2] and q != path[0]]
                if ends:
                    path.append(ends[0])
                break
            cand.sort(key=lambda q: abs(q[0] - path[-1][0]) + abs(q[1] - path[-1][1]))
            nxt = cand[0]
            used.add(nxt); path.append(nxt)
        return path
    for a in nodes:
        for b in nb(a):
            if b in used or (b in nodes and (a, b) in used):
                continue
            if b in nodes:   # 갈림길끼리 바로 붙음
                used.add((a, b)); used.add((b, a)); continue
            out.append(walk(a, b))
    left = pts - used - nodes
    while left:   # 갈림길 없는 고리
        a = next(iter(left)); used.add(a)
        rest = [q for q in nb(a) if q not in used]
        if rest:
            out.append(walk(a, rest[0]))
        left = pts - used - nodes
    return [l for l in out if len(l) >= 8]


def simplify(pts, eps):
    if len(pts) < 3:
        return pts
    a, b = np.array(pts[0], float), np.array(pts[-1], float)
    ab = b - a
    d = [abs(ab[0] * (p[1] - a[1]) - ab[1] * (p[0] - a[0])) / (np.linalg.norm(ab) or 1) for p in pts[1:-1]]
    i = int(np.argmax(d)) + 1
    if d[i - 1] > eps:
        return simplify(pts[:i + 1], eps)[:-1] + simplify(pts[i:], eps)
    return [pts[0], pts[-1]]


def chaikin(pts, n=2):
    for _ in range(n):
        if len(pts) < 3:
            return pts
        q = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            q += [(0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]), (0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1])]
        pts = q[:1] + q[2:-1] + [pts[-1]]   # 양 끝점은 그대로(갈림길에서 이어지게)
    return pts


def build(col, dem, osm, H, W, min_px=30):
    to_ll = lambda y, x: [round(dem["north"] - (y + 0.5) * (dem["rows"] - 1) / H * dem["step"], 6),
                          round(dem["west"] + (x + 0.5) * (dem["cols"] - 1) / W * dem["step"], 6)]
    k = math.cos(math.radians(dem["north"]))
    meters = lambda a, b: math.hypot((a[0] - b[0]) * 111320, (a[1] - b[1]) * 111320 * k)
    def seg_dist(p, a, b):
        ax, ay, bx, by, px_, py = a[1] * k, a[0], b[1] * k, b[0], p[1] * k, p[0]
        dx, dy = bx - ax, by - ay
        t = 0 if dx == dy == 0 else max(0, min(1, ((px_ - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(px_ - ax - t * dx, py - ay - t * dy) * 111320
    out = []
    lv = {s["id"]: s.get("difficulty") for s in osm["slopes"]}
    for c in (1, 2, 3, 4):
        m = col == c
        if not m.any():
            continue
        m = features.sieve(close(m).astype(np.uint8), min_px) == 1
        for path in trace(prune(thin(m))):
            pts = chaikin(simplify(path, 1.0))
            line = [to_ll(y, x) for y, x in pts]
            # 연결: OSM 슬로프 선까지 평균 거리(선을 따라 20개 점)
            samp = [line[int(i * (len(line) - 1) / 19)] for i in range(20)]
            best = (1e9, None)
            for s in osm["slopes"]:
                segs = [(a, b) for l in s["lines"] for a, b in zip(l, l[1:])]
                if not segs:
                    continue
                d = sum(min(seg_dist(p, a, b) for a, b in segs) for p in samp) / len(samp)
                if d + (0 if LEVEL.get(s.get("difficulty")) == c else 25) < best[0] + (0 if best[1] is None or LEVEL.get(lv[best[1]]) == c else 25):
                    best = (d, s["id"])   # 25m 안이면 난이도가 같은 슬로프를 먼저
            out.append({"slope": best[1] if best[0] < (80 if best[1] and LEVEL.get(lv[best[1]]) == c else 60) else None, "difficulty": NAMES[c], "line": line,
                        "_len": sum(meters(a, b) for a, b in zip(line, line[1:])), "_d": best[0]})
    return out


if __name__ == "__main__" and len(sys.argv) == 1:   # 자체 확인: Y자 파랑 선 → 갈림길에서 3조각, 짧은 점은 버림
    base = np.full((3, 80, 80), 200, np.int32)
    p = base.copy()
    for i in range(10, 40):
        p[:, i, 39:42] = np.array([30, 40, 220])[:, None]               # 줄기
        p[:, 40 + (i - 10), 39 - (i - 10) // 1 : 42 - (i - 10)] = np.array([30, 40, 220])[:, None]   # 왼쪽 가지
        p[:, 40 + (i - 10), 39 + (i - 10) : 42 + (i - 10)] = np.array([30, 40, 220])[:, None]        # 오른쪽 가지
    p[:, 5:7, 5:7] = np.array([30, 40, 220])[:, None, None]             # 부스러기
    c = classify(p, base)
    assert (c == 2).sum() > 100 and c[0, 0] == 0
    segs = trace(thin(features.sieve((c == 2).astype(np.uint8), 30) == 1))
    assert len(segs) == 3, len(segs)
    assert chaikin([(0, 0), (0, 10), (10, 10)])[0] == (0, 0) and chaikin([(0, 0), (0, 10), (10, 10)])[-1] == (10, 10)
    print("ok")
elif __name__ == "__main__":
    swap = "--swap" in sys.argv
    sys.argv = [a for a in sys.argv if a != "--swap"]
    if swap:
        NAMES[3], NAMES[4] = NAMES[4], NAMES[3]
    painted, base_path, rid = sys.argv[1:4]
    dem = json.load(open(MAPS / f"dem-{rid}.json")); osm = json.load(open(MAPS / f"osm-{rid}.json"))
    base = read(base_path); H, W = base.shape[1:]
    lines = build(classify(read(painted, (H, W)), base), dem, osm, H, W)
    names = {s["id"]: s.get("name") for s in osm["slopes"]}
    for l in lines:
        print(f"  {l['difficulty']:12s} {l['_len']:5.0f}m → {l['slope']} {names.get(l['slope'])} (평균 {l['_d']:.0f}m)")
    doc = {"lines": [{k: v for k, v in l.items() if not k.startswith("_")} for l in lines]}
    (MAPS / f"lines-{rid}.json").write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{rid}: 선 {len(lines)}개 → lines-{rid}.json")
    if len(sys.argv) > 4:   # 확인용: 바탕 위에 선
        img = base.astype(np.uint8).copy()
        pal = {1: (46, 158, 79), 2: (58, 79, 184), 3: (217, 58, 58), 4: (140, 60, 190)}
        inv = {"easy": 1, "intermediate": 2, "advanced": 3, "expert": 4}
        for l in lines:
            for (la, lo) in l["line"]:
                y = int((dem["north"] - la) / dem["step"] / (dem["rows"] - 1) * H); x = int((lo - dem["west"]) / dem["step"] / (dem["cols"] - 1) * W)
                img[:, max(0, y - 1):y + 2, max(0, x - 1):x + 2] = np.array(pal[inv[l["difficulty"]]])[:, None, None]
        with rasterio.open(sys.argv[4], "w", driver="PNG", width=W, height=H, count=3, dtype="uint8") as f:
            f.write(img)
