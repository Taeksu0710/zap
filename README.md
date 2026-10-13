# Zap

FastFind(youngsam.net/programs/fastfind, Windows용 Rust 파일 검색기)의 macOS 네이티브 클론. NTFS MFT/USN 저널 대신 `getattrlistbulk()` 전체 스캔 + FSEvents 실시간 감지로 같은 목표(수십만 파일을 sub-10ms급으로 검색)를 달성한다. 핵심 차별점은 **한글 초성 검색**(예: `ㄴㄴ` → "나눔고딕" 매칭).

개인용 도구(공증 없음, ad-hoc 서명)로 개발 중이며, 패키지 이름은 여전히 `FindFast`이지만 앱 자체는 **Zap**으로 리브랜딩됐다.

## 현재 상태

**완료**
- 병렬 디렉토리 스캔(`getattrlistbulk` C shim) + trigram/초성 역색인 기반 검색
- 인덱스 영속화 — 커스텀 바이너리 포맷(`~/Library/Application Support/FindFast/index.bin`)에 저장, 재실행 시 전체 재스캔 없이 즉시 로드
- FSEvents 기반 실시간 증분 업데이트 — 앱 실행 중 파일 생성/삭제/이름변경이 수 초 내 검색 결과에 반영
- **앱 시작 시 최근 파일 즉시 표시** — 검색어 없이 열면 수정일 최신 순으로 500개가 바로 나온다. 검색창에 커서도 자동으로 들어가 있어 바로 타이핑 시작 가능
- **정렬 기능** — 관련도 / 이름 / 수정일 / 생성일 Picker. 기본값은 수정일 내림차순(최신 먼저)
- **수정일·생성일 양쪽 표시** — 결과 행마다 "수정 N일 전 · 생성 N일 전" 형태로 표기
- **수정일 정렬 fast path** — 빌드 시 `mtimeSortedIndices`(mtime 내림차순 인덱스)를 미리 계산해두어, 빈 쿼리나 짧은 검색어처럼 후보가 전체인 경우 O(N log N) 정렬 없이 순서대로 순회하다 limit 도달 즉시 종료
- 검색 결과 더블클릭으로 `NSWorkspace`를 통해 바로 열기
- 스캔 루트는 실행 사용자의 홈 디렉토리로 자동 설정(`NSHomeDirectory()` 기반), 경로 필드 왼쪽 폴더 아이콘을 눌러 `NSOpenPanel`로 원하는 폴더로 변경 가능
- CLI(`findfast`)와 GUI(`Zap.app`) 양쪽 지원, 같은 `FindFastCore` 엔진 공유
- Dock 아이콘 + 앱 번들 패키징(`scripts/build_app.sh`), `scripts/install_app.sh`로 `/Applications`에 배포 설치 가능
- Full Disk Access 온보딩 — 미부여 상태면 앱 실행 시 한 번만 안내 얼럿 표시(시스템 설정으로 바로 이동 버튼 포함)
- **인덱스 빌드 병렬화** — `IndexBuilder.build(from:)`를 CPU 코어 수만큼 샤딩해 병렬 처리. 홈 디렉토리 기준 45만 엔트리를 release 빌드로 ~0.3초에 빌드(이전 ~6초)
- CLI와 GUI가 기본 루트(홈 디렉토리)를 공유해 같은 `index.bin` 캐시를 재사용 — 번갈아 실행해도 서로의 캐시를 무효화하지 않음
- UI 폴리시: 검색창 pill 스타일, 결과 행 hover 하이라이트, 우클릭(Finder에서 보기/경로 복사), 상태 전환 애니메이션

**미구현 (원 계획의 Phase 2+)**
- 쿼리 문법 확장(`ext:` `size:` `mtime:` `type:` `dupe:` 등) — 지금은 이름/초성 매칭만 가능
- 메뉴바 상주 + 전역 단축키
- QuickLook 미리보기 패널
- Finder 우클릭 확장(FinderSync)
- `content:` 파일 내용 검색
- REST API

## 스캔 범위는 홈 디렉토리로 한정 (의도된 결정)

GUI(`Zap.app`)의 기본 스캔 루트는 **홈 디렉토리**(`NSHomeDirectory()`, 예: `/Users/<user>`)다. `/Applications`, 다른 사용자 폴더, 외장 볼륨 등 그 바깥은 검색되지 않는다.

FastFind(Windows)는 `C:` 드라이브 전체를 인덱싱하지만, 이 macOS 버전은 **개인 파일 검색 용도로는 홈 디렉토리만으로 충분하다고 판단해 의도적으로 범위를 좁혔다** — 전체 디스크로 확장하려면 Full Disk Access 권한이 필요해지고 인덱스 크기도 크게 늘어나는데, 그 비용 대비 실익이 적다고 확인된 결정이다. 전체 디스크 스캔이 필요해지면 `Scanner.swift`의 `defaultSkipPaths`(firmlink 중복 제거용)가 이미 "/"를 루트로 스캔하는 상황을 가정하고 작성돼 있어 큰 재작업 없이 확장 가능하다.

CLI(`findfast`)는 `-p` 플래그로 임의의 루트를 지정할 수 있어, 필요하면 `findfast -s <term> -p /` 로 전체 디스크도 검색 가능하다(단, GUI 기본값과는 무관).

## 아키텍처

```
Sources/
  CFFBulk/                # getattrlistbulk() C shim
  FindFastCore/           # 엔진 전체 (SPM 라이브러리)
    Scanner/              # 병렬 디렉토리 스캔, NFC 정규화
    IndexStore/            # actor 기반 인덱스 보관 + trigram/초성 검색
    Persistence/           # 바이너리 인덱스 직렬화(IndexFile) / 사이드카 메타데이터
    Watcher/               # FSEvents 브리징, dirty 경로 재조정
    QueryParser/           # 쿼리 문자열 파싱 (현재: 이름/초성만)
  findfast/                # CLI 실행파일
  FindFastApp/             # SwiftUI GUI (Zap)
  findfast-tests/          # 경량 자체 테스트 러너 (XCTest 미사용)
Resources/AppIcon.icns      # Zap 아이콘
scripts/build_app.sh        # Zap.app 번들 패키징 스크립트 (.build/Zap.app에 생성)
scripts/install_app.sh      # release 빌드 후 /Applications/Zap.app으로 설치
```

`IndexStore`는 `actor`로 격리되어 있어 검색(reader)과 재조정/저장(writer)이 동시에 발생해도 안전하다 — writer가 교체하기 전까지는 이전 스냅샷으로 응답한다.

## 빌드 & 실행

**요구 사항**
- macOS 14 이상
- Xcode Command Line Tools (`xcode-select --install`)

**CLI**
```bash
swift run findfast -s <검색어> [-p <루트경로>]
```

**GUI (Zap.app) — 개발용 빌드**
```bash
./scripts/build_app.sh debug    # 또는 release
open .build/Zap.app
```
스크립트가 `.build/Zap.app`을 조립하고(Info.plist, 아이콘, ad-hoc 코드사인 포함) 즉시 실행 가능한 번들을 만든다.

**GUI (Zap.app) — /Applications에 배포 설치**
```bash
./scripts/install_app.sh
```
release 구성으로 빌드한 뒤 `/Applications/Zap.app`으로 설치(기존 설치본이 있으면 교체)한다. 이후로는 Dock/Spotlight/Finder에서 일반 앱처럼 실행 가능 — 터미널이나 프로젝트 디렉토리에 의존하지 않는다. 코드를 수정한 뒤 다시 반영하려면 같은 스크립트를 재실행하면 된다.

**다른 사람에게 공유하기**
```bash
./scripts/package_for_sharing.sh
```
`dist/Zap.zip`(공유용 압축)과 `dist/HOW_TO_OPEN.txt`(받는 사람에게 같이 전달할 Gatekeeper 우회 안내문)를 생성한다. Apple Developer Program 계정 없이 ad-hoc 서명만 쓰므로, 받는 사람은 처음 실행 시 "확인되지 않은 개발자" 경고가 뜨고 control+클릭 → 열기(또는 시스템 설정 > 개인정보 보호 및 보안 > 확인 없이 열기)를 한 번 해줘야 한다 — 이후로는 정상적으로 더블클릭 실행된다. 이 Mac(Apple Silicon) 전용 바이너리라 Intel Mac에는 실행되지 않는다(유니버설 빌드가 필요하면 추가 작업 필요).

**테스트**
```bash
swift run findfast-tests
```

## 알려진 제약

- **FSEvents 히스토리 리플레이 없음** — 앱이 꺼져 있던 동안의 변경은 자동으로 반영되지 않는다. 수동 Rescan 버튼으로 해결.
- **TCC 보호 폴더 조용히 건너뜀** — `~/Library` 일부 하위 등 권한이 없는 폴더는 에러 없이 스킵된다.
- **재조정 시 인덱스 전체 재빌드** — FSEvents로 인한 재조정은 변경된 디렉토리만 재스캔하지만, trigram 인덱스는 전체를 다시 빌드한다. 병렬화 이후 수십만 엔트리 규모에서는 빠르지만(release 기준 1초 미만) 대규모 환경에서 재조정이 잦으면 반복 비용이 쌓일 수 있다.
- **ad-hoc 서명 한계** — 재설치(`install_app.sh` 재실행)할 때마다 서명 식별자가 바뀌어 Full Disk Access 권한이 초기화된다. self-signed 인증서로 고정 서명을 시도했으나 `errSecInternalComponent`로 실패해 보류 중.
