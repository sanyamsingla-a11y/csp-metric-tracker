WITH cohort AS (
    SELECT
        n.EXECUTION_CANDIDATE_ID,
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.created_at)) AS created_dt,
        n.state,
        n.reason_code,
        n.created_at,
        n.updated_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.created_at))
          BETWEEN CURRENT_DATE - 29 AND CURRENT_DATE - 22
),

daily AS (
    SELECT
        created_dt,
        COUNT(DISTINCT EXECUTION_CANDIDATE_ID) AS total,
        COUNT(DISTINCT CASE
            WHEN (state = 'COMPLETED'
                  OR (state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED'))
                 AND DATEDIFF(day, created_at, updated_at) <= 21
            THEN EXECUTION_CANDIDATE_ID END) AS resolved,
        COUNT(DISTINCT CASE
            WHEN state = 'COMPLETED'
                 AND DATEDIFF(day, created_at, updated_at) <= 21
            THEN EXECUTION_CANDIDATE_ID END) AS pickup_done,
        COUNT(DISTINCT CASE
            WHEN state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED'
                 AND DATEDIFF(day, created_at, updated_at) <= 21
            THEN EXECUTION_CANDIDATE_ID END) AS recharge_done,
        COUNT(DISTINCT CASE
            WHEN state = 'FAILED'
            THEN EXECUTION_CANDIDATE_ID END) AS lost
    FROM cohort
    GROUP BY created_dt
)

SELECT
    metric AS "Metric",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 22 THEN val END) AS "T-22",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 23 THEN val END) AS "T-23",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 24 THEN val END) AS "T-24",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 25 THEN val END) AS "T-25",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 26 THEN val END) AS "T-26",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 27 THEN val END) AS "T-27",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 28 THEN val END) AS "T-28",
    MAX(CASE WHEN created_dt = CURRENT_DATE - 29 THEN val END) AS "T-29"
FROM (
    SELECT created_dt, '1. Resolved within 21 days %' AS metric,
           ROUND(100.0 * resolved / NULLIF(total, 0), 1) AS val FROM daily
    UNION ALL
    SELECT created_dt, '2.   ↳ Pickup Done %' AS metric,
           ROUND(100.0 * pickup_done / NULLIF(total, 0), 1) AS val FROM daily
    UNION ALL
    SELECT created_dt, '3.   ↳ Recharge Done %' AS metric,
           ROUND(100.0 * recharge_done / NULLIF(total, 0), 1) AS val FROM daily
    UNION ALL
    SELECT created_dt, '4. Lost Rate %' AS metric,
           ROUND(100.0 * lost / NULLIF(total, 0), 1) AS val FROM daily
) x
GROUP BY metric
ORDER BY metric
