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

태그의 소스로 Core 테스트를 실행하고, macOS 14를 최소 대상으로 하는 `arm64`·`x86_64` Universal Release 앱을 고정된 앱 전용 인증서로 서명해 ZIP으로 묶습니다. 개인 Apple Development 인증서나 공증 자격 증명은 사용하지 않습니다. 앱의 `CFBundleShortVersionString`에는 태그의 숫자 기본 버전, `CFBundleVersion`에는 소스 커밋의 Unix 시각을 사용합니다. 로컬과 CI가 같은 기준을 사용하며, 다음 릴리스의 빌드 번호는 이전보다 커야 합니다. prerelease 식별자를 포함한 전체 버전은 태그·ZIP 이름·`AgentSwapReleaseTag`·업데이트 화면에 유지합니다.

테스트·패키징·서명·체크섬 확인이 성공하면 ZIP, 서명된 `appcast.xml`, 두 파일의 `SHA256SUMS`를 첨부한 **draft prerelease**를 생성합니다. 담당자는 GitHub의 Releases에서 릴리스 노트, 알려진 제한과 첨부 파일을 검토한 뒤 공개 여부를 결정합니다. 기존 같은 태그의 초안이나 첨부 파일은 덮어쓰지 않으므로 재실행으로 교체하지 말고 새 버전을 준비하세요. 초안 생성이나 Universal 빌드는 v1 완료·실계정 호환성 검증을 뜻하지 않습니다.

로컬 패키징은 다음과 같습니다. 일반 빌드의 `build/AgentSwap.app`을 설치하거나 실행하지 않습니다.

```sh
./scripts/package-release.sh 0.1.0
```

- 산출물: `build/releases/0.1.0/AgentSwap-0.1.0-universal.zip`, `appcast.xml`, `SHA256SUMS`
- 같은 버전 폴더가 있으면 덮어쓰기를 거부합니다.
- 로컬 빌드 번호도 소스 커밋 시각이며 `AGENTSWAP_RELEASE_BUILD_NUMBER`에 이전 릴리스보다 큰 양의 정수를 지정할 수 있습니다.

### GitHub Releases 자동 업데이트 서명

앱은 Sparkle 2.10.0으로 업데이트를 설치합니다. 별도 서버나 GitHub Pages는 필요하지 않습니다. GitHub API에서 공개 릴리스와 `appcast.xml`·ZIP 첨부 파일을 확인한 뒤, 태그별 고정 URL의 피드를 사용합니다. beta 앱은 prerelease도 조회하고 정식 앱은 정식 릴리스만 조회합니다. 초안이나 첨부 파일이 빠진 릴리스는 후보에서 제외합니다. v0.1.0-beta.5 이전 앱에는 updater가 없으므로 한 번은 수동으로 새 앱을 받아야 합니다.

[`fetch-sparkle-tools.sh`](scripts/fetch-sparkle-tools.sh)는 공식 배포 파일을 고정된 SHA-256으로 확인하고 도구를 준비합니다. 다음 명령은 최초 서명 키를 만들거나 같은 계정의 기존 키를 재사용합니다. Keychain의 기존 키를 삭제하거나 바꾸지 마세요.

```sh
./scripts/fetch-sparkle-tools.sh build/sparkle-signing-tools
./build/sparkle-signing-tools/bin/generate_keys --account net.mercen.agentswap
./build/sparkle-signing-tools/bin/generate_keys --account net.mercen.agentswap -p
```

공개 키만 `AgentSwapApp/Info.plist`의 `SUPublicEDKey`에 넣습니다. 개인 키는 macOS 로그인 Keychain의 Sparkle 서비스와 `net.mercen.agentswap` 계정에 보관합니다. 로컬 패키징은 이 키를 직접 사용합니다. GitHub Actions에는 같은 개인 키를 저장소의 `SPARKLE_PRIVATE_KEY` encrypted secret으로 등록합니다. 키를 출력·로그·명령 인자·Git에 넣지 않습니다. 임시 파일로 옮겨야 한다면 접근 제한된 임시 폴더에서만 내보내고 secret 등록 직후 삭제하세요.

CI는 개인 키를 Sparkle 도구의 표준 입력으로 전달합니다. 패키징은 공개 키와 개인 키가 일치하는 ZIP 서명, 피드 서명, 정확한 URL·버전·파일 크기·최소 OS를 확인하고, 서명 검증에 실패하면 산출물을 공개하지 않습니다. 앱은 피드와 ZIP 서명을 확인하며 압축 해제 전 검증을 요구합니다. 현재 배포는 Developer ID 서명을 사용하지 않으므로 Sparkle 키를 잃으면 기존 설치에 새 업데이트 키를 안전하게 자동 배포할 수 없습니다. 기존 키를 유지하세요. [Sparkle 서명 문서](https://sparkle-project.org/documentation/)

현재 패키징은 Developer ID 서명·Apple 공증·DMG를 제공하지 않습니다. `codesign` 검증과 SHA-256 일치는 앱·파일의 무결성 확인이며 Gatekeeper의 개발자 신원·공증 검증과 다릅니다. 다운로드한 개발용 앱은 macOS에서 경고하거나 차단될 수 있습니다. [Apple의 Gatekeeper 안내](https://support.apple.com/ko-kr/102445)

Hardened Runtime은 유지합니다. 별도 identity의 Sparkle 프레임워크를 불러오기 위해 현재 self-signed 공개 패키지와 로컬 개발 빌드는 `AgentSwap-AdHoc.entitlements`의 library validation 예외를 적용합니다. 공개 패키지는 기본 디버깅 entitlement 주입을 끕니다. 향후 Developer ID 배포 파이프라인을 만들 때는 포함된 코드를 같은 identity로 서명하고 library validation 예외를 제거해야 합니다. 이 예외는 Apple 공증을 대신하지 않습니다. [Sparkle 설정 안내](https://sparkle-project.org/documentation/)

### Keychain 앱 식별을 유지하는 릴리즈 서명

beta.8부터 `scripts/signing/release-certificate.cer`의 공개 인증서를 고정합니다. 앱의 designated requirement는 `net.mercen.agentswap` 식별자와 이 인증서의 hash를 함께 요구합니다. 인증서를 새로 만들거나 ad-hoc으로 대체하면 기존 Keychain 승인을 유지할 수 없으므로, 인증서·개인 키는 계속 재사용해야 합니다. 공개 DER만 Git에 포함하며 개인 키·P12·암호는 포함하지 않습니다. self-signed 서명은 Apple Developer ID나 공증이 아닙니다. [Apple 코드 서명 정책](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

CI는 encrypted repository secrets `AGENTSWAP_SIGNING_P12_BASE64`·`AGENTSWAP_SIGNING_P12_PASSWORD`를 `prepare-release-signing.py`에 전달합니다. 준비 프로그램이 환경에서 비밀 값을 제거한 뒤 표준 입력으로만 임시 Keychain에 가져옵니다. 기본 Keychain·검색 목록·시스템 신뢰 설정은 바꾸지 않으며 `always()` 정리 단계에서 임시 Keychain을 삭제합니다. 개인 Apple Development 인증서를 내보내 이 용도로 사용하지 않습니다.

로컬 패키징은 고정 인증서의 개인 키가 있는 Keychain의 경로를 `AGENTSWAP_RELEASE_SIGNING_KEYCHAIN`으로 지정합니다. 패키징은 인증서 원문·개인 키 존재·서명 후 DR을 확인하고, ad-hoc이나 다른 인증서를 거부합니다. `python3 scripts/test-release-signing.py`는 독립된 합성 키로 코드가 다른 두 앱의 DR 연속성, 잘못된 인증서·ad-hoc 거부, CI 준비·반복 정리와 검색 목록 불변을 확인합니다.

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
