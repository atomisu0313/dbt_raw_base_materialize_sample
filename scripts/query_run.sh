#!/bin/bash
set -Ceu

if [ -z $1 ]; then
    echo "Usage: $0 <query_file>"
    echo "Example: $0 myquery/select_base.sql"
    exit 1
fi

uv run --env-file .env duckcli raw_base_mate.duckdb -e "$(cat $1)"
