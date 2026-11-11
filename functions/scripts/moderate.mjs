#!/usr/bin/env node
// 신고 처리 (R16). 인자 없이 실행하면 사용법을 보여 준다.
// 인증: Google Cloud 관리자 자격 증명(ADC). 예: `gcloud auth application-default login` 뒤 실행,
// 또는 GOOGLE_APPLICATION_CREDENTIALS=저장소 밖 서비스 계정 키. 에뮬레이터는 FIRESTORE_EMULATOR_HOST.
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import * as m from "../lib/moderation.js";

initializeApp({ projectId: process.env.GCLOUD_PROJECT ?? "slopemate-f9a5b" });
const db = getFirestore();
const [cmd, a, b] = process.argv.slice(2);

const help = `npm run build 뒤 node scripts/moderate.mjs <명령>
  list                      미처리 신고(오래된 순, 같은 대상·이름 묶음)
  reset-name <신고ID>        표시 이름을 "${m.RESET_NAME}"으로(신고 당시 이름인 사본만)
  rename-crew <신고ID> <새 이름>
  close-crew <신고ID>        크루를 닫는다(멤버·초대·차단 기록 삭제)
  restrict-report <신고ID>   신고 대상(크루 이름이면 크루장)을 이용 제한하고 신고를 닫음
  restrict <uid>            신고 없이 계정 이용 제한 (unrestrict <uid>로 해제)
바꿀 것이 없었으면(대상이 이미 이름을 바꿈, 크루·계정이 없음) 신고는 "검토"로 닫히고 신고자에게 "검토했어요"로 알린다.
  dismiss <신고ID>          조치 없이 닫기
처리 목표: 접수 48시간 안. 시즌 중 매일 list를 본다.`;

/** 처리 결과 한 줄: 조치·검토, 이미 닫힌 신고면 기존 결과 */
function report(o) {
  if (o === null) return console.log("삭제 중인 계정이라 건너뜀(신고는 열어 둠)");
  const word = o.status === "resolved" ? "조치" : "검토";
  console.log(o.already ? `이미 ${word}로 닫힌 신고라 아무것도 하지 않음` : `${word}로 닫음${o.changed ? `(${o.changed}곳 바꿈)` : "(바꿀 것이 없었음)"}`);
}

switch (cmd) {
  case "list": {
    const groups = await m.listOpen(db);
    if (groups.length === 0) { console.log("미처리 신고 없음"); break; }
    const oldest = groups[0].oldest;
    console.log(`미처리 ${groups.length}건, 가장 오래된 접수 ${oldest.toISOString()} (${Math.floor((Date.now() - oldest.getTime()) / 3600_000)}시간 전)`);
    for (const g of groups) {
      console.log(`- ${g.target === "crew_name" ? "크루 이름" : "표시 이름"} "${g.name}" 크루 ${g.crew_id} 대상 ${g.target_uid} · ${g.ids.length}건 · ${g.oldest.toISOString()} · 신고ID ${g.ids[0]}`);
    }
    break;
  }
  case "reset-name": report(await m.resetName(db, a)); break;
  case "rename-crew": report(await m.renameCrew(db, a, b)); break;
  case "close-crew": report(await m.closeCrew(db, a)); break;
  case "restrict-report": report(await m.restrictByReport(db, a)); break;
  case "dismiss": report(await m.dismiss(db, a)); break;
  case "restrict": console.log((await m.restrict(db, a, true)) ? "완료" : "계정이 없거나 삭제 중"); break;
  case "unrestrict": await m.restrict(db, a, false); console.log("완료"); break;
  default: console.log(help);
}
