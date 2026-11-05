with customers as (
    select * from {{ ref('seed_customers') }}
),

{{
    cleansing_data(
        input = "customers",
        output = "cleaned_latest"
    )
}}

-- 最終出力の定義
final as (
    select
        *
    from cleaned_latest
)

select * from final
