select * from marts.fct_daily_order_status_history_dsnp
order by partition_date asc, order_id asc, status asc;

