-- I2 — Settlement-Rails Success Rate
-- One row per withdrawal_id (from WITHDRAWAL_DEBIT wallet entries).
-- Check if it appears in payout_retry_log — if not, first_ok=1.
-- Rate = first_ok / total attempts per period.

with params as (select convert_timezone('Asia/Kolkata',current_timestamp())::date as_of_date),
anchors as (
    select as_of_date,dateadd('day',1-dayofweekiso(as_of_date),as_of_date)::date current_week_monday,
           date_trunc('month',as_of_date)::date current_month_start from params),
periods as (
    select 'D-1' period_name,dateadd('day',-1,as_of_date)::date start_date,dateadd('day',-1,as_of_date)::date end_date from anchors
    union all select 'D-2',dateadd('day',-2,as_of_date),dateadd('day',-2,as_of_date) from anchors
    union all select 'D-3',dateadd('day',-3,as_of_date),dateadd('day',-3,as_of_date) from anchors
    union all select 'W-1',dateadd('day',-7,current_week_monday),dateadd('day',-1,current_week_monday) from anchors
    union all select 'W-2',dateadd('day',-14,current_week_monday),dateadd('day',-8,current_week_monday) from anchors
    union all select 'W-3',dateadd('day',-21,current_week_monday),dateadd('day',-15,current_week_monday) from anchors
    union all select 'M-1',dateadd('month',-1,current_month_start),dateadd('day',-1,current_month_start) from anchors
    union all select 'M-2',dateadd('month',-2,current_month_start),dateadd('day',-1,dateadd('month',-1,current_month_start)) from anchors
    union all select 'M-3',dateadd('month',-3,current_month_start),dateadd('day',-1,dateadd('month',-2,current_month_start)) from anchors),
csp_account as (
    select csp_id, partner_id from csp_gateway_service_csp_gateway_service.csp_account
    where _fivetran_active and csp_id not in ('a0a6w1','a0a0b1') and partner_id is not null),

-- all withdrawal debits
withdrawals as (
    select w.reference_id as withdrawal_id,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as debit_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='WITHDRAWAL_DEBIT'),

-- check if withdrawal needed retry
retry_log as (
    select distinct withdrawal_id
    from csp_payment_settlement_service_csp_payment_settlement_service.payout_retry_log
    where not _fivetran_deleted),

withdrawal_events as (
    select wd.debit_date,
           iff(r.withdrawal_id is null, 1, 0) as first_ok
    from withdrawals wd
    left join retry_log r on r.withdrawal_id=wd.withdrawal_id),

period_rates as (
    select p.period_name,
           round(100.0*sum(e.first_ok)/nullif(count(e.debit_date),0),2) rate_pct
    from periods p
    left join withdrawal_events e on e.debit_date between p.start_date and p.end_date
    group by p.period_name)

select 'I2 — Settlement-Rails Success Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
