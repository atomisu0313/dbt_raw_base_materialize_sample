#!/bin/bash
set -Ceu

uv run --env-file .env dbt seed

uv run --env-file .env dbt run -s "raw_customer"
uv run --env-file .env dbt snapshot -s "raw_customer_snapshot"
uv run --env-file .env dbt run -s "base_customer"

#↑の一覧の処理はdbt debugで終了
