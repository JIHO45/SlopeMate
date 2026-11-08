<div align="center">

# SlopeMate ⛷️
국내 스키장 전용 트래킹·기록 iOS 앱

</div>

시즌권자를 위한 하루·시즌 기록 앱. 버전 2.0을 이번 시즌 개장(2026년 11월 말)에 출시하고 업데이트로 기능을 더한다. 기획은 [`docs/`](docs/), 진행 상황은 [`docs/todo.md`](docs/todo.md).

## 실행

```bash
git clone https://github.com/JIHO45/SlopeMate.git
open SlopeMate/SlopeMate.xcodeproj
```

Scheme `SlopeMate`, iOS 17.6 이상. API 키는 필요 없다.

빌드 설정: `Debug`, `TestFlight`에는 테스트 기록 내보내기(R22)가 들어 있고 `Release`(앱스토어)에는 없다. TestFlight 배포는 `TestFlight` 설정으로, 앱스토어 제출은 `Release` 설정으로 아카이브한다. TestFlight 빌드가 앱스토어로 잘못 나가도 앱스토어에서 받은 앱에서는 내보내기가 보이지 않는다.

테스트 기록 재생: `SlopeMateTests/Replays/`에 내보낸 기록 파일(`*.json`)과 기대 결과(`*.expected.json`)를 두면 테스트가 하강 횟수·거리·고도차를 확인한다.

## 구성

| 영역 | 내용 |
| --- | --- |
| UI | SwiftUI |
| 저장 | SQLite ([GRDB](https://github.com/groue/GRDB.swift)) |
| 리조트 데이터 | `SlopeMate/Resources/resorts.json` (12곳) |

## Contact
- **Email**: pjh030331@gmail.com
