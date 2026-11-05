select * from marts.fct_daily_order_backlog_dsnp
order by partition_date asc, order_id asc, status asc;

