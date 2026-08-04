with params as (select date(convert_timezone('Asia/Kolkata',current_timestamp())) as_of_date),
anchors as (select as_of_date, dateadd('day',1-dayofweekiso(as_of_date),as_of_date)::date current_week_monday, date_trunc('month',as_of_date)::date current_month_start from params),
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

step1 as (
    select date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '1. Gross Credits (INR)' metric,
           round(sum(wle.amount) / 100.0, 2) amount_inr
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
    join csp_account c on c.csp_id = wle.csp_id
    where wle._fivetran_active
      and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
    group by 1, 2),

step2 as (
    select date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '2. TDS Registered (INR)' metric,
           round(sum(r.tds_amount_paise) / 100.0, 2) amount_inr
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
    join csp_account c on c.csp_id = wle.csp_id
    join csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry r
        on r.source_wallet_ledger_entry_id = wle.id and r._fivetran_active
    where wle._fivetran_active
      and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
    group by 1, 2),

step3 as (
    select date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '3. TDS Batched (INR)' metric,
           round(sum(r.tds_amount_paise) / 100.0, 2) amount_inr
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
    join csp_account c on c.csp_id = wle.csp_id
    join csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry r
        on r.source_wallet_ledger_entry_id = wle.id and r._fivetran_active
    join csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
        on b.id = r.batch_ref and b._fivetran_active
    where wle._fivetran_active
      and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
    group by 1, 2),

step4 as (
    select date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '4. TW Posted to Wallet (INR)' metric,
           round(sum(
               case
                   when tw.id is null then 0
                   when abs(tw.amount) >= b.aggregate_tds_paise then r.tds_amount_paise
                   else r.tds_amount_paise * abs(tw.amount) / nullif(b.aggregate_tds_paise, 0)
               end
           ) / 100.0, 2) amount_inr
    from csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
    join csp_account c on c.csp_id = wle.csp_id
    join csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry r
        on r.source_wallet_ledger_entry_id = wle.id and r._fivetran_active
    join csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
        on b.id = r.batch_ref and b._fivetran_active
    left join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries tw
        on tw.id = b.wallet_ledger_entry_ref and tw._fivetran_active and tw.entry_type = 'TAX_WITHHELD'
    where wle._fivetran_active
      and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
    group by 1, 2),

step5 as (
    select date(convert_timezone('Asia/Kolkata', wle.created_at)) due_date,
           '5. TDS Liability Created (INR)' metric,
           round(sum(ll.amount * r.tds_amount_paise / nullif(b.aggregate_tds_paise, 0)) / 100.0, 2) amount_inr
    from csp_payment_settlement_service_csp_payment_settlement_service.liability_ledger_entries ll
    join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries tw
        on tw.reference_id = ll.reference_id and tw._fivetran_active and tw.entry_type = 'TAX_WITHHELD'
    join csp_payment_settlement_service_csp_payment_settlement_service.settlement_day_batch_entry b
        on b.wallet_ledger_entry_ref = tw.id and b._fivetran_active
    join csp_payment_settlement_service_csp_payment_settlement_service.tds_deduction_register_entry r
        on r.batch_ref = b.id and r._fivetran_active
    join csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries wle
        on wle.id = r.source_wallet_ledger_entry_id and wle._fivetran_active
        and wle.entry_type in ('BASE_PAYOUT','BONUS_CREDIT','INTERVENTION_CREDIT','RECOVERY_RETURN')
    join csp_account c on c.csp_id = wle.csp_id
    where ll._fivetran_active and ll.entry_type = 'TDS_OVERFLOW'
    group by 1, 2),

step6 as (
    select due_date, '6. TW + Liability Total (INR)' metric, round(sum(amount_inr), 2) amount_inr
    from (select due_date, amount_inr from step4 union all select due_date, amount_inr from step5)
    group by 1, 2),

daily as (
    select * from step1 union all select * from step2 union all select * from step3
    union all select * from step4 union all select * from step5 union all select * from step6),
period_amounts as (
    select d.metric, p.period_name,
           round(sum(d.amount_inr), 2) total_inr
    from periods p
    left join daily d on d.due_date between p.start_date and p.end_date
    group by 1, 2)
select metric,
    max(iff(period_name='D-1', total_inr, null)) "D-1",
    max(iff(period_name='D-2', total_inr, null)) "D-2",
    max(iff(period_name='D-3', total_inr, null)) "D-3",
    max(iff(period_name='W-1', total_inr, null)) "W-1",
    max(iff(period_name='W-2', total_inr, null)) "W-2",
    max(iff(period_name='W-3', total_inr, null)) "W-3",
    max(iff(period_name='M-1', total_inr, null)) "M-1",
    max(iff(period_name='M-2', total_inr, null)) "M-2",
    max(iff(period_name='M-3', total_inr, null)) "M-3"
from period_amounts
group by metric order by metric;
