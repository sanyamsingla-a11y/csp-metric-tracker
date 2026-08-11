-- Ticket-to-CSP Visibility Rate — PN Delivered
WITH anchor AS (
    SELECT DATEADD(MINUTE, 330, CURRENT_TIMESTAMP())::DATE AS today_ist
),
periods AS (
    SELECT
        today_ist - 1 AS d1,
        today_ist - 2 AS d2,
        today_ist - 3 AS d3,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '7 days'  AS w1_start,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '1 day'   AS w1_end,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '14 days' AS w2_start,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '8 days'  AS w2_end,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '21 days' AS w3_start,
        DATE_TRUNC('WEEK', today_ist) - INTERVAL '15 days' AS w3_end,
        DATE_TRUNC('MONTH', today_ist) - INTERVAL '1 month'  AS m1_start,
        DATE_TRUNC('MONTH', today_ist) - INTERVAL '1 day'    AS m1_end,
        DATE_TRUNC('MONTH', today_ist) - INTERVAL '2 months' AS m2_start,
        DATEADD(DAY, -1, DATE_TRUNC('MONTH', today_ist) - INTERVAL '1 month')  AS m2_end,
        DATE_TRUNC('MONTH', today_ist) - INTERVAL '3 months' AS m3_start,
        DATEADD(DAY, -1, DATE_TRUNC('MONTH', today_ist) - INTERVAL '2 months') AS m3_end
    FROM anchor
),
tickets AS (
    SELECT execution_candidate_id,
           TO_DATE(DATEADD(MINUTE, 330, created_at)) AS created_date_ist
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RECHARGE_EXECUTION_CANDIDATES
    WHERE _fivetran_active
      AND created_at >= DATEADD(MONTH, -5, CURRENT_DATE())
),
pn_sent AS (
    SELECT DISTINCT PARSE_JSON(properties):"execution_id"::string AS execution_id
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA
    WHERE timestamp >= DATEADD(MONTH, -5, CURRENT_DATE())
      AND event_name = 'recharge_task_created'
),
pn_delivered AS (
    SELECT DISTINCT PARSE_JSON(properties):"execution_id"::string AS execution_id
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA
    WHERE timestamp >= DATEADD(MONTH, -5, CURRENT_DATE())
      AND event_name IN ('pn_delivered','fpn_delivered')
      AND TRY_PARSE_JSON(properties):pn_type::string IS NOT NULL
),
ticket_flags AS (
    SELECT t.execution_candidate_id, t.created_date_ist,
           CASE WHEN ps.execution_id IS NOT NULL THEN 1 ELSE 0 END AS is_pn_sent,
           CASE WHEN pd.execution_id IS NOT NULL THEN 1 ELSE 0 END AS is_pn_delivered
    FROM tickets t
    LEFT JOIN pn_sent      ps ON t.execution_candidate_id = ps.execution_id
    LEFT JOIN pn_delivered pd ON t.execution_candidate_id = pd.execution_id
),
agg AS (
    SELECT
        SUM(CASE WHEN tf.created_date_ist = p.d1 THEN 1 END) AS d1_tickets,
        SUM(CASE WHEN tf.created_date_ist = p.d1 THEN tf.is_pn_delivered END) AS d1_delivered,
        SUM(CASE WHEN tf.created_date_ist = p.d2 THEN 1 END) AS d2_tickets,
        SUM(CASE WHEN tf.created_date_ist = p.d2 THEN tf.is_pn_delivered END) AS d2_delivered,
        SUM(CASE WHEN tf.created_date_ist = p.d3 THEN 1 END) AS d3_tickets,
        SUM(CASE WHEN tf.created_date_ist = p.d3 THEN tf.is_pn_delivered END) AS d3_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w1_start AND p.w1_end THEN 1 END) AS w1_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w1_start AND p.w1_end THEN tf.is_pn_delivered END) AS w1_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w2_start AND p.w2_end THEN 1 END) AS w2_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w2_start AND p.w2_end THEN tf.is_pn_delivered END) AS w2_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w3_start AND p.w3_end THEN 1 END) AS w3_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.w3_start AND p.w3_end THEN tf.is_pn_delivered END) AS w3_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m1_start AND p.m1_end THEN 1 END) AS m1_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m1_start AND p.m1_end THEN tf.is_pn_delivered END) AS m1_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m2_start AND p.m2_end THEN 1 END) AS m2_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m2_start AND p.m2_end THEN tf.is_pn_delivered END) AS m2_delivered,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m3_start AND p.m3_end THEN 1 END) AS m3_tickets,
        SUM(CASE WHEN tf.created_date_ist BETWEEN p.m3_start AND p.m3_end THEN tf.is_pn_delivered END) AS m3_delivered
    FROM ticket_flags tf CROSS JOIN periods p
)
SELECT
       'ISP Ticket-to-CSP Visibility Rate - PN Delivered' AS kpi,
       ROUND(100.0 * d1_delivered / NULLIF(d1_tickets, 0), 2)AS "D-1",
       ROUND(100.0 * d2_delivered / NULLIF(d2_tickets, 0), 2)AS "D-2",
       ROUND(100.0 * d3_delivered / NULLIF(d3_tickets, 0), 2)AS "D-3",
       ROUND(100.0 * w1_delivered / NULLIF(w1_tickets, 0), 2)AS "W-1",
       ROUND(100.0 * w2_delivered / NULLIF(w2_tickets, 0), 2)AS "W-2",
       ROUND(100.0 * w3_delivered / NULLIF(w3_tickets, 0), 2)AS "W-3",
       ROUND(100.0 * m1_delivered / NULLIF(m1_tickets, 0), 2)AS "M-1",
       ROUND(100.0 * m2_delivered / NULLIF(m2_tickets, 0), 2)AS "M-2",
       ROUND(100.0 * m3_delivered / NULLIF(m3_tickets, 0), 2)AS "M-3"
FROM agg;
