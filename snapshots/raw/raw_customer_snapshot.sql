{% snapshot raw_customer_snapshot %}

select * from {{ ref('raw_customer') }}

{% endsnapshot %}
