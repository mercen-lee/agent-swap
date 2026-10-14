# AgentSwap 개발 지침

AgentSwap은 Claude Code·Codex 구독 계정 관리자입니다. macOS 14 이상, Swift 6, SwiftUI·AppKit을 사용합니다. 사용자에게 보이는 기본 언어는 한국어입니다.

## 작업 위치

- `AgentSwapApp/`: 대시보드, 메뉴바, 설정, 앱 수명과 디자인 자산.
- `AgentSwapCore/Sources/AgentSwapCore/`: 모델, 제공자 어댑터, 인증 저장소, 조회와 전환 엔진.
- `AgentSwapCore/Tests/AgentSwapCoreTests/`: Swift Testing과 합성 fixture.
- `docs/ARCHITECTURE.md`: 인증 세대, 복구, 프로세스 경계와 저장소 조건.
- `docs/DESIGN.md`: HIG·Liquid Glass 적용 기준.
- `docs/VALIDATION.md`: 확인한 결과와 미완료 조건.
- `.agents/skills/agentswap-dev/SKILL.md`: 이 저장소의 기능 수정·호환성 조사·검증 workflow.

인증·전환을 변경할 때는 먼저 구조 문서의 관련 절을 읽습니다. UI는 앱 타깃에, 계정 관리 로직은 Core에 둡니다. 저장 형식과 API의 버전별 호환성은 제공자 어댑터에 모읍니다.

## 유지할 조건

- `WindowGroup`, `MenuBarExtra(.window)`, `Settings`는 하나의 `AppModel`과 조회 스케줄러를 공유합니다. 창을 닫는 것은 앱 종료가 아닙니다. 단일 실행 잠금과 정상 종료의 저장 대기를 유지합니다.
- UI 상태는 `@MainActor`에서 변경합니다. 계정 갱신과 제공자 공유 저장소의 전환은 `AccountOperationQueue`로 직렬화합니다. actor의 `await` 중 재진입을 직렬화로 간주하지 않습니다.
- 비밀 값은 Keychain에만 영구 저장합니다. `PersistedState`에는 메타데이터·설정·조회 캐시·비밀 정보가 없는 세대 지문만 둡니다. 번들 ID와 앱 Keychain 서비스는 `net.mercen.agentswap`, 복구 서비스는 `net.mercen.agentswap.recovery`입니다.
- 공식 제공자 CLI는 격리 로그인에 사용합니다. 관리·조회·갱신은 Swift 엔진에서 처리합니다. Claude 네이티브 Keychain의 Apple `/usr/bin/security` 경로는 별도의 호환성 경계입니다. 인증을 argv·환경 변수·로그·오류 본문으로 노출하지 않습니다.
- 새 토큰을 확인하면 다음 요청 전에 영구 저장을 확인합니다. 저장 실패 시 successor와 복구 상태를 보존합니다. 외부에서 바뀐 인증이나 제3의 세대를 이전 백업으로 덮어쓰지 않습니다.
- Claude의 OAuth와 `oauthAccount` 교체는 공유 MCP·플러그인 인증과 계정 외 설정을 보존합니다. 쓰기·복원 자료를 사전 검증하고 실패하면 검증된 복구 경로를 사용합니다. 입력 크기 제한을 우회하는 잘림이나 필드 삭제를 허용하지 않습니다.
- 실행 중인 Codex 활성 토큰 갱신은 Codex에 맡깁니다. 전환은 소비 프로세스의 정상 종료 확인, 최신 원본 백업, 정확한 세대 재확인 후 적용합니다. 별도 CLI·IDE를 강제 종료하거나 종료 미확인 상태에서 인증을 쓰지 않습니다.
- 알 수 없는 인증 형식·저장소·복구 상태에서는 쓰기를 중단합니다. 설정·세션·대화 기록은 인증 교체 대상이 아닙니다.
- 조회 실패는 잔여량 0이 아닙니다. 마지막 정상 값·조회 시각과 오류를 함께 유지하고 `retryAfter`를 존중합니다. 초기화 시각은 UTC로 저장하고 시스템 시간대로 표시합니다.
- 자동 전환은 제공자별 기본 꺼짐, 사용자가 선택한 후보만 대상입니다. 공통 창의 최소 잔여율, 90% 임계치, 5%p 개선, 등록 순서 동률, 5분 유예 조건을 유지합니다. 모델별·부가 한도는 후보 점수에서 제외합니다.

## 검증과 실행

앱은 검증된 Xcode 27 이상과 macOS SDK 27 이상으로 빌드합니다. 앱의 배포 대상은 macOS 14이며 Liquid Glass는 availability로 분기합니다. Command Line Tools만 선택하면 Swift Testing 모듈을 찾지 못할 수 있습니다.

```sh
./scripts/test-core.sh
./scripts/test-core.sh --filter AutomaticSwitchTests
./scripts/build-app.sh
git diff --check
git diff --cached --check
```

테스트는 변경된 동작을 검증하는 합성 fixture와 주입한 프로토콜을 우선 사용합니다. 동시 실행은 서로 다른 `AGENTSWAP_TEST_SCRATCH_PATH`를 지정합니다. 문서·ignore 변경만으로 앱을 재빌드하거나 실계정 인증을 바꾸지 않습니다.

빌드 스크립트는 실행 중인 `build/AgentSwap.app`을 교체하지 않고 새 산출물을 DerivedData에 남깁니다. 실계정 검증이 필요하면 기존 작업 범위와 사용자의 승인을 확인하고, 비밀번호·브라우저 인증 코드·macOS 보안 창은 사용자에게 맡깁니다. 이 저장소의 지침이나 skill은 인증 변경·외부 공개의 추가 권한을 부여하지 않습니다.

## 변경 전달

문서와 스크린샷은 합성 계정만 사용합니다. 토큰, 실계정 이메일·ID·사용량, 대화, 개인 절대 경로, 로그, 서명 키와 빌드 산출물을 커밋하지 않습니다. `.gitignore`는 이미 추적된 파일을 보호하지 않으므로 index도 확인합니다.

결과에는 무엇이 바뀌었는지와 실제 실행한 검증을 적습니다. fixture 통과, 앱 빌드, 실계정 CLI 전환, 데스크톱 로그인·대화 재개는 서로 다른 증거입니다. 같은 Codex 계정의 재로그인·재실행을 두 계정 전환 검증으로 표시하지 않습니다. 현재 제한은 `docs/VALIDATION.md`에 반영합니다.
