-- D2 — Error-Free Credit Rate
-- Credits only (intervention, recovery, base_payout, bonus). Checks is_correct (amount match), NOT timeliness.

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

-- intervention: amount match between entitlement and wallet
intervention_events as (
    select e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at)) due_date,
           max(iff(w.correlation_id is not null and w.amount=e.amount,1,0)) is_correct
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e
    join csp_account c on c.csp_id=e.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
      on w._fivetran_active and w.entry_type='INTERVENTION_CREDIT' and w.correlation_id=e.correlation_id
    where e._fivetran_active and e.entry_type='INTERVENTION_SUPPORT_CREDIT'
    group by e.correlation_id, date(convert_timezone('Asia/Kolkata',e.created_at))),

-- recovery: abs(amount) = 5000
recovery_entered as (
    select device_id, connection_id, max(entered_at) entered_at
    from (select p:device_id::string device_id, p:last_connection_id::string connection_id,
                 try_to_timestamp_tz(p:entered_at::string) entered_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceEnteredCustomerRecovery%' and coalesce(_fivetran_deleted,false)=false))
    group by device_id, connection_id),
recovery_due as (
    select distinct x.csp_id, x.device_id, x.connection_id,
           date(convert_timezone('Asia/Kolkata',x.confirmed_at)) due_date
    from (select p:csp_id::string csp_id, p:device_id::string device_id,
                 p:last_connection_id::string connection_id, p:recovery_method::string recovery_method,
                 try_to_timestamp_tz(p:confirmed_at::string) confirmed_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceRecoveryConfirmed%' and coalesce(_fivetran_deleted,false)=false)) x
    join csp_account c on c.csp_id=x.csp_id
    left join recovery_entered e on e.device_id=x.device_id and e.connection_id=x.connection_id
    where x.recovery_method in ('CSP_PICKUP','CUSTOMER_RETURN')
      and (e.entered_at is null or x.confirmed_at<=dateadd('day',30,e.entered_at))),
recovery_wallet as (
    select w.csp_id, w.remarks:device_id::string device_id, w.remarks:connection_id::string connection_id,
           max(iff(abs(w.amount)=5000,1,0)) correct_amount
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='RECOVERY_RETURN'
    group by w.csp_id, w.remarks:device_id::string, w.remarks:connection_id::string),
recovery_events as (
    select d.due_date,
           iff(w.csp_id is not null and w.correct_amount=1,1,0) is_correct
    from recovery_due d
    left join recovery_wallet w on w.csp_id=d.csp_id and w.device_id=d.device_id and w.connection_id=d.connection_id),

-- base_payout: abs(amount) = 30000
base_payout_events as (
    select date(convert_timezone('Asia/Kolkata',w.created_at)) due_date, iff(abs(w.amount)=30000,1,0) is_correct
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BASE_PAYOUT'),

-- bonus: matched to comp/dynamo source (amount match only, no date check)
bonus_wallet as (
    select w.id, w.csp_id, c.partner_id, w.amount, w.line_item_description,
           date(convert_timezone('Asia/Kolkata',w.created_at)) wallet_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BONUS_CREDIT'),
bonus_comp as (
    select csp_id, amount
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
    where _fivetran_active and entry_type='BONUS_CREDIT'),
bonus_dynamo_single as (
    select account_id, round(amount,2) amount_rs
    from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE','RATING_INCENTIVE')),
bonus_dynamo_clubbed as (
    select account_id, round(sum(amount),2) amount_rs
    from DYNAMODB.T_TRANSACTIONS where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE')
    group by account_id),
bonus_events as (
    select w.id, w.wallet_date due_date,
           iff(max(iff(c.csp_id is not null,1,0))=1
               or max(iff(ds.account_id is not null,1,0))=1
               or max(iff(dc.account_id is not null,1,0))=1
               or max(iff(w.line_item_description ilike '%Rating bonus%May 2026%',1,0))=1,1,0) is_correct
    from bonus_wallet w
    left join bonus_comp c on c.csp_id=w.csp_id and c.amount=w.amount
    left join bonus_dynamo_single ds on ds.account_id=w.partner_id and ds.amount_rs=round(w.amount/100,2)
    left join bonus_dynamo_clubbed dc on dc.account_id=w.partner_id and dc.amount_rs=round(w.amount/100,2)
    group by w.id, w.wallet_date),

all_credit_events as (
    select due_date, is_correct from intervention_events
    union all select due_date, is_correct from recovery_events
    union all select due_date, is_correct from base_payout_events
    union all select due_date, is_correct from bonus_events),

period_rates as (
    select p.period_name, round(100.0*sum(e.is_correct)/nullif(count(e.due_date),0),2) rate_pct
    from periods p left join all_credit_events e on e.due_date between p.start_date and p.end_date
    group by p.period_name)

select 'D2 — Error-Free Credit Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
