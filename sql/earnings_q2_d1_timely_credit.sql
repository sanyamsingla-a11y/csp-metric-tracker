with params as (
    select convert_timezone('Asia/Kolkata', current_timestamp())::date as as_of_date),
anchors as (
    select as_of_date,
           dateadd('day',1-dayofweekiso(as_of_date),as_of_date)::date as current_week_monday,
           date_trunc('month',as_of_date)::date as current_month_start from params),
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
    select csp_id, partner_id
    from csp_gateway_service_csp_gateway_service.csp_account
    where _fivetran_active and csp_id not in ('a0a6w1','a0a0b1') and partner_id is not null),
intervention_due as (
    select correlation_id, csp_id, amount, created_at as due_ts,
           date(convert_timezone('Asia/Kolkata',created_at)) as due_date
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
    where _fivetran_active and entry_type='INTERVENTION_SUPPORT_CREDIT'),
intervention_wallet as (
    select correlation_id, amount, created_at as wallet_ts
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries
    where _fivetran_active and entry_type='INTERVENTION_CREDIT'),
intervention_events as (
    select e.correlation_id, e.due_date,
           max(iff(w.correlation_id is not null
                   and date(convert_timezone('Asia/Kolkata',w.wallet_ts))=e.due_date,1,0)) as is_timely
    from intervention_due e
    join csp_account c on c.csp_id=e.csp_id
    left join intervention_wallet w on w.correlation_id=e.correlation_id
    group by e.correlation_id, e.due_date),
recovery_entered as (
    select device_id, connection_id, max(entered_at) as entered_at
    from (select p:device_id::string device_id, p:last_connection_id::string connection_id,
                 try_to_timestamp_tz(p:entered_at::string) entered_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceEnteredCustomerRecovery%'
                  and coalesce(_fivetran_deleted,false)=false))
    group by device_id, connection_id),
recovery_due as (
    select distinct x.csp_id, x.device_id, x.connection_id, x.confirmed_at as due_ts,
           date(convert_timezone('Asia/Kolkata',x.confirmed_at)) as due_date
    from (select p:csp_id::string csp_id, p:device_id::string device_id,
                 p:last_connection_id::string connection_id, p:recovery_method::string recovery_method,
                 try_to_timestamp_tz(p:confirmed_at::string) confirmed_at
          from (select try_parse_json(payload) p
                from csp_asset_custody_service_csp_asset_custody_service.outbox_record
                where record_type ilike '%DeviceRecoveryConfirmed%'
                  and coalesce(_fivetran_deleted,false)=false)) x
    join csp_account c on c.csp_id=x.csp_id
    left join recovery_entered e on e.device_id=x.device_id and e.connection_id=x.connection_id
    where x.recovery_method in ('CSP_PICKUP','CUSTOMER_RETURN')
      and (e.entered_at is null or x.confirmed_at<=dateadd('day',30,e.entered_at))),
recovery_wallet as (
    select w.csp_id, w.remarks:device_id::string device_id, w.remarks:connection_id::string connection_id,
           min(w.created_at) first_wallet_ts
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='RECOVERY_RETURN'
    group by w.csp_id, w.remarks:device_id::string, w.remarks:connection_id::string),
recovery_events as (
    select d.due_date,
           iff(w.first_wallet_ts is not null and w.first_wallet_ts>=d.due_ts
               and w.first_wallet_ts<=dateadd('hour',24,d.due_ts),1,0) as is_timely
    from recovery_due d
    left join recovery_wallet w
      on w.csp_id=d.csp_id and w.device_id=d.device_id and w.connection_id=d.connection_id),
base_payout_events as (
    select date(convert_timezone('Asia/Kolkata',w.created_at)) as due_date, 1 as is_timely
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BASE_PAYOUT'),
bonus_wallet as (
    select w.id, w.csp_id, c.partner_id, w.amount, w.line_item_description,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as wallet_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BONUS_CREDIT'),
bonus_comp as (
    select csp_id, amount, date(convert_timezone('Asia/Kolkata',created_at)) source_date
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries
    where _fivetran_active and entry_type='BONUS_CREDIT'),
bonus_dynamo_single as (
    select account_id, round(amount,2) amount_rs, date(convert_timezone('Asia/Kolkata',created)) source_date
    from DYNAMODB.T_TRANSACTIONS
    where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE','RATING_INCENTIVE')),
bonus_dynamo_clubbed as (
    select account_id, date(convert_timezone('Asia/Kolkata',created)) source_date, round(sum(amount),2) amount_rs
    from DYNAMODB.T_TRANSACTIONS
    where transaction_type in ('WORK_INCENTIVE','DEVICE_INCENTIVE')
    group by account_id, date(convert_timezone('Asia/Kolkata',created))),
bonus_events as (
    select w.id, w.wallet_date as due_date,
           iff(max(iff(c.csp_id is not null and c.source_date=w.wallet_date,1,0))=1
               or max(iff(ds.account_id is not null and ds.source_date=w.wallet_date,1,0))=1
               or max(iff(dc.account_id is not null and dc.source_date=w.wallet_date,1,0))=1
               or max(iff(w.line_item_description ilike '%Rating bonus%May 2026%',1,0))=1,1,0) as is_timely
    from bonus_wallet w
    left join bonus_comp c on c.csp_id=w.csp_id and c.amount=w.amount
    left join bonus_dynamo_single ds on ds.account_id=w.partner_id and ds.amount_rs=round(w.amount/100,2)
    left join bonus_dynamo_clubbed dc on dc.account_id=w.partner_id and dc.amount_rs=round(w.amount/100,2)
    group by w.id, w.wallet_date),
all_events as (
    select due_date,is_timely from intervention_events
    union all select due_date,is_timely from recovery_events
    union all select due_date,is_timely from base_payout_events
    union all select due_date,is_timely from bonus_events),
period_rates as (
    select p.period_name,
           round(100.0*sum(e.is_timely)/nullif(count(e.due_date),0),2) rate_pct
    from periods p left join all_events e on e.due_date between p.start_date and p.end_date
    group by p.period_name)
select 'D1 — Timely Credit Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
