#!/bin/bash
set -Ceu

uv run --env-file .env dbt seed
