-- I4 — Transaction Notification Delivery
-- Match wallet events to CleverTap events.
-- BASE_PAYOUT matched by reference_id, RECOVERY_RETURN matched by csp+device+connection.
-- Rate = notified / total txns per period.

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

-- BASE_PAYOUT wallet events
base_payout_wallet as (
    select w.id as wal_id, w.csp_id, w.reference_id,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as txn_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='BASE_PAYOUT'),

-- CleverTap: compensation_recharge_credit_issued (for BASE_PAYOUT, matched by reference_id in event props)
ct_recharge as (
    select distinct
        event_props:reference_id::string as ct_reference_id
    from prod_db.clevertap_csp_api.events_data
    where event_name='compensation_recharge_credit_issued'),

base_payout_notif as (
    select bp.txn_date,
           iff(ct.ct_reference_id is not null,1,0) as is_notified
    from base_payout_wallet bp
    left join ct_recharge ct on ct.ct_reference_id=bp.reference_id),

-- RECOVERY_RETURN wallet events
recovery_wallet as (
    select w.id as wal_id, w.csp_id,
           w.remarks:device_id::string as device_id,
           w.remarks:connection_id::string as connection_id,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as txn_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active and w.entry_type='RECOVERY_RETURN'),

-- CleverTap: compensation_pickup_credit_issued (for RECOVERY, matched by csp+device+connection)
ct_pickup as (
    select distinct
        event_props:csp_id::string as ct_csp_id,
        event_props:device_id::string as ct_device_id,
        event_props:connection_id::string as ct_connection_id
    from prod_db.clevertap_csp_api.events_data
    where event_name='compensation_pickup_credit_issued'),

recovery_notif as (
    select rw.txn_date,
           iff(ct.ct_csp_id is not null,1,0) as is_notified
    from recovery_wallet rw
    left join ct_pickup ct
      on ct.ct_csp_id=rw.csp_id and ct.ct_device_id=rw.device_id and ct.ct_connection_id=rw.connection_id),

all_notif_events as (
    select txn_date, is_notified from base_payout_notif
    union all select txn_date, is_notified from recovery_notif),

period_rates as (
    select p.period_name,
           round(100.0*sum(e.is_notified)/nullif(count(e.txn_date),0),2) rate_pct
    from periods p
    left join all_notif_events e on e.txn_date between p.start_date and p.end_date
    group by p.period_name)

select 'I4 — Transaction Notification Delivery' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
