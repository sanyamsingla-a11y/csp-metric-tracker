-- Compensation to Wallet Sync Rate  (v3)
-- Full outer join between entitlement_ledger_entries and the settlement side for 5 types.
-- is_synced = matched AND amount diff <= 100, OR legacy_ok.
--
-- v2 CHANGE (per PM RCA, 2026-08-25):
--   Carry fee was the only type under-syncing (84.6% D-1 / 90.0% W-1). Root cause: when the
--   CSP wallet cannot cover the fee, the shortfall is booked to LIABILITY_LEDGER_ENTRIES
--   (entry_type = 'CARRY_FEE_OVERFLOW') instead of the wallet. v1 only looked at the wallet,
--   so those settlements read as missing.
--   The overflow comes in TWO shapes, both of which v1 scored as unsynced:
--     (a) TOTAL   -- wallet row absent entirely, 100% to liability      (680 entries / 30d)
--     (b) PARTIAL -- wallet row present but short, remainder to liability (458 entries / 30d)
--   (b) is why this is a SUM and not a COALESCE fallback: those rows DO join to a wallet
--   entry, but fail the amount test because the wallet holds only part of the fee.
--   Settlement is therefore wallet + liability, summed per correlation_id.
--
-- v3 CHANGE (join fan-out fix, 2026-08-25):
--   INTERVENTION joined on correlation_id alone, but correlation_id is a BATCH id for
--   intervention, not a settlement id: 1,683 entitlement rows share only 961 correlation_ids.
--   Two bulk batches on 2026-08-16 -- 'wiom-sahayata-yogdan-aug2026' (711 CSPs) and
--   'sehat-guarantee-2026-08-16' (13 CSPs) -- produced a CARTESIAN product of
--   711x711 + 13x13 = 505,690 phantom join rows, collapsing W-2 to 15.6%.
--   Both batches reconcile rupee-for-rupee; the money was always fine, the JOIN was not.
--   Fix: join on correlation_id + csp_id, which IS unique on both sides
--   (1,683 rows / 1,683 distinct correlation_id+csp_id, zero duplicates).
--   W-2 intervention: 505,742 events / 12.21%  ->  776 events / 100%.
--
--   NOT fixed here, flagged for follow-up: BONUS still joins on csp_id + amount with no
--   batch key (ent 3,241 rows / 485 correlation_ids; wal 3,683 / 382) and is exposed to
--   the same class of fan-out. BASE joins on recharge_event_ref and is unaffected.

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

-- entitlement side (5 types)
ent as (
    select e.id as ent_id, e.csp_id, e.entry_type, e.amount as ent_amount,
           e.recharge_event_ref, e.correlation_id as ent_correlation_id,
           date(convert_timezone('Asia/Kolkata',e.created_at)) as ent_date
    from csp_compensation_service_csp_compensation_service.entitlement_ledger_entries e
    join csp_account c on c.csp_id=e.csp_id
    where e._fivetran_active
      and e.entry_type in ('BASE_PAYOUT_CREDIT','RECOVERY_PAYOUT_CREDIT','INTERVENTION_SUPPORT_CREDIT','BONUS_CREDIT','CARRY_FEE_DEBIT')),

-- wallet side (5 matching types)
-- NOTE: 'CARRY_FEE' is retained here for reference only; carry fee now settles via
--       carry_fee_settlement below, which unions the wallet with the liability ledger.
wal as (
    select w.id as wal_id, w.csp_id, w.entry_type as w_entry_type, w.amount as wal_amount,
           w.reference_id, w.correlation_id as wal_correlation_id,
           w.line_item_description,
           date(convert_timezone('Asia/Kolkata',w.created_at)) as wal_date
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    join csp_account c on c.csp_id=w.csp_id
    where w._fivetran_active
      and w.entry_type in ('BASE_PAYOUT','RECOVERY_RETURN','INTERVENTION_CREDIT','BONUS_CREDIT','CARRY_FEE')),

-- v2: carry fee settlement = wallet debit + liability overflow, summed per correlation_id.
-- A fee is settled if the money was accounted for ANYWHERE, whether it left the wallet
-- or was carried as a liability because the wallet was short.
carry_fee_settlement as (
    select correlation_id,
           sum(amt)          as settled_amount,
           min(settle_date)  as settle_date,
           max(is_wallet)    as has_wallet,
           max(is_liability) as has_liability
    from (
        select w.correlation_id, abs(w.amount) as amt, 1 as is_wallet, 0 as is_liability,
               date(convert_timezone('Asia/Kolkata',w.created_at)) as settle_date
        from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
        join csp_account c on c.csp_id=w.csp_id
        where w._fivetran_active and w.entry_type='CARRY_FEE'
        union all
        select l.correlation_id, abs(l.amount), 0, 1,
               date(convert_timezone('Asia/Kolkata',l.created_at))
        from csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries l
        join csp_account c on c.csp_id=l.csp_id
        where l._fivetran_active and l.entry_type='CARRY_FEE_OVERFLOW'
    )
    group by correlation_id),

-- BASE_PAYOUT: join on recharge_event_ref <-> reference_id
base_sync as (
    select coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.recharge_event_ref=w.reference_id
      and e.entry_type='BASE_PAYOUT_CREDIT' and w.w_entry_type='BASE_PAYOUT'
    where e.entry_type='BASE_PAYOUT_CREDIT' or w.w_entry_type='BASE_PAYOUT'),

-- RECOVERY: join on correlation_id
recovery_sync as (
    select coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.ent_correlation_id=w.wal_correlation_id
      and e.entry_type='RECOVERY_PAYOUT_CREDIT' and w.w_entry_type='RECOVERY_RETURN'
    where e.entry_type='RECOVERY_PAYOUT_CREDIT' or w.w_entry_type='RECOVERY_RETURN'),

-- INTERVENTION (v3): join on correlation_id + csp_id (correlation_id alone is a batch id)
intervention_sync as (
    select coalesce(e.ent_date, w.wal_date) as sync_date,
           iff(e.ent_id is not null and w.wal_id is not null and abs(abs(e.ent_amount)-abs(w.wal_amount))<=100,1,0) as is_synced
    from ent e
    full outer join wal w
      on e.ent_correlation_id=w.wal_correlation_id
      and e.csp_id=w.csp_id
      and e.entry_type='INTERVENTION_SUPPORT_CREDIT' and w.w_entry_type='INTERVENTION_CREDIT'
    where e.entry_type='INTERVENTION_SUPPORT_CREDIT' or w.w_entry_type='INTERVENTION_CREDIT'),

-- BONUS: join on csp_id + amount (legacy exceptions: rating bonus wallet orphans, 2026-05-01 bonus)
bonus_sync as (
    select coalesce(e.ent_date, w.wal_date) as sync_date,
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

-- CARRY_FEE (v2): join on correlation_id against wallet + liability combined
carry_fee_sync as (
    select coalesce(e.ent_date, s.settle_date) as sync_date,
           iff(e.ent_id is not null and s.correlation_id is not null
               and abs(abs(e.ent_amount)-abs(s.settled_amount))<=100,1,0) as is_synced
    from ent e
    full outer join carry_fee_settlement s
      on e.ent_correlation_id=s.correlation_id
      and e.entry_type='CARRY_FEE_DEBIT'
    where e.entry_type='CARRY_FEE_DEBIT' or s.correlation_id is not null),

all_sync_events as (
    select sync_date, is_synced from base_sync
    union all select sync_date, is_synced from recovery_sync
    union all select sync_date, is_synced from intervention_sync
    union all select sync_date, is_synced from bonus_sync
    union all select sync_date, is_synced from carry_fee_sync),

period_rates as (
    select p.period_name, round(100.0*sum(e.is_synced)/nullif(count(e.sync_date),0),2) rate_pct
    from periods p left join all_sync_events e on e.sync_date between p.start_date and p.end_date
    group by p.period_name)

select 'Compensation to Wallet Sync Rate' metric,
    max(iff(period_name='D-1',rate_pct,null)) "D-1",max(iff(period_name='D-2',rate_pct,null)) "D-2",
    max(iff(period_name='D-3',rate_pct,null)) "D-3",max(iff(period_name='W-1',rate_pct,null)) "W-1",
    max(iff(period_name='W-2',rate_pct,null)) "W-2",max(iff(period_name='W-3',rate_pct,null)) "W-3",
    max(iff(period_name='M-1',rate_pct,null)) "M-1",max(iff(period_name='M-2',rate_pct,null)) "M-2",
    max(iff(period_name='M-3',rate_pct,null)) "M-3"
from period_rates;
