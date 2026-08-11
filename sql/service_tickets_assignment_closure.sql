WITH base AS (
  SELECT
    TICKET_ID,
    DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT))  AS created_dt,
    STATE,
    ASSIGNED_TECHNICIAN_ID,
    RESOLVED_BY_ACTOR_TYPE
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND TICKET_ID IS NOT NULL
    AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD('day', -37, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
daily AS (
  SELECT
    created_dt AS dt,
    COUNT(*)                                                                                 AS tickets_created,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NOT NULL THEN 1 ELSE 0 END)                      AS tech_assigned,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NULL THEN 1 ELSE 0 END)                          AS csp_self_assigned,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NOT NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'TECHNICIAN' THEN 1 ELSE 0 END)                   AS tech_asgn_closed_by_tech,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NOT NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'CSP' THEN 1 ELSE 0 END)                          AS tech_asgn_closed_by_csp,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NOT NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'OTHER' THEN 1 ELSE 0 END)                        AS tech_asgn_closed_by_other,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NOT NULL AND STATE = 'COMPLETED'
              AND (RESOLVED_BY_ACTOR_TYPE IS NULL OR RESOLVED_BY_ACTOR_TYPE = '') THEN 1 ELSE 0 END) AS tech_asgn_closed_by_null,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'TECHNICIAN' THEN 1 ELSE 0 END)                   AS csp_asgn_closed_by_tech,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'CSP' THEN 1 ELSE 0 END)                          AS csp_asgn_closed_by_csp,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NULL AND STATE = 'COMPLETED'
              AND RESOLVED_BY_ACTOR_TYPE = 'OTHER' THEN 1 ELSE 0 END)                        AS csp_asgn_closed_by_other,
    SUM(CASE WHEN ASSIGNED_TECHNICIAN_ID IS NULL AND STATE = 'COMPLETED'
              AND (RESOLVED_BY_ACTOR_TYPE IS NULL OR RESOLVED_BY_ACTOR_TYPE = '') THEN 1 ELSE 0 END) AS csp_asgn_closed_by_null
  FROM base
  GROUP BY created_dt
),
unpivoted AS (
  SELECT dt, '1. Tickets Created'                        AS metric, tickets_created::FLOAT          AS val, 1  AS sk FROM daily
  UNION ALL SELECT dt, '2a. Tech Assigned',                         tech_assigned::FLOAT,                      2     FROM daily
  UNION ALL SELECT dt, '2b. CSP Self-Assigned',                     csp_self_assigned::FLOAT,                  3     FROM daily
  UNION ALL SELECT dt, '3a. Tech Asgn → Closed by Tech',           tech_asgn_closed_by_tech::FLOAT,           4     FROM daily
  UNION ALL SELECT dt, '3b. Tech Asgn → Closed by CSP',            tech_asgn_closed_by_csp::FLOAT,            5     FROM daily
  UNION ALL SELECT dt, '3c. Tech Asgn → Closed by Other',          tech_asgn_closed_by_other::FLOAT,          6     FROM daily
  UNION ALL SELECT dt, '3d. Tech Asgn → Closed by Null',           tech_asgn_closed_by_null::FLOAT,           7     FROM daily
  UNION ALL SELECT dt, '4a. CSP Asgn → Closed by Tech',            csp_asgn_closed_by_tech::FLOAT,            8     FROM daily
  UNION ALL SELECT dt, '4b. CSP Asgn → Closed by CSP',             csp_asgn_closed_by_csp::FLOAT,             9     FROM daily
  UNION ALL SELECT dt, '4c. CSP Asgn → Closed by Other',           csp_asgn_closed_by_other::FLOAT,           10    FROM daily
  UNION ALL SELECT dt, '4d. CSP Asgn → Closed by Null',            csp_asgn_closed_by_null::FLOAT,            11    FROM daily
)
SELECT
  metric                                                                        AS "Metric",
  MAX(CASE WHEN dt = CURRENT_DATE()                      THEN val END)          AS "TODAY",
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
GROUP BY metric, sk
ORDER BY sk
LIMIT 10000
