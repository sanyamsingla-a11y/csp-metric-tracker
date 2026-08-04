with params as (select convert_timezone('Asia/Kolkata',current_timestamp())::date as_of_date),
anchors as (select as_of_date,
    dateadd('day',1-dayofweekiso(as_of_date),as_of_date)::date current_week_monday,
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
    select csp_id from csp_gateway_service_csp_gateway_service.csp_account
    where _fivetran_active and csp_id not in ('a0a6w1','a0a0b1') and partner_id is not null),

-- Hop 1: % of credit entries with a TDS register entry (anchored by credit date)
hop1 as (
    select to_date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '1. Credit -> Register' hop,
           count(distinct wle.id) total,
           count(distinct case when r.id is not null then wle.id end) matched
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
    join csp_account c on c.csp_id=wle.csp_id
    left join csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry r
        on r.source_wallet_ledger_entry_id=wle.id
    where wle._fivetran_active
      and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
      and to_date(convert_timezone('Asia/Kolkata', wle.created_at)) >= dateadd('day',-95,current_date())
    group by 1,2),

-- Single scan for batch-level hops (2-6): register sum, TW entry, TW amount, liability amount
batch_base as (
    select b.batch_date::date due_date,
           b.id                          batch_id,
           b.aggregate_tds_paise,
           s.register_sum,
           w.id                          tw_id,
           w.amount                      tw_amount,
           ll.amount                     ll_amount
    from csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
    join csp_account c on c.csp_id=b.csp_id
    left join (select batch_ref, sum(tds_amount_paise) register_sum
               from csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry
               where _fivetran_active group by 1) s on s.batch_ref=b.id
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
        on w.id=b.wallet_ledger_entry_ref and w._fivetran_active and w.entry_type='TAX_WITHHELD'
    left join csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries ll
        on ll.reference_id=w.reference_id and ll._fivetran_active and ll.entry_type='TDS_OVERFLOW'
    where b._fivetran_active
      and b.aggregate_tds_paise>0
      and b.batch_date >= dateadd('day',-95,current_date())),

hop2 as (
    select due_date, '2. Register sum = Batch TDS' hop,
           count(distinct batch_id) total,
           count(distinct case when register_sum=aggregate_tds_paise then batch_id end) matched
    from batch_base group by 1,2),

hop3 as (
    select due_date, '3. Batch -> TW Exists' hop,
           count(distinct batch_id) total,
           count(distinct case when tw_id is not null then batch_id end) matched
    from batch_base group by 1,2),

hop4 as (
    select due_date, '4. TW % of Batch TDS' hop,
           sum(aggregate_tds_paise) total,
           sum(coalesce(abs(tw_amount),0)) matched
    from batch_base group by 1,2),

hop5 as (
    select due_date, '5. Liability % of Batch TDS' hop,
           sum(aggregate_tds_paise) total,
           sum(coalesce(ll_amount,0)) matched
    from batch_base group by 1,2),

hop6 as (
    select due_date, '6. TW + Liability % of Batch TDS' hop,
           sum(aggregate_tds_paise) total,
           sum(coalesce(abs(tw_amount),0) + coalesce(ll_amount,0)) matched
    from batch_base group by 1,2),

rate_daily as (
    select * from hop1 union all select * from hop2 union all select * from hop3
    union all select * from hop4 union all select * from hop5 union all select * from hop6),
period_rates as (
    select d.hop, p.period_name,
           round(100.0*sum(d.matched)/nullif(sum(d.total),0),2) val
    from periods p
    left join rate_daily d on d.due_date between p.start_date and p.end_date
    where d.hop is not null
    group by 1,2)

select hop,
    max(iff(period_name='D-1',val,null)) "D-1",
    max(iff(period_name='D-2',val,null)) "D-2",
    max(iff(period_name='D-3',val,null)) "D-3",
    max(iff(period_name='W-1',val,null)) "W-1",
    max(iff(period_name='W-2',val,null)) "W-2",
    max(iff(period_name='W-3',val,null)) "W-3",
    max(iff(period_name='M-1',val,null)) "M-1",
    max(iff(period_name='M-2',val,null)) "M-2",
    max(iff(period_name='M-3',val,null)) "M-3"
from period_rates
group by hop order by hop;
