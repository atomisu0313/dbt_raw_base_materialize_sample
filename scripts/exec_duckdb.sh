#!/bin/bash
set -Ceu

db_name="snapshot_2510.duckdb"

uv run --env-file .env duckcli $db_name
