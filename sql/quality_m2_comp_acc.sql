WITH

m2_eligible AS (
    SELECT
        c.COMPLAINT_ID,
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.INTAKE_TIMESTAMP)) AS intake_date
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS c
    WHERE c._FIVETRAN_ACTIVE = TRUE
      AND c.CSP_ID IS NOT NULL
      AND (
          (c.PRIMARY_CLASS = 'SERVICE_ISSUE' AND c.SECONDARY_SUBTYPE IN (
              'NO_INTERNET','RECHARGE_DONE_NO_INTERNET','SLOW_INTERNET',
              'FREQUENT_DISCONNECTION','OPTICAL_POWER_OUT_OF_RANGE'))
          OR
          (c.PRIMARY_CLASS = 'INSTALLATION_DEFECT' AND c.SECONDARY_SUBTYPE IN (
              'INCOMPLETE_INSTALLATION','POOR_SIGNAL_QUALITY'))
      )
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.INTAKE_TIMESTAMP))
          BETWEEN DATEADD(day,-29, CURRENT_DATE()-1) AND CURRENT_DATE()-1
),

ledger AS (
    SELECT COMPLAINT_ID
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.COMPLAINT_RESOLUTION_LEDGER
    WHERE _FIVETRAN_ACTIVE = TRUE
),

m2_completeness AS (
    SELECT
        e.intake_date AS dt,
        ROUND(100.0 * COUNT(DISTINCT l.COMPLAINT_ID)
              / NULLIF(COUNT(DISTINCT e.COMPLAINT_ID), 0), 1) AS val
    FROM m2_eligible e
    LEFT JOIN ledger l ON e.COMPLAINT_ID = l.COMPLAINT_ID
    GROUP BY 1
),

complaints_base AS (
    SELECT
        c.COMPLAINT_ID, c.CSP_ID,
        c.INTAKE_TIMESTAMP, c.RESOLVED_AT,
        c.SLA_AT, c.WITHIN_TAT
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS c
    WHERE c._FIVETRAN_ACTIVE = TRUE
      AND c.CSP_ID IS NOT NULL
      AND c.INTAKE_TIMESTAMP >= DATEADD(day,-90, CURRENT_DATE())
      AND (
          (c.PRIMARY_CLASS = 'SERVICE_ISSUE' AND c.SECONDARY_SUBTYPE IN (
              'NO_INTERNET','RECHARGE_DONE_NO_INTERNET','SLOW_INTERNET',
              'FREQUENT_DISCONNECTION','OPTICAL_POWER_OUT_OF_RANGE'))
          OR
          (c.PRIMARY_CLASS = 'INSTALLATION_DEFECT' AND c.SECONDARY_SUBTYPE IN (
              'INCOMPLETE_INSTALLATION','POOR_SIGNAL_QUALITY'))
      )
),

snapshots AS (
    SELECT
        CSP_ID, SNAPSHOT_DATE,
        RESOLUTION_TIMELINESS_NUMERATOR   AS snap_m2_num,
        RESOLUTION_TIMELINESS_DENOMINATOR AS snap_m2_denom,
        RESOLUTION_TIMELINESS_STATE       AS snap_m2_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND IS_CYCLE_CLOSE = FALSE
      AND SNAPSHOT_DATE BETWEEN DATEADD(day,-30, CURRENT_DATE-1) AND CURRENT_DATE-1
),

computed_per_csp_day AS (
    SELECT
        s.CSP_ID, s.SNAPSHOT_DATE,
        COUNT(DISTINCT CASE
            WHEN c.RESOLVED_AT IS NOT NULL
             AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.RESOLVED_AT))
                 BETWEEN DATEADD(day,-59, s.SNAPSHOT_DATE) AND s.SNAPSHOT_DATE
             AND c.WITHIN_TAT = 1
            THEN c.COMPLAINT_ID END) AS calc_m2_num,
        COUNT(DISTINCT CASE
            WHEN c.RESOLVED_AT IS NOT NULL
             AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.RESOLVED_AT))
                 BETWEEN DATEADD(day,-59, s.SNAPSHOT_DATE) AND s.SNAPSHOT_DATE
            THEN c.COMPLAINT_ID END) AS calc_m2_denom
    FROM snapshots s
    LEFT JOIN complaints_base c ON c.CSP_ID = s.CSP_ID
    GROUP BY s.CSP_ID, s.SNAPSHOT_DATE
),

with_states AS (
    SELECT
        cpd.CSP_ID, cpd.SNAPSHOT_DATE,
        cpd.calc_m2_num, cpd.calc_m2_denom,
        CASE
            WHEN cpd.calc_m2_denom < 10                                THEN 'INSUFFICIENT_DATA'
            WHEN 1.0 * cpd.calc_m2_num / cpd.calc_m2_denom >= 0.8     THEN 'PASS'
            ELSE 'FAIL'
        END AS calc_m2_state,
        s.snap_m2_num, s.snap_m2_denom, s.snap_m2_state
    FROM computed_per_csp_day cpd
    JOIN snapshots s ON cpd.CSP_ID = s.CSP_ID AND cpd.SNAPSHOT_DATE = s.SNAPSHOT_DATE
),

accuracy_per_day AS (
    SELECT
        SNAPSHOT_DATE AS dt,
        ROUND(100.0 * COUNT(CASE WHEN calc_m2_num   = snap_m2_num   THEN 1 END) / COUNT(*), 1) AS m2_num_match_pct,
        ROUND(100.0 * COUNT(CASE WHEN calc_m2_denom = snap_m2_denom THEN 1 END) / COUNT(*), 1) AS m2_denom_match_pct,
        ROUND(100.0 * COUNT(CASE WHEN calc_m2_state = snap_m2_state THEN 1 END) / COUNT(*), 1) AS m2_state_match_pct
    FROM with_states
    GROUP BY SNAPSHOT_DATE
),

unpivoted AS (
    SELECT dt, 1 AS s, 'C1: M2 Completeness % (eligible complaints -> ledger)'    AS metric, val               FROM m2_completeness UNION ALL
    SELECT dt, 2,      'A1: M2 Numerator match % (computed vs snapshot)',          m2_num_match_pct             FROM accuracy_per_day UNION ALL
    SELECT dt, 3,      'A2: M2 Denominator match % (computed vs snapshot)',        m2_denom_match_pct           FROM accuracy_per_day UNION ALL
    SELECT dt, 4,      'A3: M2 State match % (computed state vs snapshot state)',  m2_state_match_pct           FROM accuracy_per_day
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
    ROUND(AVG(val),1)                                                AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1)       AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1)       AS "30D P90"
FROM unpivoted
GROUP BY metric, s
ORDER BY s
