-- D3 — Timely Debit Rate
-- Debits only (tax, withdrawal, netbox, liability). Checks is_timely.

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

-- tax: wallet entry exists and date <= batch_date
tax_events as (
    select b.batch_date::date due_date,
           iff(w.id is not null and date(convert_timezone('Asia/Kolkata',w.created_at))<=b.batch_date::date,1,0) is_timely
    from csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
    join csp_account c on c.csp_id=b.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
      on w.id=b.wallet_ledger_entry_ref and w._fivetran_active and w.entry_type='TAX_WITHHELD'
    where b._fivetran_active and b.aggregate_tds_paise>0),

-- withdrawal: RazorpayX disposition OK_PAID or OK_REVERSED, settled within 24h of debit; exclude INFLIGHT_NEFT
led as (
    select reference_id withdrawal_id, csp_id, payout_id orig_payout, created_at debit_ts,
           date(convert_timezone('Asia/Kolkata',created_at)) debit_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries
    where _fivetran_active and entry_type='WITHDRAWAL_DEBIT'
      and date(convert_timezone('Asia/Kolkata',created_at))
          between (select dateadd('month',-3,current_month_start) from anchors)
              and (select dateadd('day',-1,as_of_date) from anchors)),
wd_retry as (
    select withdrawal_id, retry_payout_id, retry_status, retry_utr, retry_status_at
    from csp_payment_settlement_service_csp_payment_settlement_service.payout_retry_log where not _fivetran_deleted),
wd_wallet as (
    select reference_id withdrawal_id, round(sum(amount)/100,0) wallet_net_rs,
           sum(iff(reason_code='WITHDRAWAL_REVERSAL',1,0)) reversal_cnt,
           max(iff(reason_code='WITHDRAWAL_REVERSAL',created_at,null)) reversal_ts
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries
    where _fivetran_active and reference_id in (select withdrawal_id from led) group by 1),
wd_rzp as (
    select source_id, max_by(status,_created) status, max_by(utr,_created) utr,
           max(iff(status='processed',_created,null)) processed_ts
    from prod_db.public.razorpayx where source_id is not null group by 1),
wd_disp as (
    select l.debit_ts, l.debit_date,
           coalesce(xr.processed_ts, xo.processed_ts, r.retry_status_at, w.reversal_ts) settled_ts,
           case
             when coalesce(r.retry_utr, iff(xo.status='processed',xo.utr,null)) is not null
                  and w.wallet_net_rs<0                                   then 'OK_PAID'
             when r.retry_utr is null and xo.status<>'processed'
                  and w.reversal_cnt=0 and r.retry_status='processing'    then 'INFLIGHT_NEFT'
             when w.wallet_net_rs=0 and w.reversal_cnt>=1                 then 'OK_REVERSED_not_paid'
             when w.wallet_net_rs>=0 and coalesce(r.retry_utr,xo.utr) is not null then 'ANOMALY_LEAK'
             else 'REVIEW' end disp
    from led l
    join wd_wallet w on w.withdrawal_id=l.withdrawal_id
    left join wd_retry r on r.withdrawal_id=l.withdrawal_id
    left join wd_rzp xo on xo.source_id=l.orig_payout
    left join wd_rzp xr on xr.source_id=r.retry_payout_id),
withdrawal_events as (
    select debit_date due_date,
           iff(disp in ('OK_PAID','OK_REVERSED_not_paid') and settled_ts is not null
               and datediff('hour',debit_ts,settled_ts) between 0 and 24,1,0) is_timely
    from wd_disp where disp<>'INFLIGHT_NEFT'),

-- netbox: deposit_ledger same-day match exists
netbox_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(d.correlation_id is not null
                   and date(convert_timezone('Asia/Kolkata',d.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_timely
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.deposit_ledger_entries d
      on d.correlation_id=w.correlation_id and d._fivetran_active and d.entry_type='SECURITY_FROM_WALLET'
    where w._fivetran_active and w.entry_type='NETBOX_SECURITY_DEDUCTION'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),

-- liability: liability_ledger same-day match exists
liability_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(l.correlation_id is not null
                   and date(convert_timezone('Asia/Kolkata',l.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_timely
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l
      on l.correlation_id=w.correlation_id and l._fivetran_active and l.entry_type='LIABILITY_AUTO_ADJUST'
    where w._fivetran_active and w.entry_type='LIABILITY_AUTO_ADJUST'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),

all_debit_events as (
    select due_date, is_timely from tax_events
    union all select due_date, is_timely from withdrawal_events
    union all select due_date, is_timely from netbox_events
    union all select due_date, is_timely from liability_events),

period_rates as (
    select p.period_name, round(100.0*sum(e.is_timely)/nullif(count(e.due_date),0),2) rate_pct
    from periods p left join all_debit_events e on e.due_date between p.start_date and p.end_date
    group by p.period_name)

select 'D3 — Timely Debit Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
