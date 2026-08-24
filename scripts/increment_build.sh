#!/bin/sh
# Bump a local build counter and stamp it into the built app's Info.plist.
# Skipped for indexing so SourceKit does not consume numbers.

set -e

case "${ACTION:-}" in
  indexbuild|installhdrs) exit 0 ;;
esac

NUM_FILE="${SRCROOT}/.build-number"
if [ -f "$NUM_FILE" ]; then
  NUM=$(cat "$NUM_FILE")
  case "$NUM" in
    ''|*[!0-9]*) NUM=0 ;;
  esac
else
  NUM=0
fi
NUM=$((NUM + 1))
printf '%s\n' "$NUM" > "$NUM_FILE"

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUM" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $NUM" "$PLIST"
fi

echo "========================================"
echo "How Many Landings  BUILD ${NUM}"
echo "========================================"
echo "note: How Many Landings build ${NUM}"

if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"Build ${NUM} is ready\" with title \"How Many Landings\"" >/dev/null 2>&1 || true
fi
