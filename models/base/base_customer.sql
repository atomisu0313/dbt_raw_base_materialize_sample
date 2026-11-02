with customers as (
    select * from {{ ref('raw_customers') }}
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
        id,
        first_name,
        last_name,
        email,
        updated_at,
        partition_date
    from cleaned_latest
)

select * from final
