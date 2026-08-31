#!/bin/sh
# Bump the local build counter at the start of each build.
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
