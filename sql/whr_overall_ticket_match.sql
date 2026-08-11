with csp_partner AS (
  SELECT DISTINCT ca.PARTNER_ID, csp_id
  FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT ca
  WHERE
    ca._FIVETRAN_ACTIVE = TRUE AND
    ca.STATUS='ACTIVE' AND
    ca.PARTNER_ID IS NOT NULL
),

base as (
    select
        kapture_ticket_id,
        ticket_id,
        task_id,
        last_title,
        current_partner_account_id partner_id,
        ticket_added_time added_time,
        csp_id
    from service_ticket_model stm
    inner join csp_partner csp on csp.partner_id::int = coalesce(stm.current_partner_account_id::int, stm.lco_account_id::int)
    where ticket_id is not null
    group by all
),

filtered_tickets as (
    select
        kapture_ticket_id,
        ticket_id,
        task_id,
        last_title,
        partner_id,
        csp_id,
        added_time
    from base
    where 1=1
        and last_title ilike '%shifting%'
),

csp_complaints as (
    select
        ticket_id,
        complaint_id,
        CSP_ID,
        primary_class,
        secondary_subtype,
        created_at,
        row_number() over (partition by ticket_id order by created_at desc) as rn
    from PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    where
        _fivetran_active and
        created_at >= dateadd(month, -4, date_trunc('month', current_date())) and
        ticket_id not ilike '%prod%' and
        ticket_id not ilike '%test%' and
        ticket_id is not null and
        secondary_subtype is not null
        AND SECONDARY_SUBTYPE not IN ('OPTICAL_POWER_OUT_OF_RANGE','RECHARGE_DONE_NO_INTERNET','FREQUENT_DISCONNECTION','SLOW_INTERNET','NO_INTERNET')
    qualify rn = 1
),

matched as (
    select
        service_tickets.ticket_id,
        dateadd(minute, 330, service_tickets.added_time) added_time,
        case when csp_tickets.ticket_id is not null then 1 else 0 end as is_matched
    from filtered_tickets service_tickets
    left join csp_complaints csp_tickets
        on csp_tickets.ticket_id::int = service_tickets.ticket_id::int
)

select
    'Overall Ticket Level Match Rate' as kpi,
    round(100.0 * avg(case when date(added_time) = dateadd(day, -1, current_date()) then is_matched end), 1) as "D-1",
    round(100.0 * avg(case when date(added_time) = dateadd(day, -2, current_date()) then is_matched end), 1) as "D-2",
    round(100.0 * avg(case when date(added_time) = dateadd(day, -3, current_date()) then is_matched end), 1) as "D-3",
    round(100.0 * avg(case when date(added_time) >= dateadd(week, -1, date_trunc('week', current_date()))
                            and date(added_time) <  date_trunc('week', current_date()) then is_matched end), 1) as "W-1",
    round(100.0 * avg(case when date(added_time) >= dateadd(week, -2, date_trunc('week', current_date()))
                            and date(added_time) <  dateadd(week, -1, date_trunc('week', current_date())) then is_matched end), 1) as "W-2",
    round(100.0 * avg(case when date(added_time) >= dateadd(week, -3, date_trunc('week', current_date()))
                            and date(added_time) <  dateadd(week, -2, date_trunc('week', current_date())) then is_matched end), 1) as "W-3",
    round(100.0 * avg(case when date(added_time) >= dateadd(month, -1, date_trunc('month', current_date()))
                            and date(added_time) <  date_trunc('month', current_date()) then is_matched end), 1) as "M-1",
    round(100.0 * avg(case when date(added_time) >= dateadd(month, -2, date_trunc('month', current_date()))
                            and date(added_time) <  dateadd(month, -1, date_trunc('month', current_date())) then is_matched end), 1) as "M-2",
    round(100.0 * avg(case when date(added_time) >= dateadd(month, -3, date_trunc('month', current_date()))
                            and date(added_time) <  dateadd(month, -2, date_trunc('month', current_date())) then is_matched end), 1) as "M-3"
from matched
