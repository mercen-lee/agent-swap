---
name: agentswap-dev
description: "Implement, review, or verify AgentSwap’s Swift macOS account manager, including provider compatibility, credential transactions, polling, account switching, and native UI. Use for work in this repository."
---

# AgentSwap 개발

이 저장소의 비밀 정보 없는 fixture와 실제 제공자 인증 경계를 구분하면서 요청한 기능을 구현하고 검증합니다. 먼저 [AGENTS.md](../../../AGENTS.md)를 읽고 현재 diff와 관련 구현을 확인합니다. 사용자의 요청은 이 skill보다 우선하며, skill 적용은 실계정 변경이나 공개 권한을 추가하지 않습니다.

## 변경에 맞는 경로

필요한 경로만 읽습니다. 현재 구현의 한계를 새 요구사항의 완료 기준으로 축소하지 않습니다.

| 변경 | 먼저 볼 구현·문서 | 관련 테스트 |
|---|---|---|
| 제공자 API·파싱·로그인 | `ProvidersHTTP.swift`, `ProvidersParsing.swift`, `ProvidersLogin.swift`, `ProvidersAdapters.swift` | `ProviderTests`, `ClaudeReadBindingTests`, `ClaudePartialMetadataRotationTests` |
| Claude 인증·Keychain·회전 | `ClaudeKeychainAccess.swift`, `StorageClaude.swift`, `StorageTransactions.swift`; 구조 문서의 저장소·토큰 절 | `ClaudeNativeKeychainTests`, `ClaudeNativeEncodingTests`, `ClaudeRotationRecoveryTests`, `ClaudeCredentialRetentionTests` |
| Codex 저장소·재실행 | `ProvidersAdapters.swift`, `AppModel.swift`, `StorageCodex.swift`, `StorageCodexConfiguration.swift`, `ProvidersProcesses.swift`; 구조 문서의 프로세스 경계 | `StorageTests`, `CodexSwitchBoundaryTests`, `CodexQuitRotationTests`, `SourceBackupRegistrationTests` |
| 스케줄러·캐시·자동 전환 | `AppModel.swift`, `AccountOperationQueue.swift`, `AutomaticSwitchPolicy.swift`, `Models.swift` | `EngineTests`, `AutomaticSwitchTests`, `PendingCredentialPersistenceTests` |
| Claude 로컬 Code 목록 | `ClaudeDesktopSessionPreserver.swift`, `ClaudeDesktopProcesses.swift`; 구조 문서의 세션 보존 | `ClaudeDesktopSessionPreserverTests`, `EngineSessionPreservationTests` |
| SwiftUI·앱 수명 | `AgentSwapApp/`, [디자인 기준](../../../docs/DESIGN.md) | 관련 Core fixture, 데모 UI와 접근성 확인 |
| 릴리즈·패키징 | `scripts/package-release.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, [기여 안내](../../../CONTRIBUTING.md) | Core 테스트, ZIP 복원 후 서명·양쪽 아키텍처·버전·최소 OS·체크섬 확인 |

Core 파일은 `AgentSwapCore/Sources/AgentSwapCore/`, 테스트는 `AgentSwapCore/Tests/AgentSwapCoreTests/` 아래에 있습니다. 저장소·프로세스 변경에는 [ARCHITECTURE.md](../../../docs/ARCHITECTURE.md), 완료 주장에는 [VALIDATION.md](../../../docs/VALIDATION.md)를 확인합니다.

## 기능 수정과 호환성 조사

1. 변경할 동작의 현재 호출 경로와 합성 fixture를 확인합니다. 제공자 응답·인증 형식의 변경은 공식 문서 또는 해당 설치 버전의 공개 소스로 검증하고 불확실성을 기록합니다.
2. 새 필드·토큰 회전·부분 실패·취소·외부 인증 변경 중 영향을 받는 경계를 찾습니다. fixture는 실제 인증을 복사하지 말고 합성 값과 임시 저장소로 만듭니다.
3. 새 OAuth 응답을 다시 교환하지 않도록 첫 영구 저장 실패까지 처리하고, 원본 세대와 복구 자료를 쓰기 직전에 재확인합니다. 잠금과 읽기 오류를 로그아웃으로 취급하지 않습니다.
4. 관련 suite를 실행합니다. 공통 저장소·동시성·전환 경계 변경은 전체 Core 테스트와 앱 컴파일까지 확인합니다. 문서 수정은 링크·명령·diff 검사로 충분합니다.

Claude의 작은 네이티브 인증은 4094바이트 이내 SecurityTool 명령을 사용하고, 큰 인증은 검증된 Apple Swift 인터프리터와 번들 helper의 표준 입력으로 저장합니다. 전송 안전 상한 1 MiB와 별도로 Claude CLI의 SecurityTool 출력 1,000,000바이트 한도를 대상·복원 자료 모두 검사합니다. 출력 가능한 ASCII는 길이+LF, 다른 바이트는 hex 길이+LF를 계산합니다. helper 수정 시 컴파일된 resource SHA-256을 갱신하고 변조 거부 fixture를 확인합니다. 비밀 argv·평문 파일·공유 필드 삭제로 대체하지 말고 별도 SecurityTool이 같은 인증을 읽는 증거와 정확한 복원 경로를 확보합니다. Swift SDK의 자체 읽기 성공만으로 Claude CLI 호환성을 판단하지 않습니다.

## UI와 실제 검증

UI는 공유 `AppModel`, 표준 탐색·목록·Form·툴바, 의미 기반 색과 시스템 시간대를 사용합니다. 데이터 표면에 장식용 Glass를 추가하지 않습니다. 새 API는 macOS 14 fallback을 유지합니다.

전환 결과 UI를 바꾸면 최소 760×520pt에서 전환 성공·재시도·대화 재개 안내·상세 메시지 열기/닫기를 메모리 데모로 확인합니다. `--demo --demo-session-incompatible --demo-narrow`가 이 경계를 재현합니다. 네이티브 split child의 가변 높이 inset에 오류·전환 액션을 넣지 말고, 고정 높이 상태바와 읽기 전용 상세 표시의 크기 계약을 유지합니다. Core fixture 통과만으로 AppKit 배치 종료가 해결됐다고 표시하지 않습니다.

UI 확인에는 `build/AgentSwap.app`의 `--demo` 모드와 메모리 계정을 사용합니다. 실제 모드와 데모를 전환할 때는 앱을 정상 종료합니다. 실제 계정의 스크린샷·응답·프로세스 인자를 문서에 저장하지 않습니다. 앱 재빌드의 ad-hoc 서명 변경은 Keychain 재승인을 유발할 수 있으므로 문서 작업에 앱 교체를 연결하지 않습니다.

Codex 재실행 검증은 현재 작업을 호스팅하는 데스크톱까지 종료할 수 있습니다. 사용자와 준비된 검증 순서를 확인하고 정상 종료·소비자 종료·최신 백업·대상 적용·재실행·로그인과 사용량 확인을 각각 기록합니다. 두 번째 구독 계정이 없으면 두 계정 검증은 미완료로 남깁니다. Claude CLI 전환이나 로컬 목록 준비는 Claude 데스크톱의 로그인 변경·기존 대화 이어쓰기 성공을 뜻하지 않습니다.

## 전달

브라우저의 자동 열기는 공식 CLI만 담당하며 출력된 수동 fallback은 사용자 요청 때만 한 번 엽니다. 제공자의 전환 호환성은 조회·로그인·명시 재확인 뒤 최신 상태로 갱신하고 비활성화 이유를 UI에 표시합니다.

Claude 일반·자동 전환은 대화 목록 보존과 분리합니다. 전환 중 비공개 Code 목록·transcript를 읽거나 쓰거나 복사하지 않고 Desktop 프로세스도 종료·재실행하지 않습니다. 이전 보존 저널만 안전한 상태 경로에서 존재 여부를 검사하며, 미완료 기록은 별도의 명시적 복구로 처리합니다. 원본 인증 백업·갱신 저장·정확한 세대 재확인 조건은 유지합니다. 대화 재개 안내는 공식 `claude --resume`·Desktop `/resume`를 사용하고 다른 계정의 Desktop 대화 자동 이전을 약속하지 않습니다. 이전 형식 parser와 복구 fixture는 새 전환 경로에 연결하지 않습니다.

명시적인 `Desktop과 CLI 함께 전환`은 별도 경계입니다. 각 계정의 공식 Desktop 로그인에서 독립적으로 확인한 사용자와 불투명 인증 저장소를 Keychain에만 백업합니다. 정상 종료를 확인한 뒤 등록된 원본·대상 Code 버킷만 처리하며 새 필드 전체 allowlist를 두지 않습니다. 원본·공유 transcript와 대상의 기존 표시 설정을 유지하고, 삭제 표시·ID 충돌·지문 변경·제3 인증 세대에서는 쓰기를 중단합니다. CLI 성공과 Desktop 실패의 부분 상태를 숨기거나 CLI를 이전 토큰으로 되돌리지 않습니다. 새 Desktop 저널이 남으면 일반 CLI 전환도 차단하며 명시적 복구를 제공합니다. 실계정 검증 전에는 메모리 UI, 합성 파일·Keychain·프로세스 실패와 재시작 복구를 먼저 확인합니다.

릴리즈 패키징은 격리된 빌드에서 Universal 앱을 만들며 실행 중인 기본 앱을 교체하지 않습니다. 버전과 대상 커밋을 확인하고 실제 버전 태그를 추정해 만들지 않습니다. 현재 태그 workflow는 초안 prerelease와 ZIP·체크섬을 준비합니다. ad-hoc 서명을 Developer ID 서명·공증으로 표시하거나 패키징 성공을 v1 완료로 해석하지 않습니다. 인증서·로그인 자격 증명은 Git에 포함하지 않습니다.

[기여 안내](../../../CONTRIBUTING.md)의 명령을 사용하고, 요청한 동작·검증 결과·남은 한계를 간결하게 보고합니다. 재현 가능한 소스·합성 fixture·문서만 Git에 포함합니다. 공개 준비에서는 ignore 규칙과 현재 index를 모두 검사합니다.
