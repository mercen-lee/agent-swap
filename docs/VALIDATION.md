# 검증과 알려진 제한

검증 기준일: 2026-10-15 · Asia/Seoul. 이 문서는 개발 중인 소스의 확인 범위를 기록합니다. **v1 완료·배포 준비를 의미하지 않습니다.** 개인 계정 정보, 인증 원문, 대화와 로컬 진단 로그는 포함하지 않습니다.

## 확인 환경

| 항목 | 확인한 버전 |
|---|---|
| Xcode | 27.0 (27A266a) |
| Swift | 6.4, Swift 언어 모드 6 |
| 앱 배포 대상 | macOS 14 이상 |
| 실제 실행 환경 | Apple Silicon, macOS 27.0.1 (26A434) |
| Claude Code | 2.1.296 |
| Claude 데스크톱 | 2.37337.1, `com.anthropic.claudefordesktop` |
| Codex CLI | 0.162.0-alpha.17.2 |
| Codex 데스크톱 | 26.1007.30912, `com.openai.codex` |

다른 버전의 호환성은 해당 환경에서 다시 확인해야 합니다. macOS 14·15에서의 실제 실행 검증은 아직 없습니다.

## 재현 명령

전체 Xcode를 사용합니다. Command Line Tools만 선택된 환경에서는 Swift Testing 모듈이 없을 수 있습니다. 현재 앱 Release 빌드는 Xcode 27과 macOS SDK 27로 검증합니다.

```sh
./scripts/test-core.sh
./scripts/test-core.sh --filter AutomaticSwitchTests
./scripts/build-app.sh
codesign --verify --deep --strict build/AgentSwap.app
plutil -lint AgentSwapApp/Info.plist AgentSwap.xcodeproj/project.pbxproj
```

테스트 스크립트는 Xcode의 `xcrun swift`, native SwiftPM, 별도 scratch 경로를 사용합니다. 기본 캐시는 `build/CoreTests`이며 동시 실행 시 `AGENTSWAP_TEST_SCRATCH_PATH`를 서로 다르게 지정합니다. 실행 중인 앱을 빌드 스크립트로 덮어쓰지 않습니다.

## 자동 검증

Core **252개 테스트·20개 스위트 통과**, Release **BUILD SUCCEEDED**, 앱 deep·strict 서명 검증과 plist·diff 검사 통과를 확인했습니다. 기존 macOS Keychain API의 deprecation 경고는 남아 있으며, 확인한 빌드에는 동시성 경고나 컴파일 오류가 없었습니다.

저장소 준비 과정에서도 새 `scripts/test-core.sh`로 252개·20개 스위트가 통과했습니다. 전용 skill·CI YAML·내부 문서 링크·shell 문법·ignore 규칙과 index의 비밀 정보 후보 검사를 통과했습니다. 기본 앱을 교체하거나 인증을 변경하지 않았습니다.

첫 GitHub CI는 Core 빌드를 완료했지만 테스트 실행이 끝나지 않고 작업의 20분 제한 부근에서 취소됐습니다. 별도 strict cooperative pool 실행에서 Codex 취소 fixture의 동기 대기로 테스트가 정체되는 문제를 재현했습니다. 취소·해제 제어를 독립 Dispatch 실행기로 옮기고 대기에 상한과 실패 assertion을 추가했으며 기존 병렬화·인증 보존 검증은 유지했습니다. 수정 후 관련 9개 테스트가 strict·일반 실행 모두 통과했고, 전체 252개·20개 스위트도 일반 2.973초·strict 3.502초에 통과했습니다. 이 로컬 재현을 첫 원격 실행의 유일한 원인으로 단정하지 않으며 수정본의 원격 CI에서 Core 테스트 통과를 확인했습니다. 이어진 앱 Release 빌드는 Xcode 26.6·Swift 6.3.3의 컴파일러 내부 IR 생성 중 충돌했습니다. 따라서 CI와 릴리즈 workflow를 로컬 Universal 빌드가 통과한 Xcode 27 도구로 맞췄으며, macOS 실행 최소 버전 14.0은 유지합니다. 다른 앱 빌드 도구의 호환성은 확인하지 않았습니다.

Fixture는 합성 인증, 임시 디렉터리, 주입한 HTTP·Keychain·프로세스 제어를 사용합니다. 테스트를 실행하기 위해 실제 계정에 로그인할 필요는 없습니다.

| 경계 | 검증한 동작 |
|---|---|
| 사용량 파싱 | Claude 공통·모델 창, Codex 가변 한도·크레딧·초기화 횟수, 누락·추가 필드, UTC 시각 |
| 조회·자동 전환 | 429·네트워크 오류, 마지막 정상 캐시, 임계치·최소 개선·등록 순서·유예·오래된 데이터·후보 없음 |
| 로그인·식별 | 중복 등록, 메타데이터 보존, 격리 프로필 정리, 취소, 수동 코드 stdin, 사용자 이름 fallback |
| 저장소 | file·Keychain·auto 우선순위, 알 수 없는 형식·secrets·ephemeral 거부, 파일 권한·원자적 교체·symlink 거부 |
| Claude 전환 | CLI 잠금, 공유 MCP·플러그인·계정 외 설정 보존, 입력 한도 사전 거부, 정확한 읽기 검증 |
| 회전·복구 | 만료·동시 갱신, 첫 저장 실패의 successor 보존, 부분 실패·중단 복구, 제3 세대 거부, 완료 저널 정리 |
| Codex 프로세스 | CLI·IDE·데몬 차단, 정상 종료 실패·미확인, 종료 후 최신 백업·세대 재확인, 재실행 실패 |
| 앱 수명 | 단일 실행 잠금, 초기화·대기열·종료 교착 방지, 저장 실패 시 정상 종료 보류 |
| Claude 로컬 목록 | 원본 대화 불변, 대상 편집·삭제 표시 보존, 중복·SSH·알 수 없는 형식 거부, 생성 자료의 제한된 복원 |
| 읽기 전용 승인 | 선택한 앱 저장 인증만 읽기, 인증 쓰기·전환·캐시 변경 없음, 메타데이터 저장 오류 중 사용 |

테스트 통과와 자체 저장소 읽기는 제공자 CLI의 인증 읽기나 데스크톱 로그인 변경을 대신하지 않습니다.

## 실제 앱 확인 범위

| 항목 | 결과·범위 |
|---|---|
| 대시보드 | 데모로 라이트·다크, 제공자 필터, 목록·상세, 최소 760×520, 추가 시트·설정·접근성을 확인 |
| 메뉴바 수명 | 창을 닫은 뒤 실행 유지, 실제 메뉴 요약과 대시보드 재열기를 사용자 확인. 앞선 UI 빌드의 결과 |
| 실제 메타데이터 | 별명·자동 전환 후보 저장과 원래 값 복원을 확인 |
| 격리 로그인 | 공식 CLI와 브라우저 로그인, 현재 로그인 가져오기, 중복 계정 갱신을 확인 |
| Keychain 승인 | 항목별 항상 허용 후 반복 새로고침에서 등록 계정들의 정상 조회와 오류 해제를 확인 |
| Claude CLI 전환 | 최종 빌드의 GUI A → B → A, 공식 CLI 로그인·사용자·워크스페이스 일치, API 조회, 공유 설정 보존을 확인 |
| Codex 실행 중 조회 | 소비 프로세스가 실행 중일 때 새로고침 전후 네이티브 인증과 데스크톱 PID 불변, 정상 API 조회와 적용 대기를 확인 |
| 앱 아이콘 | ImageGen 원본, macOS 10개 asset 크기·alpha, Release 반영을 확인 |

실계정 화면은 저장하지 않았습니다. [스크린샷](screenshots/)은 합성 계정을 사용하는 데모입니다. CLI 로그인과 API 조회 성공은 Claude 데스크톱의 로그인 변경·기존 Code 대화 재개 성공으로 해석하지 않습니다. 동일 Codex 계정의 재로그인은 서로 다른 두 계정의 전환 검증이 아닙니다.

## 남은 완료 조건

- 두 개의 서로 다른 Codex 구독 계정으로 CLI·데스크톱 로그인과 사용량 변경, 원래 계정 복귀 확인. 기존 검증 환경에 추가 계정이 없어 미완료입니다.
- 별도 CLI·IDE·데몬을 종료한 뒤 실제 **전환 및 재실행**의 정상 종료·최신 백업·인증 적용·재실행 확인. 현재 앱을 호스팅하는 Codex까지 종료될 수 있으므로 사용자와 검증 순서를 정합니다.
- Claude 데스크톱 로그인 변경 후 기존 Code 대화를 새 계정으로 그대로 이어 쓰기. 현재 로컬 목록 보존만으로 이를 해결하거나 입증하지 못했습니다.
- 현재 빌드의 실제 메뉴 전환과 창 수명 재확인, 로그인 시 실행 등록 후 재로그인, macOS 14·15 실제 실행 확인.
- Developer ID 서명·공증·DMG. 배포 인증서가 준비된 뒤 적용합니다.

## 릴리즈 패키징

`scripts/package-release.sh`로 격리된 Universal Release 빌드와 개발용 ZIP·SHA256SUMS 생성을 확인했습니다. ZIP을 다시 추출한 앱의 deep·strict 서명, arm64·x86_64 아키텍처, `net.mercen.agentswap` 번들 ID, 요청한 버전·빌드 번호, 최소 macOS 14.0, 체크섬이 모두 일치했습니다. 실행 중인 기본 앱의 실행 파일 바이트도 기존과 같았습니다. 실제 앱 실행이나 계정 인증 변경은 수행하지 않았습니다.

버전별 출력 폴더의 기존 산출물을 덮어쓰지 않습니다. GitHub의 버전 태그 workflow는 테스트·패키징·검증 후 초안 prerelease를 만들며, 현재 검증에서 실제 태그나 릴리즈를 생성하지 않았습니다. ad-hoc 개발용 ZIP을 제공하는 경로이며 Developer ID 서명·공증·DMG와 실제 계정 검증은 별도 완료 조건입니다.

## 호환성 제한

Claude의 네이티브 Keychain은 Apple `/usr/bin/security`의 고정 인자와 hex stdin 경로를 사용합니다. SDK 저장 후 자체 읽기와 API 조회만 성공하고 CLI 읽기는 실패한 이전 경로와 구분합니다. 네이티브 경로의 실제 CLI 왕복 성공은 설치 버전과 지원 입력 크기에 한정합니다.

- 명령 한도는 4094바이트이며 공유 MCP·플러그인 자료를 포함한 실제 인증은 약 2 KiB까지만 지원합니다. 알려진 형식이라도 초과하면 원본을 유지하고 쓰기를 중단합니다. 큰 인증 자료의 전환·활성 토큰 갱신은 아직 지원하지 않습니다.
- 값 없는 `-w`의 비밀번호 입력은 공개 소스에서 `getpass()`의 128바이트 버퍼를 사용합니다. 큰 인증을 전달하는 대안으로 사용하지 않습니다. [SecurityTool](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/keychain_add.c), [Libc](https://github.com/apple-oss-distributions/Libc/blob/main/gen/FreeBSD/readpassphrase.c), [버퍼 정의](https://github.com/apple-oss-distributions/Libinfo/blob/main/lookup.subproj/pwd.h)
- 앱 vault·복구·Codex의 Swift Security 호출은 백그라운드 승인 UI를 금지합니다. 별도 Claude SecurityTool에는 이 정책이 상속되지 않습니다. 잠금 사전 확인과 2초 제한을 적용하지만 승인 창이 절대 나타나지 않는다고 보장하지 않습니다.
- 개발 빌드는 ad-hoc 서명입니다. 재빌드로 서명이 바뀌면 Keychain 항목별 승인을 다시 요청할 수 있습니다.
- 검증된 갱신 응답의 첫 영구 저장 이전에 강제 종료·시스템 중단이 발생하면 RAM에만 있는 새 인증은 복구할 수 없습니다. 정상 종료 대기와 첫 저장 이후 복구는 fixture로 검증했습니다.
- 기본 로컬 구독 프로필이 대상입니다. API 키, 프로젝트별 실행, 클라우드 동기화, 인증 내보내기, 관리 정책·별도 secrets 백엔드는 v1 범위에 포함하지 않습니다.

세부 조건은 [ARCHITECTURE.md](ARCHITECTURE.md), UI 기준은 [DESIGN.md](DESIGN.md), 개발 절차는 [CONTRIBUTING.md](../CONTRIBUTING.md)를 참고하세요.
