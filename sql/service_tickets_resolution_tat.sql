WITH tas_tickets AS (
  SELECT
    r.TICKET_ID,
    r.SECONDARY_SUBTYPE,
    DATE(CONVERT_TIMEZONE('Asia/Kolkata', r.UPDATED_AT))   AS closed_dt,
    DATEDIFF('minute', r.CREATED_AT, r.UPDATED_AT) / 60.0 AS tat_hours
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES r
  WHERE r._FIVETRAN_ACTIVE = TRUE
    AND r.STATE = 'COMPLETED'
    AND r.TICKET_ID IS NOT NULL
    AND REGEXP_LIKE(r.TICKET_ID, '^[0-9]+$')
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', r.UPDATED_AT)) >= DATEADD('day', -37, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY r.TICKET_ID ORDER BY r.UPDATED_AT DESC, r.STATE_VERSION DESC) = 1
),
stm_titles AS (
  SELECT TICKET_ID::VARCHAR AS TICKET_ID, LAST_TITLE
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL
  WHERE TICKET_ID IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY TICKET_ADDED_TIME DESC) = 1
),
classified AS (
  SELECT
    t.TICKET_ID,
    t.closed_dt,
    t.tat_hours,
    CASE
      WHEN t.SECONDARY_SUBTYPE IN ('RECHARGE_DONE_NO_INTERNET','SLOW_INTERNET','NO_INTERNET',
                                    'FREQUENT_DISCONNECTION','OPTICAL_POWER_OUT_OF_RANGE')
        THEN 'Internet Issues'
      WHEN t.SECONDARY_SUBTYPE IN ('SHIFT_WITHIN_HOME','SHIFT_TO_NEW_ADDRESS')
           OR s.LAST_TITLE ILIKE 'Shifting Request|%'
        THEN 'Shifting'
      ELSE 'Others'
    END AS ticket_group
  FROM tas_tickets t
  LEFT JOIN stm_titles s ON s.TICKET_ID = t.TICKET_ID
),
daily_pcts AS (
  SELECT
    closed_dt AS dt,
    ticket_group,
    COUNT(*) AS cnt,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_hours), 1) AS p50,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY tat_hours), 1) AS p75,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY tat_hours), 1) AS p99
  FROM classified
  GROUP BY closed_dt, ticket_group
),
unpivoted AS (
  SELECT dt, ticket_group, 'Tickets Resolved' AS metric, cnt AS val, 0 AS sk FROM daily_pcts
  UNION ALL
  SELECT dt, ticket_group, 'P50 TAT (hrs)', p50, 1 FROM daily_pcts
  UNION ALL
  SELECT dt, ticket_group, 'P75 TAT (hrs)', p75, 2 FROM daily_pcts
  UNION ALL
  SELECT dt, ticket_group, 'P99 TAT (hrs)', p99, 3 FROM daily_pcts
)
SELECT
  ticket_group                                                                  AS "Subtype",
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
GROUP BY ticket_group, metric, sk
ORDER BY
  CASE ticket_group WHEN 'Internet Issues' THEN 1 WHEN 'Shifting' THEN 2 ELSE 3 END,
  sk
