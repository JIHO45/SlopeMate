// 에뮬레이터 공통: 로그인 토큰, 계정 문서, 함수 호출, 데이터 비우기
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

export const PROJECT = "demo-slopemate";
const AUTH = `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST ?? "127.0.0.1:9099"}`;
const FS = `http://${process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080"}`;
const FN = `http://127.0.0.1:5001/${PROJECT}/asia-northeast3`;

if (!getApps().length) initializeApp({ projectId: PROJECT });
export const db = getFirestore();

/** 에뮬레이터에 새 사용자를 만들고 users 문서를 넣는다. user: false면 문서 없이. */
export async function newUser(name = "스키어", user = {}) {
  const r = await fetch(`${AUTH}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ returnSecureToken: true }),
  }).then((r) => r.json());
  if (user !== false) {
    await db.doc(`users/${r.localId}`).set({ display_name: name, age14_confirmed: true, deleting: false, created_at: new Date(), ...user });
  }
  return { uid: r.localId, token: r.idToken };
}

/** Callable 호출. 성공이면 { result }, 실패면 { error: { status, message } } */
export async function call(fn, data, who) {
  const headers = { "content-type": "application/json" };
  if (who) headers.authorization = `Bearer ${who.token}`;
  const res = await fetch(`${FN}/${fn}`, { method: "POST", headers, body: JSON.stringify({ data }) });
  return res.json();
}

/** aborted(경합)만 몇 번 다시 부른다 */
export async function callRetry(fn, data, who) {
  for (let i = 0; ; i++) {
    const r = await call(fn, data, who);
    if (r.error?.status !== "ABORTED" || i >= 20) return r;
    await new Promise((s) => setTimeout(s, 50 + Math.random() * 200));
  }
}

export async function clear() {
  await fetch(`${FS}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`, { method: "DELETE" });
}

/** 크루 전체 상태: 크루 문서, 멤버 uid 목록, 초대 문서 수 */
export async function snapshot(crewId) {
  const crew = await db.doc(`crews/${crewId}`).get();
  const members = (await db.collection(`crews/${crewId}/members`).get()).docs.map((d) => d.id).sort();
  const invites = (await db.collection("invites").where("crew_id", "==", crewId).get()).size;
  return { crew: crew.exists ? crew.data() : null, members, invites };
}
