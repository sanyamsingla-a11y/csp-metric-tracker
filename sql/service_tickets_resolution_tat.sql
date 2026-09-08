WITH tas_tickets AS (
  SELECT
    TICKET_ID,
    CASE
      WHEN SECONDARY_SUBTYPE IN ('RECHARGE_DONE_NO_INTERNET','SLOW_INTERNET','NO_INTERNET',
                                  'FREQUENT_DISCONNECTION','OPTICAL_POWER_OUT_OF_RANGE')
        THEN 'Internet Issues'
      WHEN SECONDARY_SUBTYPE IN ('SHIFT_WITHIN_HOME','SHIFT_TO_NEW_ADDRESS')
        THEN 'Shifting'
      ELSE 'Others'
    END AS ticket_group,
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
    ticket_group,
    COUNT(*) AS cnt,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_hours), 1) AS p50,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY tat_hours), 1) AS p75,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY tat_hours), 1) AS p99
  FROM tas_tickets
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
