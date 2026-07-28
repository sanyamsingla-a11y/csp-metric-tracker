-- Overall Payment Success Rate
WITH params AS (
    SELECT CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP())::DATE AS today
),
anchors AS (
    SELECT
        today,
        DATEADD('day', 1 - DAYOFWEEKISO(today), today)::DATE AS current_week_monday,
        DATE_TRUNC('month', today)::DATE                      AS current_month_start
    FROM params
),
periods AS (
    SELECT 'D-1' AS period_name, DATEADD('day',-1,today)::DATE AS start_date, DATEADD('day',-1,today)::DATE AS end_date FROM anchors
    UNION ALL SELECT 'D-2', DATEADD('day',-2,today), DATEADD('day',-2,today) FROM anchors
    UNION ALL SELECT 'D-3', DATEADD('day',-3,today), DATEADD('day',-3,today) FROM anchors
    UNION ALL SELECT 'W-1', DATEADD('day',-7,current_week_monday), DATEADD('day',-1,current_week_monday) FROM anchors
    UNION ALL SELECT 'W-2', DATEADD('day',-14,current_week_monday), DATEADD('day',-8,current_week_monday) FROM anchors
    UNION ALL SELECT 'W-3', DATEADD('day',-21,current_week_monday), DATEADD('day',-15,current_week_monday) FROM anchors
    UNION ALL SELECT 'M-1', DATEADD('month',-1,current_month_start), DATEADD('day',-1,current_month_start) FROM anchors
    UNION ALL SELECT 'M-2', DATEADD('month',-2,current_month_start), DATEADD('day',-1,DATEADD('month',-1,current_month_start)) FROM anchors
    UNION ALL SELECT 'M-3', DATEADD('month',-3,current_month_start), DATEADD('day',-1,DATEADD('month',-2,current_month_start)) FROM anchors
),
csp_account AS (
    SELECT csp_id
    FROM csp_gateway_service_csp_gateway_service.csp_account
    WHERE _fivetran_active
      AND csp_id NOT IN ('a0a6w1','a0a0b1')
      AND partner_id IS NOT NULL
),
led AS (
    SELECT
        w.reference_id AS withdrawal_id,
        MIN(DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.created_at))) AS debit_date
    FROM csp_payment_settlement_service_csp_payment_settlement_service.wallet_ledger_entries w
    JOIN csp_account c ON c.csp_id = w.csp_id
    WHERE w._fivetran_active
      AND w.entry_type = 'WITHDRAWAL_DEBIT'
      AND w.reference_id IS NOT NULL
    GROUP BY w.reference_id
),
retry AS (
    SELECT withdrawal_id, retry_status
    FROM csp_payment_settlement_service_csp_payment_settlement_service.payout_retry_log
    WHERE NOT _fivetran_deleted
),
outcomes AS (
    SELECT
        l.debit_date,
        CASE
            WHEN r.withdrawal_id IS NULL              THEN 1
            WHEN r.retry_status  = 'processed'        THEN 1
            WHEN r.retry_status IN ('failed','reversed') THEN 0
            ELSE NULL
        END AS succeeded
    FROM led l
    LEFT JOIN retry r ON r.withdrawal_id = l.withdrawal_id
),
period_stats AS (
    SELECT
        p.period_name,
        ROUND(100.0 * SUM(o.succeeded) / NULLIF(COUNT(o.succeeded), 0), 2) AS val
    FROM periods p
    LEFT JOIN outcomes o ON o.debit_date BETWEEN p.start_date AND p.end_date
                        AND o.succeeded IS NOT NULL
    GROUP BY p.period_name
)
SELECT
    'Overall Wallet to Bank S.R' AS "Metric",
    MAX(CASE WHEN period_name = 'D-1' THEN val END) AS "D-1",
    MAX(CASE WHEN period_name = 'D-2' THEN val END) AS "D-2",
    MAX(CASE WHEN period_name = 'D-3' THEN val END) AS "D-3",
    MAX(CASE WHEN period_name = 'W-1' THEN val END) AS "W-1",
    MAX(CASE WHEN period_name = 'W-2' THEN val END) AS "W-2",
    MAX(CASE WHEN period_name = 'W-3' THEN val END) AS "W-3",
    MAX(CASE WHEN period_name = 'M-1' THEN val END) AS "M-1",
    MAX(CASE WHEN period_name = 'M-2' THEN val END) AS "M-2",
    MAX(CASE WHEN period_name = 'M-3' THEN val END) AS "M-3"
FROM period_stats
