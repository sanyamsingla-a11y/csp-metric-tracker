WITH

period_def AS (
    SELECT 'D-1' AS period, 1 AS sort_order, DATEADD(day,-1,CURRENT_DATE()) AS p_start, DATEADD(day,-1,CURRENT_DATE()) AS p_end
    UNION ALL SELECT 'D-2', 2, DATEADD(day,-2,CURRENT_DATE()), DATEADD(day,-2,CURRENT_DATE())
    UNION ALL SELECT 'D-3', 3, DATEADD(day,-3,CURRENT_DATE()), DATEADD(day,-3,CURRENT_DATE())
    UNION ALL SELECT 'W-1', 4, DATEADD(day,-7,CURRENT_DATE()), DATEADD(day,-1,CURRENT_DATE())
    UNION ALL SELECT 'W-2', 5, DATEADD(day,-14,CURRENT_DATE()), DATEADD(day,-8,CURRENT_DATE())
    UNION ALL SELECT 'W-3', 6, DATEADD(day,-21,CURRENT_DATE()), DATEADD(day,-15,CURRENT_DATE())
    UNION ALL SELECT 'M-1', 7, DATE_TRUNC('month',DATEADD(month,-1,CURRENT_DATE())), LAST_DAY(DATEADD(month,-1,CURRENT_DATE()))
    UNION ALL SELECT 'M-2', 8, DATE_TRUNC('month',DATEADD(month,-2,CURRENT_DATE())), LAST_DAY(DATEADD(month,-2,CURRENT_DATE()))
    UNION ALL SELECT 'M-3', 9, DATE_TRUNC('month',DATEADD(month,-3,CURRENT_DATE())), LAST_DAY(DATEADD(month,-3,CURRENT_DATE()))
),

m1_step7 AS (
    SELECT EXECUTION_CANDIDATE_ID, MIN(UPDATED_AT) AS step7_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
    WHERE COMPLETED_STEP = 7
      AND UPDATED_AT >= DATEADD(day, -120, CURRENT_DATE - 1)
    GROUP BY EXECUTION_CANDIDATE_ID
),

installs AS (
    SELECT
        e.CONFIRMED_SLOT_DATE,
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', s.step7_at)) AS install_date
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
    JOIN m1_step7 s ON e.EXECUTION_CANDIDATE_ID = s.EXECUTION_CANDIDATE_ID
    WHERE e._FIVETRAN_ACTIVE = TRUE
      AND e.CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
      AND e.CONFIRMED_SLOT_AT IS NOT NULL
      AND e.CURRENT_STATE = 'CONNECTION_ACTIVE'
      AND s.step7_at IS NOT NULL
      AND e.CONFIRMED_SLOT_DATE >= DATEADD(day, -120, CURRENT_DATE())
),

period_stats AS (
    SELECT
        p.period,
        p.sort_order,
        ROUND(SUM(CASE WHEN i.install_date = i.CONFIRMED_SLOT_DATE THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS on_slot_pct,
        ROUND(SUM(CASE WHEN i.install_date < i.CONFIRMED_SLOT_DATE THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS before_slot_pct
    FROM period_def p
    JOIN installs i ON i.CONFIRMED_SLOT_DATE BETWEEN p.p_start AND p.p_end
    GROUP BY p.period, p.sort_order
),

unpivoted AS (
    SELECT 1 AS s, 'Install- On Slot Date %'    AS "Metric", on_slot_pct    AS val, period, sort_order FROM period_stats
    UNION ALL
    SELECT 2,      'Install- Before Slot Date %', before_slot_pct AS val, period, sort_order FROM period_stats
)

SELECT
    "Metric",
    MAX(CASE WHEN period = 'D-1' THEN val END) AS "D-1",
    MAX(CASE WHEN period = 'D-2' THEN val END) AS "D-2",
    MAX(CASE WHEN period = 'D-3' THEN val END) AS "D-3",
    MAX(CASE WHEN period = 'W-1' THEN val END) AS "W-1",
    MAX(CASE WHEN period = 'W-2' THEN val END) AS "W-2",
    MAX(CASE WHEN period = 'W-3' THEN val END) AS "W-3",
    MAX(CASE WHEN period = 'M-1' THEN val END) AS "M-1",
    MAX(CASE WHEN period = 'M-2' THEN val END) AS "M-2",
    MAX(CASE WHEN period = 'M-3' THEN val END) AS "M-3"
FROM unpivoted
GROUP BY s, "Metric"
ORDER BY s
