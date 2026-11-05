{{
    config(
        materialized = 'table'
    )
}}

with raw_customers as (
    select * from {{ ref('seed_customers') }}
),

-- 同一日に同一顧客の複数回更新がある場合、その日の最新（updated_at が一番新しい）レコードを採用
customers_dedup as (
    select
        id,
        first_name,
        last_name,
        email,
        updated_at,
        row_number() over (
            partition by id, cast(updated_at as date)
            order by updated_at desc
        ) as _rn
    from raw_customers
),

customers_scd2 as (
    select
        id,
        first_name,
        last_name,
        email,
        updated_at,
        cast(updated_at as date) as valid_from_date,
        lead(cast(updated_at as date)) over (
            partition by id
            order by updated_at asc
        ) as valid_to_date,
        cast(updated_at as date) as partition_date
    from customers_dedup
    where _rn = 1
)

select * from customers_scd2
