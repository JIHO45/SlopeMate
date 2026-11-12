// 익명 표본 (R12): 집계 숫자만 오르고 개별 표본이 남지 않음, 모양·범위·허용 ID·App Check 거부, 클라이언트 접근 거부.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { assertFails, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc } from "firebase/firestore";
import { clear, db, PROJECT } from "./helpers.js";
import { kstDate, parseSample } from "../lib/samples.js";

const URL_ = `http://127.0.0.1:5001/${PROJECT}/asia-northeast3/submitSample`;
const now = new Date("2026-12-06T03:00:00Z"); // 한국 12월 6일 12:00
const today = kstDate(new Date());

function send(body, { token = "emulator-ok", type = "application/json", method = "POST" } = {}) {
  const headers = { "content-type": type };
  if (token) headers["X-Firebase-AppCheck"] = token;
  return fetch(URL_, { method, headers, body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined });
}
const snow = (o = {}) => ({ kind: "snow", resort: "high1", slope: "high1-s01", date: today, slot: 40, value: "ice", ...o });
const wait = (o = {}) => ({ kind: "wait", resort: "high1", lift: "high1-l01", date: today, slot: 40, sec: 125, ...o });

beforeEach(clear);

test("parseSample: 정상 표본, 한국 날짜 0~8일 전만", () => {
  assert.ok(parseSample(snow({ date: "2026-12-06" }), now));
  assert.ok(parseSample(snow({ date: "2026-11-28" }), now));
  assert.equal(parseSample(snow({ date: "2026-11-27" }), now), null); // 9일 전
  assert.equal(parseSample(snow({ date: "2026-12-07" }), now), null); // 미래
  assert.equal(parseSample(snow({ date: "2026-02-30" }), now), null);
  // 한국은 이미 12월 7일(UTC 12월 6일 16시)
  assert.ok(parseSample(snow({ date: "2026-12-07" }), new Date("2026-12-06T16:00:00Z")));
  assert.ok(parseSample(wait({ date: "2026-12-06", sec: 0 }), now));
  assert.ok(parseSample(wait({ date: "2026-12-06", sec: 1800 }), now));
});

test("parseSample: 다른 필드·범위·허용 ID 밖이면 거부", () => {
  const bad = [
    snow({ extra: 1 }), snow({ uid: "a" }), snow({ lat: 37.1 }), snow({ value: "powder" }), snow({ slot: 96 }), snow({ slot: 1.5 }),
    snow({ slope: "high1-s99" }), snow({ slope: "yongpyong-s01" }), snow({ resort: "nowhere" }), snow({ resort: "__proto__" }),
    wait({ sec: -1 }), wait({ sec: 1801 }), wait({ sec: 12.5 }), wait({ lift: "high1-s01" }),
    { ...snow(), kind: "wait" }, null, [], "x",
  ];
  for (const b of bad) assert.equal(parseSample(typeof b === "object" && b && !Array.isArray(b) ? { ...b, date: "2026-12-06" } : b, now), null, JSON.stringify(b));
});

test("보내면 집계 숫자만 오르고 요청 내용은 남지 않음", async () => {
  for (const v of ["ice", "ice", "ok"]) assert.equal((await send(snow({ value: v }))).status, 204);
  assert.equal((await send(wait())).status, 204);
  assert.equal((await send(wait({ sec: 35 }))).status, 204);

  const s = await db.doc(`snow_agg/high1_high1-s01_${today}_40`).get();
  assert.deepEqual(s.data(), { resort: "high1", slope: "high1-s01", date: today, slot: 40, ice: 2, ok: 1 });
  const w = await db.doc(`wait_agg/high1_high1-l01_${today}_40`).get();
  assert.deepEqual(w.data(), { resort: "high1", lift: "high1-l01", date: today, slot: 40, count: 2, sum_sec: 160, sum_sq: 125 * 125 + 35 * 35 });
  // 집계 문서 두 개 말고는 아무것도 없다
  const cols = (await db.listCollections()).map((c) => c.id).sort();
  assert.deepEqual(cols, ["snow_agg", "wait_agg"]);
  assert.equal((await db.collection("snow_agg").get()).size, 1);
});

test("App Check 없음·틀림, 잘못된 요청은 거부하고 아무것도 쓰지 않음", async () => {
  assert.equal((await send(snow(), { token: null })).status, 401);
  assert.equal((await send(snow(), { token: "fake" })).status, 401);
  assert.equal((await send(snow({ extra: 1 }))).status, 400);
  assert.equal((await send("not json", { type: "text/plain" })).status, 400);
  assert.equal((await send("{not json")).status, 400); // application/json인데 JSON이 아님
  assert.equal((await send({ ...snow(), pad: "x".repeat(2000) })).status, 400);
  assert.equal((await send(null, { method: "GET" })).status, 405);
  assert.equal((await db.listCollections()).length, 0);
});

test("클라이언트는 집계를 읽지도 쓰지도 못함", async () => {
  const env = await initializeTestEnvironment({
    projectId: PROJECT,
    firestore: { rules: readFileSync(new URL("../../firebase/firestore.rules", import.meta.url), "utf8") },
  });
  try {
    for (const c of [env.unauthenticatedContext(), env.authenticatedContext("a")]) {
      const f = c.firestore();
      await assertFails(getDoc(doc(f, "snow_agg/x")));
      await assertFails(getDoc(doc(f, "wait_agg/x")));
      await assertFails(setDoc(doc(f, "snow_agg/x"), { ice: 1 }));
    }
  } finally {
    await env.cleanup();
  }
});
