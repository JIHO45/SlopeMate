"""App Store 이미지(한국어) 만들기. 사용: python3 build.py
raw/의 시뮬레이터 화면으로 html/*.html을 만들고 Chrome headless로 ../*.png를 렌더한 뒤 알파를 뺀다.
데모 데이터는 demo_data.py."""
import os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

SHOTS = [  # (파일, 원본 화면, 회색 줄, 굵은 줄, 배지). 원본이 .png가 아니라 "card:"로 시작하면 휴대폰 없이 그 이미지를 카드로
    ("1.png", "s2_home.png", "어디 갈지 고민될 때", "날씨·설질·3D 지도를 한눈에", ""),
    ("2.png", "s5_recording.png", "주머니에 넣고 타기만 하세요", "몇 번 탔는지 알아서 기록해요", ""),
    ("3.png", "s6_3d.png", "내가 탄 산을", "3D 지도로 돌려 봐요", "시즌 이용권"),
    ("4.png", "s9_season.png", "시즌권 본전, 뽑았는지 궁금하다면", "1회 방문당 금액을 알려줘요", ""),
    ("5.png", "recap_1.png", "한 시즌을", "결산 카드로 돌아봐요", ""),
    ("6.png", "card:share_image.png", "오늘 하루를", "한 장으로 공유해요", "시즌 이용권"),  # 3D 그림 판은 이용권(decisions 2026-11-22)
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

def shot(img, gray, bold, badge=""):
    w = 1100
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width:1320px; height:2868px; }}
.copy {{ position:absolute; top:250px; width:100%; text-align:center; }}
.g {{ font-size:58px; font-weight:600; color:var(--sub); letter-spacing:-1px; }}
.h {{ margin-top:22px; font-size:96px; font-weight:800; letter-spacing:-3px; line-height:1.15; }}
.badge {{ display:inline-block; margin-top:30px; padding:12px 30px; border-radius:999px; background:var(--accent); color:#fff; font-size:40px; font-weight:700; letter-spacing:-1px; }}
</style></head><body>
<div class="copy"><div class="g">{gray}</div><div class="h">{bold}</div>{f'<div><span class="badge">{badge}</span></div>' if badge else ""}</div>
{phone(img, (1320 - w) // 2, 640, w) if not img.startswith("card:") else share_card(img[5:])}
</body></html>"""

def share_card(img):
    """공유 이미지(1080x1350)를 휴대폰 대신 살짝 기울인 카드로"""
    w = 1120
    return (f'<div style="position:absolute;left:{(1320 - w) // 2}px;top:800px;width:{w}px;height:{w * 1350 // 1080}px;'
            f'border-radius:48px;overflow:hidden;transform:rotate(-2.5deg);box-shadow:0 40px 90px rgba(20,27,45,.22);'
            f'background:url(../raw/{img}) center / cover no-repeat;"></div>')

def crop(img, x, y, w, h, scale, left, top, rot, radius=40):
    """원본 이미지의 (x,y,w,h) 영역을 scale배로 잘라 기울인 카드"""
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w*scale}px;height:{h*scale}px;'
            f'border-radius:{radius}px;overflow:hidden;transform:rotate({rot}deg);box-shadow:0 24px 60px rgba(20,27,45,.16);'
            f'background:url(../raw/{img}) {-x*scale}px {-y*scale}px / {1320*scale if img!="share_image.png" else 1080*scale}px auto no-repeat;"></div>')

def hero():
    # 헤더 자산은 쓰이는 곳마다 다르게 잘린다. 아이폰 제품 페이지 실측(2026-11-17, 2400x1350 기준):
    # 보이는 곳은 x 552~1844, y 0~850이고 위쪽 모서리(y 200~360)는 뒤로·공유 버튼이 덮는다.
    # 내용은 x 640~1800, y 370~820 안에 모은다(휴대폰 아래쪽은 잘려도 됨).
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{BASE_CSS}
body {{ width:2400px; height:1350px; background:radial-gradient(ellipse 800px 560px at 1450px 560px, #fff 0%, var(--bg) 100%); }}
.copy {{ position:absolute; left:640px; top:385px; }}
.h {{ font-size:78px; font-weight:800; letter-spacing:-3px; line-height:1.2; }}
.h em {{ font-style:normal; color:var(--accent); }}
.s {{ margin-top:30px; font-size:36px; font-weight:500; color:var(--sub); line-height:1.5; letter-spacing:-1px; }}
</style></head><body>
<div class="copy">
  <div class="h">스키장에서<br><em>기록 시작</em>만 누르세요</div>
  <div class="s">12개 스키장 날씨·3D 지도부터<br>하강 기록, 시즌 결산까지</div>
</div>
{crop("s6_3d.png", 0, 330, 1320, 1560, 0.17, 1590, 390, 6, 22)}
{phone("s2_home.png", 1330, 215, 300)}
{crop("recap_1.png", 183, 769, 956, 600, 0.25, 1540, 630, -4, 18)}
</body></html>"""

def render(html, png, w, h, scale=1):
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                    f"--window-size={w},{h}", f"--screenshot={png}", "file://" + html],
                   check=True, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    # 알파 제거: JPEG를 거쳐 PNG로 (App Store는 알파 채널을 받지 않음)
    tmp = png + ".jpg"
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "100", png, "--out", tmp], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sips", "-s", "format", "png", tmp, "--out", png], check=True, stdout=subprocess.DEVNULL)
    os.remove(tmp)

def main():
    os.makedirs(f"{HERE}/html", exist_ok=True)
    jobs = [(name, shot(img, g, b, badge), 1320, 2868) for name, img, g, b, badge in SHOTS] + [("hero.png", hero(), 2400, 1350)]
    for name, html, w, h in jobs:
        path = f"{HERE}/html/{name.replace('.png', '.html')}"
        open(path, "w").write(html)
        render(path, f"{OUT}/{name}", w, h)
        print(name)
    # 15.5·15.9cm(6.3형) 자리용 1206x2622: 비율이 거의 같아(0.4603 대 0.4600) 줄이기만 한다
    os.makedirs(f"{OUT}/6.3", exist_ok=True)
    for name, *_ in SHOTS:
        subprocess.run(["sips", "-z", "2622", "1206", f"{OUT}/{name}", "--out", f"{OUT}/6.3/{name}"], check=True, stdout=subprocess.DEVNULL)
    print("6.3/")
    # 헤더 자산 규격: 같은 배너를 크게 렌더한 뒤 5244x2950으로 맞춘다
    big = f"{OUT}/hero_5244x2950.png"
    render(f"{HERE}/html/hero.html", big, 2400, 1350, 2.2)
    subprocess.run(["sips", "-z", "2950", "5244", big], check=True, stdout=subprocess.DEVNULL)
    print("hero_5244x2950.png")

main()
