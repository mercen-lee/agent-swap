# 개발과 기여

AgentSwap은 아직 개발 중입니다. [README](README.md)에서 기능과 현재 제한을, [구조 문서](docs/ARCHITECTURE.md)에서 인증·복구 경계를 확인하세요. 에이전트와 협업할 때는 [AGENTS.md](AGENTS.md)와 저장소의 [$agentswap-dev](.agents/skills/agentswap-dev/SKILL.md)를 사용합니다. skill은 Codex의 저장소별 `.agents/skills` 위치에 있습니다. [공식 skill 안내](https://learn.chatgpt.com/docs/build-skills)

## 개발 환경

- macOS와 Xcode 27 이상. 현재 앱 Release 빌드는 macOS SDK 27로 검증합니다.
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

빌드 스크립트는 기본적으로 ad-hoc 서명합니다. 최종 앱의 서명 identity는 `AGENTSWAP_SIGN_IDENTITY`로 선택할 수 있습니다. 개발 Mac에서 같은 서명으로 반복 빌드하려면 공개 인증서 SHA-1만 담은 한 줄짜리 `.agentswap-signing-identity`를 저장소 루트에 두면 됩니다. 환경 변수가 있으면 그 값을 우선하며 `AGENTSWAP_SIGN_IDENTITY=-`는 ad-hoc 서명을 명시합니다. Xcode 빌드는 provisioning 설정에 의존하지 않도록 ad-hoc으로 만든 뒤 선택한 identity로 최종 앱을 다시 서명합니다. 이 파일은 Git에서 제외합니다. 실행 중인 앱은 덮어쓰지 않으므로 새 산출물의 경로를 확인하고 앱을 정상 종료한 뒤 다시 설치하세요. 서명 키·인증서와 공증 자격 증명은 저장소에 넣지 않습니다.

## 변경 검증

관련 fixture를 먼저 실행하고 인증 저장소·전환·공통 모델·동시성 변경은 전체 Core 테스트와 앱 빌드를 확인합니다. 문서·ignore만 수정할 때는 앱 실행이나 실계정 변경이 필요하지 않습니다.

새 fixture는 합성 인증, 임시 디렉터리, 주입한 HTTP·Keychain·프로세스 제어를 사용합니다. 오류·누락 필드·토큰 회전·다른 원본 세대·취소·부분 실패 중 변경과 관련된 경계를 검증합니다. 성공한 코드 경로를 그대로 재현하는 assertion보다 관찰 가능한 결과와 보존 조건을 확인하세요.

실제 검증 결과는 날짜·도구 버전·확인 범위만 [검증 기록](docs/VALIDATION.md)에 적습니다. fixture, CLI 로그인, 데스크톱 로그인, 대화 재개를 별도로 구분하세요. 두 번째 계정이 없는 경우 동일 계정 로그인으로 전환 검증을 대체하지 않습니다.

## 초안 릴리스

[릴리스 워크플로](.github/workflows/release.yml)는 원격 저장소에 버전 태그를 push할 때 실행합니다. 태그는 `vMAJOR.MINOR.PATCH` 형식이며 `v0.1.0-beta.1`처럼 SemVer prerelease 식별자를 붙일 수 있습니다. `+build` 메타데이터는 받지 않습니다. 태그 생성과 push는 릴리스 담당자의 별도 작업이며, 워크플로가 태그를 자동으로 만들지 않습니다.

태그의 소스로 Core 테스트를 실행하고, macOS 14를 최소 대상으로 하는 `arm64`·`x86_64` Universal Release 앱을 ad-hoc 서명해 ZIP으로 묶습니다. 인증서나 공증 자격 증명은 사용하지 않습니다. 앱의 `CFBundleShortVersionString`에는 태그의 숫자 기본 버전, `CFBundleVersion`에는 `github.run_number`를 사용합니다. prerelease 식별자를 포함한 전체 버전은 태그와 ZIP 이름에 유지합니다.

테스트·패키징·체크섬 확인이 성공하면 ZIP과 `SHA256SUMS`를 첨부한 **draft prerelease**를 생성합니다. 담당자는 GitHub의 Releases에서 릴리스 노트, 알려진 제한과 첨부 파일을 검토한 뒤 공개 여부를 결정합니다. 기존 같은 태그의 초안이나 첨부 파일은 덮어쓰지 않으므로 재실행으로 교체하지 말고 새 버전을 준비하세요. 초안 생성이나 Universal 빌드는 v1 완료·실계정 호환성 검증을 뜻하지 않습니다.

로컬 패키징은 다음과 같습니다. 일반 빌드의 `build/AgentSwap.app`을 설치하거나 실행하지 않습니다.

```sh
./scripts/package-release.sh 0.1.0
```

- 산출물: `build/releases/0.1.0/AgentSwap-0.1.0-universal.zip`, `build/releases/0.1.0/SHA256SUMS`
- 같은 버전 폴더가 있으면 덮어쓰기를 거부합니다.
- 로컬 빌드 번호는 기본 `1`이며 `AGENTSWAP_RELEASE_BUILD_NUMBER`에 양의 정수를 지정할 수 있습니다.

현재 패키징은 Developer ID 서명·Apple 공증·DMG를 제공하지 않습니다. `codesign` 검증과 SHA-256 일치는 앱·파일의 무결성 확인이며 Gatekeeper의 개발자 신원·공증 검증과 다릅니다. 다운로드한 개발용 앱은 macOS에서 경고하거나 차단될 수 있습니다. [Apple의 Gatekeeper 안내](https://support.apple.com/ko-kr/102445)

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
