-- ==============================================================================
-- Test: assert_fct_daily_order_backlog_dsnp_matches_scd2.sql
-- Description:
--   fct_daily_order_backlog_dsnp（日次断面 Base 参照）と
--   fct_daily_order_backlog_scd2（SCD Type 2 Base 参照）のデータ一致を検証する Singular Test。
--
--   両モデルを FULL OUTER JOIN し、
--   ① 片側にしか存在しないレコード（欠損）
--   ② 同一キー（order_id, partition_date）でカラム値が一致しないレコード
--   が存在する場合にその行を返す。
--   差分が 0 件（返却行なし）であればテスト合格（PASS）となる。
--
-- Usage:
--   dbt test --select assert_fct_daily_order_backlog_dsnp_matches_scd2
-- ==============================================================================

{{ config(store_failures = true) }}

{% if execute %}
  {% set rel_std = load_relation(ref('fct_daily_order_backlog_dsnp')) %}
  {% set rel_scd2 = load_relation(ref('fct_daily_order_backlog_scd2')) %}
  {% if rel_std is not none and rel_scd2 is not none %}
    {% set diff_query %}
      with standard as (
          select * from {{ ref('fct_daily_order_backlog_dsnp') }}
      ),
      scd2 as (
          select * from {{ ref('fct_daily_order_backlog_scd2') }}
      ),
      diff as (
          select
              coalesce(a.order_id, b.order_id) as order_id,
              coalesce(a.partition_date, b.partition_date) as partition_date,
              coalesce(a.status, b.status) as status,
              case
                  when a.order_id is null then 'ONLY_IN_SCD2'
                  when b.order_id is null then 'ONLY_IN_STANDARD'
                  else 'VALUE_MISMATCH'
              end as diff_type,
              a.customer_first_name as std_customer_first_name,
              b.customer_first_name as scd2_customer_first_name,
              a.shop_name as std_shop_name,
              b.shop_name as scd2_shop_name
          from standard as a
          full outer join scd2 as b
              on a.order_id = b.order_id
             and a.status = b.status
             and a.partition_date = b.partition_date
          where
              a.order_id is null
              or b.order_id is null
              or a.customer_id is distinct from b.customer_id
              or a.shop_id is distinct from b.shop_id
              or a.amount is distinct from b.amount
              or a.status is distinct from b.status
              or a.ordered_at is distinct from b.ordered_at
              or a.customer_first_name is distinct from b.customer_first_name
              or a.customer_last_name is distinct from b.customer_last_name
              or a.customer_email is distinct from b.customer_email
              or a.shop_name is distinct from b.shop_name
              or a.shop_location is distinct from b.shop_location
      )
      select * from diff
    {% endset %}
    {% set failure_rows = run_query(diff_query) %}
    {% if failure_rows and failure_rows.rows | length > 0 %}
      {{ print("================================================================================") }}
      {{ print("[ERROR] 【テスト不一致エラー】assert_fct_daily_order_backlog_dsnp_matches_scd2: " ~ failure_rows.rows | length ~ " 件の不一致レコードを検出しました") }}
      {% for row in failure_rows.rows %}
        {{ print("  [ERROR RECORD] order_id=" ~ row['order_id'] ~ ", partition_date=" ~ row['partition_date'] ~ ", status=" ~ row['status'] ~ ", diff_type=" ~ row['diff_type'] ~ " (std_customer=" ~ row['std_customer_first_name'] ~ " vs scd2_customer=" ~ row['scd2_customer_first_name'] ~ ")") }}
      {% endfor %}
      {{ print("================================================================================") }}
      {{ exceptions.warn("assert_fct_daily_order_backlog_dsnp_matches_scd2: " ~ failure_rows.rows | length ~ " mismatched row(s) detected") }}
    {% endif %}
  {% endif %}
{% endif %}

with standard as (
    select
        order_id,
        customer_id,
        shop_id,
        amount,
        status,
        ordered_at,
        customer_first_name,
        customer_last_name,
        customer_email,
        shop_name,
        shop_location,
        partition_date
    from {{ ref('fct_daily_order_backlog_dsnp') }}
),

scd2 as (
    select
        order_id,
        customer_id,
        shop_id,
        amount,
        status,
        ordered_at,
        customer_first_name,
        customer_last_name,
        customer_email,
        shop_name,
        shop_location,
        partition_date
    from {{ ref('fct_daily_order_backlog_scd2') }}
),

diff as (
    select
        coalesce(a.order_id, b.order_id) as order_id,
        coalesce(a.partition_date, b.partition_date) as partition_date,
        case
            when a.order_id is null then 'ONLY_IN_SCD2'
            when b.order_id is null then 'ONLY_IN_STANDARD'
            else 'VALUE_MISMATCH'
        end as diff_type,
        a.customer_first_name as std_customer_first_name,
        b.customer_first_name as scd2_customer_first_name,
        a.shop_name as std_shop_name,
        b.shop_name as scd2_shop_name
    from standard as a
    full outer join scd2 as b
        on a.order_id = b.order_id
       and a.status = b.status
       and a.partition_date = b.partition_date
    where
        a.order_id is null
        or b.order_id is null
        or a.customer_id is distinct from b.customer_id
        or a.shop_id is distinct from b.shop_id
        or a.amount is distinct from b.amount
        or a.status is distinct from b.status
        or a.ordered_at is distinct from b.ordered_at
        or a.customer_first_name is distinct from b.customer_first_name
        or a.customer_last_name is distinct from b.customer_last_name
        or a.customer_email is distinct from b.customer_email
        or a.shop_name is distinct from b.shop_name
        or a.shop_location is distinct from b.shop_location
)

select *
from diff
