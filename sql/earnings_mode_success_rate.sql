WITH rzp_latest AS (
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
        DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at))                     AS dt,
        SUM(CASE WHEN r.status = 'processed' THEN 1 ELSE 0 END)                    AS success_cnt,
        COUNT(*)                                                                     AS attempt_cnt,
        ROUND(
            100.0
            * SUM(CASE WHEN r.status = 'processed' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0),
        1)                                                                           AS val
    FROM CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES wl
    LEFT JOIN rzp_latest r
        ON wl.payout_id = r.source_id
    WHERE
        wl.entry_type ILIKE '%withdrawal%'
        AND wl._fivetran_active
        AND r.status NOT IN ('processing', 'queued')
        AND DATE(CONVERT_TIMEZONE('Asia/Calcutta', wl.created_at)) >= DATEADD(day, -30, CURRENT_DATE())
    GROUP BY 1, 2
)

SELECT
    CASE mode
        WHEN 'IMPS' THEN 'IMPS_Success_Rate'
        WHEN 'NEFT' THEN 'NEFT_Success_Rate'
        ELSE mode
    END                                                                              AS metric,

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

FROM daily
GROUP BY mode
ORDER BY 1
