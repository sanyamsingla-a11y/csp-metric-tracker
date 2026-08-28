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
intervention_events as (
    select e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at)) due_date,
           iff(max(iff(w.correlation_id is not null and date(convert_timezone('Asia/Kolkata',w.created_at))=date(convert_timezone('Asia/Kolkata',e.created_at)),1,0))=1
               and max(iff(w.correlation_id is not null and w.amount=e.amount,1,0))=1,1,0) is_good
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e
    join csp_account c on c.csp_id=e.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
      on w._fivetran_active and w.entry_type='INTERVENTION_CREDIT' and w.correlation_id=e.correlation_id
    where e._fivetran_active and e.entry_type='INTERVENTION_SUPPORT_CREDIT'
    group by e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at))),
recovery_entered as (
    select device_id, connection_id, max(entered_at) entered_at
    from (select p:device_id::string device_id, p:last_connection_id::string connection_id,
                 try_to_timestamp_tz(p:entered_at::string) entered_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceEnteredCustomerRecovery%' and coalesce(_fivetran_deleted,false)=false))
    group by device_id, connection_id),
recovery_due as (
    select distinct x.csp_id, x.device_id, x.connection_id, x.confirmed_at due_ts,
           date(convert_timezone('Asia/Kolkata',x.confirmed_at)) due_date
    from (select p:csp_id::string csp_id, p:device_id::string device_id,
                 p:last_connection_id::string connection_id, p:recovery_method::string recovery_method,
                 try_to_timestamp_tz(p:confirmed_at::string) confirmed_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceRecoveryConfirmed%' and coalesce(_fivetran_deleted,false)=false)) x
    join csp_account c on c.csp_id=x.csp_id
    -- FIXED: connection_id is NULL on both sides for some recoveries, and NULL=NULL is
    -- never true, so a strict join silently drops them. device_id stays strict.
    left join recovery_entered e
      on e.device_id=x.device_id and equal_null(e.connection_id, x.connection_id)
    where x.recovery_method in ('CSP_PICKUP','CUSTOMER_RETURN')
      and (e.entered_at is null or x.confirmed_at<=dateadd('day',30,e.entered_at))),
recovery_wallet as (
    select w.csp_id, w.remarks:device_id::string device_id, w.remarks:connection_id::string connection_id,
           min(w.created_at) first_wallet_ts, max(iff(abs(w.amount)=5000,1,0)) correct_amount
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='RECOVERY_RETURN'
    group by w.csp_id, w.remarks:device_id::string, w.remarks:connection_id::string),
recovery_events as (
    select d.due_date,
           iff(w.first_wallet_ts is not null and w.first_wallet_ts>=d.due_ts
               and w.first_wallet_ts<=dateadd('hour',24,d.due_ts) and w.correct_amount=1,1,0) is_good
    from recovery_due d
    -- FIXED: null-safe connection_id (see recovery_due). Two 27-Aug-2026 recoveries were
    -- paid Rs 50 within ~1 second of the due timestamp but scored as never paid.
    left join recovery_wallet w
      on w.csp_id=d.csp_id and w.device_id=d.device_id
     and equal_null(w.connection_id, d.connection_id)),
base_payout_events as (
    -- A base payout is correct when it equals the amount the compensation service
    -- actually entitled -- NOT a hardcoded Rs 300. The Rs 750 tier (live 18-Aug-2026,
    -- 61 CSPs) and Rs 850 tier (25-Aug-2026) are legitimate payouts and every one of
    -- them carries a BASE_PAYOUT_CREDIT entitlement row with an exactly equal amount.
    -- The old `abs(w.amount)=30000` literal flagged all of them as errors, decaying
    -- this metric a little more each day as the new tiers ramped.
    -- Grouped by w.id so a duplicate entitlement row cannot fan out the wallet row.
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(e.correlation_id is not null and abs(w.amount)=abs(e.amount),1,0)) is_good
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e
      on e.correlation_id=w.correlation_id and e._fivetran_active
     and e.entry_type='BASE_PAYOUT_CREDIT'
    where w._fivetran_active and w.entry_type='BASE_PAYOUT'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),
bonus_wallet as (
    select w.id, w.csp_id, c.partner_id, w.amount, w.line_item_description,
           date(convert_timezone('Asia/Kolkata',w.created_at)) wallet_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BONUS_CREDIT'),
bonus_comp as (
    select csp_id, amount, date(convert_timezone('Asia/Kolkata',created_at)) source_date
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
    where _fivetran_active and entry_type='BONUS_CREDIT'),
bonus_dynamo_single as (
    select account_id, round(amount,2) amount_rs, date(convert_timezone('Asia/Kolkata',created)) source_date
    from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE','RATING_INCENTIVE')),
bonus_dynamo_clubbed as (
    select account_id, date(convert_timezone('Asia/Kolkata',created)) source_date, round(sum(amount),2) amount_rs
    from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE')
    group by account_id, date(convert_timezone('Asia/Kolkata',created))),
bonus_events as (
    select w.id, w.wallet_date due_date,
           iff(max(iff(c.csp_id is not null and c.source_date=w.wallet_date,1,0))=1
               or max(iff(ds.account_id is not null and ds.source_date=w.wallet_date,1,0))=1
               or max(iff(dc.account_id is not null and dc.source_date=w.wallet_date,1,0))=1
               or max(iff(w.line_item_description ilike '%Rating bonus%May 2026%',1,0))=1,1,0) is_good
    from bonus_wallet w
    left join bonus_comp c on c.csp_id=w.csp_id and c.amount=w.amount
    left join bonus_dynamo_single ds on ds.account_id=w.partner_id and ds.amount_rs=round(w.amount/100,2)
    left join bonus_dynamo_clubbed dc on dc.account_id=w.partner_id and dc.amount_rs=round(w.amount/100,2)
    group by w.id, w.wallet_date),
tds_overflow as (
    -- When the wallet cannot cover the TDS due, the settlement service withholds what it
    -- can and books the remainder as a TDS_OVERFLOW liability (drawn down later by
    -- LIABILITY_AUTO_ADJUST). Verified 1 row per csp per day, and the batch is 1 row per
    -- csp per batch_date, so csp_id + date is a safe key.
    select csp_id, date(convert_timezone('Asia/Kolkata',created_at)) ovf_date,
           sum(amount) ovf_paise
    from csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries
    where _fivetran_active and entry_type='TDS_OVERFLOW'
    group by csp_id, date(convert_timezone('Asia/Kolkata',created_at))),
tax_events as (
    -- FIXED: TDS is correct when withheld + overflow equals the batch total. The old rule
    -- (abs(w.amount) = aggregate_tds_paise) failed every partial overflow, and after
    -- 19-Aug-2026 every total overflow too (those write no wallet row at all and leave
    -- wallet_ledger_entry_ref NULL) -- an equality the service deliberately never guarantees.
    -- Timeliness is only assertable when a wallet entry exists.
    select b.batch_date::date due_date,
           iff(coalesce(abs(w.amount),0) + coalesce(o.ovf_paise,0) = b.aggregate_tds_paise
               and (w.id is null
                    or date(convert_timezone('Asia/Kolkata',w.created_at))<=b.batch_date::date),1,0) is_good
    from csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
    join csp_account c on c.csp_id=b.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
      on w.id=b.wallet_ledger_entry_ref and w._fivetran_active and w.entry_type='TAX_WITHHELD'
    left join tds_overflow o
      on o.csp_id=b.csp_id and o.ovf_date=b.batch_date::date
    where b._fivetran_active and b.aggregate_tds_paise>0),
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
             else 'REVIEW' end disp,
           -- operative RazorpayX status: the retry's if there was one, else the original.
           coalesce(xr.status, xo.status) eff_status
    from led l
    join wd_wallet w on w.withdrawal_id=l.withdrawal_id
    left join wd_retry r on r.withdrawal_id=l.withdrawal_id
    left join wd_rzp xo on xo.source_id=l.orig_payout
    left join wd_rzp xr on xr.source_id=r.retry_payout_id),
withdrawal_events as (
    -- FIXED: a payout that has not reached a terminal RazorpayX status has not resolved
    -- yet, so it is excluded from the denominator rather than scored as a failure. The old
    -- rule failed every payout sitting at 'processing' (a UTR is often already assigned),
    -- which is a snapshot-maturity artefact, not a settlement failure.
    -- Terminal = processed / failed / reversed. Non-terminal = processing / queued / no
    -- RazorpayX record yet.
    select debit_date due_date,
           iff(disp in ('OK_PAID','OK_REVERSED_not_paid') and settled_ts is not null
               and datediff('hour',debit_ts,settled_ts) between 0 and 24,1,0) is_good
    from wd_disp
    where disp<>'INFLIGHT_NEFT'
      -- Withhold judgment ONLY on payouts genuinely still in flight at the gateway
      -- (RazorpayX status 'processing' or 'queued'). Everything else is scored:
      --   * already OK_PAID / OK_REVERSED  -> stays, scored good, so the exclusion can
      --     never inflate the rate by dropping rows that already succeeded;
      --   * terminal processed/failed/reversed -> scored on its merits;
      --   * NO RazorpayX record at all -> scored BAD. The wallet is debited and a payout_id
      --     is assigned, but nothing exists at the gateway: money has left the CSP's wallet
      --     with no transfer to match it. That is a defect and must be visible, not excluded.
      --     (Observed 3x on 28-Aug-2026; zero on every other August day, against 187 other
      --     hour-23 debits -- so it is not routine end-of-day ingestion lag.)
      and (disp in ('OK_PAID','OK_REVERSED_not_paid')
           or coalesce(eff_status,'NO_GATEWAY_RECORD') not in ('processing','queued'))),
netbox_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(d.correlation_id is not null and abs(w.amount)=d.amount
                   and date(convert_timezone('Asia/Kolkata',d.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_good
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.deposit_ledger_entries d
      on d.correlation_id=w.correlation_id and d._fivetran_active and d.entry_type='SECURITY_FROM_WALLET'
    where w._fivetran_active and w.entry_type='NETBOX_SECURITY_DEDUCTION'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),
liability_events as (
    select w.id, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
           max(iff(l.correlation_id is not null and abs(w.amount)=l.amount
                   and date(convert_timezone('Asia/Kolkata',l.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_good
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l
      on l.correlation_id=w.correlation_id and l._fivetran_active and l.entry_type='LIABILITY_AUTO_ADJUST'
    where w._fivetran_active and w.entry_type='LIABILITY_AUTO_ADJUST'
    group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),
all_events as (
    select due_date,is_good from intervention_events
    union all select due_date,is_good from recovery_events
    union all select due_date,is_good from base_payout_events
    union all select due_date,is_good from bonus_events
    union all select due_date,is_good from tax_events
    union all select due_date,is_good from withdrawal_events
    union all select due_date,is_good from netbox_events
    union all select due_date,is_good from liability_events),
period_rates as (
    select p.period_name, round(100.0*sum(e.is_good)/nullif(count(e.due_date),0),2) rate_pct
    from periods p left join all_events e on e.due_date between p.start_date and p.end_date
    group by p.period_name)
select 'On-Time Accurate Compensation Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
