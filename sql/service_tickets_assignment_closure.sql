WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID
  FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
stm_tickets AS (
  SELECT
    stm.TICKET_ID,
    DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp
    ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL
    AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (
      stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%'
      OR stm.LAST_TITLE ILIKE 'Others|Recharge expired (Service issue)%'
      OR stm.LAST_TITLE ILIKE 'Others|TV/Camera issue%'
      OR stm.LAST_TITLE ILIKE 'Others|Adapter issue%'
      OR stm.LAST_TITLE ILIKE 'Shifting Request|Shift to New Address%'
      OR stm.LAST_TITLE ILIKE 'Shifting Request|Shift Within My Home%'
    )
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -37, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
restore AS (
  SELECT
    TICKET_ID,
    COMPLAINT_ID,
    STATE,
    ASSIGNED_TECHNICIAN_ID,
    EXECUTOR_ID
  FROM PROD_DB.DBT_CSP.TAS_RESTORE_EXECUTION_CANDIDATES
  WHERE ETL_CURRENT = TRUE
    AND TICKET_ID IS NOT NULL
),
joined AS (
  SELECT
    s.dt,
    s.TICKET_ID,
    r.COMPLAINT_ID,
    r.STATE,
    r.ASSIGNED_TECHNICIAN_ID,
    r.EXECUTOR_ID
  FROM stm_tickets s
  LEFT JOIN restore r ON r.TICKET_ID = s.TICKET_ID
),
ticket_level AS (
  SELECT
    dt,
    TICKET_ID,
    COUNT(COMPLAINT_ID)                                                 AS total_complaints,
    SUM(IFF(EXECUTOR_ID IS NOT NULL, 1, 0))                             AS executor_assigned,
    SUM(IFF(ASSIGNED_TECHNICIAN_ID IS NOT NULL, 1, 0))                  AS tech_assigned,
    SUM(IFF(STATE = 'COMPLETED', 1, 0))                                 AS completed_complaints,
    IFF(total_complaints > 0 AND completed_complaints = total_complaints, 1, 0) AS ticket_fully_closed
  FROM joined
  GROUP BY dt, TICKET_ID
),
daily AS (
  SELECT
    dt,
    COUNT(*)                            AS tickets_created,
    SUM(total_complaints)               AS total_complaints,
    SUM(executor_assigned)              AS executor_assigned,
    SUM(tech_assigned)                  AS tech_assigned,
    SUM(completed_complaints)           AS complaints_closed,
    SUM(ticket_fully_closed)            AS tickets_closed
  FROM ticket_level
  GROUP BY dt
),
unpivoted AS (
  SELECT dt, 1 AS sk, '1. Tickets Created'       AS metric, tickets_created::FLOAT    AS val FROM daily
  UNION ALL SELECT dt, 2, '2. Total Complaints',             total_complaints::FLOAT          FROM daily
  UNION ALL SELECT dt, 3, '2b. Executor Assigned',           executor_assigned::FLOAT         FROM daily
  UNION ALL SELECT dt, 4, '3. Technician Assigned',          tech_assigned::FLOAT             FROM daily
  UNION ALL SELECT dt, 5, '4. Complaints Closed',            complaints_closed::FLOAT         FROM daily
  UNION ALL SELECT dt, 6, '5. Tickets Closed (all resolved)', tickets_closed::FLOAT           FROM daily
)
SELECT
  metric AS "Metric",
  MAX(CASE WHEN dt = CURRENT_DATE() THEN val END)                     AS "TODAY",
  MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END)   AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END)   AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END)   AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END)   AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END)   AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END)   AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END)   AS "T-7",
  ROUND(AVG(val),1)                                                    AS "AVG",
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1)           AS "MEDIAN",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1)           AS "P90"
FROM unpivoted
GROUP BY metric, sk
ORDER BY sk
