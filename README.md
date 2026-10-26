# 🍅 Focus Guard

**한국어** | [English](README.en.md)

macOS 메뉴 막대 뽀모도로 + 집중 중 사이트 차단

- 집중 35분 → 정리 3분 → 휴식 7분 (변경 가능)
- 집중·정리 중 유튜브·인스타·링크드인 등 차단 (유튜브 뮤직은 허용)
- `⌥⇧L` 어디서든 "나중에 할 것" 메모
- 오늘 할 일 · 주간 공부 기록

## 설치

- 필요: **macOS 14 이상** / Chrome·Safari·Arc·Brave·Edge (Firefox ✕)
- 터미널에서:

```bash
xcode-select --install          # 처음 한 번만
git clone https://github.com/brightree/focus-guard.git
cd focus-guard/app
./build.sh
open FocusGuard.app
```

- 메뉴 막대에 🍅 → 완료
- 권한: **"브라우저 제어" 허용** (안 하면 차단 ✕) · 알림 허용
- 추천: 설정 → **로그인 시 자동 실행** 켜기 (앱 꺼지면 차단 ✕)

## 유의사항

- ⚠️ **집중 시작 시 열린 차단 사이트 탭 → 차단 페이지로 전환 → 쓰던 글 사라질 수 있음**
- 포기: 설정 문장 입력 필요 (기본 "일해야 졸업하지")
- 기록: 내 맥에만 저장 (`~/Library/Application Support/FocusGuard`), **암호화 ✕**
- 인터넷 전송 · 추적 · 관리자 권한 · 시스템 설정 변경 없음
- 내 맥 안에서만 열리는 작은 서버 사용 (`127.0.0.1:47321`, 차단 페이지용)
- 강제 차단 ✕ → 앱 종료·Firefox 사용 시 우회 가능
- 서명 없는 빌드 → 빌드된 앱 말고 **소스로 각자 빌드**, 재빌드 시 권한 다시 물을 수 있음
- 개인 프로젝트 → 버그 가능

## 삭제

- 설정 → **Focus Guard 삭제…** → 앱(+선택 시 기록) 휴지통으로 이동

자세한 보안·저장 방식·한계: [English README](README.en.md)

## 라이선스

[MIT](LICENSE)
