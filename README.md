# dbt Raw-Base Materialization Catalog

本リポジトリは、**dbt におけるイベントデータ（トランザクション）とマスタデータを「どう永続化（Materialize / Incremental）するのか」を体系化したカタログリポジトリ**です。

データ連携の形態（全量連携 / 差分連携）およびデータ種別（マスタ / イベント）の違いに応じて、Base 層でどのように履歴保持・最新断面抽出を行い、Incremental モデルとして効率的に永続化するかを実動するコードとハンズオン形式で提供します。

リファレンス仕様: [`docs/raw.md`](docs/raw.md)（実環境の Snowflake CDP 履歴保持マクロ仕様書）

---

## 1. 永続化パターンの全体像

| ドメイン | データ種別 | 連携形態 | 適用マクロ | 出力の形態 | 永続化戦略 (Materialization) |
|---|---|---|---|---|---|
| **`customer`** | マスタ | **差分連携**<br>(変更行のみ配信) | [`cleansing_master_diff_data`](macros/cleansing_master_diff_data.sql) | 日付 (`partition_date`) ごとの**全件スナップショット** | **Incremental (Delete + Insert)**<br>`pre_hook` で直近 `expiration_day` 日分を事前 DELETE し再構築 |
| **`shops`** | マスタ | **全量連携**<br>(定期全件ダンプ) | [`cleansing_master_all_data`](macros/cleansing_master_all_data.sql) | 日付ごとの**全件スナップショット**<br>(未配信日の歯抜けを直前データで自動補完) | **Incremental (Delete + Insert)**<br>`pre_hook` で直近 `expiration_day` 日分を事前 DELETE し再構築 |
| **`orders`** | イベント / トランザクション | **差分連携**<br>(発生・更新イベント) | [`cleansing_transaction_diff_data`](macros/cleansing_transaction_diff_data.sql) | PK ごとの**最新状態 1 行** | **Incremental (Merge / Upsert)**<br>`unique_key: [order_id]` に基づく最新状態マージ |

---

## 2. コア設計思想

### ① `pre_hook` の事前 DELETE 範囲と INSERT 範囲の基準日（`target_date`）完全一致
増分実行（Incremental）において、**事前に DELETE するパーティション範囲**と、**再計算して INSERT するパーティション範囲**は、同一の基準日 `target_date = var('execution_date', current_date())::date` に完全に揃えられています。

* **削除範囲（`pre_hook`）**:
  $$(\text{target\_date} - \text{reset\_days}) < \text{partition\_date} \le \text{target\_date}$$
* **投入範囲（`get_all_date_prep`）**:
  $$\text{target\_date} - (\text{reset\_days} - 1) \le \text{partition\_date} \le \text{target\_date}$$

両者が完全に一致しているため、バッチが数日間遅延した場合や、過去日を指定したバックフィル（`--vars '{"execution_date": "YYYY-MM-DD"}'`）時にも、**無関係な最新データが誤削除されたり、重複が発生したりする破綻を 100% 防止**します。

### ② 月次など「30日おきに連携されるデータ」の日次断面化
30日おきにしか連携されないデータでも、日付グリッドの上限を `target_date`（今日）まで延伸し、最新レコードの `ended_at = 9999-12-31` とクロスジョインすることで、**最後に届いたデータが今日までの全日に自然に Forward-fill（前方補完）され、欠損のない日次断面**が維持されます。

### ③ なぜ `loaded_at` ではなく `coalesce(updated_at, created_at, loaded_at)` なのか？
外部ストレージ（S3, GCS）から `COPY INTO` 等で Raw テーブルに取り込む際、`loaded_at`（取込日時）はロード実行時のシステム時刻で上書き・付加されることが多く、業務上の実際の更新タイミングとは乖離します。
そのため、本カタログのマクロ群では以下の優先順位で**「真の業務有効日時（`effective_at`）」**を自動解決します：

$$\text{effective\_at} = \text{coalesce}(\text{updated\_at}, \text{created\_at}, \text{loaded\_at})$$

1. **`updated_at`（業務更新日時）**: レコードが変更された真の業務日時（最優先）
2. **`created_at`（業務作成・発生日時）**: 注文日や初回登録日などの発生日時
3. **`loaded_at`（システム取込日時）**: 業務日時が存在しない場合のフォールバック

---

## 3. 各パターンの仕様と永続化ロジック

### ① `customer`: 差分連携のマスタ
* **データフロー**:
  `seed_customers` → `raw_customer` → **`raw_customer_snapshot`（dbt snapshot で SCD Type 2 履歴管理）** → **`base_customer`**
* **マクロロジック (`cleansing_master_diff_data`)**:
  1. `coalesce(updated_at, dbt_updated_at)` から `lag` により次回更新日（`ended_at`）を算出。
  2. 基準日（`target_date`）から過去へ向かって日付リスト（`partition_date`）を生成。
  3. クロスジョインし、`effective_at <= partition_date < ended_at` の条件で「その日付時点で有効だった版」だけを抽出。
  4. `pre_hook` で直近 `expiration_day` 日分の断面を事前 DELETE してから INSERT。
  5. **強み**: dbt の実行が数日間止まっても、データの更新日ベースで過去全日分の断面が自律的にバックフィル・復元されます。

### ② `shops`: 全量連携のマスタ
* **データフロー**:
  `seed_shops` → `raw_shops` → **`base_shops`**
* **マクロロジック (`cleansing_master_all_data`)**:
  1. 断面作成対象の日付リスト（`calendar`）を生成（たかだか 14 行程度）。
  2. 実際に配信があった日付リスト（`delivery_dates`）を抽出（数行）。
  3. **ASOF JOIN**（`c.partition_date >= d.delivery_date`）を用いて、各日付から見た「直近最新の配信日」を瞬時にマッピング。
     - 配信があった日: その日のデータに 1:1 でマップ
     - 未配信日（歯抜け・未来日）: **直前配信日のデータに自動補完マッピング**
  4. 本体テーブル（`raw_table`）と参照すべき配信日で**通常の等結合（Equi-Join）**。
  5. **強み**: `cross join` や全件ソートの `lag` が完全に不要になり、計算量とメモリ使用量が劇的に削減されます。
  6. `pre_hook` で直近 `expiration_day` 日分の断面を事前 DELETE してから INSERT。

### ③ `orders`: 差分連携のイベント（トランザクション）
* **データフロー**:
  `seed_orders` → `raw_orders` → **`base_orders`**
* **マクロロジック (`cleansing_transaction_diff_data`)**:
  1. PK ごとに `coalesce(updated_at, ordered_at, loaded_at)` が最新のレコードを `row_number() = 1` で特定。
  2. 同一秒の更新がある場合は `loaded_at` でタイブレーク。
  3. Incremental 実行時は直近 `expiration_day` 日以内に変更があったイベントのみを抽出し、`unique_key: ['order_id']` で Base テーブルに **MERGE**。

---

## 4. モデル設定: `schema.yml` (`_BASE.yml`) による連携種別とメタデータの完全一元管理

適用するデータ連携種別（`source_delivery_type`）やパラメータ（主キー、業務更新日、取込日、保持期間など）はすべて `_BASE.yml` の `config.meta` に集約されています。

```yaml
models:
  - name: base_customer
    config:
      meta:
        source_delivery_type: "master_diff"    # 差分マスタを動的指定！
        expiration_day: 14
        pk_col: ["id"]
        updated_at: "updated_at"
        loaded_at: "dbt_updated_at"

  - name: base_shops
    config:
      meta:
        source_delivery_type: "master_all"     # 全量マスタを動的指定！
        expiration_day: 14
        pk_col: ["shop_id"]
        loaded_at: "loaded_at"

  - name: base_orders
    config:
      meta:
        source_delivery_type: "transaction_diff" # イベント差分マージを動的指定！
        expiration_day: 7
        pk_col: ["order_id"]
        updated_at: "updated_at"
        created_at: "ordered_at"
        loaded_at: "loaded_at"
```

これにより、**すべての Base モデル SQL は `cleansing_data` を 1 行呼ぶだけの完全に統一された定型コード**になります：

```sql
with source_data as (
    select * from {{ ref('raw_customer_snapshot') }}
),

{{
    cleansing_data(
        input = "source_data",
        output = "cleaned_latest"
    )
}}

final as (
    select * from cleaned_latest
)

select * from final
```

---

## 5. ハンズオン実行手順

本プロジェクトは **dbt 2.x** および **DuckDB** で動作します。

### ステップ 1: 初回ビルド（Full Refresh）
```bash
uv run dbt build --full-refresh
```
* `customer`: `2025-10-01` 〜 `execution_date` の日次断面が生成されます。
* `shops`: `2025-10-01` 〜 `execution_date` の日次断面（未配信日の歯抜けが自動補完）が生成されます。
* 全 38 件のテストが 100% PASS します。

### ステップ 2: 増分ビルド（Incremental）
```bash
uv run dbt run
```
* `base_customer` / `base_shops`: `pre_hook` で直近 `expiration_day` 日分が事前 DELETE され、重複なく再投入されます。
* `base_orders`: 直近 `expiration_day` 日分の最新ステータスのみが MERGE されます。

### ステップ 3: バックフィル実行（過去日の指定）
```bash
uv run dbt run --vars '{"execution_date": "2025-10-05"}'
```
* `execution_date` を起点として、指定日の直近 `expiration_day` 日分のみが整合性を保ったまま再計算・更新されます。
