WITH base AS (
  SELECT
    EXECUTION_CANDIDATE_ID,
    DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT))  AS created_dt,
    STATE,
    ASSIGNEE_TYPE,
    REASON_CODE,
    DATEDIFF('minute', CREATED_AT, UPDATED_AT) / 60.0   AS tat_hours
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD('day', -37, CURRENT_DATE())
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) < CURRENT_DATE()
),
daily AS (
  SELECT
    created_dt AS dt,
    COUNT(*)                                                                     AS put_created,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'SELF' THEN 1 ELSE 0 END)                     AS self_cnt,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'TEAM_MEMBER' THEN 1 ELSE 0 END)              AS team_cnt,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'SELF'
              AND STATE IN ('COMPLETED','CANCELLED','FAILED') THEN 1 ELSE 0 END)   AS self_closed,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'TEAM_MEMBER'
              AND STATE IN ('COMPLETED','CANCELLED','FAILED') THEN 1 ELSE 0 END)   AS team_closed,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'SELF' AND STATE = 'COMPLETED' THEN 1 ELSE 0 END)        AS self_pickup,
    SUM(CASE WHEN ASSIGNEE_TYPE = 'TEAM_MEMBER' AND STATE = 'COMPLETED' THEN 1 ELSE 0 END) AS team_pickup
  FROM base
  GROUP BY created_dt
),
daily_with_pct AS (
  SELECT
    dt,
    put_created,
    self_cnt,  ROUND(self_cnt * 100.0 / NULLIF(put_created, 0), 1)     AS self_pct,
    team_cnt,  ROUND(team_cnt * 100.0 / NULLIF(put_created, 0), 1)     AS team_pct,
    self_closed, ROUND(self_closed * 100.0 / NULLIF(self_cnt, 0), 1)   AS self_closed_pct,
    team_closed, ROUND(team_closed * 100.0 / NULLIF(team_cnt, 0), 1)   AS team_closed_pct,
    self_pickup, ROUND(self_pickup * 100.0 / NULLIF(self_closed, 0), 1) AS self_pickup_pct,
    team_pickup, ROUND(team_pickup * 100.0 / NULLIF(team_closed, 0), 1) AS team_pickup_pct
  FROM daily
),
tat_daily AS (
  SELECT
    created_dt AS dt,
    ASSIGNEE_TYPE,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_hours), 1) AS p50_hrs
  FROM base
  WHERE STATE = 'COMPLETED'
  GROUP BY created_dt, ASSIGNEE_TYPE
),
all_unpivoted AS (
  SELECT dt, '1. PUT Created'                   AS metric, put_created::VARCHAR AS val, 1  AS sk FROM daily_with_pct
  UNION ALL SELECT dt, '2a. Self Assigned',                self_cnt::VARCHAR,                2    FROM daily_with_pct
  UNION ALL SELECT dt, '2b. Self Assigned %',              self_pct::VARCHAR || '%',         3    FROM daily_with_pct
  UNION ALL SELECT dt, '3a. Team Assigned',                team_cnt::VARCHAR,                4    FROM daily_with_pct
  UNION ALL SELECT dt, '3b. Team Assigned %',              team_pct::VARCHAR || '%',         5    FROM daily_with_pct
  UNION ALL SELECT dt, '4a. Self Closed',                  self_closed::VARCHAR,             6    FROM daily_with_pct
  UNION ALL SELECT dt, '4b. Self Closed % of Assigned',    self_closed_pct::VARCHAR || '%',  7    FROM daily_with_pct
  UNION ALL SELECT dt, '5a. Team Closed',                  team_closed::VARCHAR,             8    FROM daily_with_pct
  UNION ALL SELECT dt, '5b. Team Closed % of Assigned',    team_closed_pct::VARCHAR || '%',  9    FROM daily_with_pct
  UNION ALL SELECT dt, '6a. Self Pickup Done',             self_pickup::VARCHAR,             10   FROM daily_with_pct
  UNION ALL SELECT dt, '6b. Self Pickup % of Closed',      self_pickup_pct::VARCHAR || '%',  11   FROM daily_with_pct
  UNION ALL SELECT dt, '7a. Team Pickup Done',             team_pickup::VARCHAR,             12   FROM daily_with_pct
  UNION ALL SELECT dt, '7b. Team Pickup % of Closed',      COALESCE(team_pickup_pct::VARCHAR || '%', '-'), 13 FROM daily_with_pct
  UNION ALL SELECT dt, '8. Self Pickup Median TAT (hrs)',  p50_hrs::VARCHAR,                 14   FROM tat_daily WHERE ASSIGNEE_TYPE = 'SELF'
  UNION ALL SELECT dt, '9. Team Pickup Median TAT (hrs)',  p50_hrs::VARCHAR,                 15   FROM tat_daily WHERE ASSIGNEE_TYPE = 'TEAM_MEMBER'
),
agg_base AS (
  SELECT dt, metric, val, sk,
    CASE WHEN sk IN (3,5,7,9,11,13) THEN 1 ELSE 0 END AS is_pct
  FROM all_unpivoted
  WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
)
SELECT
  metric                                                                        AS "Metric",
  MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE())  THEN val END)          AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE())  THEN val END)          AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE())  THEN val END)          AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE())  THEN val END)          AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE())  THEN val END)          AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE())  THEN val END)          AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE())  THEN val END)          AS "T-7",
  MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE())  THEN val END)          AS "T-8",
  CASE WHEN MAX(is_pct) = 0 THEN ROUND(AVG(TRY_TO_DOUBLE(val)), 1)::VARCHAR END                                  AS "30D Avg",
  CASE WHEN MAX(is_pct) = 0 THEN ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY TRY_TO_DOUBLE(val)), 1)::VARCHAR END AS "30D Median",
  CASE WHEN MAX(is_pct) = 0 THEN ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY TRY_TO_DOUBLE(val)), 1)::VARCHAR END AS "30D P90"
FROM agg_base
GROUP BY metric, sk
ORDER BY sk
LIMIT 10000
