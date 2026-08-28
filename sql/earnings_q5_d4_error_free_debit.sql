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
tds_overflow as (
    -- When the wallet cannot cover the TDS due, the settlement service withholds what it can
    -- and books the remainder as a TDS_OVERFLOW liability (drawn down later by
    -- LIABILITY_AUTO_ADJUST). Since 19-Aug-2026 a TOTAL overflow writes no wallet row at all
    -- and leaves wallet_ledger_entry_ref NULL. Verified 1 row per csp per day.
    select csp_id, date(convert_timezone('Asia/Kolkata',created_at)) ovf_date, sum(amount) ovf_paise
    from csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries
    where _fivetran_active and entry_type='TDS_OVERFLOW'
    group by csp_id, date(convert_timezone('Asia/Kolkata',created_at))),
tax_events as (
    select b.batch_date::date due_date,
           -- FIXED: correct when withheld + overflow = the batch total.
           iff(coalesce(abs(w.amount),0)+coalesce(o.ovf_paise,0)=b.aggregate_tds_paise,1,0) is_correct
    from csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
    join csp_account c on c.csp_id=b.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
      on w.id=b.wallet_ledger_entry_ref and w._fivetran_active and w.entry_type='TAX_WITHHELD'
    left join tds_overflow o on o.csp_id=b.csp_id and o.ovf_date=b.batch_date::date
    where b._fivetran_active and b.aggregate_tds_paise>0),
/* ---- WITHDRAWAL (RazorpayX-correlated) ---- */
-- FIX 3: join csp_account to exclude test accounts from withdrawal denominator
led as (
    select w.reference_id withdrawal_id, w.csp_id, w.payout_id orig_payout,
           w.created_at debit_ts,
           date(convert_timezone('Asia/Kolkata',w.created_at)) debit_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='WITHDRAWAL_DEBIT'
      and date(convert_timezone('Asia/Kolkata',w.created_at))
          between (select dateadd('month',-3,current_month_start) from anchors)
              and (select dateadd('day',-1,as_of_date) from anchors)),
wd_wallet as (
    select reference_id withdrawal_id, round(sum(amount)/100,0) wallet_net_rs,
           sum(iff(reason_code='WITHDRAWAL_REVERSAL',1,0)) reversal_cnt,
           max(iff(reason_code='WITHDRAWAL_REVERSAL',created_at,null)) reversal_ts
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries
    where _fivetran_active and reference_id in (select withdrawal_id from led) group by 1),
-- FIX 2: status-precedence ranking — terminal states always outrank non-terminal
wd_rzp as (
    select source_id,
           max_by(status,
               case status when 'processed' then 5 when 'reversed' then 5 when 'failed' then 5
                           when 'processing' then 2 when 'initiated' then 1 when 'queued' then 0
                           else 3 end * 1e13 + date_part('epoch_second',_created)) status,
           max_by(utr,
               case status when 'processed' then 5 when 'reversed' then 5 when 'failed' then 5
                           when 'processing' then 2 when 'initiated' then 1 when 'queued' then 0
                           else 3 end * 1e13 + date_part('epoch_second',_created)) utr,
           max(iff(status='processed',_created,null)) processed_ts
    from prod_db.public.razorpayx where source_id is not null group by 1),
-- FIX 1: retry lookup via razorpayx synthetic reference_ids, not payout_retry_log
rzp_by_ref as (
    select reference_id,
           max_by(status,
               case status when 'processed' then 5 when 'reversed' then 5 when 'failed' then 5
                           when 'processing' then 2 when 'initiated' then 1 when 'queued' then 0
                           else 3 end * 1e13 + date_part('epoch_second',_created)) status,
           max(utr) utr
    from prod_db.public.razorpayx where reference_id is not null group by 1),
wd_retry_resolved as (
    select l.withdrawal_id,
           coalesce(
               iff(r1.status='processed', r1.utr, null),
               iff(r2.status='processed', r2.utr, null),
               iff(r3.status='processed', r3.utr, null)
           ) retry_utr,
           coalesce(r3.status, r2.status, r1.status) latest_retry_status
    from led l
    left join rzp_by_ref r1 on r1.reference_id='wd_'||replace(l.withdrawal_id,'-','')||'r1'
    left join rzp_by_ref r2 on r2.reference_id='wd_'||replace(l.withdrawal_id,'-','')||'r2'
    left join rzp_by_ref r3 on r3.reference_id='wd_'||replace(l.withdrawal_id,'-','')||'r3'),
wd_disp as (
    select l.debit_date,
           case
             -- FIX 5: payout request was never created in razorpayx
             when l.orig_payout is null and r.retry_utr is null
                                                              then 'NO_PAYOUT_CREATED'
             when coalesce(r.retry_utr, iff(xo.status='processed',xo.utr,null)) is not null
                  and w.wallet_net_rs<0                       then 'OK_PAID'
             -- FIX 4: in-flight based on razorpayx status, not payout_retry_log row
             when r.retry_utr is null
                  and xo.status in ('processing','initiated','queued')
                  and w.reversal_cnt=0                        then 'INFLIGHT_NEFT'
             when w.wallet_net_rs=0 and w.reversal_cnt>=1     then 'OK_REVERSED_not_paid'
             when w.wallet_net_rs>=0 and coalesce(r.retry_utr,xo.utr) is not null
                                                              then 'ANOMALY_LEAK'
             else 'REVIEW' end disp
    from led l
    join wd_wallet w on w.withdrawal_id=l.withdrawal_id
    left join wd_retry_resolved r on r.withdrawal_id=l.withdrawal_id
    left join wd_rzp xo on xo.source_id=l.orig_payout),
withdrawal_events as (
    select debit_date due_date, iff(disp in ('OK_PAID','OK_REVERSED_not_paid'),1,0) is_correct
    from wd_disp where disp<>'INFLIGHT_NEFT'),
netbox_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(d.correlation_id is not null and abs(w.amount)=d.amount,1,0)) is_correct
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.deposit_ledger_entries d
      on d.correlation_id=w.correlation_id and d._fivetran_active and d.entry_type='SECURITY_FROM_WALLET'
    where w._fivetran_active and w.entry_type='NETBOX_SECURITY_DEDUCTION'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),
liability_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(l.correlation_id is not null and abs(w.amount)=l.amount,1,0)) is_correct
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l
      on l.correlation_id=w.correlation_id and l._fivetran_active and l.entry_type='LIABILITY_AUTO_ADJUST'
    where w._fivetran_active and w.entry_type='LIABILITY_AUTO_ADJUST'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),
all_events as (
    select due_date,is_correct from tax_events
    union all select due_date,is_correct from withdrawal_events
    union all select due_date,is_correct from netbox_events
    union all select due_date,is_correct from liability_events),
period_rates as (
    select p.period_name, round(100.0*sum(e.is_correct)/nullif(count(e.due_date),0),2) rate_pct
    from periods p left join all_events e on e.due_date between p.start_date and p.end_date
    group by p.period_name)
select 'D4 — Error-Free Debit Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
