/** 시즌 이름(한국 시간): 11~4월은 그 시즌, 5~10월은 다가오는 시즌. 앱 HomeData.currentSeason과 같다. */
export function currentSeason(now = new Date()): string {
  const kst = new Date(now.getTime() + 9 * 3600_000 - 6 * 3600_000); // 영업일은 06:00 시작
  const y = kst.getUTCFullYear(), m = kst.getUTCMonth() + 1;
  const start = m <= 4 ? y - 1 : y;
  return `${start}-${String((start + 1) % 100).padStart(2, "0")}`;
}

