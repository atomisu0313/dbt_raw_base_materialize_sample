with customers as (
    select * from {{ ref('raw_customer_snapshot') }}
),


{{
    cleansing_master_diff_data_from_snapshot(
    input = "customers",
    output = "cleaned_latest",
    loaded_at = "dbt_updated_at",
    pk_col = ["id"]
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
