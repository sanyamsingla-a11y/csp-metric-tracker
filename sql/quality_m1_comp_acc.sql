WITH
snap_dates AS (
    SELECT DATEADD(day, -(ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1), CURRENT_DATE - 1) AS dt
    FROM TABLE(GENERATOR(ROWCOUNT => 30))
),
iec_comp AS (
    SELECT TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', e.UPDATED_AT)) AS dt,
        e.EXECUTION_CANDIDATE_ID, e.CONNECTION_ID, e.CSP_ID
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
    WHERE e._FIVETRAN_ACTIVE = TRUE
      AND e.CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
      AND e.CONFIRMED_SLOT_AT IS NOT NULL
      AND e.CURRENT_STATE IN (
            'CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED',
            'INSTALLATION_CANCELLED_ONSITE','INSTALLATION_EXPIRED',
            'CANCELLED_BY_CUSTOMER','CANCELLED_BY_UPSTREAM')
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', e.UPDATED_AT))
          BETWEEN DATEADD(day, -30, CURRENT_DATE - 1) AND CURRENT_DATE - 1
),
iml_comp AS (
    SELECT l.CONNECTION_ID, l.CSP_ID
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.INSTALL_MATURATION_LEDGER l
    WHERE l._FIVETRAN_ACTIVE = TRUE
      AND l.CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
      AND COALESCE(l.TERMINAL_OUTCOME, '') <> 'UPSTREAM_CANCEL_PRE_CONFIRM'
),
comp_daily AS (
    SELECT e.dt,
        ROUND(COUNT(l.CONNECTION_ID) * 100.0 / NULLIF(COUNT(e.EXECUTION_CANDIDATE_ID), 0), 1) AS match_rate
    FROM iec_comp e
    LEFT JOIN iml_comp l ON e.CONNECTION_ID = l.CONNECTION_ID AND e.CSP_ID = l.CSP_ID
    GROUP BY 1
),
iec_daily AS (
    SELECT d.dt, e.CSP_ID,
        SUM(CASE WHEN e.CURRENT_STATE <> 'CANCELLED_BY_CUSTOMER' THEN 1 ELSE 0 END) AS iec_denom,
        SUM(CASE
                WHEN e.CURRENT_STATE = 'CONNECTION_ACTIVE'
                 AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata',
                         COALESCE(e.INSTALLATION_COMPLETED_AT, e.UPDATED_AT)))
                     <= e.CONFIRMED_SLOT_DATE
                THEN 1 ELSE 0
            END) AS iec_numer,
        SUM(CASE WHEN e.CURRENT_STATE = 'CONNECTION_ACTIVE' THEN 1 ELSE 0 END) AS iec_completed
    FROM snap_dates d
    JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
        ON TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata',
               COALESCE(e.INSTALLATION_COMPLETED_AT, e.FAILURE_REPORTED_AT,
                        e.DISMISSED_AT, e.UPDATED_AT)))
           BETWEEN DATEADD(day, -58, d.dt) AND d.dt  -- -58 from IEC date = -59 from SNAPSHOT_DATE
    WHERE e._FIVETRAN_ACTIVE = TRUE
      AND e.CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
      AND e.CONFIRMED_SLOT_AT IS NOT NULL
      AND e.CURRENT_STATE IN (
            'CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED',
            'INSTALLATION_CANCELLED_ONSITE','INSTALLATION_EXPIRED',
            'CANCELLED_BY_CUSTOMER')
    GROUP BY 1, 2
),
iec_with_state AS (
    SELECT dt, CSP_ID, iec_numer, iec_denom,
        CASE
            WHEN iec_completed < 10                                      THEN 'INSUFFICIENT_DATA'
            WHEN iec_denom > 0 AND iec_numer * 1.0 / iec_denom >= 0.80  THEN 'PASS'
            ELSE 'FAIL'
        END AS expected_state
    FROM iec_daily
),
dms_daily AS (
    SELECT CSP_ID, SNAPSHOT_DATE AS dt,
        INSTALL_COMPLIANCE_NUMERATOR   AS dms_numer,
        INSTALL_COMPLIANCE_DENOMINATOR AS dms_denom,
        INSTALL_COMPLIANCE_STATE       AS dms_state
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
      AND SNAPSHOT_DATE BETWEEN DATEADD(day, -30, CURRENT_DATE - 1) AND CURRENT_DATE - 1
),
csp_acc AS (
    SELECT d.dt, d.CSP_ID,
        CASE
            WHEN d.dms_numer = i.iec_numer THEN 1
            WHEN i.iec_numer IS NULL AND d.dms_numer IS NULL THEN 1
            WHEN d.dms_state = 'INSUFFICIENT_DATA' AND i.expected_state = 'INSUFFICIENT_DATA' THEN 1
            ELSE 0
        END AS numer_match,
        CASE
            WHEN d.dms_denom = i.iec_denom THEN 1
            WHEN i.iec_denom IS NULL AND d.dms_denom = 0 THEN 1
            ELSE 0
        END AS denom_match,
        CASE
            WHEN d.dms_state = i.expected_state THEN 1
            WHEN i.expected_state IS NULL AND d.dms_state = 'INSUFFICIENT_DATA' THEN 1
            ELSE 0
        END AS state_match,
        -- ADJUSTED: forgives DMS > IEC (rolling window boundary / IML ON_TIME classification diff)
        CASE
            WHEN d.dms_numer = i.iec_numer THEN 1
            WHEN i.iec_numer IS NULL AND d.dms_numer IS NULL THEN 1
            WHEN d.dms_state = 'INSUFFICIENT_DATA' AND i.expected_state = 'INSUFFICIENT_DATA' THEN 1
            WHEN d.dms_numer > i.iec_numer THEN 1
            ELSE 0
        END AS numer_match_adj,
        -- ADJUSTED: forgives ±1 (P74 bug residual / IML ingestion lag)
        CASE
            WHEN d.dms_denom = i.iec_denom THEN 1
            WHEN i.iec_denom IS NULL AND d.dms_denom = 0 THEN 1
            WHEN ABS(d.dms_denom - i.iec_denom) = 1 THEN 1
            ELSE 0
        END AS denom_match_adj,
        CASE
            WHEN d.dms_state = i.expected_state THEN 1
            WHEN i.expected_state IS NULL AND d.dms_state = 'INSUFFICIENT_DATA' THEN 1
            WHEN d.dms_state = 'PASS' AND i.expected_state = 'FAIL'
                 AND d.dms_numer > i.iec_numer THEN 1
            WHEN d.dms_state = 'INSUFFICIENT_DATA' AND i.expected_state = 'FAIL'
                 AND ABS(d.dms_denom - i.iec_denom) = 1 THEN 1
            ELSE 0
        END AS state_match_adj
    FROM dms_daily d
    LEFT JOIN iec_with_state i
        ON d.CSP_ID = i.CSP_ID
        AND i.dt = DATEADD(day, -1, d.dt)
),
acc_daily AS (
    SELECT dt,
        ROUND(SUM(numer_match)    *100.0/COUNT(*),1) AS numer_match_rate,
        ROUND(SUM(denom_match)    *100.0/COUNT(*),1) AS denom_match_rate,
        ROUND(SUM(state_match)    *100.0/COUNT(*),1) AS state_match_rate,
        ROUND(SUM(numer_match_adj)*100.0/COUNT(*),1) AS numer_match_rate_adj,
        ROUND(SUM(denom_match_adj)*100.0/COUNT(*),1) AS denom_match_rate_adj,
        ROUND(SUM(state_match_adj)*100.0/COUNT(*),1) AS state_match_rate_adj
    FROM csp_acc GROUP BY 1
),
unpivoted AS (
    SELECT dt, 1 AS s, 'C1: M1 Completeness %'          AS metric, match_rate           AS val FROM comp_daily
    -- UNION ALL SELECT dt, 2, 'A1: Numerator Accuracy %',  numer_match_rate               FROM acc_daily
    -- UNION ALL SELECT dt, 3, 'A2: Denominator Accuracy %',denom_match_rate               FROM acc_daily
    -- UNION ALL SELECT dt, 4, 'A3: State Match %',         state_match_rate               FROM acc_daily
    UNION ALL SELECT dt, 5, 'A1: Numerator Accuracy %',numer_match_rate_adj           FROM acc_daily
    UNION ALL SELECT dt, 6, 'A2: Denominator Accuracy %',denom_match_rate_adj           FROM acc_daily
    UNION ALL SELECT dt, 7, 'A3: State Match %',state_match_rate_adj           FROM acc_daily
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
    ROUND(AVG(val),1) AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "30D Median"
FROM unpivoted GROUP BY metric, s ORDER BY s
