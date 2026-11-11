// 이름 거르기 (R16). 크루 이름과 표시 이름을 저장하기 전에 본다. 목록을 고치면 함수를 다시 배포한다.
// 거르기는 첫 방어선일 뿐이고, 빠져나간 이름은 신고(reportName)와 처리 스크립트로 다룬다.

/** 욕설·비하·성적 표현. 정규화한 이름(아래)에 들어 있으면 거부한다. 음절 단위로 비교한다. */
const PROFANITY = [
  "시발", "씨발", "시빨", "씨빨", "시팔", "씨팔", "씹", "좆", "좃", "존나",
  "개새", "개색", "병신", "븅신", "빙신", "느금", "니애미", "니에미", "창녀",
  "보지", "자지", "섹스", "fuck", "shit", "bitch",
];
/** 초성만 쓴 욕설. 모음 없이 남은 자모끼리만 맞춘다(음절로 쓴 이름의 자음과 섞지 않는다). */
const INITIALS = ["ㅅㅂ", "ㅆㅂ", "ㅂㅅ", "ㅈㄹ"];
/** 사칭: 이름 전체가 이것이면 거부(관리자1 → 관리자). "비관리자"처럼 일부인 것은 허용. */
const IMPERSONATION = ["관리자", "운영자", "운영진", "운영팀", "고객센터", "공식", "admin", "administrator", "official", "slopemate", "슬로프메이트"];
/** 앱 이름과 운영 역할을 함께 쓰면 거부("slopemate팬"은 허용, "슬로프메이트 공식"은 거부) */
const BRAND = ["slopemate", "슬로프메이트"];
const ROLE = ["관리자", "운영", "공식", "admin", "official", "team", "팀", "staff"];

const CHO = [..."ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"];
const JUNG = [..."ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"];
const JONG = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ", "ㄹㅅ", "ㄹㅌ", "ㄹㅍ", "ㄹㅎ",
  "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"];
const CONSONANTS = new Set(CHO);
const VOWELS = new Set(JUNG);

/** 한 글자를 자모 글자들로. 완성형, 첫·가운데·끝소리 자모, 호환 자모가 모두 같은 글자가 된다. 그 밖의 문자는 null. */
function letters(ch: string): string[] | null {
  const c = ch.codePointAt(0)!;
  if (c >= 0xac00 && c <= 0xd7a3) {
    const i = c - 0xac00;
    return [CHO[Math.floor(i / 588)], JUNG[Math.floor((i % 588) / 28)], ...JONG[i % 28]];
  }
  if (c >= 0x1100 && c < 0x1100 + 19) return [CHO[c - 0x1100]];
  if (c >= 0x1161 && c < 0x1161 + 21) return [JUNG[c - 0x1161]];
  if (c >= 0x11a8 && c < 0x11a8 + 27) return [...JONG[c - 0x11a8 + 1]];
  if (CONSONANTS.has(ch) || VOWELS.has(ch)) return [ch];
  if (/[ㄱ-ㅎ]/.test(ch)) return [...ch.normalize("NFKD")].flatMap((x) => letters(x) ?? []);
  if (/[a-z]/.test(ch)) return [ch];
  return null;
}

/** 비교용 이름: NFKC, 소문자, 한글 자모와 영문 외 문자(숫자, 공백, 기호, 폭 없는 문자)를 지운 뒤
 *  자모를 다시 음절로 묶는다. "시 1 발", "시ㅂㅏㄹ", "시​발"이 모두 "시발"이 된다. 저장하는 이름은 바꾸지 않는다. */
export function normalizeName(name: string): string {
  const stream = [...name.normalize("NFKC").toLowerCase()].flatMap((ch) => letters(ch) ?? []);
  let out = "";
  for (let i = 0; i < stream.length; ) {
    const l = stream[i], v = stream[i + 1];
    if (CONSONANTS.has(l) && v !== undefined && VOWELS.has(v)) {
      // 받침: 다음 자음이 모음 앞이 아니면 받침으로 붙인다(겹받침은 두 자음)
      let t = "";
      const a = stream[i + 2], b = stream[i + 3], c = stream[i + 4];
      if (a && CONSONANTS.has(a) && !(b && VOWELS.has(b))) {
        t = a;
        if (b && CONSONANTS.has(b) && JONG.includes(a + b) && !(c && VOWELS.has(c))) t = a + b;
      }
      const ti = JONG.indexOf(t);
      if (ti >= 0) {
        out += String.fromCodePoint(0xac00 + CHO.indexOf(l) * 588 + JUNG.indexOf(v) * 28 + ti);
        i += 2 + [...t].length;
        continue;
      }
    }
    out += l;
    i += 1;
  }
  return out;
}

const norm = (list: string[]) => list.map(normalizeName);
const PROFANITY_N = norm(PROFANITY), IMPERSONATION_N = norm(IMPERSONATION), BRAND_N = norm(BRAND), ROLE_N = norm(ROLE);

/** 쓸 수 없는 이름인지 */
export function isBannedName(name: string): boolean {
  const n = normalizeName(name);
  if (PROFANITY_N.some((w) => n.includes(w))) return true;
  // 초성 욕설: 음절에 묶이지 않고 남은 자음만 이어 붙여 본다
  const loose = [...n].filter((ch) => CONSONANTS.has(ch)).join("");
  if (INITIALS.some((w) => loose.includes(w))) return true;
  if (IMPERSONATION_N.includes(n)) return true;
  if (BRAND_N.some((b) => n.includes(b)) && ROLE_N.some((r) => n.includes(r))) return true;
  return false;
}
