WITH latest AS (
    SELECT MAX(snapshot_date) AS dt
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _fivetran_active
),
cycle_info AS (
    SELECT
        dt AS curr_dt,
        CASE
            WHEN DAY(dt) <= 15
                THEN DATE_TRUNC('month', dt)
            ELSE DATE_TRUNC('month', dt) + INTERVAL '15 days'
        END AS cycle_start,
        CASE
            WHEN DAY(dt) <= 15
                THEN '1-' || DAY(dt) || ' ' || TO_CHAR(dt, 'MON YY')
            ELSE '16-' || DAY(dt) || ' ' || TO_CHAR(dt, 'MON YY')
        END AS cycle_label,
        CASE
            WHEN DAY(dt) <= 15
                THEN '16-' || DAY(LAST_DAY(DATEADD('month', -1, dt))) || ' ' || TO_CHAR(DATEADD('month', -1, dt), 'MON YY')
            ELSE '1-15 ' || TO_CHAR(dt, 'MON YY')
        END AS benchmark_label
    FROM latest
),
prev AS (
    SELECT s.csp_id, s.COMPOSITE_STATE AS prev_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS s
    JOIN cycle_info ci ON s.snapshot_date = ci.cycle_start
    WHERE s._fivetran_active
      AND s.COMPOSITE_STATE IN ('COMPLIANT','AT_RISK','NON_COMPLIANT')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.csp_id ORDER BY s._fivetran_synced DESC) = 1
),
curr AS (
    SELECT s.csp_id, s.COMPOSITE_STATE AS curr_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS s
    JOIN cycle_info ci ON s.snapshot_date = ci.curr_dt
    WHERE s._fivetran_active
      AND s.COMPOSITE_STATE IN ('COMPLIANT','AT_RISK','NON_COMPLIANT')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY s.csp_id ORDER BY s._fivetran_synced DESC) = 1
),
paired AS (
    SELECT p.csp_id, p.prev_state, c.curr_state,
        CASE
            WHEN (p.prev_state IN ('AT_RISK','NON_COMPLIANT') AND c.curr_state = 'COMPLIANT')
              OR (p.prev_state = 'NON_COMPLIANT' AND c.curr_state = 'AT_RISK') THEN 1
            WHEN (p.prev_state = 'COMPLIANT' AND c.curr_state IN ('AT_RISK','NON_COMPLIANT'))
              OR (p.prev_state = 'AT_RISK' AND c.curr_state = 'NON_COMPLIANT') THEN -1
            ELSE 0
        END AS nqs_points
    FROM prev p
    JOIN curr c ON p.csp_id = c.csp_id
)
SELECT
    ci.cycle_label AS cycle,
    ci.benchmark_label AS benchmark_cycle,
    COUNT(*) AS total_csps_paired,
    SUM(CASE WHEN nqs_points = 1 THEN 1 ELSE 0 END) AS improved_csps,
    SUM(CASE WHEN nqs_points = -1 THEN 1 ELSE 0 END) AS decreased_csps,
    SUM(CASE WHEN nqs_points = 0 THEN 1 ELSE 0 END) AS same_state,
    SUM(nqs_points) AS NQS
FROM paired, cycle_info ci
GROUP BY ci.cycle_label, ci.benchmark_label, ci.cycle_start, ci.curr_dt
