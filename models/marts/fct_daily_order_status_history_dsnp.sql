{{
    config(
        materialized = 'incremental',
        incremental_strategy = 'microbatch',
        event_time = 'partition_date',
        batch_size = 'day',
        begin = var('begin', var('execution_date', '1900-01-01'))
    )
}}

with orders as (
    select * from {{ ref('base_order_dsnp') }}
),

customers as (
    select * from {{ ref('base_customer_dsnp') }}
),

shops as (
    select * from {{ ref('base_shop') }}
),

final as (
    select
        o.order_id,
        o.customer_id,
        o.shop_id,
        o.amount,
        o.status,
        o.ordered_at,
        o.updated_at,
        c.first_name as customer_first_name,
        c.last_name as customer_last_name,
        c.email as customer_email,
        s.shop_name,
        s.location as shop_location,
        o.partition_date
    from orders as o
    left join customers as c
        on o.customer_id = c.id
    left join shops as s
        on o.shop_id = s.shop_id
)

select * from final
