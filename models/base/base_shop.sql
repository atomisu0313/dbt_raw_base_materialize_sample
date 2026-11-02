with source_data as (
    select * from {{ ref('raw_shops') }}
),

{{
    cleansing_data(
        input = "source_data",
        output = "cleaned_latest"
    )
}}

final as (
    select
        shop_id,
        shop_name,
        location,
        loaded_at,
        partition_date
    from cleaned_latest
)

select * from final
