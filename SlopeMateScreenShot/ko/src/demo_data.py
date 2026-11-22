r"""App Store 스크린샷용 데모 기록을 시뮬레이터 DB에 넣는 SQL을 만든다.
사용: python3 demo_data.py > demo.sql ; sqlite3 <앱 컨테이너>/Library/Application\ Support/SlopeMate/slopemate.sqlite < demo.sql
내장 OSM 리프트·슬로프 선을 따라 리프트 상승 → 슬로프 하강을 반복하는 위치점을 만든다. 슬로프 이름은 쓰지 않는다."""
import json, math, random, uuid, datetime as dt, sys, os

ROOT = os.path.join(os.path.dirname(__file__), "../../../SlopeMate/Resources/maps")
KST = dt.timezone(dt.timedelta(hours=9))
M = 111_000

def dist(a, b):
    return math.hypot((a[0]-b[0]) * M, (a[1]-b[1]) * M * math.cos(math.radians(a[0])))

def resample(line, step):
    out = [line[0]]
    for a, b in zip(line, line[1:]):
        d = dist(a, b); n = max(1, math.ceil(d / step))
        out += [[a[0] + (b[0]-a[0]) * i / n, a[1] + (b[1]-a[1]) * i / n] for i in range(1, n + 1)]
    return out

def graph(resort):
    m = json.load(open(f"{ROOT}/osm-{resort}.json"))
    lifts = [l["line"] for l in m["lifts"]]
    loops = {}
    for i, lift in enumerate(lifts):
        top = lift[-1]
        for s in m["slopes"]:
            line = max(s["lines"], key=len)
            if dist(line[-1], top) < dist(line[0], top): line = line[::-1]
            if dist(line[0], top) > 250: continue
            j = min(range(len(lifts)), key=lambda k: dist(line[-1], lifts[k][0]))
            if dist(line[-1], lifts[j][0]) < 400 and sum(dist(a, b) for a, b in zip(line, line[1:])) > 300:
                loops.setdefault(i, []).append((line, j))
    return lifts, loops

def day(resort, start, n_runs, rid, rng):
    lifts, loops = graph(resort)
    i = rng.choice(list(loops))
    pts, t, alt = [], start, 750.0
    def walk(line, speed, a0, a1):
        nonlocal t
        line = resample(line, speed * 2)
        for k, p in enumerate(line):
            f = k / max(1, len(line) - 1)
            jitter = rng.uniform(-0.00002, 0.00002)
            pts.append((t, p[0] + jitter, p[1] + jitter, a0 + (a1 - a0) * f, speed))
            t += dt.timedelta(seconds=2)
    for _ in range(n_runs):
        lift = lifts[i]
        rise = min(450, sum(dist(a, b) for a, b in zip(lift, lift[1:])) * 0.3)
        # 줄 서기
        for _ in range(rng.randint(30, 150)):
            pts.append((t, lift[0][0] + rng.uniform(-3e-5, 3e-5), lift[0][1] + rng.uniform(-3e-5, 3e-5), 750, 0.3)); t += dt.timedelta(seconds=2)
        walk(lift, 4.5, 750, 750 + rise)
        line, j = rng.choice(loops[i])
        walk([lift[-1], line[0]], 2, 750 + rise, 750 + rise)
        walk(line, rng.uniform(8, 12), 750 + rise, 755)
        walk([line[-1], lifts[j][0]], 1.5, 755, 750)
        i = j if j in loops else rng.choice(list(loops))
        if rng.random() < 0.12: t += dt.timedelta(minutes=rng.randint(20, 50))  # 쉬는 시간
    return pts

def ts(d): return d.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
def blob(u): return "X'" + u.hex + "'"

DAYS = [  # (리조트, 날짜, 시작 시각, 하강 수) 용평 9일 · 하이원 6일. 2.1 스크린샷은 시계를 바꾸지 않고 2026-11-22(일, 주 첫날)을 마지막 날로 찍음
    ("yongpyong", "2026-11-02", "09:10", 11), ("high1", "2026-11-03", "09:30", 12),
    ("yongpyong", "2026-11-05", "09:20", 10), ("high1", "2026-11-07", "09:30", 14),
    ("yongpyong", "2026-11-08", "10:00", 9), ("high1", "2026-11-10", "09:40", 13),
    ("yongpyong", "2026-11-12", "09:15", 12), ("yongpyong", "2026-11-14", "09:05", 15),
    ("high1", "2026-11-15", "10:10", 11), ("yongpyong", "2026-11-16", "09:15", 13),
    ("high1", "2026-11-17", "09:20", 15), ("yongpyong", "2026-11-18", "09:00", 14),
    ("high1", "2026-11-20", "09:20", 16), ("yongpyong", "2026-11-22", "09:10", 12),
    ("yongpyong", "2026-11-21", "09:00", 18),  # 앞 줄과 날짜만 바꿈: 가운데 곤돌라 경로가 마지막 기록(3D 장면)이 되게
]

LIVE_RUNS = 8

def main():
    rng = random.Random(7)
    out = ["BEGIN;", "DELETE FROM point; DELETE FROM restart; DELETE FROM gap; DELETE FROM recording_cache; DELETE FROM recording;",
           "DELETE FROM pass_resort; DELETE FROM season_pass; DELETE FROM home_resort;",
           "INSERT INTO home_resort VALUES ('yongpyong',0),('high1',1);"]
    live = "--live" in sys.argv  # 오늘 아직 끝나지 않은 기록(마지막 위치가 방금): 기록 중 화면·Live Activity용
    now = dt.datetime.now(KST) - dt.timedelta(minutes=67)
    today = now.strftime("%Y-%m-%d")
    days = [x for x in DAYS if not (live and x[1] == today)]  # 기록 중 화면은 오늘 끝난 기록 대신 진행 중 기록
    for resort, d, hm, n, open_ in [(*x, False) for x in days] + ([("yongpyong", today, now.strftime("%H:%M"), LIVE_RUNS, True)] if live else []):
        rid = uuid.uuid5(uuid.NAMESPACE_URL, f"slopemate-demo-{d}")
        start = dt.datetime.fromisoformat(f"{d}T{hm}:00").replace(tzinfo=KST)
        pts = day(resort, start, n, rid, rng)
        if open_:  # 마지막 위치가 방금(20초 전) 들어온 것처럼 통째로 옮김
            shift = dt.datetime.now(KST) - dt.timedelta(seconds=20) - pts[-1][0]
            start += shift; pts = [(t + shift, *rest) for t, *rest in pts]
        end = pts[-1][0] + dt.timedelta(seconds=30)
        if open_: print(f"-- live last point {pts[-1][0]}", file=sys.stderr)
        e = "NULL,NULL" if open_ else f"'{ts(end)}','user'"
        out.append(f"INSERT INTO recording (id,resortId,startedAt,endedAt,endReason) VALUES ({blob(rid)},'{resort}','{ts(start)}',{e});")
        out.append(f"INSERT INTO restart VALUES ({blob(rid)},0,'{ts(start)}','start');")
        rows = [f"({blob(rid)},'{ts(t)}',{la:.6f},{lo:.6f},5,{a + 30:.1f},4,{s:.1f},{a - 750:.1f},'{ts(t)}',0)" for t, la, lo, a, s in pts]
        for k in range(0, len(rows), 500):
            out.append("INSERT INTO point (recordingId,t,lat,lon,hAcc,gpsAlt,vAcc,speed,baroAlt,baroT,seq) VALUES " + ",".join(rows[k:k+500]) + ";")
    p1, p2 = uuid.uuid5(uuid.NAMESPACE_URL, "pass1"), uuid.uuid5(uuid.NAMESPACE_URL, "pass2")
    out.append(f"INSERT INTO season_pass VALUES ({blob(p1)},'2026-27','용평 시즌권',590000,99000,0),({blob(p2)},'2026-27','하이원 시즌권',450000,95000,1);")
    out.append(f"INSERT INTO pass_resort VALUES ({blob(p1)},'yongpyong'),({blob(p2)},'high1');")
    out.append("COMMIT;")
    print("\n".join(out))

main()
