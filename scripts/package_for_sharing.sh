#!/bin/bash
# Builds a release Zap.app and packages it into a zip suitable for sharing
# with other people (not just installing on this machine) — e.g. AirDrop,
# Slack, Google Drive.
#
# Uses `ditto` (not `zip`) to archive the .app: `zip` can silently mangle a
# bundle's extended attributes and code signature; `ditto -c -k` is Apple's
# own recommended way to zip an .app while preserving both.
#
# The app is still only ad-hoc signed (no Apple Developer Program account),
# so recipients will see a Gatekeeper "unidentified developer" warning on
# first launch — see dist/HOW_TO_OPEN.txt (included in the zip) for the
# one-time workaround they need to click through.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Zap"
DIST_DIR="$ROOT_DIR/dist"

echo "==> building release bundle"
"$ROOT_DIR/scripts/build_app.sh" release

SRC="$ROOT_DIR/.build/$APP_NAME.app"
if [ ! -d "$SRC" ]; then
  echo "error: built bundle not found at $SRC" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
rm -f "$ZIP_PATH"

echo "==> zipping (ditto, preserves code signature + resource forks)"
ditto -c -k --sequesterRsrc --keepParent "$SRC" "$ZIP_PATH"

cat > "$DIST_DIR/HOW_TO_OPEN.txt" << 'EOF'
Zap 실행이 안 되고 "확인되지 않은 개발자" 또는 "손상되었습니다" 경고가 뜨나요?

Apple 개발자 등록(유료) 없이 만든 앱이라 macOS Gatekeeper가 기본적으로 막습니다.
딱 한 번만 아래처럼 해주시면 이후로는 평소처럼 더블클릭으로 바로 실행됩니다.

1. Zap.zip의 압축을 풀어 Zap.app을 Applications 폴더로 옮깁니다.
2. Zap.app을 더블클릭 (바로 막히는 게 정상입니다) — 또는 처음부터:
   Finder에서 Zap.app을 "control(⌃)+클릭" → "열기" 선택 → 열기 확인
3. 그래도 안 되면: 시스템 설정 > 개인정보 보호 및 보안 (Privacy & Security)으로 이동해
   아래쪽에 "Zap"이 차단되었다는 안내가 보이면 "확인 없이 열기(Open Anyway)" 클릭.
4. 한 번 허용하면 그 다음부터는 경고 없이 바로 실행됩니다.

참고: 이 앱은 홈 폴더 전체를 검색 대상으로 스캔합니다. 실행 중 "다른 폴더에
접근하려고 합니다" 같은 권한 팝업이 뜨면 허용해주세요 — 검색 기능에 필요합니다.
EOF

echo "==> done:"
echo "    $ZIP_PATH"
echo "    $DIST_DIR/HOW_TO_OPEN.txt (zip과 같이 전달하세요)"
