# Firebase Hosting (앱 업데이트 없이 바꾸는 파일)

`firebase deploy --only hosting`으로 올린다. 앱은 앞에 있는 동안 1시간에 한 번(켤 때·다시 볼 때 마지막으로 받은 지 1시간이 지났으면 바로) 받아 기기에 저장하고, 받지 못하면 마지막으로 받은 값을 쓴다.

- `public/config.json`
  - `slopeNames`: 슬로프 이름을 보여 줄 리조트 ID 목록(R9). 현장 기준을 통과한 리조트만 넣는다. 빠지면 꺼진다.
  - `crewSync`: false면 앱이 시즌 합계를 보내지 않는다(비용 차단 스위치, 05-design 5장).
  - `samples`: false면 익명 표본을 보내지 않는다(R12, 표본 전송을 붙일 때 사용). 두 스위치는 차단용이라 평소에는 true이고, 표본을 실제로 보낼지는 사용자 동의가 정한다.
- `public/timetables.json`: 운영 시간표(R7). 앱 내장 `SlopeMate/Resources/timetables.json`과 같은 형식이다. 앱은 내장분과 합쳐 쓰고, 같은 리조트·기간이 겹치면 `version`이 큰 것을 쓴다. 고칠 때는 `version`을 올리고 `updatedAt`을 고친 시각으로 바꾼다.

- `public/.well-known/apple-app-site-association`: Universal Links(앱 ID `CH7CDR7288.com.Joe.SlopeMate`, 경로 `/i/*`). 확장자가 없어 firebase.json에서 `Content-Type: application/json`을 따로 준다. 숨김 파일은 `.DS_Store`·`.git`만 빼고 올라가므로 이 폴더에 다른 숨김 파일을 두지 않는다.
- `public/invite.html`: `/i/{토큰}` 초대 웹페이지(앱이 없거나 링크가 웹으로 열렸을 때). 로그인 없이 previewInvite를 불러 크루 이름·인원·크루장 이름을 보여 주고, App Store·링크 복사·이름 신고(문의 메일)를 둔다. `noindex`, `Referrer-Policy: no-referrer`.
- `public/support.html`(`/support`): 앱스토어 지원 URL. `public/privacy.html`(`/privacy`): 개인정보처리방침(초안, M3에서 최종 점검). 앱 설정의 개인정보처리방침 행이 연결된다.

형식이 틀린 파일은 앱이 버리고 이전 값을 쓴다. 올리기 전에 앱 테스트(`HostingFilesTests`)로 두 파일이 읽히는지 확인한다.
