WITH tas_tickets AS (
  SELECT
    TICKET_ID,
    SECONDARY_SUBTYPE,
    DATE(CONVERT_TIMEZONE('Asia/Kolkata', UPDATED_AT))   AS closed_dt,
    DATEDIFF('minute', CREATED_AT, UPDATED_AT) / 60.0   AS tat_hours
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND STATE = 'COMPLETED'
    AND TICKET_ID IS NOT NULL
    AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', UPDATED_AT)) >= DATEADD('day', -37, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
daily_pcts AS (
  SELECT
    closed_dt AS dt,
    SECONDARY_SUBTYPE,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_hours), 1) AS p50,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY tat_hours), 1) AS p75,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY tat_hours), 1) AS p99
  FROM tas_tickets
  GROUP BY closed_dt, SECONDARY_SUBTYPE
),
unpivoted AS (
  SELECT dt, SECONDARY_SUBTYPE, 'P50 TAT (hrs)' AS metric, p50 AS val FROM daily_pcts
  UNION ALL
  SELECT dt, SECONDARY_SUBTYPE, 'P75 TAT (hrs)', p75 FROM daily_pcts
  UNION ALL
  SELECT dt, SECONDARY_SUBTYPE, 'P99 TAT (hrs)', p99 FROM daily_pcts
)
SELECT
  SECONDARY_SUBTYPE                                                             AS "Subtype",
  metric                                                                        AS "Metric",
  MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE())  THEN val END)          AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE())  THEN val END)          AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE())  THEN val END)          AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE())  THEN val END)          AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE())  THEN val END)          AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE())  THEN val END)          AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE())  THEN val END)          AS "T-7",
  ROUND(AVG(val), 1)                                                            AS "AVERAGE",
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1)                   AS "MEDIAN",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1)                   AS "P90"
FROM unpivoted
GROUP BY SECONDARY_SUBTYPE, metric
ORDER BY
  SECONDARY_SUBTYPE,
  CASE metric
    WHEN 'P50 TAT (hrs)' THEN 1
    WHEN 'P75 TAT (hrs)' THEN 2
    WHEN 'P99 TAT (hrs)' THEN 3
  END
LIMIT 10000
