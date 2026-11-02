{%- macro cleansing_master_all_data(
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
        pre_hook="""
            {% if is_incremental() %}
                delete from {{ this }}
                where partition_date > date_add(
                    """ ~ target_date_expr ~ """,
                    -""" ~ reset_days ~ """ * interval '1' day
                )
                and partition_date <= """ ~ target_date_expr ~ """
            {% endif %}
        """
    )
}}

-- 1. 最古の有効日から基準日（target_date）までの日数を計算
get_calc_date as (
    select
        min(cast({{ effective_at }} as date)) as min_date,
        coalesce(greatest(0, {{ target_date_expr }} - min(cast({{ effective_at }} as date))), 0) as date_diff
    from {{ input }}
    where cast({{ effective_at }} as date) <= {{ target_date_expr }}
),

-- 2. 断面を作成したい日付リスト（カレンダー）を生成
calendar as (
    select
        cast(
            date_add(
                {{ target_date_expr }},
                (-i) * interval '1' day
            ) as date 
        ) as partition_date
    {%- if is_incremental() %}
    from generate_series(0, {{ reset_days }} - 1) as t(i)
    {%- else %}
    from generate_series(0, (select date_diff from get_calc_date)) as t(i)
    {%- endif %}
),

-- 3. 実際に全量データが届いた配信日リスト（数行〜十数行）
delivery_dates as (
    select distinct cast({{ effective_at }} as date) as delivery_date
    from {{ input }}
    where cast({{ effective_at }} as date) <= {{ target_date_expr }}
),

-- 4. ASOF JOIN で各カレンダー日付時点の最新配信日をマッピング（歯抜け・未配信日・未来日を直前データで補完）
date_mapping as (
    select
        c.partition_date,
        d.delivery_date as source_delivery_date
    from calendar as c
    asof join delivery_dates as d
        on c.partition_date >= d.delivery_date
),

-- 5. 本体データと通常の等結合（cross join を完全排除し、参照すべき配信日と 1:N 結合）
{{ output }} as (
    select
        r.*,
        m.partition_date
    from {{ input }} as r
    inner join date_mapping as m
        on cast({{ effective_at }} as date) = m.source_delivery_date
),

{%- endmacro -%}
