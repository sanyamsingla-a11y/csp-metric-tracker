WITH

-- ── C1: M3 Completeness (expected breaches → ledger) ─────────────────────────
-- Anchor: breach_date = TO_DATE(intake+48h IST)
-- Eligible breach = 48h mark has passed AND ticket was open at that mark
m3_eligible AS (
    SELECT
        c.COMPLAINT_ID,
        CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP)) AS breach_ts_ist,
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP))) AS breach_date,
        c.RESOLVED_AT
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
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP)))
          BETWEEN DATEADD(day,-29, CURRENT_DATE()-1) AND CURRENT_DATE()-1
      AND CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP))
          < CONVERT_TIMEZONE('Asia/Kolkata', CURRENT_TIMESTAMP)
),

ledger AS (
    SELECT COMPLAINT_ID, BREACHED_OPEN_AT
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.COMPLAINT_RESOLUTION_LEDGER
    WHERE _FIVETRAN_ACTIVE = TRUE
),

m3_completeness AS (
    SELECT
        e.breach_date AS dt,
        ROUND(100.0 * COUNT(DISTINCT l.COMPLAINT_ID)
              / NULLIF(COUNT(DISTINCT e.COMPLAINT_ID), 0), 1) AS val
    FROM m3_eligible e
    LEFT JOIN ledger l
           ON e.COMPLAINT_ID = l.COMPLAINT_ID AND l.BREACHED_OPEN_AT IS NOT NULL
    WHERE e.RESOLVED_AT IS NULL
       OR CONVERT_TIMEZONE('Asia/Kolkata', e.RESOLVED_AT) > e.breach_ts_ist
    GROUP BY 1
),

-- ── A1–A3: M3 Accuracy (computed vs snapshot) ────────────────────────────────
complaints_base AS (
    SELECT
        c.COMPLAINT_ID, c.CSP_ID,
        c.INTAKE_TIMESTAMP, c.RESOLVED_AT, c.STATUS
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
        LONG_OPEN_BREACH_COUNT AS snap_m3_breach,
        LONG_OPEN_TICKET_COUNT AS snap_m3_tickets,
        LONG_OPEN_STATE        AS snap_m3_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND IS_CYCLE_CLOSE = FALSE
      AND SNAPSHOT_DATE BETWEEN DATEADD(day,-30, CURRENT_DATE-1) AND CURRENT_DATE-1
),

computed_per_csp_day AS (
    SELECT
        s.CSP_ID,
        s.SNAPSHOT_DATE,
        -- FIX 1: both tickets and breaches anchor on intake_date (same as DMS)
        COUNT(DISTINCT CASE
            WHEN TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.INTAKE_TIMESTAMP))
                 BETWEEN DATEADD(day,-14, s.SNAPSHOT_DATE) AND s.SNAPSHOT_DATE
            THEN c.COMPLAINT_ID END)                                          AS calc_m3_tickets,

        COUNT(DISTINCT CASE
            WHEN TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.INTAKE_TIMESTAMP))
                 BETWEEN DATEADD(day,-14, s.SNAPSHOT_DATE) AND s.SNAPSHOT_DATE
             -- FIX 2: breach date must have arrived by snapshot date (not CURRENT_TIMESTAMP)
             AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP)))
                 <= s.SNAPSHOT_DATE
             AND (
                 -- resolved after 48h mark
                 (c.RESOLVED_AT IS NOT NULL
                  AND CONVERT_TIMEZONE('Asia/Kolkata', c.RESOLVED_AT)
                      > CONVERT_TIMEZONE('Asia/Kolkata', DATEADD(hour,48, c.INTAKE_TIMESTAMP)))
                 OR
                 -- FIX 3: unresolved with status filter matching canonical spec
                 (c.RESOLVED_AT IS NULL
                  AND c.STATUS IN ('INTAKE','ASSIGNED'))
             )
            THEN c.COMPLAINT_ID END)                                          AS calc_m3_breach
    FROM snapshots s
    LEFT JOIN complaints_base c ON c.CSP_ID = s.CSP_ID
    GROUP BY s.CSP_ID, s.SNAPSHOT_DATE
),

with_states AS (
    SELECT
        cpd.CSP_ID, cpd.SNAPSHOT_DATE,
        cpd.calc_m3_breach, cpd.calc_m3_tickets,
        CASE
            WHEN cpd.calc_m3_tickets < 10 THEN 'INSUFFICIENT_DATA'
            WHEN cpd.calc_m3_breach  <= 2 THEN 'PASS'
            ELSE 'FAIL'
        END AS calc_m3_state,
        s.snap_m3_breach, s.snap_m3_tickets, s.snap_m3_state
    FROM computed_per_csp_day cpd
    JOIN snapshots s ON cpd.CSP_ID = s.CSP_ID AND cpd.SNAPSHOT_DATE = s.SNAPSHOT_DATE
),

accuracy_per_day AS (
    SELECT
        SNAPSHOT_DATE AS dt,
        ROUND(100.0 * COUNT(CASE WHEN calc_m3_breach  = snap_m3_breach  THEN 1 END) / COUNT(*), 1) AS m3_breach_match_pct,
        ROUND(100.0 * COUNT(CASE WHEN calc_m3_tickets = snap_m3_tickets THEN 1 END) / COUNT(*), 1) AS m3_ticket_match_pct,
        ROUND(100.0 * COUNT(CASE WHEN calc_m3_state   = snap_m3_state   THEN 1 END) / COUNT(*), 1) AS m3_state_match_pct
    FROM with_states
    GROUP BY SNAPSHOT_DATE
),

unpivoted AS (
    SELECT dt, 1 AS s, 'C1: M3 Completeness % (expected breaches -> ledger)'     AS metric, val                FROM m3_completeness  UNION ALL
    SELECT dt, 2,      'A1: M3 Breach count match % (computed vs snapshot)',      m3_breach_match_pct           FROM accuracy_per_day UNION ALL
    SELECT dt, 3,      'A2: M3 Ticket count match % (computed vs snapshot)',      m3_ticket_match_pct           FROM accuracy_per_day UNION ALL
    SELECT dt, 4,      'A3: M3 State match % (computed state vs snapshot state)', m3_state_match_pct            FROM accuracy_per_day
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
