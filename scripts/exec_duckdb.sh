#!/bin/bash
set -Ceu

db_name="raw_base_mate.duckdb"

uv run --env-file .env duckcli $db_name
