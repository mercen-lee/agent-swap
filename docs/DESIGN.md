# 네이티브 macOS 화면

Apple Human Interface Guidelines의 macOS 구조와 시스템 소재를 사용합니다. 웹 대시보드 형태의 카드 그리드와 장식적인 문구 대신 계정 관리에 필요한 정보와 행동을 앞에 둡니다.

- 표준 `NavigationSplitView`와 `.sidebar` 목록에서 제공자를 선택합니다.
- 계정 목록에서 활성 상태와 공통 사용량을 비교하고, 선택한 계정의 상세 정보는 `inspector`의 시스템 `Form`에서 확인합니다.
- 통합 툴바에서 계정 추가·새로고침·검색·상세 패널 표시를 수행합니다.
- 시스템 글꼴과 의미 기반 색을 사용합니다. 강조색은 시스템 설정을 따르고, 한도 경고에는 상태 문구도 함께 표시합니다.
- 대시보드 결과는 탐색 패널 밖의 고정 높이 상태바에 한 줄로 표시합니다. 전체 메시지는 정보 버튼의 고정 크기 팝오버에서 읽고 선택·복사할 수 있습니다. 긴 오류와 전환 안내가 `List`·`NavigationSplitView`의 최소 크기를 변경하게 하지 않습니다.
- macOS 26 이상에서는 시스템 탐색·툴바의 Liquid Glass와 계정 전환 액션의 `GlassEffectContainer`, `.glass`, `.glassProminent`를 사용합니다. 사용량과 계정 데이터 자체에는 유리를 적용하지 않습니다.
- macOS 14·15에서는 표준 시스템 버튼과 소재로 대응합니다. 라이트·다크 모드, 투명도 감소, 대비 증가 설정을 존중합니다.

참고 문서:

- [Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [AgentSwap 개발 skill](../.agents/skills/agentswap-dev/SKILL.md)
