{%- macro cleansing_master_diff_data(
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
),

-- 2. lag の前で先回りフィルタ（effective_at <= target_date）し、ended_at（次回更新日時）を追加
get_raw_table as (
    select
        *,
        lag(
            {{ effective_at }},
            1,
            '9999-12-31 23:59:59'::timestamp
        ) over (
            partition by
                {{ pk_col | join(", ") }}
            order by {{ effective_at }} desc
        ) as ended_at
    from {{ input }}
    where cast({{ effective_at }} as date) <= {{ target_date_expr }}
),

-- 3. クロスジョインの前に先回りフィルタ（ended_at > 窓開始日）
filtered_raw_table as (
    select *
    from get_raw_table
    {%- if is_incremental() %}
    where
        cast(ended_at as date) > date_add(
            {{ target_date_expr }},
            -{{ reset_days }} * interval '1' day
        )
    {%- endif %}
),

-- 4. 断面を作成したい日付リストを生成（基準日 target_date から過去へ）
get_all_date_prep as (
    select
        cast (
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

-- 5. 履歴データと日付リストをクロスジョインして全組み合わせを作成
get_all_data as (
    select
        frt.*,
        gadp.partition_date
    from filtered_raw_table as frt cross join get_all_date_prep as gadp
),

-- 6. 各日付の時点で有効（ACTIVE）だったレコードのみを抽出
{{ output }} as (
    select * exclude (ended_at)
    from get_all_data
    where
        cast({{ effective_at }} as date) <= partition_date
        and cast(ended_at as date) > partition_date
),

{%- endmacro -%}
