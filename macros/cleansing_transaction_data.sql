{%- macro cleansing_transaction_diff_data(
    input,
    output,
    pk_col=none,
    updated_at=none,
    created_at=none,
    loaded_at=none,
    expiration_day=none
) -%}

{# meta から未指定引数をフォールバック解決 #}
{%- set meta = model.get('meta') or model.get('config', {}).get('meta') or config.get('meta', {}) or {} -%}
{%- set pk_col = pk_col or meta.get('pk_col') -%}
{%- set updated_at = updated_at or meta.get('updated_at') -%}
{%- set created_at = created_at or meta.get('created_at') -%}
{%- set loaded_at = loaded_at or meta.get('loaded_at') -%}
{%- set reset_days = expiration_day or meta.get('expiration_day') or var('expiration_day', var('reset_date', 14)) -%}

{# 1. 優先度順に存在するカラムを coalesce する式を生成（業務更新日 updated_at > 作成日 created_at > 取込日 loaded_at） #}
{%- set date_cols = [] -%}
{%- if updated_at %}{% do date_cols.append(updated_at) %}{% endif -%}
{%- if created_at %}{% do date_cols.append(created_at) %}{% endif -%}
{%- if loaded_at %}{% do date_cols.append(loaded_at) %}{% endif -%}
{%- set effective_at = "coalesce(" ~ (date_cols | join(", ")) ~ ")" if date_cols else "current_timestamp" -%}

{# 基準日: execution_date は必須パラメータ（明示指定されない場合はエラー） #}
{%- set raw_execution_date = var("execution_date", none) -%}
{%- if not raw_execution_date -%}
    {{ exceptions.raise_compiler_error(
        "Variable 'execution_date' is required for model '" ~ model.name ~ "'. " ~
        "Please provide it explicitly via CLI, e.g.: dbt run --vars '{\"execution_date\": \"YYYY-MM-DD\"}'"
    ) }}
{%- endif -%}
{%- if raw_execution_date == "current_date()" or raw_execution_date == "current_timestamp()" -%}
    {%- set target_date_expr = raw_execution_date ~ "::date" -%}
{%- else -%}
    {%- set target_date_expr = "'" ~ raw_execution_date ~ "'::date" -%}
{%- endif -%}

{{
    config(
        materialized="incremental",
        unique_key=pk_col
    )
}}

-- PKごとに最新レコード（真の有効日時 effective_at が最新のレコード）をランク付け
ranked_records as (
    select
        *,
        row_number() over (
            partition by
                {{ pk_col | join(", ") }}
            order by
                {{ effective_at }} desc
                {%- if loaded_at and loaded_at not in [updated_at, created_at] %},
                coalesce({{ loaded_at }}, '1970-01-01 00:00:00'::timestamp) desc
                {%- endif %}
        ) as _row_num
    from {{ input }}
    where cast({{ effective_at }} as date) <= {{ target_date_expr }}
    {%- if is_incremental() %}
      and cast({{ effective_at }} as date) > date_add(
            {{ target_date_expr }},
            -{{ reset_days }} * interval '1' day
        )
    {%- endif %}
),

-- 最新の1件のみを抽出
{{ output }} as (
    select
        * exclude (_row_num),
        cast({{ effective_at }} as date) as partition_date
    from ranked_records
    where _row_num = 1
),

{%- endmacro -%}
