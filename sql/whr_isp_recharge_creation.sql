with RECURSIVE date_cte AS
(
    SELECT DATE '2026-07-01' AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt)
    FROM date_cte
    WHERE dt < CURRENT_DATE()+2
)
,
trum AS
(
SELECT
        router_nas_id,created_by,base_transaction_id,
        MIN(plan_created_time)    AS plan_created_time,
        MIN(plan_start_time) AS plan_start_time,
        MAX(plan_end_time) AS plan_end_time
from
(
    SELECT
        router_nas_id,created_by,
        CASE
            WHEN ARRAY_SIZE(SPLIT(TRANSACTION_ID, '_')) > 4
            THEN REGEXP_REPLACE(TRANSACTION_ID, '_[0-9]+$', '')
            ELSE TRANSACTION_ID end AS  base_transaction_id,
                DATEADD('minute', 330, OTP_ISSUED_TIME) AS plan_start_time,
        DATEADD('minute', 330, otp_expiry_time) AS plan_end_time,
        DATEADD('minute', 330, created_on) AS plan_created_time
    FROM PROD_DB.PUBLIC.T_ROUTER_USER_MAPPING
    WHERE device_limit = 10
      AND otp = 'DONE'
      AND mobile > '5999999999'
)
group by all
)
,Conn as (
  select c.connection_id, c.customer_id, c.csp_id, c.current_state, cae.caeo_state, cae.entitlement_end as ent_caeo_raw,
    to_char(cae.entitlement_end,'YYYY-MM-DD HH24:MI') as entitlement_end_caeo, to_date(c.created_at) as connection_created_date, nasid
  from PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
  left join (select distinct connection_id, caeo_state, entitlement_end
              from PROD_DB.CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.CUSTOMER_ACCESS_STATES
              where _fivetran_active
            ) cae on cae.connection_id=c.connection_id
  left join (select account_id, nasid, mobile from PROD_DB.PUBLIC.T_WG_CUSTOMER
            where _fivetran_deleted='FALSE'
        qualify row_number() over(partition by account_id order by added_time desc)=1
            ) as inv on c.customer_id=inv.account_id
  where c._fivetran_active
)
,E as
(
        Select connection_id
        ,coalesce(renewal_start_time_i,dateadd(day,-30,renewal_end_time_ist)) as renewal_start_time_ist
        ,renewal_end_time_ist
       ,to_date(coalesce(renewal_start_time_i,dateadd(day,-30,renewal_end_time_ist))) as renewal_start_date_ist
        ,to_date(renewal_end_time_ist) as renewal_end_date_ist
        ,last_renewal_end_ist
        from
        (
        select connection_id,window_end as we_raw,window_start as ws_raw,
        to_char(DATEADD('minute', 330, window_start),'YYYY-MM-DD HH24:MI') as renewal_start_time_i,
        to_char(DATEADD('minute', 330, window_end),'YYYY-MM-DD HH24:MI') as renewal_end_time_ist
        ,lead(to_char(DATEADD('minute', 330, window_end),'YYYY-MM-DD HH24:MI')) over(partition by connection_id order by window_end desc) as last_renewal_end_ist
        , to_date(DATEADD('minute', 330, created_at)) as created_date_RG
        from PROD_DB.CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES
       where  _fivetran_active
        )
)
,isp_plan_days as
(
Select d.dt as isp_plan_dates,e.* from E
inner join conn as c on E.connection_id=c.connection_id
inner join date_cte d
    ON (d.dt >= to_date(e.renewal_start_time_ist) AND d.dt <= to_date(e.renewal_end_time_ist))
)
,
trum_days as
(
Select d.dt as customer_plan_dates, c.connection_id ,t.*
from trum as t
inner join conn as c on t.router_nas_id=c.nasid
inner join date_cte d
    ON (d.dt >= to_date(t.plan_start_time) AND d.dt <= to_date(t.plan_end_time))
)
, ticket_due_dates as (
    select e.connection_id,
           e.renewal_end_date_ist,
           min(pd.customer_plan_dates) as ticket_due_date
    from E
    join trum_days pd
      on pd.connection_id = e.connection_id
     and pd.customer_plan_dates >= e.renewal_end_date_ist
    group by e.connection_id, e.renewal_end_date_ist
)
,REC as
(
select r.connection_id, r.customer_id,r.obligation_window_start,r.obligation_window_end, r.execution_candidate_id as recharge_execution_candidate_id,
r.commission_status,r.state,
to_char(DATEADD('minute', 330, r.created_at),'YYYY-MM-DD HH24:MI') as created_time_rec, o.reason
from PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RECHARGE_EXECUTION_CANDIDATES as r
left join PROD_DB.CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
 as o on r.authority_entity_id=o.obligation_ref
where r._fivetran_active
)
,Final_data as
(
select distinct *
, case when ticket_due_date is not null then 1
       when renewal_end_time_ist is null and has_prior_ticket = 1 then 0
       when renewal_end_time_ist is null then 1
       else 0 end as Renewal_ticket_required
, case
    when Renewal_ticket_required = 1 and has_ticket_pm2 = 1 then 'ticket created'
    when Renewal_ticket_required = 1 then 'no ticket'
    else null
  end as Renewal_ticket_status
from
(
    Select t.*,i.* EXCLUDE (connection_id),
    rec.created_time_rec, rec.recharge_execution_candidate_id, rec.reason
   ,case when td.ticket_due_date is not null and renewal_end_time_ist>plan_end_time then null
            else td.ticket_due_date end as ticket_due_date
    , max(case when rtk.tkt_date is not null then 1 else 0 end)
        over(partition by t.connection_id, t.customer_plan_dates) as has_ticket_pm2
    , max(case when rall.tkt_date is not null then 1 else 0 end)
        over(partition by t.connection_id, t.customer_plan_dates) as has_prior_ticket
from trum_days as t
left join isp_plan_days as i on t.connection_id=i.connection_id and t.customer_plan_dates=i.isp_plan_dates
left join rec on t.connection_id=rec.connection_id and t.customer_plan_dates=to_date(rec.created_time_rec)
left join ticket_due_dates td on td.connection_id = t.connection_id and td.ticket_due_date = t.customer_plan_dates
left join (select distinct connection_id, to_date(created_time_rec) as tkt_date from rec) rtk
        on rtk.connection_id = t.connection_id
        and abs(datediff('day', rtk.tkt_date, t.customer_plan_dates)) <= 2
left join (select distinct connection_id, to_date(created_time_rec) as tkt_date from rec) rall
        on rall.connection_id = t.connection_id
        and rall.tkt_date < t.customer_plan_dates
    qualify row_number() over(partition by customer_plan_dates,t.connection_id order by plan_start_time asc)=1
)
order by customer_plan_dates asc
)
, req_days as
(
    select distinct connection_id, customer_plan_dates as req_date
    from final_data where Renewal_ticket_required=1
)
, Final_data_N as
(
Select distinct t.*
    , max(case when rq.req_date is not null then 1 else 0 end)
        over(partition by t.connection_id, t.customer_plan_dates) as has_required_pm2

from final_Data as t

left join req_days rq
        on rq.connection_id = t.connection_id
        and abs(datediff('day', rq.req_date, to_Date(t.CREATED_TIME_REC))) <= 3
order by customer_plan_dates asc
)

, bucketed as (
    select
        recharge_execution_candidate_id,
        has_required_pm2,
        to_date(created_time_rec) as rec_date
    from final_data_n
    where created_time_rec is not null
)

select
    'ISP Recharge Ticket Creation Rate' as Metric,
    ROUND(100.0 * count(distinct case when ticket_due_date = dateadd(day,-1,current_date) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date = dateadd(day,-1,current_date) then connection_id end),0), 2) as "D-1",
    ROUND(100.0 * count(distinct case when ticket_due_date = dateadd(day,-2,current_date) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date = dateadd(day,-2,current_date) then connection_id end),0), 2) as "D-2",
    ROUND(100.0 * count(distinct case when ticket_due_date = dateadd(day,-3,current_date) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date = dateadd(day,-3,current_date) then connection_id end),0), 2) as "D-3",

    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(week,-1,date_trunc('week',current_date)) and dateadd(day,-1,date_trunc('week',current_date)) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(week,-1,date_trunc('week',current_date)) and dateadd(day,-1,date_trunc('week',current_date)) then connection_id end),0), 2) as "W-1",
    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(week,-2,date_trunc('week',current_date)) and dateadd(day,-1,dateadd(week,-1,date_trunc('week',current_date))) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(week,-2,date_trunc('week',current_date)) and dateadd(day,-1,dateadd(week,-1,date_trunc('week',current_date))) then connection_id end),0), 2) as "W-2",
    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(week,-3,date_trunc('week',current_date)) and dateadd(day,-1,dateadd(week,-2,date_trunc('week',current_date))) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(week,-3,date_trunc('week',current_date)) and dateadd(day,-1,dateadd(week,-2,date_trunc('week',current_date))) then connection_id end),0), 2) as "W-3",

    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(month,-1,date_trunc('month',current_date)) and dateadd(day,-1,date_trunc('month',current_date)) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(month,-1,date_trunc('month',current_date)) and dateadd(day,-1,date_trunc('month',current_date)) then connection_id end),0), 2) as "M-1",
    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(month,-2,date_trunc('month',current_date)) and dateadd(day,-1,dateadd(month,-1,date_trunc('month',current_date))) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(month,-2,date_trunc('month',current_date)) and dateadd(day,-1,dateadd(month,-1,date_trunc('month',current_date))) then connection_id end),0), 2) as "M-2",
    ROUND(100.0 * count(distinct case when ticket_due_date between dateadd(month,-3,date_trunc('month',current_date)) and dateadd(day,-1,dateadd(month,-2,date_trunc('month',current_date))) and has_ticket_pm2=1 then connection_id end)
      / nullif(count(distinct case when ticket_due_date between dateadd(month,-3,date_trunc('month',current_date)) and dateadd(day,-1,dateadd(month,-2,date_trunc('month',current_date))) then connection_id end),0), 2) as "M-3"
from
Final_data_N
