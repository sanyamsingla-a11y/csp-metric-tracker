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
rzp_latest AS (
    SELECT *
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY _created DESC) AS rn
        FROM razorpayx
    ) t
    WHERE rn = 1
),
daily AS (
    SELECT
        r.mode,
        DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at)) AS dt,
        SUM(CASE WHEN r.status = 'processed' THEN 1 ELSE 0 END) AS success_cnt,
        COUNT(*) AS attempt_cnt
    FROM CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES wl
    LEFT JOIN rzp_latest r ON wl.payout_id = r.source_id
    WHERE wl.entry_type ILIKE '%withdrawal%'
      AND wl._fivetran_active
      AND r.status NOT IN ('processing', 'queued')
      AND DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at)) >= DATEADD(day, -95, CURRENT_DATE())
    GROUP BY 1, 2
),
period_stats AS (
    SELECT
        d.mode,
        p.period_name,
        ROUND(100.0 * SUM(d.success_cnt) / NULLIF(SUM(d.attempt_cnt), 0), 1) AS val
    FROM periods p
    LEFT JOIN daily d ON d.dt BETWEEN p.start_date AND p.end_date
    WHERE d.mode IS NOT NULL
    GROUP BY d.mode, p.period_name
),
final AS (
    SELECT
        CASE mode WHEN 'IMPS' THEN 'IMPS Success Rate' WHEN 'NEFT' THEN 'NEFT Success Rate' ELSE mode END AS "Metric",
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
    GROUP BY mode
)
SELECT * FROM final ORDER BY "Metric"
