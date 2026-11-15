"""App Store 이미지(한국어) 만들기. 사용: python3 build.py
raw/의 시뮬레이터 화면으로 html/*.html을 만들고 Chrome headless로 ../*.png를 렌더한 뒤 알파를 뺀다.
데모 데이터는 demo_data.py."""
import os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

SHOTS = [  # (파일, 원본 화면, 회색 줄, 굵은 줄)
    ("1.png", "s5_recording.png", "주머니에 넣고 타기만 하세요", "몇 번 탔는지 알아서 기록해요"),
    ("2.png", "s6_map.png", "오늘 탄 길을", "지도에서 다시 봐요"),
    ("3.png", "s9_season.png", "시즌권 본전, 뽑았는지 궁금하다면", "1회 방문당 금액을 알려줘요"),
    ("4.png", "s8_list.png", "다녀온 날이 차곡차곡", "시즌 기록이 한곳에 모여요"),
    ("5.png", "weather.png", "출발하기 전에", "날씨와 예상 설질을 확인해요"),
]

BASE_CSS = """
:root { --bg:#EEF5F7; --ink:#141B2D; --sub:#6B7280; --accent:#087480; --bezel:#1B2438; }
* { margin:0; padding:0; box-sizing:border-box; }
html, body { background:var(--bg); overflow:hidden; }
body { font-family:"Apple SD Gothic Neo", -apple-system, sans-serif; color:var(--ink); position:relative; }
.phone { position:absolute; background:var(--bezel); border-radius:var(--r); padding:var(--b); box-shadow:0 30px 80px rgba(20,27,45,.18); }
.screen { width:100%; height:100%; border-radius:calc(var(--r) - var(--b)); background-size:cover; background-position:top center; position:relative; overflow:hidden; }
.island { position:absolute; left:50%; transform:translateX(-50%); background:#000; border-radius:999px; }
"""

def phone(img, left, top, width, extra=""):
    """width = 바깥 폭(px). 화면 비율은 1320:2868"""
    b = round(width * 0.028)
    sw = width - 2 * b
    sh = round(sw * 2868 / 1320)
    r = round(width * 0.155)
    iw, ih, it = round(sw * 0.285), round(sw * 0.083), round(sw * 0.026)
    return (f'<div class="phone" style="left:{left}px;top:{top}px;width:{width}px;height:{sh + 2*b}px;--b:{b}px;--r:{r}px;{extra}">'
            f'<div class="screen" style="background-image:url(../raw/{img})">'
            f'<div class="island" style="width:{iw}px;height:{ih}px;top:{it}px"></div></div></div>')

def shot(img, gray, bold):
    w = 1100
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width:1320px; height:2868px; }}
.copy {{ position:absolute; top:250px; width:100%; text-align:center; }}
.g {{ font-size:58px; font-weight:600; color:var(--sub); letter-spacing:-1px; }}
.h {{ margin-top:22px; font-size:96px; font-weight:800; letter-spacing:-3px; line-height:1.15; }}
</style></head><body>
<div class="copy"><div class="g">{gray}</div><div class="h">{bold}</div></div>
{phone(img, (1320 - w) // 2, 640, w)}
</body></html>"""

def crop(img, x, y, w, h, scale, left, top, rot, radius=40):
    """원본 이미지의 (x,y,w,h) 영역을 scale배로 잘라 기울인 카드"""
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w*scale}px;height:{h*scale}px;'
            f'border-radius:{radius}px;overflow:hidden;transform:rotate({rot}deg);box-shadow:0 24px 60px rgba(20,27,45,.16);'
            f'background:url(../raw/{img}) {-x*scale}px {-y*scale}px / {1320*scale if img!="share_image.png" else 1080*scale}px auto no-repeat;"></div>')

def hero():
    # 헤더 자산은 5244x2950(1.778)와 3840x1646(2.333) 두 비율로 다 쓰여서, 세로로 자를 때
    # 위아래 약 160px씩(2400x1350 기준) 잘릴 수 있다. 중요한 내용은 y=160~1190 안에 둔다.
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width:2400px; height:1350px; }}
.copy {{ position:absolute; left:170px; top:400px; }}
.h {{ font-size:112px; font-weight:800; letter-spacing:-4px; line-height:1.2; }}
.h em {{ font-style:normal; color:var(--accent); }}
.s {{ margin-top:44px; font-size:46px; font-weight:500; color:var(--sub); line-height:1.5; letter-spacing:-1px; }}
</style></head><body>
<div class="copy">
  <div class="h">스키장에서<br><em>기록 시작</em>만 누르세요</div>
  <div class="s">하강 횟수와 거리는 알아서 세고,<br>시즌권 1회 방문당 금액까지 알려줘요</div>
</div>
{crop("share_image.png", 0, 150, 540, 1200, 0.55, 1110, 300, -8)}
{crop("s6_map.png", 0, 450, 1320, 1600, 0.3, 1940, 220, 7, 36)}
{phone("s2_home.png", 1460, 170, 480)}
{crop("s9_season.png", 50, 509, 1220, 280, 0.46, 1770, 820, -4, 26)}
</body></html>"""

def render(html, png, w, h):
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--window-size={w},{h}", f"--screenshot={png}", "file://" + html],
                   check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    # 알파 제거: JPEG를 거쳐 PNG로 (App Store는 알파 채널을 받지 않음)
    tmp = png + ".jpg"
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", png, "--out", tmp], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sips", "-s", "format", "png", tmp, "--out", png], check=True, stdout=subprocess.DEVNULL)
    os.remove(tmp)

def main():
    os.makedirs(f"{HERE}/html", exist_ok=True)
    jobs = [(name, shot(img, g, b), 1320, 2868) for name, img, g, b in SHOTS] + [("hero.png", hero(), 2400, 1350)]
    for name, html, w, h in jobs:
        path = f"{HERE}/html/{name.replace('.png', '.html')}"
        open(path, "w").write(html)
        render(path, f"{OUT}/{name}", w, h)
        print(name)

main()
