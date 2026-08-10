WITH deduped AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY csp_id, snapshot_date
        ORDER BY _fivetran_start DESC
    ) AS rn
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
),
base AS (
    SELECT * FROM deduped WHERE rn = 1
),
latest_dt AS (
    SELECT MAX(snapshot_date) AS dt FROM base
),
rep_dates AS (
    SELECT DISTINCT snapshot_date FROM base WHERE DAY(snapshot_date) IN (1, 16)
    UNION
    SELECT dt FROM latest_dt
),
cycle_map AS (
    SELECT snapshot_date,
        CASE
            WHEN DAY(snapshot_date) = 16 THEN DATE_TRUNC('month', snapshot_date)
            WHEN DAY(snapshot_date) = 1  THEN DATEADD('day', 15, DATE_TRUNC('month', DATEADD('month', -1, snapshot_date)))
            WHEN DAY(snapshot_date) BETWEEN 2 AND 15 THEN DATE_TRUNC('month', snapshot_date)
            ELSE DATEADD('day', 15, DATE_TRUNC('month', snapshot_date))
        END AS cycle_start
    FROM rep_dates
),
cycle_numbered_raw AS (
    SELECT cycle_start,
        MAX(snapshot_date) AS cycle_date,
        CASE WHEN DAY(cycle_start) = 1
             THEN '1-15 ' || TO_CHAR(cycle_start, 'MON YY')
             ELSE '16-' || TO_CHAR(DAY(LAST_DAY(cycle_start))) || ' ' || TO_CHAR(cycle_start, 'MON YY')
        END AS cycle_label
    FROM cycle_map
    GROUP BY cycle_start
),
snap_all AS (
    SELECT csp_id, snapshot_date,
        CASE WHEN COMPOSITE_STATE = 'COMPLIANT' AND TIER_BAND = 'VG' THEN TRUE ELSE FALSE END AS is_good
    FROM base
),
cycle_numbered AS (
    SELECT cn.*,
        ROW_NUMBER() OVER (ORDER BY cn.cycle_start) AS cohort_num
    FROM cycle_numbered_raw cn
    WHERE EXISTS (
        SELECT 1 FROM snap_all s
        WHERE s.snapshot_date = cn.cycle_date AND s.is_good
    )
),
snap AS (
    SELECT csp_id, snapshot_date, is_good
    FROM snap_all
    WHERE snapshot_date IN (SELECT cycle_date FROM cycle_numbered)
),
-- total CSPs evaluated per cycle
total_csps AS (
    SELECT cn.cohort_num, COUNT(DISTINCT b.csp_id) AS total_evaluated
    FROM cycle_numbered cn
    JOIN base b ON b.snapshot_date = cn.cycle_date
    GROUP BY cn.cohort_num
),
cohorts AS (
    SELECT cn.cohort_num, cn.cycle_date AS cohort_date, cn.cycle_label, s.csp_id
    FROM cycle_numbered cn
    JOIN snap s ON s.snapshot_date = cn.cycle_date AND s.is_good
),
cohort_sizes AS (
    SELECT cohort_num, cohort_date, cycle_label, COUNT(*) AS cohort_size
    FROM cohorts GROUP BY cohort_num, cohort_date, cycle_label
),
retention_check AS (
    SELECT c.cohort_num, cn2.cohort_num - c.cohort_num AS cycles_later,
        COUNT(*) AS retained, cs.cohort_size
    FROM cohorts c
    JOIN snap s ON c.csp_id = s.csp_id AND s.is_good
    JOIN cycle_numbered cn2 ON s.snapshot_date = cn2.cycle_date AND cn2.cohort_num > c.cohort_num
    JOIN cohort_sizes cs ON cs.cohort_num = c.cohort_num
    GROUP BY c.cohort_num, cn2.cohort_num, cs.cohort_size
),
funnel_rows AS (
    -- Row: Bonus Cycle (label row)
    SELECT cohort_num, 0 AS row_num, cycle_label AS val FROM cycle_numbered

    UNION ALL
    -- Row: Total CSPs Evaluated
    SELECT t.cohort_num, 1, t.total_evaluated::VARCHAR FROM total_csps t

    UNION ALL
    -- Row: CSPs (Compliant + Very Good)
    SELECT cohort_num, 2, cohort_size::VARCHAR FROM cohort_sizes

    UNION ALL
    -- Rows: R1, R2, R3… retention
    SELECT cohort_num, cycles_later + 2, ROUND(100.0 * retained / cohort_size, 1) || '%'
    FROM retention_check
)
SELECT
    CASE row_num
        WHEN 0 THEN 'Bonus Cycle'
        WHEN 1 THEN 'Total CSPs Evaluated'
        WHEN 2 THEN 'CSPs (Compliant+VG)'
        ELSE 'R' || (row_num - 2)
    END AS "Metric",
    MAX(CASE WHEN cohort_num = 1 THEN val END) AS "C1",
    MAX(CASE WHEN cohort_num = 2 THEN val END) AS "C2",
    MAX(CASE WHEN cohort_num = 3 THEN val END) AS "C3",
    MAX(CASE WHEN cohort_num = 4 THEN val END) AS "C4",
    MAX(CASE WHEN cohort_num = 5 THEN val END) AS "C5",
    MAX(CASE WHEN cohort_num = 6 THEN val END) AS "C6",
    MAX(CASE WHEN cohort_num = 7 THEN val END) AS "C7",
    MAX(CASE WHEN cohort_num = 8 THEN val END) AS "C8"
FROM funnel_rows
GROUP BY row_num
ORDER BY row_num
