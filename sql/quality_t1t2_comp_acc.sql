WITH

snap_dates AS (
    SELECT DATEADD(day, -seq, CURRENT_DATE() - 1) AS snap_date
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS seq FROM TABLE(GENERATOR(ROWCOUNT => 30)))
),

csp_map AS (
    SELECT DISTINCT PARTNER_ID, csp_id
    FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _fivetran_active
),

-- ── T1 SOURCE ──
t1_hourly_raw AS (
    SELECT
        h.DEVICE_ID, c.csp_id,
        h.DATE_IST::DATE         AS signal_date,
        h.TOTAL_PINGS_RECEIVED   AS hour_pings,
        h.OPTICAL_IN_RANGE_PINGS AS in_range_pings
    FROM PROD_DB.PUBLIC.HOURLY_DEVICE_PING_INFLUX h
    INNER JOIN csp_map c ON h.PARTNER_ID = c.PARTNER_ID
    WHERE (UPPER(h.DEVICE_ID) LIKE 'GX%' OR UPPER(h.DEVICE_ID) LIKE 'SY%')
      AND UPPER(h.DEVICE_ID) NOT LIKE 'PNM%'
      AND h.DATE_IST::DATE BETWEEN DATEADD(day,-48,CURRENT_DATE()) AND CURRENT_DATE()-1
),

t1_conn_day AS (
    SELECT csp_id, DEVICE_ID, signal_date,
        SUM(hour_pings)     AS daily_pings,
        SUM(in_range_pings) AS daily_in_range
    FROM t1_hourly_raw GROUP BY 1,2,3
),

t1_eval AS (
    SELECT csp_id, DEVICE_ID, signal_date,
        CASE WHEN daily_pings >= 60 THEN 1 ELSE 0 END AS is_evaluated,
        CASE WHEN daily_pings >= 60 AND daily_in_range >= 0.95*daily_pings THEN 1 ELSE 0 END AS is_happy
    FROM t1_conn_day
),

t1_source_daily AS (
    SELECT signal_date, COUNT(DISTINCT csp_id) AS source_t1_csps FROM t1_conn_day GROUP BY 1
),

t1_15d AS (
    SELECT sd.snap_date, e.csp_id,
        SUM(e.is_evaluated) AS eval_days,
        SUM(e.is_happy)     AS happy_days,
        ROUND(100.0*SUM(e.is_happy)/NULLIF(SUM(e.is_evaluated),0),1) AS t1_happy_pct
    FROM snap_dates sd
    JOIN t1_eval e ON e.signal_date >= DATEADD(day,-15,sd.snap_date) AND e.signal_date < sd.snap_date
    GROUP BY sd.snap_date, e.csp_id
),

t1_ont_15d AS (
    SELECT sd.snap_date, e.csp_id, COUNT(DISTINCT e.DEVICE_ID) AS active_ont_count
    FROM snap_dates sd
    JOIN t1_eval e ON e.signal_date >= DATEADD(day,-15,sd.snap_date) AND e.signal_date < sd.snap_date
    GROUP BY sd.snap_date, e.csp_id
),

-- ── T2 SOURCE ──
t2_device AS (
    SELECT DEVICE_ID, lco_account_id::TEXT AS partnerid
    FROM PROD_DB.PUBLIC.T_DEVICE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY long_nas_id ORDER BY modified_time DESC) = 1
),

t2_raw AS (
    SELECT
        rl.deviceid        AS device_id,
        rl.tested_on::DATE AS test_date,
        CASE
            WHEN (UPPER(rl.deviceid) LIKE 'GX%' OR UPPER(rl.deviceid) LIKE 'SY%') AND rl.speed >= 80 THEN 1
            WHEN UPPER(rl.deviceid) NOT LIKE 'GX%' AND UPPER(rl.deviceid) NOT LIKE 'SY%' AND rl.speed >= 63 THEN 1
            ELSE 0
        END AS is_passing
    FROM PROD_DB.DBT.DAILY_SPEED_TEST rl
    WHERE rl.version_name = 'speed_test_result_v3'
      AND rl.tested_on::DATE BETWEEN DATEADD(day,-48,CURRENT_DATE()) AND CURRENT_DATE()-1
      AND HOUR(rl.tested_on) BETWEEN 18 AND 23
      AND UPPER(rl.deviceid) NOT LIKE 'PNM%'
      AND rl.speed IS NOT NULL
),

t2_with_csp AS (
    SELECT t.device_id, t.test_date, t.is_passing, a.csp_id
    FROM t2_raw t
    LEFT JOIN t2_device d ON t.device_id = d.DEVICE_ID
    LEFT JOIN PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT a
           ON d.partnerid = a.partner_id::TEXT AND a._fivetran_active
    WHERE a.csp_id IS NOT NULL
),

t2_source_daily AS (
    SELECT test_date, COUNT(DISTINCT csp_id) AS source_t2_csps FROM t2_with_csp GROUP BY 1
),

t2_15d AS (
    SELECT sd.snap_date, t.csp_id,
        COUNT(*) AS total_tests, SUM(t.is_passing) AS passing_tests,
        ROUND(100.0*SUM(t.is_passing)/NULLIF(COUNT(*),0),1) AS t2_speed_ok_pct
    FROM snap_dates sd
    JOIN t2_with_csp t ON t.test_date >= DATEADD(day,-15,sd.snap_date) AND t.test_date < sd.snap_date
    GROUP BY sd.snap_date, t.csp_id
),

-- ── ROLLUP + DMS ──
rollup_actual AS (
    SELECT SIGNAL_DATE,
        COUNT(DISTINCT CASE WHEN OPTICAL_DENOMINATOR > 0 THEN CSP_ID END) AS rollup_t1_csps,
        COUNT(DISTINCT CASE WHEN SPEED_DENOMINATOR   > 0 THEN CSP_ID END) AS rollup_t2_csps
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.TELEMETRY_ROLLUP_RECORDS
    WHERE _FIVETRAN_ACTIVE = TRUE AND SIGNAL_DATE >= DATEADD(day,-35,CURRENT_DATE())
    GROUP BY 1
),

dms_base AS (
    SELECT CSP_ID, SNAPSHOT_DATE, T1_OOR_RATE, T2_SPEED_OK_RATE, COMPOSITE_STATE, TIER_BAND
    FROM PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE.DAILY_METRIC_SNAPSHOTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND SNAPSHOT_DATE >= DATEADD(day,-35,CURRENT_DATE())
),

-- ── ACCURACY + TIER ──
accuracy_per_csp AS (
    SELECT d.SNAPSHOT_DATE AS snap_date, d.CSP_ID,
        d.T1_OOR_RATE, d.T2_SPEED_OK_RATE, d.COMPOSITE_STATE, d.TIER_BAND,
        CASE
            WHEN COALESCE(ont.active_ont_count,0) < 20 THEN 'NOT_APPLICABLE'
            WHEN COALESCE(t1.eval_days,0) < 15          THEN 'INSUFFICIENT'
            WHEN t1.t1_happy_pct >= 95                   THEN 'VERY_GOOD'
            WHEN t1.t1_happy_pct >= 90                   THEN 'GOOD'
            ELSE 'BASE'
        END AS t1_src_verdict,
        CASE
            WHEN COALESCE(t2.total_tests,0) < 20 THEN 'INSUFFICIENT'
            WHEN t2.t2_speed_ok_pct >= 95        THEN 'VERY_GOOD'
            WHEN t2.t2_speed_ok_pct >= 90        THEN 'GOOD'
            ELSE 'BASE'
        END AS t2_src_verdict,
        CASE WHEN t1.t1_happy_pct IS NOT NULL AND d.T1_OOR_RATE IS NOT NULL
              AND ABS(t1.t1_happy_pct - d.T1_OOR_RATE) <= 1.0 THEN 1 ELSE 0 END AS t1_match,
        CASE WHEN t2.t2_speed_ok_pct IS NOT NULL AND d.T2_SPEED_OK_RATE IS NOT NULL
              AND ABS(t2.t2_speed_ok_pct - d.T2_SPEED_OK_RATE) <= 1.0 THEN 1 ELSE 0 END AS t2_match
    FROM dms_base d
    LEFT JOIN t1_15d     t1  ON t1.snap_date  = d.SNAPSHOT_DATE AND t1.csp_id  = d.CSP_ID
    LEFT JOIN t2_15d     t2  ON t2.snap_date  = d.SNAPSHOT_DATE AND t2.csp_id  = d.CSP_ID
    LEFT JOIN t1_ont_15d ont ON ont.snap_date = d.SNAPSHOT_DATE AND ont.csp_id = d.CSP_ID
),

accuracy_with_tier AS (
    SELECT *,
        CASE
            WHEN t1_src_verdict = 'INSUFFICIENT' OR t2_src_verdict = 'INSUFFICIENT' THEN 'VG'
            WHEN t1_src_verdict = 'NOT_APPLICABLE' THEN
                CASE t2_src_verdict WHEN 'VERY_GOOD' THEN 'VG' WHEN 'GOOD' THEN 'GOOD' ELSE 'NO_PAYOUT' END
            WHEN t1_src_verdict = 'VERY_GOOD' AND t2_src_verdict = 'VERY_GOOD' THEN 'VG'
            WHEN t1_src_verdict = 'VERY_GOOD' AND t2_src_verdict = 'GOOD'      THEN 'VG'
            WHEN t1_src_verdict = 'VERY_GOOD' AND t2_src_verdict = 'BASE'      THEN 'BASIC'
            WHEN t1_src_verdict = 'GOOD'      AND t2_src_verdict = 'VERY_GOOD' THEN 'VG'
            WHEN t1_src_verdict = 'GOOD'      AND t2_src_verdict = 'GOOD'      THEN 'GOOD'
            WHEN t1_src_verdict = 'GOOD'      AND t2_src_verdict = 'BASE'      THEN 'BASIC'
            WHEN t1_src_verdict = 'BASE'      AND t2_src_verdict = 'VERY_GOOD' THEN 'BASIC'
            WHEN t1_src_verdict = 'BASE'      AND t2_src_verdict = 'GOOD'      THEN 'BASIC'
            WHEN t1_src_verdict = 'BASE'      AND t2_src_verdict = 'BASE'      THEN 'NO_PAYOUT'
            ELSE 'NO_PAYOUT'
        END AS expected_tier
    FROM accuracy_per_csp
),

accuracy AS (
    SELECT snap_date,
        SUM(CASE WHEN T1_OOR_RATE IS NOT NULL THEN t1_match ELSE 0 END)      AS t1_match_csps,
        COUNT(CASE WHEN T1_OOR_RATE IS NOT NULL THEN 1 END)                   AS t1_dms_csps,
        SUM(CASE WHEN T2_SPEED_OK_RATE IS NOT NULL THEN t2_match ELSE 0 END) AS t2_match_csps,
        COUNT(CASE WHEN T2_SPEED_OK_RATE IS NOT NULL THEN 1 END)              AS t2_dms_csps,
        SUM(CASE WHEN COMPOSITE_STATE='COMPLIANT' AND TIER_BAND != 'NONE'
                  AND expected_tier = TIER_BAND THEN 1 ELSE 0 END)            AS tier_match_csps,
        COUNT(CASE WHEN COMPOSITE_STATE='COMPLIANT' AND TIER_BAND != 'NONE' THEN 1 END) AS compliant_csps
    FROM accuracy_with_tier GROUP BY snap_date
),

daily_metrics AS (
    SELECT sd.snap_date AS dt,
        ROUND(100.0*COALESCE(ra.rollup_t1_csps,0)/NULLIF(t1s.source_t1_csps,0),1) AS c1,
        ROUND(100.0*COALESCE(ra.rollup_t2_csps,0)/NULLIF(t2s.source_t2_csps,0),1) AS c2,
        ROUND(100.0*COALESCE(ac.t1_match_csps,0)/NULLIF(ac.t1_dms_csps,0),1)      AS a1,
        ROUND(100.0*COALESCE(ac.t2_match_csps,0)/NULLIF(ac.t2_dms_csps,0),1)      AS a2,
        ROUND(100.0*COALESCE(ac.tier_match_csps,0)/NULLIF(ac.compliant_csps,0),1) AS a3
    FROM snap_dates sd
    LEFT JOIN t1_source_daily t1s ON t1s.signal_date = sd.snap_date
    LEFT JOIN t2_source_daily t2s ON t2s.test_date   = sd.snap_date
    LEFT JOIN rollup_actual   ra  ON ra.SIGNAL_DATE  = sd.snap_date
    LEFT JOIN accuracy        ac  ON ac.snap_date    = sd.snap_date
),

unpivoted AS (
    SELECT dt, 1 AS s, 'C1: T1 Optical Completeness % (eligible → rollup)'                      AS metric, c1 AS val FROM daily_metrics UNION ALL
    SELECT dt, 2,      'C2: T2 Speed Completeness % (eligible → rollup)',              c2 FROM daily_metrics UNION ALL
    SELECT dt, 3,      'A1: T1 Accuracy Match % (computed vs snapshot)',         a1 FROM daily_metrics UNION ALL
    SELECT dt, 4,      'A2: T2 Accuracy Match % (computed vs snapshot)', a2 FROM daily_metrics UNION ALL
    SELECT dt, 5,      'A3: Tier Band Match % (computed vs snapshot)',    a3 FROM daily_metrics
)

SELECT
    metric AS "Metric",
    MAX(CASE WHEN dt=DATEADD(day,-1,CURRENT_DATE())  THEN val END) AS "T-1",
    MAX(CASE WHEN dt=DATEADD(day,-2,CURRENT_DATE())  THEN val END) AS "T-2",
    MAX(CASE WHEN dt=DATEADD(day,-3,CURRENT_DATE())  THEN val END) AS "T-3",
    MAX(CASE WHEN dt=DATEADD(day,-4,CURRENT_DATE())  THEN val END) AS "T-4",
    MAX(CASE WHEN dt=DATEADD(day,-5,CURRENT_DATE())  THEN val END) AS "T-5",
    MAX(CASE WHEN dt=DATEADD(day,-6,CURRENT_DATE())  THEN val END) AS "T-6",
    MAX(CASE WHEN dt=DATEADD(day,-7,CURRENT_DATE())  THEN val END) AS "T-7",
    MAX(CASE WHEN dt=DATEADD(day,-8,CURRENT_DATE())  THEN val END) AS "T-8",
    ROUND(AVG(val), 1)                                              AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1)     AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1)     AS "30D P90"
FROM unpivoted
GROUP BY metric, s
ORDER BY s
