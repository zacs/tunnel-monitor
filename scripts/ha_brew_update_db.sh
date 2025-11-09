#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LOGTAG="ha_brew_update_db"
DATE_STR="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

if ! command -v brew >/dev/null 2>&1; then
  echo "[$LOGTAG] $DATE_STR: brew not found" >&2
  exit 0
fi

brew update >/dev/null 2>&1 || true
echo "[$LOGTAG] $DATE_STR: brew update done"