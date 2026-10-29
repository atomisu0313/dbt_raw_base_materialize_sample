with 
customers as (
    select * from "snapshot_2510"."raw"."raw_customer_snapshot"
),

-- 元のデータにpartition_dateを追加
get_raw_table as (
    select
        *,
    CAST(dbt_updated_at AS date) as partition_date
    from customers
),

-- 最新のデータを取得し、partition_dateを最も新しい日付に更新する
get_raw_table_latest as (
    select
        * exclude (
            partition_date
        ),
        current_date() as partition_date
    from get_raw_table
    qualify rank() over (partition by id order by updated_at desc) = 1
),

-- 最新のデータと今のデータを結合する (重複する場合があるため、unionで結合する)
-- idとpartition_dateで一意キーにならない場合があるので注意する
get_raw_table_with_latest as (
    select * from get_raw_table
        union
    select * from get_raw_table_latest
),

-- レコードに歯抜け情報を付加し、複製する必要のあるレコードとその数のみを取得する
skipped_dates as (
    select 
        *,
        lag(partition_date) over (partition by id order by partition_date desc, updated_at desc) as next_day,
        next_day - partition_date - 1 as not_enough
    from
        get_raw_table_with_latest
    qualify
        coalesce(not_enough, 0) > 0
),

-- 過去の歯抜けデータを作成する
skipped_data as (
    select 
        skipped_dates.* exclude (partition_date, not_enough, next_day),
        date_add(partition_date, i * INTERVAL '1' DAY) as partition_date
    from 
        skipped_dates, generate_series(1, skipped_dates.not_enough) AS s(i)
),

-- 最新のデータ、未来分のデータ、過去の歯抜けデータを結合する
final_data as (
    select * from get_raw_table_with_latest
        union all
    select * from skipped_data
)

select * exclude(dbt_scd_id) from final_data
order by id asc, partition_date desc;