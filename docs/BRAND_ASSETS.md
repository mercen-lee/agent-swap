# 브랜드 아이콘과 앱 아이콘

제공자 아이콘은 네트워크에서 실행 중에 받지 않고 앱의 asset catalog에 벡터로 포함합니다. 계정 이름·상태 문구를 함께 표시하며 아이콘만으로 제공자를 구분하지 않습니다. 사용량·경고 색과 시스템 강조색은 기존 의미를 유지합니다.

## Claude

- 원본: [Simple Icons](https://simpleicons.org/), [claude.svg](https://github.com/simple-icons/simple-icons/blob/c71c69e3a27e4436936b831c72643e6513b9f49b/icons/claude.svg)
- 고정한 upstream 커밋: `c71c69e3a27e4436936b831c72643e6513b9f49b` (2026-10-21 확인)
- 브랜드 메타데이터: [simple-icons.json](https://github.com/simple-icons/simple-icons/blob/c71c69e3a27e4436936b831c72643e6513b9f49b/data/simple-icons.json), `Claude`, `#D97757`, 원본 사이트 `https://claude.ai`
- 라이선스: [CC0 1.0 Universal 원문](licenses/Simple-Icons-CC0-1.0.txt). Simple Icons의 [면책·상표 안내](https://github.com/simple-icons/simple-icons/blob/c71c69e3a27e4436936b831c72643e6513b9f49b/DISCLAIMER.md)도 적용됩니다. 상표권은 해당 권리자에게 있습니다.
- 파일: `AgentSwapApp/Assets.xcassets/ClaudeBrand.imageset/claude.svg`
- 원본 파일 SHA-256: `2d6fda79eb18ddccca35b799eeb3cece0dfabc22520ce3b10abd25668df9fa93`

SVG의 path와 viewBox는 수정하지 않았습니다. Claude Desktop과 Claude 계정 행에 같은 Claude 마크를 사용합니다. 평상시에는 메타데이터의 terracotta를 쓰며, 선택 행과 대비 증가 환경에서는 읽기 쉬운 단색으로 표시합니다.

## Codex의 OpenAI 표시

위 Simple Icons 커밋에는 Codex·OpenAI·ChatGPT 아이콘이 없습니다. 기존 OpenAI 항목은 [upstream PR #13944](https://github.com/simple-icons/simple-icons/pull/13944)에서 제거됐습니다. 과거 Simple Icons 항목을 현재 제공 자산처럼 가져오지 않고, Codex 제공자를 나타내는 보조 아이콘으로 OpenAI가 직접 배포하는 Blossom을 사용합니다. Codex 전용 마크로 표시하거나 CC0 자산으로 재분류하지 않습니다.

- 배포자·브랜드 안내: [OpenAI Design Guidelines](https://openai.com/brand/), [Marks usage terms](https://openai.com/brand/#usage-terms)
- 공식 다운로드: [OpenAI-Logos-2025.zip](https://cdn.openai.com/brand/OpenAI-Logos-2025.zip) (2026-10-21 확인)
- ZIP SHA-256: `b2c4cd1e86bbe76bdc4946a72d014efa455240c177f4878fd68cc9b88c71d2ec`
- ZIP 내부 원본: `OpenAI-logos(new)/SVGs/OpenAI-black-monoblossom.svg`, `OpenAI-logos(new)/SVGs/OpenAI-white-monoblossom.svg`
- 포함 파일: `AgentSwapApp/Assets.xcassets/OpenAIBrand.imageset/openai-black.svg`, `openai-white.svg`
- 검정 SVG SHA-256: `7be72f1fea831d3ba81a545cee79b7e0ae69449d5d7837c9571ccbfb4aa1e00b`
- 흰색 SVG SHA-256: `b94ea61d860fae6f82f43571f36f17111fcf5d348e8e9cc22ae4b441c7560011`

OpenAI 로고는 OpenAI의 자산입니다. 제공된 SVG를 수정 없이 포함하고 비율과 여백을 보존합니다. 원본은 검정 `#000000`과 흰색 `#FFFFFF`이며 밝은·어두운 appearance에 대응합니다. 선택 행에서는 시스템 텍스트 전경색을 사용하는 단색으로 표시합니다. OpenAI 서비스를 식별하는 보조 UI에만 사용하며 AgentSwap 앱 아이콘·주 브랜드에 합치거나 제휴·후원을 암시하지 않습니다.

## AgentSwap 앱 아이콘

새 아이콘은 독립적인 두 개의 둥근 전환 화살표를 ivory 타일 위에 배치한 디자인입니다. terracotta와 짙은 graphite를 사용하며 제공자의 로고를 포함하지 않습니다.

- 원본 PNG: `AgentSwapApp/Assets/AppIconSource.png`
- 생성 도구와 정확한 최종 프롬프트: `AgentSwapApp/Assets/AppIconSource.prompt.txt`
- 재현 가능한 크기 변환: `swift scripts/generate-icon.swift`
- macOS AppIcon: `AgentSwapApp/Assets.xcassets/AppIcon.appiconset/`의 10개 PNG

생성된 투명도를 유지한 채 기존 Swift 스크립트로 크기만 변환했습니다. 이미지 생성 원본에서 16·32·128·256·512pt의 1×·2× 파일을 만듭니다.
