# 작업 기록

Zap(구 FindFast)을 처음부터 지금까지 만들면서 거친 단계들의 기록. "지금 뭐가 되는지"는 `README.md`를 보고, "어떻게/왜 지금 모습이 됐는지"는 이 문서를 본다.

## 12. 시작 UX + 수정일 정렬 성능 개선

요청 배경: (1) "앱 시작할 때 커서가 검색창에 들어가 있게 해줘." (2) 그 외 추가로 수정해야 할 내용 점검.

수정 전 상태를 확인해보니 세 버그가 연쇄적으로 얽혀 있었다.

**버그 1 — 포커스 미작동**: `onAppear`에서 `loadAndWatch()`가 즉시 `isIndexing = true`를 설정하고, TextField가 `.disabled(viewModel.isIndexing)` 상태로 비활성화되기 때문에 0.1초 뒤 `searchFieldFocused = true`를 실행해도 포커스가 잡히지 않았다. → TextField에서 `.disabled(viewModel.isIndexing)` 제거, 대신 `onChange(of: viewModel.isIndexing) { if !isIndexing { searchFieldFocused = true } }`를 VStack에 추가. 인덱싱 완료 시점에 자동으로 포커스가 들어온다.

**버그 2 — 빈 쿼리가 아무것도 표시하지 않음**: `IndexStore.search()`의 guard 조건(`!query.raw.isEmpty || !query.extensionFilter.isEmpty`)이 빈 쿼리를 즉시 `[]`로 차단했다. 기본 정렬이 수정일(최신 먼저)이지만 앱 시작 직후(빈 쿼리 상태)에는 아무 파일도 보이지 않았다. → guard를 `guard index.count > 0 else { return [] }`로 단순화.

**버그 3 — limit 미전달로 fast path 무효화**: `SearchViewModel.runSearch()`가 limit 없이 `search()`를 호출(`limit = Int.max` 기본값)해, fast path의 `if results.count >= limit { break }` 조건이 절대 참이 되지 않았다. → `store.search(parsed, limit: 500, ...)` 명시 전달.

세 버그 수정 후 동작: 앱 실행 → 인덱싱 완료 → 검색창 자동 포커스 + 최근 파일 500개 즉시 표시.

## 11. 정렬 기능 + 생성일(crtime) 표시 + 수정일 정렬 fast path

요청 배경: "정렬 기능이 생각보다 성능이 안 좋네. 기본적으로 처음 검색하면 수정일이 최신인 상태로 나오면서 속도가 빠른 방법은 없나?"

**생성일(crtime) 파이프라인 추가**: APFS의 `ATTR_CMN_CRTIME`을 C shim(`CFFBulk`)에서 읽어, `FileEntry` → `BuiltIndex.crtimes` → `SearchResult` → 결과 행("생성 N일 전")까지 전 구간에 추가. `IndexFile` formatVersion을 2로 올려 자동 재스캔 폴백.

**정렬 기능**: `SearchSortOrder` enum(관련도/이름/수정일/생성일)을 `IndexStore.search()`에 추가, `SearchViewModel`에 `@Published var sortOrder`와 정렬 방향 토글 버튼, ContentView의 statusRow에 segmented Picker. 정렬 전환 시 쿼리를 재실행하도록 연결.

**수정일 정렬 fast path**:

짧은 쿼리나 빈 쿼리에서 후보가 전체 N개(45만)일 때, 기존 흐름은 전체 수집 → O(M log M) 정렬 → limit만 사용이었다. 수백 개를 쓰려고 수십만 개를 정렬하는 낭비였다.

- `BuiltIndex`에 `mtimeSortedIndices: [UInt32]` 추가 — `mergeShards`에서 빌드 시 한 번(O(N log N)) 계산해 저장.
- `allCandidates` 플래그 — 후보가 전체(빈 쿼리, 2자 미만 쿼리, 확장자 전용 쿼리)일 때 `true`.
- `sortOrder == .modified && allCandidates`이면 `mtimeSortedIndices`를 순서대로 순회하다 limit 도달 즉시 `break` — 정렬 단계 자체가 없어지고, 수백~수천 항목만 검사해 완료.

기본 정렬을 `.modified` 내림차순으로 변경(`SearchViewModel` 초기값), 짧은 쿼리에서도 바로 최신 파일 순으로 결과가 나온다.

## 1. 코어 엔진 + GUI 최초 구현

- `getattrlistbulk()` C shim(`Sources/CFFBulk`)으로 병렬 디렉토리 스캔, trigram 역색인 + 한글 초성(choseong) 역색인 기반 검색 엔진(`FindFastCore`) 구현.
- CLI(`findfast`)와 최소 SwiftUI GUI(`FindFastApp`) 구현.
- 실데이터(~10만 엔트리)로 스캔 1.5초, 검색 1.5~440ms 벤치마크 확인.
- 발견·수정한 실버그 3건:
  - CLI에서 `Task{} + DispatchSemaphore.wait()`가 Swift 6 MainActor와 맞물려 자체 교착상태 — `@main async func main()` 구조로 수정.
  - APFS가 한글 파일명을 NFD(분해형)로 반환하는데 초성 변환 로직은 NFC(완성형) 가정 — Scanner/QueryParser 양쪽에서 즉시 NFC 정규화하도록 수정.
  - GUI 창이 활성화돼도 검색 필드가 first responder를 못 받아 타이핑이 무시됨 — `NSApplicationDelegateAdaptor`(창 활성화) + `@FocusState`(자동 포커스)로 수정.

## 2. 인덱스 영속화 + FSEvents 실시간 감지

요청 배경: "매번 전체 재스캔하는 대신, 한 번 스캔한 걸 저장해두고 재실행 시 바로 불러오면서, 실행 중 변경사항은 자동 반영됐으면 좋겠다."

- 커스텀 바이너리 포맷(`Persistence/IndexFile.swift`)으로 `[FileEntry]` 목록만 저장(파생 구조인 trigram/jamo는 로드 시 재계산) — `~/Library/Application Support/FindFast/index.bin`.
- `IndexStore.loadOrBuild(root:)`: 캐시가 있고 유효하면(magic/formatVersion/volumeUUID/scanRoot 전부 일치) 즉시 로드, 아니면 전체 스캔 후 저장 — 손상/구버전 캐시는 자동으로 전체 재스캔 폴백.
- FSEvents 브리징(`Watcher/Watcher.swift`, C shim 불필요 — `import CoreServices`로 직접 호출) + `IndexStore.handleDirtyPaths(_:)` 재조정 로직: 변경된 디렉토리만 재스캔해 인덱스에 병합.
- `actor` 격리 덕분에 재조정 도중에도 검색은 안전(이전 스냅샷으로 응답).

## 3. 사용성 개선 (더블클릭 열기, 경로 UX)

- "검색 결과를 더블클릭해서 열 수 있어야 할 것 같다" → `NSWorkspace.shared.open(_:)` 연결.
- "경로를 굳이 지정해야 하나?" → 처음엔 UserDefaults로 마지막 경로 기억 + Enter로 전환하도록 했으나, 사용자가 "전체 스캔 버튼 하나 있고 그 뒤로는 그냥 되면 좋겠다"고 재요청 → 기본 루트를 홈 디렉토리 전체로 변경, 경로를 신경 쓸 필요 없게 함.

## 4. 성능 1차 튜닝

- 사용자가 "16 results in 24646.89ms" 스크린샷으로 느림을 지적 — 진단 결과 실제 검색은 0.347ms였고, 범인은 "인덱싱 중(17초짜리 홈 전체 스캔) 사용자가 입력한 검색이 액터 큐에서 대기"한 것이었음.
- 근본 수정: `Scanner.defaultSkipDirectoryNames`(node_modules, .git, DerivedData 등) 추가로 엔트리 수 1.67M → 335K로 축소, 인덱싱 중엔 검색창 비활성화 + 스피너로 혼란스러운 상태를 UI에서 차단.
- 트라이그램 해시 함수가 호출마다 배열 리터럴을 힙 할당하던 것을 언롤링으로 제거, 로드 시 불필요한 중복 NFC 정규화 제거 — 97K 엔트리 로드+빌드 1.57초 → 0.97초.

## 5. "Zap" 리브랜딩

사용자 요청: "아이콘 좀 이쁘게 바꿔주고 이름도 findfast가 아니라 다른 걸로, UI도 이쁘게."

- 이름 후보(휙/콕/Glint/Zap) 중 **Zap** 선택.
- Core Graphics로 보라→파랑 그라디언트 + 노란 번개(`bolt.fill`) 커스텀 아이콘 생성(`Resources/AppIcon.icns`).
- `scripts/build_app.sh`: 바이너리를 실제 `.app` 번들로 패키징(Info.plist, 아이콘, ad-hoc 코드사인) — 그냥 `swift build` 결과물만으로는 Dock 아이콘/이름이 제대로 안 나오기 때문.
- UI 1차 리디자인: 그라디언트 번개 아이콘, 상태 점, 캡슐형 파일 크기 배지 등.
- `scripts/install_app.sh` 추가 — release 빌드 후 `/Applications`에 설치.

## 6. Full Disk Access 온보딩 + 실제 버그 1건

사용자가 반복되는 권한 팝업을 지적:

- "개별 권한 요청이 반복되는데, 한 번에 선택할 수 있으면 좋겠다" → macOS에는 per-folder 권한을 한 번에 묶어 요청하는 API가 없어서, Full Disk Access(FDA)를 한 번 부여하면 Desktop/Documents/Downloads별 개별 프롬프트가 전부 사라진다는 점에 착안해 앱 실행 시 FDA 유도 얼럿 추가.
- 그런데 사용자가 "다른 앱의 데이터에 접근하려고 합니다"가 반복된다는 스크린샷을 보내옴 — 이건 FDA와 무관한 **실제 버그**였다: FSEvents가 홈 디렉토리 전체를 감시하는데, 재조정 로직이 다른 앱의 `~/Library/Containers/...` 변경까지 재스캔하려 시도해 매번 TCC 프롬프트를 유발. `Scanner.isPathExcluded(_:root:)`를 추가해 일반 스캔이 애초에 건드리지 않는 경로(Library 하위 등)는 재조정 대상에서도 제외하도록 수정 — 근본 수정, FDA 여부와 무관하게 더 이상 발생하지 않음.

## 7. 폴더 피커

"사용자마다 자동 인식되면 좋겠고, 원하면 변경도 가능했으면" → 확인해보니 `NSHomeDirectory()` 기반이라 이미 계정별 자동 인식이었음(README 예시 경로 때문에 오해 발생). 다만 경로 변경이 텍스트 필드 수동 입력뿐이라 발견성이 낮아, 경로 필드 왼쪽 폴더 아이콘을 `NSOpenPanel` 트리거 버튼으로 변경.

## 8. 전면 감사 + 후속 수정

작업 내역이 쌓이자 사용자 요청으로 3개 Explore 에이전트를 동원해 엔진/앱·패키징/일관성 전면 감사 진행. ~25개 지적 중 실제 버그로 확인된 것들을 수정:

- **FDA 알림 레이스/반복**: `NSAlert.runModal()`이 창 렌더링 전에 동기 호출되어 빈 창이 깜빡이던 문제, "Not Now" 눌러도 매 실행마다 알림이 반복되던 문제 → `DispatchQueue.main.async`로 지연 + `didOfferFDA` UserDefaults 플래그로 1회만 표시.
- **CLI/GUI 캐시 충돌**: CLI 기본 루트가 `/`, GUI는 홈 디렉토리라 같은 `index.bin`을 두고 서로 캐시를 무효화하던 문제 → CLI 기본값도 홈으로 통일.
- **폴더 피커 인덱싱 중 미비활성화**: 인덱싱 도중 폴더를 바꾸면 경로 필드만 바뀌고 실제 스캔은 조용히 드롭되던 문제 → 버튼 비활성화.
- **`isPathExcluded` 엣지케이스 2건**: `root`에 끝 슬래시가 있으면 제외 로직이 전혀 작동하지 않던 버그, `root`가 스킵 경로와 정확히 같으면 그 하위 전체가 잘못 제외되던 버그 → 둘 다 수정 + 회귀 테스트.
- **테스트 보강**: `versionMismatch`/`volumeMismatch` 폴백, 전체-제외 시 재조정 no-op, CLI 인자 파싱(`CLIArguments.parse`로 분리해 테스트 가능하게 만듦) 전부 커버.
- **self-signed 코드서명 시도 (보류)**: ad-hoc 서명은 재설치마다 TCC 식별자가 바뀌어 FDA 허가가 매번 초기화되는 문제가 있어, Keychain에 재사용 가능한 self-signed 인증서를 만들어 고정 서명하는 방법을 시도. `security import`의 빈 비밀번호 MAC 검증 실패, `trustAsRoot`/`trustRoot` 혼동 등을 해결해 인증서 생성·신뢰 설정까지는 성공했으나, 최종 `codesign --sign`이 `errSecInternalComponent`로 실패해 원인 미해결 상태로 **사용자 결정에 따라 작업 제외** — ad-hoc 서명 유지, 인증서는 삭제.

## 9. 성능 병렬화 + UI 폴리시 패스

사용자가 "속도 개선"과 "UI를 더 괜찮게"를 함께 요청. 감사로 확인한 사실: `IndexBuilder.build(from:)`가 완전 단일 스레드였고, 45만 엔트리 기준 스캔/로드 어느 경로든 5~6초가 거의 전부 이 함수(트라이그램 posting list 구축, 딕셔너리 삽입 800만~1000만 회)에서 소모되고 있었음 — 정작 스캔 단계는 이미 16코어 병렬화돼 있었는데 빌드 단계만 그대로였음.

- `IndexBuilder.build(from:)`를 CPU 코어 수만큼 샤딩 → 샤드별 독립 빌드(이름/자모 버퍼, 트라이그램 등 전부 로컬 인덱스로) → 단일 병합 단계(오프셋 보정, parent path 전역 interning, 트라이그램 posting list 병합). 결과: release 빌드 기준 **~6초 → 0.28초**.
- UI 폴리시 패스(사용자가 세 방향 중 "폴리시 패스" 선택 — 레이아웃 구조는 유지하고 디테일만 다듬기): 검색창을 둥근 pill 스타일로, 결과 행에 hover 하이라이트, 수정일을 상대 시간("2일 전")으로 표시, 우클릭 컨텍스트 메뉴(Finder에서 보기/경로 복사), 상태 전환에 애니메이션 추가.

## 10. 배포 준비 (ad-hoc, 소수 공유용)

"다른 사람한테 배포하고 싶으면?" 질문에 Apple Developer Program($99/년) 가입 여부로 갈라지는 선택지(가벼운 ad-hoc 공유 / Developer ID+공증 / Mac App Store)를 제시 — 사용자가 **가입 없이 소수에게 공유** 선택.

- `scripts/package_for_sharing.sh` 신규 추가: release 빌드 → `ditto -c -k`(코드서명/리소스 포크 보존, 일반 `zip`은 이를 깨뜨릴 수 있음)로 `dist/Zap.zip` 생성 → 압축 해제 후 `codesign --verify`로 서명이 왕복 과정에서 안 깨졌는지 확인 완료.
- `dist/HOW_TO_OPEN.txt` 동봉: ad-hoc 서명 앱이라 받는 사람이 처음 실행 시 겪을 Gatekeeper "확인되지 않은 개발자" 경고를 넘기는 방법(control+클릭 → 열기, 또는 시스템 설정에서 확인 없이 열기) 안내.
- 제약: 이 Mac(Apple Silicon)에서 빌드한 arm64 전용 바이너리라 Intel Mac에서는 실행 불가 — 필요해지면 universal 빌드로 확장 가능.

## 부록: 검증 방식에 대한 메모

이 프로젝트는 여러 모니터를 쓰는 활성 공유 데스크톱에서 작업했다. GUI 동작을 스크린샷/키 입력 주입으로 검증하려던 시도가 두 번 문제를 일으켰다(무관한 앱의 저장 다이얼로그에 텍스트가 섞여 들어갈 뻔함, 무관한 이메일 창을 스크린샷으로 캡처함) — 둘 다 즉시 되돌리거나 삭제했지만, 이후로는 GUI 상호작용이 필요한 검증은 가능하면 CLI/빌드/테스트 기반으로 하거나 사용자에게 직접 확인을 요청하는 방식으로 전환했다.
