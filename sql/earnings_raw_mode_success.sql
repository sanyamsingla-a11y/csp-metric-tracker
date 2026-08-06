WITH rzp_latest AS (
    SELECT *
    FROM razorpayx
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY _created DESC) = 1
),
daily AS (
    SELECT
        r.mode,
        DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at))                     AS dt,
        SUM(CASE WHEN r.status = 'processed' THEN 1 ELSE 0 END)                    AS success_cnt,
        COUNT(*)                                                                     AS attempt_cnt
    FROM CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES wl
    LEFT JOIN rzp_latest r
        ON wl.payout_id = r.source_id
    WHERE
        wl.entry_type ILIKE '%withdrawal%'
        AND wl._fivetran_active
        AND r.status NOT IN ('processing', 'queued')
        AND DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at)) >= DATEADD(day, -30, CURRENT_DATE())
    GROUP BY 1, 2
),
unpivoted AS (
    SELECT mode, dt, 'Success Count'  AS metric, success_cnt AS val FROM daily
    UNION ALL
    SELECT mode, dt, 'Attempts Count' AS metric, attempt_cnt AS val FROM daily
)

SELECT
    mode                                                                             AS "Mode",
    metric                                                                           AS "Metric",

    MAX(CASE WHEN dt = DATEADD(day, -1, CURRENT_DATE()) THEN val END)               AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day, -2, CURRENT_DATE()) THEN val END)               AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day, -3, CURRENT_DATE()) THEN val END)               AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day, -4, CURRENT_DATE()) THEN val END)               AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day, -5, CURRENT_DATE()) THEN val END)               AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day, -6, CURRENT_DATE()) THEN val END)               AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day, -7, CURRENT_DATE()) THEN val END)               AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day, -8, CURRENT_DATE()) THEN val END)               AS "T-8",

    ROUND(AVG(val), 1)                                                               AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1)                       AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1)                       AS "30D P90"

FROM unpivoted
GROUP BY 1, 2
ORDER BY 1, CASE WHEN metric = 'Success Count' THEN 1 ELSE 2 END
