WITH

-- PUT created: count by date of PUT creation
nbrec_created_daily AS (
    SELECT
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.created_at)) AS dt,
        COUNT(*) AS val
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND CONVERT_TIMEZONE('Asia/Kolkata', n.created_at) >= CURRENT_DATE - 60
    GROUP BY 1
),

-- PUT closed (Pickup Done): state = COMPLETED
nbrec_completed_daily AS (
    SELECT
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at)) AS dt,
        COUNT(*) AS val
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND n.state = 'COMPLETED'
      AND CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at) >= CURRENT_DATE - 60
    GROUP BY 1
),

-- PUT closed (Recharge Done): state = CANCELLED, reason = DEVICE_RESCUED
nbrec_rescued_daily AS (
    SELECT
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at)) AS dt,
        COUNT(DISTINCT n.EXECUTION_CANDIDATE_ID) AS val
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND n.state = 'CANCELLED'
      AND n.reason_code = 'DEVICE_RESCUED'
      AND CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at) >= CURRENT_DATE - 60
    GROUP BY 1
),

-- Payout to CSP (Pickup Done): recovery amount from wallet ledger
completed_pickups AS (
    SELECT
        n.DEVICE_ID,
        n.updated_at AS completed_at,
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at)) AS dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND n.state = 'COMPLETED'
      AND n.reason_code = 'DEVICE_RECOVERED_VERIFIED'
      AND CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at) >= CURRENT_DATE - 60
),
payout_daily AS (
    SELECT
        cp.dt,
        SUM(COALESCE(ROUND(w.AMOUNT / 100, 0), 0)) AS val
    FROM completed_pickups cp
    LEFT JOIN PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
        ON w.ENTRY_TYPE IN ('RECOVERY_RETURN', 'RECOVERY_PICKUP')
       AND w._FIVETRAN_ACTIVE
       AND cp.DEVICE_ID = PARSE_JSON(w.REMARKS):"device_id"::STRING
       AND ABS(DATEDIFF(day, cp.completed_at, w.created_at)) <= 1
    GROUP BY 1
),

-- PUT closed (Device Lost): state = FAILED
nbrec_failed_daily AS (
    SELECT
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at)) AS dt,
        COUNT(DISTINCT n.EXECUTION_CANDIDATE_ID) AS val
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE
      AND n.state = 'FAILED'
      AND CONVERT_TIMEZONE('Asia/Kolkata', n.updated_at) >= CURRENT_DATE - 60
    GROUP BY 1
),

metrics AS (
    SELECT dt, 'PUT created'                 AS metric, val FROM nbrec_created_daily
    UNION ALL
    SELECT dt, 'PUT closed (Pickup Done)'    AS metric, val FROM nbrec_completed_daily
    UNION ALL
    SELECT dt, 'PUT closed (Recharge Done)'  AS metric, val FROM nbrec_rescued_daily
    UNION ALL
    SELECT dt, 'Payout to CSP (Pickup Done)' AS metric, val FROM payout_daily
    UNION ALL
    SELECT dt, 'PUT closed (Device Lost)'    AS metric, val FROM nbrec_failed_daily
)

SELECT
    metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1)                                               AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1)      AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1)      AS "30D P90"
FROM metrics
WHERE dt >= CURRENT_DATE - 30
GROUP BY metric
ORDER BY CASE metric
    WHEN 'PUT created'                 THEN 1
    WHEN 'PUT closed (Pickup Done)'    THEN 2
    WHEN 'PUT closed (Recharge Done)'  THEN 3
    WHEN 'PUT closed (Device Lost)'    THEN 4
    WHEN 'Payout to CSP (Pickup Done)' THEN 5
    ELSE 6
END
