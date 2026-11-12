// 익명 표본 허용 ID 목록(R12)을 앱 내장 지도에서 만든다: node scripts/sample-ids.mjs
// 지난 판 앱이 보내는 ID도 받아야 하므로 기존 목록에 더하기만 한다(지우지 않음). 지도를 바꾸면 함수를 먼저 배포한 뒤 앱을 낸다.
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";

const maps = new URL("../../SlopeMate/Resources/maps/", import.meta.url);
const out = new URL("../src/sampleIds.ts", import.meta.url);
const ids = (xs) => (xs ?? []).map((x) => (typeof x === "string" ? x : x.id));

const prev = existsSync(out) ? JSON.parse(readFileSync(out, "utf8").match(/= (\{[\s\S]*\});/)[1]) : {};
const all = { ...prev };
for (const f of readdirSync(maps).filter((f) => f.endsWith(".json"))) {
  const m = JSON.parse(readFileSync(new URL(f, maps), "utf8"));
  const p = all[m.resort_id] ?? { slopes: [], lifts: [] };
  p.slopes = [...new Set([...p.slopes, ...ids(m.slopes), ...ids(m.retired_slopes)])].sort();
  p.lifts = [...new Set([...p.lifts, ...ids(m.lifts), ...ids(m.retired_lifts)])].sort();
  all[m.resort_id] = p;
}
const sorted = Object.fromEntries(Object.keys(all).sort().map((k) => [k, all[k]]));
writeFileSync(out, `// scripts/sample-ids.mjs가 만든 파일. 직접 고치지 않는다.\nexport const SAMPLE_IDS: Record<string, { slopes: string[]; lifts: string[] }> = ${JSON.stringify(sorted, null, 1)};\n`);
console.log(Object.entries(sorted).map(([k, v]) => `${k} ${v.slopes.length}/${v.lifts.length}`).join("\n"));
