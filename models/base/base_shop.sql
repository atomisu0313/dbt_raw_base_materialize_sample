with source_data as (
    select * from {{ ref('seed_shops') }}
),

{{
    cleansing_data(
        input = "source_data",
        output = "cleaned_latest"
    )
}}

final as (
    select
        *
    from cleaned_latest
)

select * from final
