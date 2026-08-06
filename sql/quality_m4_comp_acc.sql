WITH

dms_30d AS (
    SELECT
        CSP_ID,
        DATE(SNAPSHOT_DATE)   AS dt,
        AVG_RATING_COUNT      AS dms_count,
        TRUNC(AVG_RATING, 2)  AS dms_avg,
        AVG_RATING_STATE      AS dms_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND CSP_ID NOT IN ('a0a0b1', 'a0a6w1', 'a0a0m0')
      AND DATE(SNAPSHOT_DATE) >= CURRENT_DATE - 30
),

ref_max AS (
    SELECT MAX(csps_on_day) AS max_csps
    FROM (
        SELECT dt, COUNT(DISTINCT CSP_ID) AS csps_on_day
        FROM dms_30d
        GROUP BY dt
    )
),

crr_windowed AS (
    SELECT
        d.CSP_ID,
        d.dt               AS snapshot_dt,
        c.RATING,
        ROW_NUMBER() OVER (
            PARTITION BY d.CSP_ID, d.dt
            ORDER BY c.SUBMITTED_AT DESC
        )                  AS rn
    FROM dms_30d d
    JOIN PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.CUSTOMER_RATING_RECORDS c
        ON  c.CSP_ID           = d.CSP_ID
        AND c._FIVETRAN_ACTIVE = TRUE
        AND c.RATING BETWEEN 1 AND 5
        AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.SUBMITTED_AT))
            BETWEEN DATEADD('year', -1, d.dt) AND d.dt
),

crr_per_snapshot AS (
    SELECT
        CSP_ID,
        snapshot_dt,
        COUNT(*)                     AS crr_count,
        TRUNC(AVG(RATING::FLOAT), 2) AS crr_avg
    FROM crr_windowed
    WHERE rn <= 500
    GROUP BY CSP_ID, snapshot_dt
),

daily_metrics AS (
    SELECT
        d.dt,
        ROUND(100.0 * COUNT(DISTINCT d.CSP_ID)
              / NULLIF(ref.max_csps, 0), 1)                             AS c1,
        ROUND(100.0 *
            COUNT(CASE WHEN ABS(d.dms_count - COALESCE(c.crr_count, 0)) <= 3
                       THEN 1 END)
            / NULLIF(COUNT(*), 0), 1)                                   AS a1,
        ROUND(100.0 *
            COUNT(CASE WHEN d.dms_count >= 25
                            AND COALESCE(d.dms_avg, 0) = COALESCE(c.crr_avg, 0)
                       THEN 1 END)
            / NULLIF(COUNT(CASE WHEN d.dms_count >= 25 THEN 1 END), 0), 1) AS a2,
        ROUND(100.0 *
            COUNT(CASE
                WHEN d.dms_state =
                    CASE
                        WHEN COALESCE(c.crr_count, 0) < 25 THEN 'INSUFFICIENT_DATA'
                        WHEN c.crr_avg >= 4.3              THEN 'PASS'
                        ELSE                                    'FAIL'
                    END
                THEN 1 END)
            / NULLIF(COUNT(*), 0), 1)                                   AS a3
    FROM dms_30d d
    CROSS JOIN ref_max ref
    LEFT JOIN crr_per_snapshot c ON d.CSP_ID = c.CSP_ID AND d.dt = c.snapshot_dt
    GROUP BY d.dt, ref.max_csps
),

unpivoted AS (
    SELECT dt, 'C1: M4 CRR→DMS Coverage %'     AS metric, 1 AS sort_key, c1 AS val FROM daily_metrics UNION ALL
    SELECT dt, 'A1: AVG_RATING_COUNT Match %'   AS metric, 2,            a1        FROM daily_metrics UNION ALL
    SELECT dt, 'A2: AVG_RATING Match %'         AS metric, 3,            a2        FROM daily_metrics UNION ALL
    SELECT dt, 'A3: AVG_RATING_STATE Correct %' AS metric, 4,            a3        FROM daily_metrics
)

SELECT
    metric                                                       AS "Metric",
    MAX(CASE WHEN dt = CURRENT_DATE - 1 THEN val END)           AS "T-1",
    MAX(CASE WHEN dt = CURRENT_DATE - 2 THEN val END)           AS "T-2",
    MAX(CASE WHEN dt = CURRENT_DATE - 3 THEN val END)           AS "T-3",
    MAX(CASE WHEN dt = CURRENT_DATE - 4 THEN val END)           AS "T-4",
    MAX(CASE WHEN dt = CURRENT_DATE - 5 THEN val END)           AS "T-5",
    MAX(CASE WHEN dt = CURRENT_DATE - 6 THEN val END)           AS "T-6",
    MAX(CASE WHEN dt = CURRENT_DATE - 7 THEN val END)           AS "T-7",
    MAX(CASE WHEN dt = CURRENT_DATE - 8 THEN val END)           AS "T-8",
    ROUND(AVG(val), 1)                                          AS "30D Avg",
    ROUND(MEDIAN(val), 1)                                       AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "30D P90"
FROM unpivoted
GROUP BY sort_key, metric
ORDER BY sort_key
