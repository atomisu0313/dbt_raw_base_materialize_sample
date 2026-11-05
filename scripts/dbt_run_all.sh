#!/bin/bash
set -Ceu

EXEC_DATE="${1:-}"

if [ -z "${EXEC_DATE}" ]; then
  echo "Error: EXEC_DATE is required." >&2
  echo "Usage: $0 <YYYY-MM-DD> [dbt-flags...]" >&2
  echo "Example: $0 2026-10-07" >&2
  echo "Example (full refresh): $0 2026-10-07 --full-refresh" >&2
  exit 1
fi

shift

# Microbatch 用に翌日 (batch end) を標準 date コマンドで計算 (macOS / Linux 両対応)
if date -v+1d >/dev/null 2>&1; then
  NEXT_DATE=$(date -j -v+1d -f "%Y-%m-%d" "${EXEC_DATE}" "+%Y-%m-%d")
else
  NEXT_DATE=$(date -d "${EXEC_DATE} + 1 day" "+%Y-%m-%d")
fi

echo "=== Build (execution_date: ${EXEC_DATE}, microbatch: ${EXEC_DATE} ~ ${NEXT_DATE}) ==="

set -x
uv run --env-file .env dbt build \
  --vars "{\"execution_date\": \"${EXEC_DATE}\"}" \
  --event-time-start "${EXEC_DATE}" \
  --event-time-end "${NEXT_DATE}" \
  "$@"
{ set +x; } 2>/dev/null
