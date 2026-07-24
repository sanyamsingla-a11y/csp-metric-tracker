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
intv_events as (select 'INTERVENTION_CREDIT' event_type, date(convert_timezone('Asia/Kolkata',e.created_at)) due_date,
    max(iff(w.correlation_id is not null and date(convert_timezone('Asia/Kolkata',w.created_at))=date(convert_timezone('Asia/Kolkata',e.created_at)),1,0)) is_timely
  from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e join csp_account c on c.csp_id=e.csp_id
  left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w on w._fivetran_active and w.entry_type='INTERVENTION_CREDIT' and w.correlation_id=e.correlation_id
  where e._fivetran_active and e.entry_type='INTERVENTION_SUPPORT_CREDIT' group by e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at))),
r_entered as (select device_id, conn, max(entered_at) entered_at from (
    select p:device_id::string device_id, p:last_connection_id::string conn, try_to_timestamp_ntz(p:entered_at::string) entered_at
    from (select try_parse_json(payload) p from csp_asset_custody_service_csp_asset_custody_service.outbox_record
          where record_type ilike '%DeviceEnteredCustomerRecovery%' and coalesce(_fivetran_deleted,false)=false)) group by 1,2),
r_due as (select c2.csp_id, c2.device_id, c2.conn, c2.confirmed_at due_ts, date(convert_timezone('UTC','Asia/Kolkata',c2.confirmed_at)) due_date
  from (select p:csp_id::string csp_id, p:device_id::string device_id, p:last_connection_id::string conn, p:recovery_method::string method, try_to_timestamp_ntz(p:confirmed_at::string) confirmed_at
        from (select try_parse_json(payload) p from csp_asset_custody_service_csp_asset_custody_service.outbox_record
              where record_type ilike '%DeviceRecoveryConfirmed%' and coalesce(_fivetran_deleted,false)=false)) c2
  join csp_account a on a.csp_id=c2.csp_id left join r_entered e on e.device_id=c2.device_id and e.conn=c2.conn
  where c2.method in ('CSP_PICKUP','CUSTOMER_RETURN') and (e.entered_at is null or c2.confirmed_at<=dateadd('day',30,e.entered_at))),
r_paid as (select w.csp_id, w.remarks:device_id::string device_id, w.remarks:connection_id::string conn, min(w.created_at) first_ts
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account a on a.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='RECOVERY_RETURN' group by 1,2,3),
rec_events as (select 'RECOVERY_RETURN' event_type, d.due_date,
    iff(p.first_ts is not null and p.first_ts>=d.due_ts and p.first_ts<=dateadd('hour',24,d.due_ts),1,0) is_timely
  from r_due d left join r_paid p on p.csp_id=d.csp_id and p.device_id=d.device_id and p.conn=d.conn),
bp_ok as (select date(convert_timezone('Asia/Kolkata',w.created_at)) due_date, 1 is_timely
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='BASE_PAYOUT'),
bp_gaterefs as (select distinct recharge_reference_id r from csp_rv_service_csp_rv_service.recharge_gates where _fivetran_active),
bp_comprefs as (select distinct recharge_event_ref r from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
  where _fivetran_active and entry_type='BASE_PAYOUT_CREDIT' and credit_type='CONNECTION_ENTITLEMENT'),
bp_miss as (select date(convert_timezone('Asia/Kolkata',coalesce(ec.obligation_window_end,ec.created_at))) due_date, 0 is_timely
  from csp_tas_service_csp_tas_service.recharge_execution_candidates ec join csp_account c on c.csp_id=ec.csp_id
  where ec._fivetran_active and ec.commission_status<>'DISBURSED'
    and (ec.execution_candidate_id in (select r from bp_gaterefs) or ec.execution_candidate_id in (select r from bp_comprefs))),
bp_events as (select 'BASE_PAYOUT' event_type, due_date, is_timely from bp_ok union all select 'BASE_PAYOUT', due_date, is_timely from bp_miss),
bonus_wal as (select w.id, w.csp_id, c.partner_id, w.amount, w.line_item_description lid, date(convert_timezone('Asia/Kolkata',w.created_at)) due_date
  from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w join csp_account c on c.csp_id=w.csp_id
  where w._fivetran_active and w.entry_type='BONUS_CREDIT'),
bcmp as (select csp_id, amount, date(convert_timezone('Asia/Kolkata',created_at)) sd from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries where _fivetran_active and entry_type='BONUS_CREDIT'),
bds as (select account_id, round(amount,2) rs, date(convert_timezone('Asia/Kolkata',created)) sd from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE','RATING_INCENTIVE')),
bdc as (select account_id, date(convert_timezone('Asia/Kolkata',created)) sd, round(sum(amount),2) rs from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE') group by 1,2),
bonus_events as (select 'BONUS_CREDIT' event_type, w.due_date,
    max(iff((c.csp_id is not null and c.sd=w.due_date) or (ds.account_id is not null and ds.sd=w.due_date) or (dc.account_id is not null and dc.sd=w.due_date) or w.lid ilike '%Rating bonus%May 2026%',1,0)) is_timely
  from bonus_wal w left join bcmp c on c.csp_id=w.csp_id and c.amount=w.amount
  left join bds ds on ds.account_id=w.partner_id and ds.rs=round(w.amount/100,2)
  left join bdc dc on dc.account_id=w.partner_id and dc.rs=round(w.amount/100,2) group by w.id, w.due_date),
all_events as (
  select event_type, due_date, is_timely from intv_events
  union all select event_type, due_date, is_timely from rec_events
  union all select event_type, due_date, is_timely from bp_events
  union all select event_type, due_date, is_timely from bonus_events),
pr as (select e.event_type, p.pn, round(100.0*sum(e.is_timely)/nullif(count(e.due_date),0),2) rate
  from periods p left join all_events e on e.due_date between p.s and p.e group by 1,2)
select event_type metric,
  max(iff(pn='D-1',rate,null)) "D-1", max(iff(pn='D-2',rate,null)) "D-2", max(iff(pn='D-3',rate,null)) "D-3",
  max(iff(pn='W-1',rate,null)) "W-1", max(iff(pn='W-2',rate,null)) "W-2", max(iff(pn='W-3',rate,null)) "W-3",
  max(iff(pn='M-1',rate,null)) "M-1", max(iff(pn='M-2',rate,null)) "M-2", max(iff(pn='M-3',rate,null)) "M-3"
from pr group by event_type order by event_type;