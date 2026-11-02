select * from marts.fct_daily_sales
order by partition_date asc, order_id asc, status asc;

