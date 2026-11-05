select * from marts.fct_daily_order_backlog_scd2
order by partition_date asc, order_id asc, status asc;

