#!/bin/sh
# Stamp the current build number into the built app after Info.plist is generated.
# Skipped for indexing so SourceKit does not consume numbers.

set -e

case "${ACTION:-}" in
  indexbuild|installhdrs) exit 0 ;;
esac

NUM_FILE="${SRCROOT}/.build-number"
if [ ! -f "$NUM_FILE" ]; then
  exit 0
fi
NUM=$(cat "$NUM_FILE")
case "$NUM" in
  ''|*[!0-9]*) exit 0 ;;
esac

stamp_plist() {
  local plist="$1"
  if [ -f "$plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUM" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $NUM" "$plist"
  fi
}

stamp_plist "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -n "${PROCESSED_INFOPLIST_PATH:-}" ]; then
  stamp_plist "${PROCESSED_INFOPLIST_PATH}"
fi

RES_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
mkdir -p "$RES_DIR"
printf '%s\n' "$NUM" > "${RES_DIR}/BuildNumber.txt"

echo "========================================"
echo "Pattern Watcher  BUILD ${NUM}"
echo "========================================"
echo "note: Pattern Watcher build ${NUM}"

if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"Build ${NUM} is ready\" with title \"Pattern Watcher\"" >/dev/null 2>&1 || true
fi
