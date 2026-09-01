-- Pickup Ticket Creation Rate (R15 cohort, device-state exclusion)
-- Same logic as put_raw_creation_rate but with WHR period output format
-- Excludes customers whose device was already recovered before their R15 date

WITH params AS (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today),
m_c AS (
    SELECT DISTINCT CUSTOMER_ID
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS
),
last_trum AS (
    SELECT
        mc.CUSTOMER_ID                   AS account_id,
        MAX(trum.OTP_EXPIRY_TIME)::DATE  AS last_otp_expiry
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    JOIN m_c mc           ON mc.CUSTOMER_ID = tg.account_id
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0
      AND trum.device_limit = 10 AND trum.mobile > '5999999999'
    GROUP BY mc.CUSTOMER_ID
),
eligible AS (
    SELECT
        account_id,
        last_otp_expiry,
        DATEADD('day', 15, last_otp_expiry) AS dt
    FROM last_trum
    WHERE DATEADD('day', 15, last_otp_expiry) BETWEEN DATEADD('day', -95, CURRENT_DATE())
                                                  AND DATEADD('day', -1,  CURRENT_DATE())
),
already_has_open_ticket AS (
    SELECT DISTINCT e.account_id
    FROM eligible e
    JOIN PROD_DB.DYNAMODB_READ.TICKETS t
        ON  t.CUSTOMER_ACCOUNT_ID::VARCHAR = e.account_id::VARCHAR
        AND t.TICKET_TYPE = 'ROUTER_PICKUP'
        AND t.STATUS      = 'OPEN'
        AND DATE(t.CREATED_TIME + INTERVAL '330 minutes')
                BETWEEN DATEADD('day', -22, e.dt)
                AND     DATEADD('day', -1,  e.dt)
),
-- Device state exclusion CTEs
dev AS (
    SELECT e.account_id,
           e.dt,
           UPPER(TRIM(w.DEVICE_ID)) AS device_id
    FROM eligible e
    LEFT JOIN T_WG_CUSTOMER w ON w.ACCOUNT_ID = e.account_id
    WHERE w.DEVICE_ID IS NOT NULL
),
own_conns AS (
    SELECT CUSTOMER_ID, CONNECTION_ID
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS
),
pit AS (
    SELECT d.account_id, d.dt, d.device_id,
           nc.STATUS                 AS status_at_r15,
           nc.CUSTOMER_ID            AS custody_customer_id,
           nc.CURRENT_CONNECTION_ID  AS cc,
           nc.LAST_CONNECTION_ID     AS lc
    FROM dev d
    LEFT JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
      ON UPPER(TRIM(nc.DEVICE_ID)) = d.device_id
     AND nc._FIVETRAN_START <= d.dt::TIMESTAMP_TZ
     AND (nc._FIVETRAN_END  >  d.dt::TIMESTAMP_TZ OR nc._FIVETRAN_END IS NULL)
),
device_excluded AS (
    SELECT DISTINCT account_id
    FROM pit p
    WHERE p.status_at_r15 IN ('IDLE','CUSTODIED','RETURNED','RETRIEVAL_PENDING')
       OR (p.status_at_r15 = 'DEPLOYED'
           AND COALESCE(p.custody_customer_id::VARCHAR,'~') <> p.account_id::VARCHAR
           AND NOT EXISTS (
                 SELECT 1 FROM own_conns c
                 WHERE c.CUSTOMER_ID::VARCHAR = p.account_id::VARCHAR
                   AND c.CONNECTION_ID IN (p.cc, p.lc)))
),
eligible_need_ticket AS (
    SELECT * FROM eligible
    WHERE account_id NOT IN (SELECT account_id FROM already_has_open_ticket)
      AND account_id NOT IN (SELECT account_id FROM device_excluded)
),
ticket_match AS (
    SELECT
        e.account_id,
        e.dt,
        e.last_otp_expiry,
        MIN(t.CREATED_TIME + INTERVAL '330 minutes') AS ticket_created_ist
    FROM eligible_need_ticket e
    LEFT JOIN PROD_DB.DYNAMODB_READ.TICKETS t
        ON  t.CUSTOMER_ACCOUNT_ID::VARCHAR = e.account_id::VARCHAR
        AND t.TICKET_TYPE = 'ROUTER_PICKUP'
        AND DATE(t.CREATED_TIME + INTERVAL '330 minutes') >= DATEADD('day', 14, e.last_otp_expiry)
        AND DATE(t.CREATED_TIME + INTERVAL '330 minutes') <= DATEADD('day', 16, e.last_otp_expiry)
    GROUP BY 1, 2, 3
),
nbrec AS (
    SELECT
        c.CUSTOMER_ID::VARCHAR                  AS account_id,
        nec.CREATED_AT + INTERVAL '330 minutes' AS nbrec_created_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES nec
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON  nec.LAST_CONNECTION_ID = c.CONNECTION_ID
    WHERE nec._FIVETRAN_ACTIVE
      AND nec.CREATED_AT >= DATEADD('day', -100, CURRENT_DATE())
),
coverage AS (
    SELECT
        tm.dt,
        tm.account_id,
        CASE WHEN tm.ticket_created_ist IS NOT NULL THEN 1 ELSE 0 END AS has_ticket,
        MAX(CASE WHEN n.account_id IS NOT NULL THEN 1 ELSE 0 END)     AS has_nbrec_6h
    FROM ticket_match tm
    LEFT JOIN nbrec n
        ON  n.account_id = tm.account_id::VARCHAR
        AND tm.ticket_created_ist IS NOT NULL
        AND ABS(DATEDIFF('hour', tm.ticket_created_ist, n.nbrec_created_at)) <= 6
    GROUP BY 1, 2, 3
),
daily AS (
    SELECT
        dt AS d,
        COUNT(*)          AS eligible,
        SUM(has_nbrec_6h) AS nbrec_present
    FROM coverage
    GROUP BY 1
)
SELECT 'D1 — Task-Creation Reliability' AS kpi,
  1.0*SUM(CASE WHEN d = p.today-1 THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d = p.today-1 THEN eligible END),0)*100 AS "D-1",
  1.0*SUM(CASE WHEN d = p.today-2 THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d = p.today-2 THEN eligible END),0)*100 AS "D-2",
  1.0*SUM(CASE WHEN d = p.today-3 THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d = p.today-3 THEN eligible END),0)*100 AS "D-3",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN eligible END),0)*100 AS "W-1",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN eligible END),0)*100 AS "W-2",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN eligible END),0)*100 AS "W-3",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN eligible END),0)*100 AS "M-1",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN eligible END),0)*100 AS "M-2",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN nbrec_present END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN eligible END),0)*100 AS "M-3"
FROM daily CROSS JOIN params p
