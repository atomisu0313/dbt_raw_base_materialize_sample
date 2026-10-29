{%- macro cleansing_master_diff_data_from_snapshot(input, output, loaded_at, pk_col) -%}

-- 未来分データを作成する日数を計算
get_calc_date as (
    select
        coalesce(current_date()- min(CAST({{ loaded_at }} AS date)), 0)  as date_diff
    from {{ input }}
),

-- dbt_updated_atをベースにended_atを追加
get_raw_table as (
    select
        *,
        lag(
            {{ loaded_at }},
            1,
            '9999-12-31 23:59:59'::TIMESTAMP 
        ) over (
            partition by
                {{ pk_col | join(", ") }}
            order by {{ loaded_at }} desc
        ) as ended_at
    from {{ input }}
),

-- 断面を作成したい日付リストを生成
get_all_date_prep as (
    select
        date_add(
            {{ var("execution_date", "current_date()") }}, 
            (-i) * INTERVAL '1' DAY
        ) as partition_date
    from
        generate_series(0, (select date_diff from get_calc_date)) AS t(i) -- 0からdate_diffまでの連番を生成
),

-- 履歴データと日付リストを元にクロスジョインして全組み合わせを作成
get_all_data as (
    select 
        grt.*,
        gadp.partition_date
    from get_raw_table grt, get_all_date_prep gadp
),

-- 有効なレコードのみを残す
{{ output }} as (
    select *
    from get_all_data
    where
        CAST({{ loaded_at }} AS DATE) <= partition_date
        and CAST(ended_at AS DATE) > partition_date
),

{%- endmacro -%}