// 익명 표본 (R12, 05-design 4·6장, decisions 2026-11-12).
// 계정 없이 표본 하나씩 받아 시간대별 집계 숫자만 올린다. 요청 내용·IP는 저장하지 않고, 로그에는 사유 코드만 남긴다.
// 수신 시각은 집계 문서의 Firestore 메타데이터(만든·고친 시각)로만 남는다(05-design 6장 남은 위험).
// Cloud Run 요청 로그는 배포 때 제외 필터로 뺀다(docs/06-verification R12).
import { getAppCheck } from "firebase-admin/app-check";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { onRequest } from "firebase-functions/v2/https";
import { SAMPLE_IDS } from "./sampleIds.js";

/** 급할 때 서버에서 받기만 하고 버린다: functions/.env에 SAMPLES_ENABLED=false로 다시 배포. 첫 차단은 앱이 읽는 config.json의 samples */
const enabled = () => process.env.SAMPLES_ENABLED !== "false";

export type Sample =
  | { kind: "snow"; resort: string; slope: string; date: string; slot: number; value: "ice" | "ok" | "slush" }
  | { kind: "wait"; resort: string; lift: string; date: string; slot: number; sec: number };

const MAX_AGE_DAYS = 8; // 기기는 7일 뒤 버린다. 하루 여유
const MAX_WAIT = 1800;  // 앱 RunDetector maxWait

/** 한국 날짜 "YYYY-MM-DD" */
export function kstDate(now: Date): string {
  return new Date(now.getTime() + 9 * 3600_000).toISOString().slice(0, 10);
}

/** 정해진 모양·범위·허용 ID가 아니면 null. 다른 필드가 있어도 null(R17). */
export function parseSample(body: unknown, now = new Date()): Sample | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  const keys = Object.keys(b).sort().join(",");
  const ids = typeof b.resort === "string" && Object.hasOwn(SAMPLE_IDS, b.resort) ? SAMPLE_IDS[b.resort] : null;
  if (!ids || typeof b.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(b.date)) return null;
  const day = Date.parse(b.date + "T00:00:00Z");
  const today = Date.parse(kstDate(now) + "T00:00:00Z");
  if (Number.isNaN(day) || new Date(day).toISOString().slice(0, 10) !== b.date) return null;
  if (day > today || today - day > MAX_AGE_DAYS * 86400_000) return null;
  if (!Number.isInteger(b.slot) || (b.slot as number) < 0 || (b.slot as number) > 95) return null;
  const base = { resort: b.resort as string, date: b.date, slot: b.slot as number };
  if (b.kind === "snow" && keys === "date,kind,resort,slope,slot,value") {
    if (typeof b.slope !== "string" || !ids.slopes.includes(b.slope)) return null;
    if (b.value !== "ice" && b.value !== "ok" && b.value !== "slush") return null;
    return { kind: "snow", ...base, slope: b.slope, value: b.value };
  }
  if (b.kind === "wait" && keys === "date,kind,lift,resort,sec,slot") {
    if (typeof b.lift !== "string" || !ids.lifts.includes(b.lift)) return null;
    if (!Number.isInteger(b.sec) || (b.sec as number) < 0 || (b.sec as number) > MAX_WAIT) return null;
    return { kind: "wait", ...base, lift: b.lift, sec: b.sec as number };
  }
  return null;
}

/** 집계 문서에 더하기만 한다. date는 3시즌 뒤 지울 때 쓴다. */
export async function addSample(s: Sample): Promise<void> {
  const db = getFirestore();
  if (s.kind === "snow") {
    await db.doc(`snow_agg/${s.resort}_${s.slope}_${s.date}_${s.slot}`)
      .set({ resort: s.resort, slope: s.slope, date: s.date, slot: s.slot, [s.value]: FieldValue.increment(1) }, { merge: true });
  } else {
    await db.doc(`wait_agg/${s.resort}_${s.lift}_${s.date}_${s.slot}`)
      .set({ resort: s.resort, lift: s.lift, date: s.date, slot: s.slot, count: FieldValue.increment(1),
             sum_sec: FieldValue.increment(s.sec), sum_sq: FieldValue.increment(s.sec * s.sec) }, { merge: true });
  }
}

/** 요청마다 일회용 App Check 토큰(limited use)을 쓰고 받은 즉시 소비한다. 같은 토큰으로 표본끼리 묶이지 않게. */
async function appCheckOK(token: string | undefined): Promise<boolean> {
  if (!token) return false;
  if (process.env.FUNCTIONS_EMULATOR === "true") return token === "emulator-ok";
  try {
    const r = await getAppCheck().verifyToken(token, { consume: true });
    return !r.alreadyConsumed;
  } catch {
    return false;
  }
}

// index.ts의 setGlobalOptions보다 이 모듈이 먼저 로드되므로 리전을 직접 적는다(서울)
export const submitSample = onRequest({ region: "asia-northeast3", cors: false, maxInstances: 5, memory: "256MiB" }, async (req, res) => {
  if (req.method !== "POST") { res.status(405).end(); return; }
  if (!req.is("application/json") || (req.rawBody?.length ?? 0) > 1024) { res.status(400).end(); return; }
  if (!(await appCheckOK(req.header("X-Firebase-AppCheck")))) {
    logger.warn("sample rejected", { reason: "appcheck" });
    res.status(401).end();
    return;
  }
  const s = parseSample(req.body);
  if (!s) {
    logger.warn("sample rejected", { reason: "invalid" });
    res.status(400).end();
    return;
  }
  if (enabled()) {
    try {
      await addSample(s);
    } catch {
      logger.error("sample add failed", { reason: "write" });
      res.status(500).end();
      return;
    }
  }
  res.status(204).end();
});
