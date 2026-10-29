
with 
customers as (
    select * from "snapshot_2510"."raw"."raw_customer_snapshot"
),

get_calc_date as (
    select
        coalesce(current_date()- min(CAST(dbt_updated_at AS date)), 0)  as date_diff
    from customers
),

-- 元のデータにended_atを追加
get_raw_table as (
    select
        *,
        lag(
            dbt_updated_at,
            1,
            -- Snowflakeの'to_timestamp_ntz'をDuckDBのCASTに変換
            '9999-12-31 23:59:59'::TIMESTAMP 
        ) over (
            partition by
                id
            order by dbt_updated_at desc
        ) as ended_at
    from "snapshot_2510"."raw"."raw_customer_snapshot"
),

-- 断面を作成したい日付リストを生成
get_all_date_prep as (
    select
        date_add(
            '2025-10-19'::DATE, 
            (-i) * INTERVAL '1' DAY
        ) as partition_date
    from
        generate_series(0, (select date_diff from get_calc_date)) AS t(i) -- 0から6までの7つの連番を生成
),

-- 履歴データと日付リストを元にクロスジョインして全組み合わせを作成
get_all_data as (
    select 
        grt.*,
        gadp.partition_date
    from get_raw_table grt, get_all_date_prep gadp
),

-- 各日付の時点で有効だったレコードだけをフィルタリング
final as (
    select *
    from get_all_data
    where
        CAST(dbt_updated_at AS DATE) <= partition_date
        and CAST(ended_at AS DATE) > partition_date
)

select * from final
order by id asc, partition_date desc;
;