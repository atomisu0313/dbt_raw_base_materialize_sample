select * from base.base_daily_order_dsnp
order by partition_date asc, order_id asc, status asc;

