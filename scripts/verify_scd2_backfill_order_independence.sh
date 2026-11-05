#!/bin/bash
set -Ceu

# ==============================================================================
# Script: verify_scd2_backfill_order_independence.sh
# Description:
#   SCD Type 2 モデルのバックフィル（Backfill）における動作確認スクリプト。
#   dbt build による DAG 依存解決と、microbatch による並列実行の整合性を確認する。
#
# Usage:
#   ./scripts/verify_scd2_backfill_order_independence.sh
#
# Example:
#   ./scripts/verify_scd2_backfill_order_independence.sh
# ==============================================================================

SEED_INIT="seeds/seed_customers_initial.csv"
SEED_BACKFILL="seeds/seed_customers_backfill.csv"
SEED_TARGET="seeds/seed_customers.csv"

if [ ! -f "${SEED_INIT}" ] || [ ! -f "${SEED_BACKFILL}" ]; then
  echo "Error: 検証用 seed ファイルが見つかりません。" >&2
  echo "必要ファイル: ${SEED_INIT}, ${SEED_BACKFILL}" >&2
  exit 1
fi

echo "=============================================================================="
echo " SCD Type 2 Backfill 動作検証"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# STEP 1: 初期シードを配置し、プロジェクト全体を一括初期ビルド
# ------------------------------------------------------------------------------
echo ""
echo ">>> STEP 1: 初期シードを配置し、dbt build でプロジェクト全体を一括初期ビルド..."
cp "${SEED_INIT}" "${SEED_TARGET}"

set -x
uv run --env-file .env dbt build \
  --vars '{"execution_date": "2026-10-15"}' \
  --event-time-start 2026-10-01 \
  --event-time-end 2026-10-15
{ set +x; } 2>/dev/null

# ------------------------------------------------------------------------------
# STEP 2: 過去データ（Backfillシード）を配置し、dbt build で一気に洗い替え
# ------------------------------------------------------------------------------
echo ""
echo ">>> STEP 2: Backfill用シードを配置し、dbt build で一気に洗い替え（並列4スレッド）..."
cp "${SEED_BACKFILL}" "${SEED_TARGET}"

set -x
uv run --env-file .env dbt build \
  --vars '{"execution_date": "2026-10-15"}' \
  --event-time-start 2026-10-10 \
  --event-time-end 2026-10-15 \
  --threads 4
{ set +x; } 2>/dev/null

# ------------------------------------------------------------------------------
# クリーンアップ: 初期シードに戻して環境を初期状態へ復元
# ------------------------------------------------------------------------------
echo ""
echo ">>> クリーンアップ: 初期シードに戻して環境を復元中..."
cp "${SEED_INIT}" "${SEED_TARGET}"
uv run --env-file .env dbt build \
  --full-refresh \
  --vars '{"execution_date": "2026-10-15"}' \
  --event-time-start 2026-10-01 \
  --event-time-end 2026-10-15 >/dev/null

echo ""
echo "=============================================================================="
echo " 検証処理が正常に完了しました。"
echo "=============================================================================="
