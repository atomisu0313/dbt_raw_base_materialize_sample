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

echo "=== Build (execution_date: ${EXEC_DATE}) ==="
uv run --env-file .env dbt build --vars "{\"execution_date\": \"${EXEC_DATE}\"}" "$@"
