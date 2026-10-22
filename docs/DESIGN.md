# 네이티브 macOS 화면

Apple Human Interface Guidelines의 macOS 구조와 시스템 소재를 사용합니다. 웹 대시보드 형태의 카드 그리드와 장식적인 문구 대신 계정 관리에 필요한 정보와 행동을 앞에 둡니다.

- 표준 `NavigationSplitView`와 `.sidebar` 목록에서 제공자를 선택합니다.
- 계정 목록에서 활성 상태와 공통 사용량을 비교하고, 선택한 계정의 상세 정보는 `inspector`의 시스템 `Form`에서 확인합니다.
- 각 사용량 창은 계정 목록·상세·메뉴바에서 초기화까지 남은 시간과 시스템 시간대의 날짜·시각을 표시합니다. 제공하지 않은 시각은 추정하지 않으며, 지난 시각의 캐시를 사용률 초기화로 해석하지 않습니다.
- 통합 툴바에서 계정 추가·새로고침·검색·상세 패널 표시를 수행합니다.
- 저장된 계정은 드래그하거나 툴바·우클릭 메뉴의 위·아래 이동으로 순서를 바꿉니다. 제공자 필터나 검색에서 보이지 않는 계정의 위치는 유지하며 메뉴바도 같은 표시 순서를 사용합니다.
- 계정 상세와 우클릭 메뉴의 재로그인은 대상 계정·워크스페이스를 먼저 보여주고 공식 브라우저 로그인을 시작합니다. 다른 계정으로 로그인한 결과는 대상에 덮어쓰지 않습니다. 새 인증의 저장과 CLI 적용 대기를 구분해 표시합니다.
- 시스템 글꼴과 의미 기반 색을 사용합니다. 강조색은 시스템 설정을 따르고, 한도 경고에는 상태 문구도 함께 표시합니다.
- 대시보드 결과는 탐색 패널 밖의 고정 높이 상태바에 한 줄로 표시합니다. 전체 메시지는 정보 버튼의 고정 크기 팝오버에서 읽고 선택·복사할 수 있습니다. 긴 오류와 전환 안내가 `List`·`NavigationSplitView`의 최소 크기를 변경하게 하지 않습니다.
- macOS 26 이상에서는 시스템 탐색·툴바의 Liquid Glass와 계정 전환 액션의 `GlassEffectContainer`, `.glass`, `.glassProminent`를 사용합니다. 사용량과 계정 데이터 자체에는 유리를 적용하지 않습니다.
- macOS 14·15에서는 표준 시스템 버튼과 소재로 대응합니다. 라이트·다크 모드, 투명도 감소, 대비 증가 설정을 존중합니다.

참고 문서:

- [Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [AgentSwap 개발 skill](../.agents/skills/agentswap-dev/SKILL.md)
