# dbt Raw-Base Materialization Catalog

本リポジトリは、**dbt におけるイベントデータ（トランザクション）とマスタデータを「どう永続化（Materialize / Incremental）するか」を体系化したカタログプロジェクト**です。

データ連携の形態（全量連携 / 差分連携）およびデータ種別（マスタ / イベント）の違いに応じて、Base 層でどのように履歴保持・日次断面抽出を行い、Incremental モデルとして効率的に永続化するかを、実動するコードとハンズオン形式で提供します。

---

## 1. 永続化パターンの全体像

| ドメイン | データ種別 | 連携形態 | 適用マクロ | 出力の形態 | 永続化戦略 (Materialization) |
|---|---|---|---|---|---|
| **`customer`** | マスタ | **差分連携**<br>(変更行のみ配信) | `cleansing_master_diff_data` | 日付 (`partition_date`) ごとの**全件日次断面** | **Incremental (Delete + Insert)**<br>`pre_hook` で直近 `expiration_day` 日分を事前 DELETE し再構築 |
| **`shops`** | マスタ | **全量連携**<br>(定期全件ダンプ) | `cleansing_master_all_data` | 日付ごとの**全件日次断面**<br>(未配信日の歯抜け・未来日を ASOF JOIN で自動補完) | **Incremental (Delete + Insert)**<br>`pre_hook` で直近 `expiration_day` 日分を事前 DELETE し再構築 |
| **`orders`** | イベント / トランザクション | **差分連携**<br>(発生・更新イベント) | `cleansing_transaction_diff_data` | PK ごとの**最新状態 1 行**<br>（最新有効日の `partition_date` 付与） | **Incremental (Merge / Upsert)**<br>`unique_key: [order_id]` に基づく最新状態マージ |

---

## 2. コア設計思想

### ① Base 層を VIEW ではなく Incremental（物理テーブル）にする理由
一般論として「Staging / Base 層は VIEW が推奨される」と言われることがありますが、それは「1行が1行のまま変わらない薄い型変換層」に限られます。  
本プロジェクトの Base 層が行っている処理は、実質的に**「履歴データから日次スナップショットを復元するモデリング処理」**です。
- **`CROSS JOIN` や `LAG()`、`ASOF JOIN`、`ROW_NUMBER()` などの重厚な演算を含む VIEW は、下流が SELECT するたびに全量再計算され、オプティマイザの述語プッシュダウン（パーティション刈り込み）も阻害**します。
- そのため、バッチ実行時に事前に日次断面を物理確定させておく `incremental`（物理テーブル）を採用し、下流クエリのパフォーマンスと DWH コストを最適化しています。

### ② ステートレス・完全再現性の徹底（dbt snapshot の排除）
`dbt snapshot`（SCD Type 2）はデータベース側に内部状態を保持するため、「いつ・どの順番でスナップショットを叩いたか」に結果が依存し、過去の中間修正や Git での履歴追従・再現が極めて困難になります。  
本プロジェクトではスナップショットを使わず、すべての変更履歴を `seeds`（CSV）に直接保持して **`seeds` $\rightarrow$ `raw` $\rightarrow$ `base`** で処理します。これにより、誰の環境でも Git のコミット履歴から 100% 同一のデータが即座に再現（完全な冪等性）されます。

### ③ 事故防止のための基準日（`execution_date`）明示強制
`current_date()` による暗黙実行を廃止し、`execution_date` が指定されない場合は**コンパイルエラー（`raise_compiler_error`）で即座に停止**します。これにより、開発時やリカバリ時に意図しない現在日付で過去断面が上書き破壊される事故を 100% 防止します。

### ④ `pre_hook` の事前 DELETE 範囲と INSERT 範囲の完全一致
増分実行（Incremental）において、**事前に DELETE するパーティション範囲**と、**再計算して INSERT するパーティション範囲**は、同一の基準日 `target_date = var('execution_date')::date` に完全に揃えられています。

* **削除範囲（`pre_hook`）**:
  $$(\text{target\_date} - \text{reset\_days}) < \text{partition\_date} \le \text{target\_date}$$
* **投入範囲（`get_all_date_prep`）**:
  $$\text{target\_date} - (\text{reset\_days} - 1) \le \text{partition\_date} \le \text{target\_date}$$

両者が完全に一致しているため、バッチが数日間停止した場合や、過去日を指定したバックフィル時にも、重複やデータ欠落が一切発生しません。

### ⑤ 純粋なディスパッチャマクロ（単一責任の原則）
共通窓口マクロ `cleansing_data` は、各個別マクロ（`master_diff`, `master_all`, `transaction_diff`）へのルーティングのみに徹し、`config()` や二重判定を持たないクリーンな設計（20行）に純化されています。

---

## 3. 各パターンの仕様とデータフロー

### ① `customer`: 差分連携のマスタ
* **データフロー**:
  `seed_customers` $\rightarrow$ `raw_customer` $\rightarrow$ **`base_customer`**
* **マクロロジック (`cleansing_master_diff_data`)**:
  1. `coalesce(updated_at, created_at, loaded_at)` から `lag` により次回更新日（`ended_at`）を算出（最新行は `9999-12-31`）。
  2. 基準日（`target_date`）から過去へ向かって日付グリッド（`partition_date`）を生成。
  3. クロスジョインし、`effective_at <= partition_date < ended_at` の条件で「その日付時点で有効だった版」だけを抽出。
  4. `pre_hook` で直近 `expiration_day` 日分の断面を事前 DELETE してから INSERT。

### ② `shops`: 全量連携のマスタ
* **データフロー**:
  `seed_shops` $\rightarrow$ `raw_shops` $\rightarrow$ **`base_shops`**
* **マクロロジック (`cleansing_master_all_data`)**:
  1. 断面作成対象の日付リスト（`calendar`）を生成。
  2. 実際に配信があった日付リスト（`delivery_dates`）を抽出。
  3. **ASOF JOIN**（`c.partition_date >= d.delivery_date`）を用いて、各日付から見た「直近最新の配信日」をマッピング。
     - 配信があった日: その日のデータに 1:1 でマップ
     - 未配信日（歯抜け・未来日）: **直前配信日のデータに自動補完マッピング**
  4. 本体テーブルと参照すべき配信日で**通常の等結合（Equi-Join）**。
  5. `pre_hook` で直近 `expiration_day` 日分の断面を事前 DELETE してから INSERT。

### ③ `orders`: 差分連携のイベント（トランザクション）
* **データフロー**:
  `seed_orders` $\rightarrow$ `raw_orders` $\rightarrow$ **`base_orders`**
* **マクロロジック (`cleansing_transaction_diff_data`)**:
  1. PK ごとに `coalesce(updated_at, created_at, loaded_at)` が最新のレコードを `row_number() = 1` で特定。
  2. 同一秒の更新がある場合は `loaded_at` でタイブレーク。
  3. Incremental 実行時は直近 `expiration_day` 日以内に変更があったイベントのみを抽出し、`unique_key: ['order_id']` で Base テーブルに **MERGE**。
  4. 最新有効日から `cast(effective_at as date) as partition_date` を生成して連携。

---

## 4. モデル設定: `schema.yml` (`_BASE.yml`) による一元管理

各モデルの設定は `models/base/_BASE.yml` の `config.meta` に集約されています。

```yaml
models:
  - name: base_customer
    config:
      meta:
        source_delivery_type: "master_diff"    # 差分マスタ
        expiration_day: 14
        pk_col: ["id"]
        updated_at: "updated_at"

  - name: base_shops
    config:
      meta:
        source_delivery_type: "master_all"     # 全量マスタ
        expiration_day: 14
        pk_col: ["shop_id"]
        loaded_at: "loaded_at"

  - name: base_orders
    config:
      meta:
        source_delivery_type: "transaction_diff" # イベント差分
        expiration_day: 7
        pk_col: ["order_id"]
        updated_at: "updated_at"
        created_at: "ordered_at"
        loaded_at: "loaded_at"
```

これにより、**すべての Base モデル SQL は `cleansing_data` を 1 行呼ぶだけの統一コード**になっています：

```sql
with source_data as (
    select * from {{ ref('raw_customer') }}
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

本プロジェクトの実行および確認は、すべて `scripts/` 配下のスクリプト経由で行います。

### ステップ 1: 初回フルビルド（Full Refresh）
基準日 `YYYY-MM-DD` を指定し、`--full-refresh` フラグを付けて実行します：
```bash
./scripts/dbt_run_all.sh 2026-10-07 --full-refresh
```
* `seed` の投入から `raw`、`base` モデルの構築およびテストまでが一括実行されます。
* `base_customer` / `base_shops`: 最古の日付から `2026-10-07` までの全期間の日次断面が生成されます。
* `base_orders`: 最新ステータスが `partition_date: 2026-10-07` 等で物理格納されます。

---

### ステップ 2: 日次増分ビルド（Incremental）
日付を進めて通常実行します（`execution_date` 引数は必須）：
```bash
./scripts/dbt_run_all.sh 2026-10-08
```
* `base_customer` / `base_shops`: `pre_hook` で直近 `expiration_day` 日分（過去14日）が事前 DELETE され、重複なく洗い替えされます。
* `base_orders`: 直近 `expiration_day` 日分（過去7日）に変更のあった注文のみが MERGE（更新 / 追加）されます。

---

### ステップ 3: データの確認
付属のクエリ実行スクリプトで各 Base テーブルの結果を確認します：
```bash
# 顧客マスタ日次断面
./scripts/query_run.sh queries/select_base_customer.sql

# 店舗マスタ日次断面（未配信日のASOF JOIN補完結果）
./scripts/query_run.sh queries/select_base_shop.sql

# 注文データ最新ステータス
./scripts/query_run.sh queries/select_base_order.sql
```

---

### データベースのリセット（やり直したい場合）
DuckDB のデータベースファイルを初期化したい場合は、削除スクリプトを実行してから再度ビルドしてください：
```bash
./scripts/remove_duckdb.sh
./scripts/dbt_run_all.sh 2026-10-07 --full-refresh
```
