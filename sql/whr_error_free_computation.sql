with params as (select convert_timezone('Asia/Kolkata',current_timestamp())::date as_of_date),
anchors as (select as_of_date, dateadd('day',1-dayofweekiso(as_of_date),as_of_date)::date wk, date_trunc('month',as_of_date)::date mo from params),
periods as (
  select 'D-1' pn,dateadd('day',-1,as_of_date)::date s,dateadd('day',-1,as_of_date)::date e from anchors
  union all select 'D-2',dateadd('day',-2,as_of_date),dateadd('day',-2,as_of_date) from anchors
  union all select 'D-3',dateadd('day',-3,as_of_date),dateadd('day',-3,as_of_date) from anchors
  union all select 'W-1',dateadd('day',-7,wk),dateadd('day',-1,wk) from anchors
  union all select 'W-2',dateadd('day',-14,wk),dateadd('day',-8,wk) from anchors
  union all select 'W-3',dateadd('day',-21,wk),dateadd('day',-15,wk) from anchors
  union all select 'M-1',dateadd('month',-1,mo),dateadd('day',-1,mo) from anchors
  union all select 'M-2',dateadd('month',-2,mo),dateadd('day',-1,dateadd('month',-1,mo)) from anchors
  union all select 'M-3',dateadd('month',-3,mo),dateadd('day',-1,dateadd('month',-2,mo)) from anchors),
csp_account as (select csp_id, partner_id from csp_gateway_service_csp_gateway_service.csp_account
  where _fivetran_active and csp_id not in ('a0a6w1','a0a0b1') and partner_id is not null),

-- 1. TAX_WITHHELD: due=settlement batch; ok=INV-05 amount & posted within cycle (wallet_date <= batch_date)
tax_events as (select b.batch_date::date due_date,
    iff(w.id is not null and abs(w.amount)=b.aggregate_tds_paise and date(convert_timezone('Asia/Kolkata',w.created_at))<=b.batch_date::date,1,0) is_ok
  from csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
  join csp_account c on c.csp_id=b.csp_id
  left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w on w.id=b.wallet_ledger_entry_ref and w._fivetran_active and w.entry_type='TAX_WITHHELD'
  where b._fivetran_active and b.aggregate_tds_paise>0),

-- 2. INTERVENTION_CREDIT: comp entitlement -> wallet on correlation_id, amount, same day
intv_events as (select date(convert_timezone('Asia/Kolkata',e.created_at)) due_date,
    max(iff(w.correlation_id is not null and w.amount=e.amount and date(convert_timezone('Asia/Kolkata',w.created_at))=date(convert_timezone('Asia/Kolkata',e.created_at)),1,0)) is_ok
  from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e join csp_account c on c.csp_id=e.csp_id
  left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w on w._fivetran_active and w.entry_type='INTERVENTION_CREDIT' and w.correlation_id=e.correlation_id
  where e._fivetran_active and e.entry_type='INTERVENTION_SUPPORT_CREDIT' group by e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at))),

-- 3. WITHDRAWAL: per UUID; ok = paid (net<0, incl NEFT retry) or refunded whole, settled <=24h
wd_agg as (select reference_id, min(csp_id) csp_id, sum(iff(entry_type='WITHDRAWAL',1,0)) rev, sum(amount) net,
    min(iff(entry_type='WITHDRAWAL_DEBIT',created_at,null)) deb_ts, max(iff(entry_type='WITHDRAWAL',created_at,null)) rev_ts, max(created_at) last_ts
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries
  where _fivetran_active and entry_type in ('WITHDRAWAL_DEBIT','WITHDRAWAL') and reference_id is not null group by reference_id),
wd_events as (select date(convert_timezone('Asia/Kolkata',a.deb_ts)) due_date,
    iff((net<0 and last_ts<=dateadd('hour',24,deb_ts)) or (net=0 and rev>0 and rev_ts<=dateadd('hour',24,deb_ts)),1,0) is_ok
  from wd_agg a join csp_account c on c.csp_id=a.csp_id where a.deb_ts is not null),

-- 4. RECOVERY_RETURN: due=DeviceRecoveryConfirmed (method + 30d SLA); ok=payout on device+connection
r_entered as (select device_id, conn, max(entered_at) entered_at from (
    select p:device_id::string device_id, p:last_connection_id::string conn, try_to_timestamp_ntz(p:entered_at::string) entered_at
    from (select try_parse_json(payload) p from csp_asset_custody_service_csp_asset_custody_service.outbox_record
          where record_type ilike '%DeviceEnteredCustomerRecovery%' and coalesce(_fivetran_deleted,false)=false)) group by 1,2),
r_due as (select c2.device_id, c2.conn, date(convert_timezone('UTC','Asia/Kolkata',c2.confirmed_at)) due_date
  from (select p:csp_id::string csp_id, p:device_id::string device_id, p:last_connection_id::string conn, p:recovery_method::string method, try_to_timestamp_ntz(p:confirmed_at::string) confirmed_at
        from (select try_parse_json(payload) p from csp_asset_custody_service_csp_asset_custody_service.outbox_record
              where record_type ilike '%DeviceRecoveryConfirmed%' and coalesce(_fivetran_deleted,false)=false)) c2
  join csp_account a on a.csp_id=c2.csp_id left join r_entered e on e.device_id=c2.device_id and e.conn=c2.conn
  where c2.method in ('CSP_PICKUP','CUSTOMER_RETURN') and (e.entered_at is null or c2.confirmed_at<=dateadd('day',30,e.entered_at))),
r_paid as (select distinct w.remarks:device_id::string device_id, w.remarks:connection_id::string conn
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account a on a.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='RECOVERY_RETURN'),
rec_events as (select d.due_date, iff(p.device_id is not null,1,0) is_ok from r_due d left join r_paid p on p.device_id=d.device_id and p.conn=d.conn),

-- 5. NETBOX_SECURITY_DEDUCTION: wallet <-> deposit SECURITY_FROM_WALLET (correlation_id, amount, same day)
nb_events as (select date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
    max(iff(d.correlation_id is not null and abs(w.amount)=d.amount and date(convert_timezone('Asia/Kolkata',d.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_ok
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  left join csp_payment_settlement_service_csp_payment_settlement_service.deposit_ledger_entries d on d.correlation_id=w.correlation_id and d._fivetran_active and d.entry_type='SECURITY_FROM_WALLET'
  where w._fivetran_active and w.entry_type='NETBOX_SECURITY_DEDUCTION' group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),

-- 6. LIABILITY_AUTO_ADJUST: wallet <-> liability_ledger (correlation_id, amount, same day)
liab_events as (select date(convert_timezone('Asia/Kolkata',w.created_at)) due_date,
    max(iff(l.correlation_id is not null and abs(w.amount)=l.amount and date(convert_timezone('Asia/Kolkata',l.created_at))=date(convert_timezone('Asia/Kolkata',w.created_at)),1,0)) is_ok
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  left join csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l on l.correlation_id=w.correlation_id and l._fivetran_active and l.entry_type='LIABILITY_AUTO_ADJUST'
  where w._fivetran_active and w.entry_type='LIABILITY_AUTO_ADJUST' group by w.id, date(convert_timezone('Asia/Kolkata',w.created_at))),

-- 7. BASE_PAYOUT: OK = disbursed wallet rows on WALLET DATE; MISS = walk stage 4 & 5 (gate/comp but not disbursed) on obligation date
bp_ok as (select date(convert_timezone('Asia/Kolkata',w.created_at)) due_date, iff(abs(w.amount)=30000,1,0) is_ok
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='BASE_PAYOUT'),
bp_gaterefs as (select distinct recharge_reference_id r from csp_rv_service_csp_rv_service.recharge_gates where _fivetran_active),
bp_comprefs as (select distinct recharge_event_ref r from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
  where _fivetran_active and entry_type='BASE_PAYOUT_CREDIT' and credit_type='CONNECTION_ENTITLEMENT'),
bp_miss as (select date(convert_timezone('Asia/Kolkata',coalesce(ec.obligation_window_end,ec.created_at))) due_date, 0 is_ok
  from csp_tas_service_csp_tas_service.recharge_execution_candidates ec join csp_account c on c.csp_id=ec.csp_id
  where ec._fivetran_active and ec.commission_status<>'DISBURSED'
    and (ec.execution_candidate_id in (select r from bp_gaterefs) or ec.execution_candidate_id in (select r from bp_comprefs))),
bp_events as (select * from bp_ok union all select * from bp_miss),

-- 8. BONUS_CREDIT: ok if reconciled to comp | Dynamo single | Dynamo work+device clubbed | analyst manual seed
bonus_wal as (select w.id, w.csp_id, c.partner_id, w.amount, w.line_item_description lid, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='BONUS_CREDIT'),
bcmp as (select distinct csp_id, amount from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries where _fivetran_active and entry_type='BONUS_CREDIT'),
bds as (select distinct account_id, round(amount,2) rs from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE','RATING_INCENTIVE')),
bdc as (select account_id, round(sum(amount),2) rs from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE') group by account_id, date(convert_timezone('Asia/Kolkata',created))),
bonus_events as (select w.due_date,
    max(iff(c.csp_id is not null or ds.account_id is not null or dc.account_id is not null or w.lid ilike '%Rating bonus%May 2026%',1,0)) is_ok
  from bonus_wal w left join bcmp c on c.csp_id=w.csp_id and c.amount=w.amount
  left join bds ds on ds.account_id=w.partner_id and ds.rs=round(w.amount/100,2)
  left join bdc dc on dc.account_id=w.partner_id and dc.rs=round(w.amount/100,2) group by w.id, w.due_date),

all_events as (select * from tax_events union all select * from intv_events union all select * from wd_events
  union all select * from rec_events union all select * from nb_events union all select * from liab_events
  union all select * from bp_events union all select * from bonus_events),
pr as (select p.pn, round(100.0*sum(e.is_ok)/nullif(count(e.due_date),0),2) rate
  from periods p left join all_events e on e.due_date between p.s and p.e group by p.pn)
select 'On-Time, Error-Free Transaction Rate' metric,
  max(iff(pn='D-1',rate,null)) "D-1", max(iff(pn='D-2',rate,null)) "D-2", max(iff(pn='D-3',rate,null)) "D-3",
  max(iff(pn='W-1',rate,null)) "W-1", max(iff(pn='W-2',rate,null)) "W-2", max(iff(pn='W-3',rate,null)) "W-3",
  max(iff(pn='M-1',rate,null)) "M-1", max(iff(pn='M-2',rate,null)) "M-2", max(iff(pn='M-3',rate,null)) "M-3"
from pr;
