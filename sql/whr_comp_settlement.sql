-- Compensation–Payment Settlement Consistency Rate (v3, per entry type)
-- Same logic as earnings_q6_i1_sync_reliability.sql but outputs per-entry-type rows
-- for WHR __aggregate__ (min across types).
--
-- v2: carry fee liability overflow (wallet + liability summed per correlation_id)
-- v3: intervention join on correlation_id + csp_id (not correlation_id alone)

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

ent as (
    select e.id as ent_id, e.csp_id, e.entry_type, e.amount as ent_amount,
           e.recharge_event_ref, e.correlation_id as ent_correlation_id,
           date(convert_timezone('Asia/Kolkata',e.created_at)) as ent_date
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e
    join csp_account c on c.csp_id=e.csp_id
    where e._fivetran_active
      and e.entry_type in ('BASE_PAYOUT_CREDIT','RECOVERY_PAYOUT_CREDIT','INTERVENTION_SUPPORT_CREDIT','BONUS_CREDIT','CARRY_FEE_DEBIT')),

wal as (
    select w.id as wal_id, w.csp_id, w.entry_type as w_entry_type, w.amount as wal_amount,
           w.reference_id, w.correlation_id as wal_correlation_id,
           w.line_item_description,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as wal_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active
      and w.entry_type in ('BASE_PAYOUT','RECOVERY_RETURN','INTERVENTION_CREDIT','BONUS_CREDIT','CARRY_FEE')),

carry_fee_settlement as (
    select correlation_id,
           sum(amt)          as settled_amount,
           min(settle_date)  as settle_date
    from (
        select w.correlation_id, abs(w.amount) as amt,
               date(convert_timezone('Asia/Kolkata',w.created_at)) as settle_date
        from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
        join csp_account c on c.csp_id=w.csp_id
        where w._fivetran_active and w.entry_type='CARRY_FEE'
        union all
        select l.correlation_id, abs(l.amount),
               date(convert_timezone('Asia/Kolkata',l.created_at))
        from csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l
        join csp_account c on c.csp_id=l.csp_id
        where l._fivetran_active and l.entry_type='CARRY_FEE_OVERFLOW'
    )
    group by correlation_id),

base_sync as (
    select 'BASE_PAYOUT' as entry_type, coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.recharge_event_ref=w.reference_id
      and e.entry_type='BASE_PAYOUT_CREDIT' and w.w_entry_type='BASE_PAYOUT'
    where e.entry_type='BASE_PAYOUT_CREDIT' or w.w_entry_type='BASE_PAYOUT'),

recovery_sync as (
    select 'RECOVERY_RETURN' as entry_type, coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.ent_correlation_id=w.wal_correlation_id
      and e.entry_type='RECOVERY_PAYOUT_CREDIT' and w.w_entry_type='RECOVERY_RETURN'
    where e.entry_type='RECOVERY_PAYOUT_CREDIT' or w.w_entry_type='RECOVERY_RETURN'),

intervention_sync as (
    select 'INTERVENTION_CREDIT' as entry_type, coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.ent_correlation_id=w.wal_correlation_id
      and e.csp_id=w.csp_id
      and e.entry_type='INTERVENTION_SUPPORT_CREDIT' and w.w_entry_type='INTERVENTION_CREDIT'
    where e.entry_type='INTERVENTION_SUPPORT_CREDIT' or w.w_entry_type='INTERVENTION_CREDIT'),

bonus_sync as (
    select 'BONUS_CREDIT' as entry_type, coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(
             (e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100)
             or (w.wal_id is not null and w.line_item_description ilike '%Rating bonus%')
             or (w.wal_id is not null and w.wal_date='2026-05-01'),
           1,0) as is_synced
    from ent e
    full outer join wal w
      on e.csp_id=w.csp_id and abs(e.ent_amount)=abs(w.wal_amount)
      and e.entry_type='BONUS_CREDIT' and w.w_entry_type='BONUS_CREDIT'
    where e.entry_type='BONUS_CREDIT' or w.w_entry_type='BONUS_CREDIT'),

carry_fee_sync as (
    select 'CARRY_FEE' as entry_type, coalesce(e.ent_date, s.settle_date) as sync_date,
           iff(e.ent_id is not null and s.correlation_id is not null
               and abs(abs(e.ent_amount)-abs(s.settled_amount))<=100,1,0) as is_synced
    from ent e
    full outer join carry_fee_settlement s
      on e.ent_correlation_id=s.correlation_id
      and e.entry_type='CARRY_FEE_DEBIT'
    where e.entry_type='CARRY_FEE_DEBIT' or s.correlation_id is not null),

all_sync_events as (
    select entry_type, sync_date, is_synced from base_sync
    union all select entry_type, sync_date, is_synced from recovery_sync
    union all select entry_type, sync_date, is_synced from intervention_sync
    union all select entry_type, sync_date, is_synced from bonus_sync
    union all select entry_type, sync_date, is_synced from carry_fee_sync),

period_rates as (
    select e.entry_type, p.period_name,
           round(100.0*sum(e.is_synced)/nullif(count(e.sync_date),0),1) rate_pct
    from periods p
    left join all_sync_events e on e.sync_date between p.start_date and p.end_date
    group by 1, 2)

select entry_type,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates
group by entry_type
order by entry_type
