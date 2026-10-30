with source_data as (
    select * from {{ ref('raw_orders') }}
),

{{
    cleansing_data(
        input = "source_data",
        output = "cleaned_latest"
    )
}}

final as (
    select
        order_id,
        customer_id,
        shop_id,
        amount,
        status,
        ordered_at,
        updated_at,
        loaded_at
    from cleaned_latest
)

select * from final
