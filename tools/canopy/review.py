# 슬로프·숲 대조 그림(docs/decisions.md 2026-11-19 "슬로프·숲 판단은 사람이 공식 맵과 대조해 목록으로").
# 위에서 본 숲(앱과 같은 기준: 숲 판 3×3 이항 평균 ≥ 0.6, 빨강 = islands.py(A)로 지워질 외딴 덩어리) + 앱이 보여 주는 슬로프(그린 선, 색=난이도, 번호) + 리프트(회색). 앱 3D와 같은 방향(180도, 위가 남쪽).
# 공식 맵·위성 사진은 이 그림 옆에 두고 사람이 판단하는 참고로만 쓴다(따라 그리지 않음).
# 필요: numpy, scipy, pillow(같은 폴더의 islands.py를 씀). 사용: python review.py <출력 폴더> <maps 폴더> <리조트 id> [표시 상자 lat0 lat1 lon0 lon1]
import os, sys, json, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from islands import load, field, cell_m, small_islands

S, maps, rid = sys.argv[1:4]
mark = list(map(float, sys.argv[4:8])) if len(sys.argv) >= 8 else None
dem = json.load(open(f'{maps}/dem-{rid}.json')); k, hk, frac, hgt = load(f'{maps}/canopy-{rid}.bin')
osm = json.load(open(f'{maps}/osm-{rid}.json'))

def app_slopes():
    """앱이 보여 주는 슬로프(SlopeMap.drawn과 같은 규칙): 그린 선 파일이 있으면 OSM 슬로프마다 이어진 그린 선(난이도는 그린 색),
    그리지 않은 OSM 슬로프는 숨김, 어디에도 안 이어진 선은 이름 없는 슬로프 <리조트>-dNN. 파일이 없으면 OSM 그대로"""
    try:
        lines = [l for l in json.load(open(f'{maps}/lines-{rid}.json'))['lines'] if len(l['line']) > 1 and not l.get('closed')]
    except FileNotFoundError:
        return osm['slopes']
    out, first = [], {}
    for l in lines:
        if l['slope']: first.setdefault(l['slope'], l['difficulty'])
    for s_ in osm['slopes']:
        mine = [l['line'] for l in lines if l['slope'] == s_['id'] and l['difficulty'] == first.get(s_['id'])]
        named = [l.get('name') for l in lines if l['slope'] == s_['id'] and l['difficulty'] == first.get(s_['id']) and l.get('name')]
        if mine: out.append({'id': s_['id'], 'name': (named or [s_.get('name')])[0], 'difficulty': first[s_['id']], 'lines': mine})
    ids = {s_['id'] for s_ in osm['slopes']}
    loose = [l for l in lines if not l['slope'] or l['slope'] not in ids or first.get(l['slope']) != l['difficulty']]
    out += [{'id': f'{rid}-d{i:02d}', 'name': l.get('name'), 'difficulty': l['difficulty'], 'lines': [l['line']]} for i, l in enumerate(loose, 1)]
    return out
slopes = app_slopes()
def rc(lat, lon): return (dem['north'] - lat) / dem['step'] * k, (lon - dem['west']) / dem['step'] * k
pts = [p for s in slopes for l in s['lines'] for p in l] + [p for l in osm['lifts'] for p in l['line']]
ys, xs = zip(*[rc(a, o) for a, o in pts]); m = 60
r0, r1 = max(0, int(min(ys)) - m), min(frac.shape[0], int(max(ys)) + m)
c0, c1 = max(0, int(min(xs)) - m), min(frac.shape[1], int(max(xs)) + m)
Z = 3 if max(r1 - r0, c1 - c0) < 700 else 2   # 작은 리조트는 크게
H, W = (r1 - r0) * Z, (c1 - c0) * Z
forest = field(frac)[r0:r1, c0:c1] >= 0.6
img = np.full((r1 - r0, c1 - c0, 3), 255, np.uint8); img[forest] = (120, 140, 145)
rm, _ = small_islands(frac, *cell_m(dem, k)); img[rm[r0:r1, c0:c1]] = (235, 40, 40)   # A로 지워질 외딴 덩어리
im = Image.fromarray(img).resize((W, H), Image.NEAREST).rotate(180)
d = ImageDraw.Draw(im)
def px(lat, lon):   # 180도 돌린 그림의 픽셀
    y, x = rc(lat, lon); return (W - 1 - (x - c0) * Z, H - 1 - (y - r0) * Z)
col = {'easy': (30, 150, 60), 'intermediate': (30, 70, 220), 'advanced': (215, 30, 30), 'expert': (0, 0, 0), 'freeride': (230, 130, 0)}
for l in osm['lifts']: d.line([px(a, o) for a, o in l['line']], fill=(90, 90, 90), width=2)
font = ImageFont.truetype('/System/Library/Fonts/AppleSDGothicNeo.ttc', 22)
legend = []
for i, s in enumerate(slopes, 1):
    c = col.get(s.get('difficulty'), (130, 0, 160))
    for l in s['lines']: d.line([px(a, o) for a, o in l], fill=c, width=4)
    longest = max(s['lines'], key=len); a, o = longest[len(longest) // 2]; x, y = px(a, o)
    d.ellipse((x - 15, y - 15, x + 15, y + 15), fill=(255, 255, 255), outline=c, width=3)
    d.text((x, y), str(i), fill=c, font=font, anchor='mm')
    legend.append((i, s.get('name') or '(이름 없음)', s['id'].split('-')[-1], c))
if mark:   # 오늘 본 범위
    (x0, y0), (x1, y1) = px(mark[0], mark[2]), px(mark[1], mark[3])
    d.rectangle((min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)), outline=(255, 140, 0), width=5)
# 오른쪽 범례
lh = 30; LW = 480
out = Image.new('RGB', (W + LW, max(H, lh * (len(legend) + 3))), 'white'); out.paste(im, (0, 0))
d2 = ImageDraw.Draw(out); d2.text((W + 12, 10), f'{rid} 앱 슬로프 (그린 선)', fill=(0, 0, 0), font=font)
d2.text((W + 12, 10 + lh), '위가 남쪽(앱 3D 방향), 빨강 = A로 지움', fill=(90, 90, 90), font=font)
for j, (i, name, sid, c) in enumerate(legend):
    d2.text((W + 12, 10 + lh * (j + 2)), f'{i:2d}  {name}  {sid}', fill=c, font=font)
out.save(f'{S}/{rid}-overview.png'); print(out.size)
