{{
    config(
        materialized = 'table'
    )
}}

with raw_orders as (
    select * from {{ ref('seed_orders') }}
),

-- 1. 同一注文・同一ステータスの重複イベントを排除（タイブレーク: updated_at desc, loaded_at desc）
orders_dedup as (
    select
        order_id,
        customer_id,
        shop_id,
        amount,
        status,
        ordered_at,
        updated_at,
        loaded_at
    from (
        select
            *,
            row_number() over (
                partition by order_id, status
                order by updated_at desc, loaded_at desc
            ) as _rn
        from raw_orders
    )
    where _rn = 1
),

-- 2. 注文ステータス遷移の SCD Type 2 有効期間および基準日（partition_date）を算出
orders_scd2 as (
    select
        order_id,
        customer_id,
        shop_id,
        amount,
        status,
        ordered_at,
        updated_at,
        loaded_at,
        cast(updated_at as date) as valid_from_date,
        lead(cast(updated_at as date)) over (
            partition by order_id
            order by updated_at asc, loaded_at asc
        ) as valid_to_date,
        cast(updated_at as date) as partition_date
    from orders_dedup
)

select * from orders_scd2

