<div align="center">

# SlopeMate ⛷️
국내 스키장 전용 트래킹·기록 iOS 앱

</div>

시즌권자를 위한 하루·시즌 기록 앱. 버전 2.0을 2027년 11월에 출시한다. 기획은 [`docs/`](docs/), 진행 상황은 [`docs/todo.md`](docs/todo.md).

## 실행

```bash
git clone https://github.com/JIHO45/SlopeMate.git
open SlopeMate/SlopeMate.xcodeproj
```

Scheme `SlopeMate`, iOS 17.6 이상. API 키는 필요 없다.

## 구성

| 영역 | 내용 |
| --- | --- |
| UI | SwiftUI |
| 저장 | SQLite ([GRDB](https://github.com/groue/GRDB.swift)) |
| 리조트 데이터 | `SlopeMate/Resources/resorts.json` (12곳) |

## Contact
- **Email**: pjh030331@gmail.com
