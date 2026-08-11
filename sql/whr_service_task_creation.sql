with csp_complaints as (
    select
        ticket_id,
        complaint_id,
        csp_id,
        created_at
    from PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    where
        _fivetran_active
        and primary_class = 'SERVICE_ISSUE'
        and ticket_id not ilike '%prod%'
        and ticket_id not ilike '%test%'
        and created_at >= dateadd(month, -4, date_trunc('month', current_date()))
),

complaint_task_match as (
    select distinct complaint_id
    from PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINT_TASKS
    where _fivetran_active
),

matched as (
    select
        c.complaint_id,
        c.ticket_id,
        dateadd(mi, 330, c.created_at) created_at,
        case when t.complaint_id is not null then 1 else 0 end as is_task_created
    from csp_complaints c
    left join complaint_task_match t
        on t.complaint_id = c.complaint_id
)

select
    'Task Creation Rate' as kpi,
    round(100.0 * avg(case when date(created_at) = dateadd(day, -1, current_date()) then is_task_created end), 1) as "D-1",
    round(100.0 * avg(case when date(created_at) = dateadd(day, -2, current_date()) then is_task_created end), 1) as "D-2",
    round(100.0 * avg(case when date(created_at) = dateadd(day, -3, current_date()) then is_task_created end), 1) as "D-3",
    round(100.0 * avg(case when date(created_at) >= dateadd(week, -1, date_trunc('week', current_date()))
                            and date(created_at) <  date_trunc('week', current_date()) then is_task_created end), 1) as "W-1",
    round(100.0 * avg(case when date(created_at) >= dateadd(week, -2, date_trunc('week', current_date()))
                            and date(created_at) <  dateadd(week, -1, date_trunc('week', current_date())) then is_task_created end), 1) as "W-2",
    round(100.0 * avg(case when date(created_at) >= dateadd(week, -3, date_trunc('week', current_date()))
                            and date(created_at) <  dateadd(week, -2, date_trunc('week', current_date())) then is_task_created end), 1) as "W-3",
    round(100.0 * avg(case when date(created_at) >= dateadd(month, -1, date_trunc('month', current_date()))
                            and date(created_at) <  date_trunc('month', current_date()) then is_task_created end), 1) as "M-1",
    round(100.0 * avg(case when date(created_at) >= dateadd(month, -2, date_trunc('month', current_date()))
                            and date(created_at) <  dateadd(month, -1, date_trunc('month', current_date())) then is_task_created end), 1) as "M-2",
    round(100.0 * avg(case when date(created_at) >= dateadd(month, -3, date_trunc('month', current_date()))
                            and date(created_at) <  dateadd(month, -2, date_trunc('month', current_date())) then is_task_created end), 1) as "M-3"
from matched
