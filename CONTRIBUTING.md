# 개발과 기여

AgentSwap은 아직 개발 중입니다. [README](README.md)에서 기능과 현재 제한을, [구조 문서](docs/ARCHITECTURE.md)에서 인증·복구 경계를 확인하세요. 에이전트와 협업할 때는 [AGENTS.md](AGENTS.md)와 저장소의 [$agentswap-dev](.agents/skills/agentswap-dev/SKILL.md)를 사용합니다. skill은 Codex의 저장소별 `.agents/skills` 위치에 있습니다. [공식 skill 안내](https://learn.chatgpt.com/docs/build-skills)

## 개발 환경

- macOS와 Xcode 26 이상. 전체 앱에는 macOS SDK 26 이상이 필요합니다.
- Swift 6 언어 모드. 실행 배포 대상은 macOS 14 이상입니다.
- 실제 로그인에는 공식 Claude Code·Codex CLI가 필요하며 fixture 테스트에는 필요하지 않습니다.

별도 Xcode 경로를 사용하면 명령 앞에 `DEVELOPER_DIR`를 지정하세요. Command Line Tools만 선택된 환경 대신 Xcode의 도구를 사용합니다.

```sh
./scripts/test-core.sh
./scripts/test-core.sh --filter AutomaticSwitchTests
./scripts/build-app.sh
open build/AgentSwap.app --args --demo
```

`AGENTSWAP_TEST_SCRATCH_PATH`는 Core 빌드 캐시 위치입니다. 기본값은 `build/CoreTests`이며 동시에 여러 테스트를 실행하면 서로 다른 경로를 지정합니다. GitHub Actions는 macOS에서 Core 테스트와 Release 앱 빌드·서명 검증을 수행합니다. CI에는 실계정 로그인을 연결하지 않습니다.

빌드 스크립트는 기본적으로 ad-hoc 서명합니다. Developer ID는 `AGENTSWAP_SIGN_IDENTITY`로 선택할 수 있습니다. 실행 중인 앱은 덮어쓰지 않으므로 새 산출물의 경로를 확인하고 앱을 정상 종료한 뒤 다시 설치하세요. 서명 키·인증서와 공증 자격 증명은 저장소에 넣지 않습니다.

## 변경 검증

관련 fixture를 먼저 실행하고 인증 저장소·전환·공통 모델·동시성 변경은 전체 Core 테스트와 앱 빌드를 확인합니다. 문서·ignore만 수정할 때는 앱 실행이나 실계정 변경이 필요하지 않습니다.

새 fixture는 합성 인증, 임시 디렉터리, 주입한 HTTP·Keychain·프로세스 제어를 사용합니다. 오류·누락 필드·토큰 회전·다른 원본 세대·취소·부분 실패 중 변경과 관련된 경계를 검증합니다. 성공한 코드 경로를 그대로 재현하는 assertion보다 관찰 가능한 결과와 보존 조건을 확인하세요.

실제 검증 결과는 날짜·도구 버전·확인 범위만 [검증 기록](docs/VALIDATION.md)에 적습니다. fixture, CLI 로그인, 데스크톱 로그인, 대화 재개를 별도로 구분하세요. 두 번째 계정이 없는 경우 동일 계정 로그인으로 전환 검증을 대체하지 않습니다.

## Git에 포함할 자료

소스·공유 Xcode scheme·아이콘 자산·합성 fixture와 문서를 포함합니다. 앱·DerivedData·SwiftPM 캐시·Xcode 사용자 상태는 제외합니다. 인증 파일·토큰·실계정 정보·대화·로그·개인 절대 경로는 커밋하지 않습니다. 공개 스크린샷에는 데모 계정만 사용하세요.

```sh
git status --short
git diff --check
git diff --cached --check
git ls-files
```

`.gitignore`는 이미 index에 들어간 파일을 제외하지 않습니다. 실수로 들어간 자료는 커밋 전에 index에서 제거해야 합니다. PR에는 문제와 변경 결과, 실제 실행한 검증 및 남은 제한을 적으세요.

라이선스는 아직 지정되지 않았습니다. 저장소 공개 준비와 별개로 재사용·재배포 조건은 소유자가 결정합니다.
