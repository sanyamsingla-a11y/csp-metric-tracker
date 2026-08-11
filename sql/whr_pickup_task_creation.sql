WITH params AS (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today),
m_c AS (
    SELECT DISTINCT CUSTOMER_ID
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS
    WHERE _FIVETRAN_ACTIVE
),

tickets AS (
    SELECT
        DATE(t.CREATED_TIME + INTERVAL '330 minutes') AS dt,
        t.CREATED_TIME + INTERVAL '330 minutes' AS ticket_created_at,
        t.CUSTOMER_ACCOUNT_ID
    FROM PROD_DB.DYNAMODB_READ.TICKETS t
    JOIN m_c
      ON m_c.CUSTOMER_ID = t.CUSTOMER_ACCOUNT_ID
    WHERE DATE(t.CREATED_TIME + INTERVAL '330 minutes')
          BETWEEN '2026-06-17' AND CURRENT_DATE()-1
      AND t.TICKET_TYPE = 'ROUTER_PICKUP'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.CUSTOMER_ACCOUNT_ID
        ORDER BY t.CREATED_TIME DESC
    ) = 1
),

nbrec AS (
    SELECT
        c.CUSTOMER_ID,
        nec.CREATED_AT + INTERVAL '330 minutes' AS nbrec_created_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES nec
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
      ON nec.LAST_CONNECTION_ID = c.CONNECTION_ID
     AND c._FIVETRAN_ACTIVE
    WHERE nec._FIVETRAN_ACTIVE
),

matched AS (
    SELECT
        t.dt,
        t.ticket_created_at,
        n.nbrec_created_at
    FROM tickets t
    LEFT JOIN nbrec n
      ON t.CUSTOMER_ACCOUNT_ID = n.CUSTOMER_ID
     AND ABS(DATEDIFF('hour', t.ticket_created_at, n.nbrec_created_at)) <= 6
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY t.CUSTOMER_ACCOUNT_ID, t.ticket_created_at
        ORDER BY ABS(DATEDIFF('second', t.ticket_created_at, n.nbrec_created_at))
    ) = 1
),

daily AS (
    SELECT
        dt,
        COUNT(*) AS total_tickets,
        COUNT(nbrec_created_at) AS present_in_nbrec_6h
    FROM matched
    GROUP BY 1
),

base AS (
    SELECT
        dt AS d,
        present_in_nbrec_6h AS num,
        total_tickets AS den
    FROM daily
)
SELECT 'D1 — Task-Creation Reliability' AS kpi,
  1.0*SUM(CASE WHEN d = p.today-1 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-1 THEN den END),0)*100 AS "D-1",
  1.0*SUM(CASE WHEN d = p.today-2 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-2 THEN den END),0)*100 AS "D-2",
  1.0*SUM(CASE WHEN d = p.today-3 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-3 THEN den END),0)*100 AS "D-3",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-1",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-2",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-3",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-1",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-2",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-3"
 FROM base CROSS JOIN params p
