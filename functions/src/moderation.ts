// 신고 처리 (R16). 관리 화면 대신 개발자가 로컬에서 scripts/moderate.mjs로 부른다(관리자 인증).
// 이름은 users, 크루 멤버 문서, 차단 기록(bans)에 복사돼 있으므로 사본마다 신고 당시 이름과 같은 것만 바꾼다.
// 조치와 신고 닫기는 한 트랜잭션이다(조치만 되고 신고가 열린 채 남지 않음). 이미 닫힌 신고는 아무것도 하지 않고
// 기존 결과를 돌려준다(같은 명령을 다시 실행해도 결과가 뒤집히지 않음).
// 실제로 바꾼 것이 있으면 resolved("조치했어요"), 바꿀 것이 없었으면(대상이 이미 이름을 바꿈 등) dismissed("검토했어요")로 닫는다.
import { DocumentSnapshot, FieldValue, Firestore, Transaction } from "firebase-admin/firestore";

export const RESET_NAME = "스키어";

/** 미처리 신고: 오래된 순, 같은 대상·이름끼리 묶어 건수와 가장 오래된 접수 시각을 보여 준다. */
export async function listOpen(db: Firestore) {
  const snap = await db.collection("reports").where("status", "==", "open").get();
  const groups = new Map<string, { ids: string[]; oldest: Date; crew_id: string; target: string; target_uid: string; name: string }>();
  for (const d of snap.docs) {
    const k = [d.get("crew_id"), d.get("target"), d.get("target_uid"), d.get("name")].join("|");
    const at: Date = d.get("at")?.toDate() ?? new Date();
    const g = groups.get(k) ?? { ids: [] as string[], oldest: at, crew_id: d.get("crew_id"), target: d.get("target"), target_uid: d.get("target_uid"), name: d.get("name") };
    g.ids.push(d.id);
    if (at < g.oldest) g.oldest = at;
    groups.set(k, g);
  }
  return [...groups.values()].sort((a, b) => a.oldest.getTime() - b.oldest.getTime());
}

type Status = "resolved" | "dismissed";
/** 처리 결과: 이번에 닫았으면 status, 이미 닫혀 있었으면 already에 기존 결과 */
export type Outcome = { status: Status; already: boolean; changed: number };

/** 한 신고와, 같은 크루·대상·이름의 미처리 신고들(함께 닫는다). 트랜잭션 안에서 다른 읽기보다 먼저 부른다. */
async function readGroup(tx: Transaction, db: Firestore, id: string) {
  const r = await tx.get(db.doc(`reports/${id}`));
  if (!r.exists) throw new Error(`신고 ${id} 없음`);
  const open = await tx.get(db.collection("reports").where("crew_id", "==", r.get("crew_id")).where("status", "==", "open"));
  const same = open.docs.filter((d) => d.get("target") === r.get("target") && d.get("target_uid") === r.get("target_uid") && d.get("name") === r.get("name"));
  return { r, same };
}

function closeGroup(tx: Transaction, g: { r: DocumentSnapshot; same: DocumentSnapshot[] }, status: Status) {
  const docs = new Map([g.r, ...g.same].map((d) => [d.id, d]));
  for (const d of docs.values()) tx.update(d.ref, { status, resolved_at: FieldValue.serverTimestamp() });
}

/** 공통 틀: 신고를 읽고, 이미 닫혔으면 기존 결과, 아니면 act가 바꾼 곳 수에 따라 조치·검토로 닫는다.
 *  act가 -1을 돌려주면(삭제 중인 계정 등) 신고를 열어 둔다. */
async function handle(db: Firestore, id: string,
                      act: (tx: Transaction, r: DocumentSnapshot) => Promise<{ count: number; write: () => void }>): Promise<Outcome | null> {
  return db.runTransaction(async (tx) => {
    const g = await readGroup(tx, db, id);
    const prev = g.r.get("status");
    if (prev !== "open") return { status: prev as Status, already: true, changed: 0 };
    const { count, write } = await act(tx, g.r);   // 읽기는 act 안에서 끝내고, 쓰기는 write에서
    if (count < 0) return null;
    write();
    const status: Status = count > 0 ? "resolved" : "dismissed";
    closeGroup(tx, g, status);
    return { status, already: false, changed: count };
  });
}

export async function dismiss(db: Firestore, id: string) {
  return handle(db, id, async () => ({ count: 0, write: () => {} }));
}

/** 표시 이름 신고: 신고 당시 이름인 사본만 RESET_NAME으로. 삭제 중인 계정은 건드리지 않고 신고를 열어 둔다(null). */
export async function resetName(db: Firestore, id: string) {
  return handle(db, id, async (tx, r) => {
    if (r.get("target") !== "display_name") throw new Error("표시 이름 신고가 아님");
    const uid = r.get("target_uid"), name = r.get("name");
    const user = await tx.get(db.doc(`users/${uid}`));
    const members = await tx.get(db.collectionGroup("members").where("uid", "==", uid));
    const bans = await tx.get(db.collectionGroup("bans").where("uid", "==", uid));
    if (user.get("deleting") === true) return { count: -1, write: () => {} };
    const targets = [user, ...members.docs, ...bans.docs].filter((d) => d.exists && d.get("display_name") === name);
    return { count: targets.length, write: () => targets.forEach((d) => tx.update(d.ref, { display_name: RESET_NAME })) };
  });
}

/** 크루 이름 신고: 지금 이름이 신고 당시 이름일 때만 바꾼다. */
export async function renameCrew(db: Firestore, id: string, newName: string) {
  return handle(db, id, async (tx, r) => {
    if (r.get("target") !== "crew_name") throw new Error("크루 이름 신고가 아님");
    const crew = await tx.get(db.doc(`crews/${r.get("crew_id")}`));
    const ok = crew.exists && crew.get("name") === r.get("name");
    return { count: ok ? 1 : 0, write: () => { if (ok) tx.update(crew.ref, { name: newName }); } };
  });
}

/** 크루 닫기: 멤버·초대·차단 기록·크루를 지운다. 동시에 들어온 가입은 같은 크루 문서를 읽어 트랜잭션이 막는다. */
export async function closeCrew(db: Firestore, id: string) {
  return handle(db, id, async (tx, r) => {
    const crew = await tx.get(db.doc(`crews/${r.get("crew_id")}`));
    if (!crew.exists) return { count: 0, write: () => {} };
    const members = await tx.get(crew.ref.collection("members"));
    const bans = await tx.get(crew.ref.collection("bans"));
    return {
      count: 1,
      write: () => {
        for (const d of [...members.docs, ...bans.docs]) tx.delete(d.ref);
        tx.delete(db.doc(`invites/${crew.get("invite_token")}`));
        tx.delete(crew.ref);
      },
    };
  });
}

/** 계정 이용 제한: 크루 만들기·가입·이름 바꾸기·합계 보내기·신고를 막는다(나가기·계정 삭제는 됨). 다시 로그인해도 풀리지 않는다. */
export async function restrict(db: Firestore, uid: string, on = true) {
  return db.runTransaction(async (tx) => {
    const user = await tx.get(db.doc(`users/${uid}`));
    if (!user.exists || user.get("deleting") === true) return false;
    tx.update(user.ref, { restricted: on });
    return true;
  });
}

/** 신고 대상(크루 이름이면 크루장)을 이용 제한하고 그 신고를 닫는다. 계정이 없거나 삭제 중이면 검토로 닫는다. */
export async function restrictByReport(db: Firestore, id: string) {
  return handle(db, id, async (tx, r) => {
    const user = await tx.get(db.doc(`users/${r.get("target_uid")}`));
    const ok = user.exists && user.get("deleting") !== true;
    return { count: ok ? 1 : 0, write: () => { if (ok) tx.update(user.ref, { restricted: true }); } };
  });
}
