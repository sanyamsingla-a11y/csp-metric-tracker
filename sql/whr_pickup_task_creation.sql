-- Pickup Ticket Creation Rate (R15 cohort) — WHR period format
-- Same logic as QUERIES["put_raw_creation_rate"] in refresh_workflows.py (keep in sync):
-- no TICKETS table; numerator = NBREC created expiry+14..+16 IST; denominator = R15 customers
-- whose router is DEPLOYED on their own CURRENT_CONNECTION_ID at expiry+14 00:00 IST
-- (open NBREC, written-off/lost, deployed at another customer, pickup done -> no PUT needed).

WITH params AS (SELECT CURRENT_DATE() AS today),   -- session is IST; the 3-arg CONVERT double-shifted after 18:30 IST
conn AS (   -- CONNECTIONS is history mode: one current row per connection
    SELECT CONNECTION_ID, CUSTOMER_ID::VARCHAR AS customer_id
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS
    WHERE _FIVETRAN_ACTIVE
),
m_c AS (SELECT DISTINCT customer_id FROM conn),
-- each customer's last DONE OTP plan (device_limit=10, store_group_id=0 = real plans)
last_trum AS (
    SELECT mc.customer_id AS account_id, MAX(trum.OTP_EXPIRY_TIME)::DATE AS last_otp_expiry
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    JOIN m_c mc           ON mc.customer_id = tg.account_id::VARCHAR
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0
      AND trum.device_limit = 10 AND trum.mobile > '5999999999'
    GROUP BY mc.customer_id
),
-- R15 cohort; win_start = expiry+14 00:00 IST, the earliest the cron can fire
eligible AS (
    SELECT account_id, last_otp_expiry,
           DATEADD('day', 15, last_otp_expiry) AS dt,
           TIMESTAMP_TZ_FROM_PARTS(YEAR(last_otp_expiry), MONTH(last_otp_expiry), DAY(last_otp_expiry),
                                   0, 0, 0, 0, 'Asia/Kolkata') + INTERVAL '14 days' AS win_start
    FROM last_trum
    WHERE DATEADD('day', 15, last_otp_expiry) BETWEEN DATEADD('day', -95, CURRENT_DATE())
                                                  AND DATEADD('day', -1,  CURRENT_DATE())
),
-- every NBREC mapped to the customer who owned its connection
nbrec AS (
    SELECT c.customer_id AS account_id, nec.EXECUTION_CANDIDATE_ID, nec.STATE,
           nec.CREATED_AT, nec.UPDATED_AT,
           DATE(CONVERT_TIMEZONE('Asia/Kolkata', nec.CREATED_AT)) AS created_ist_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES nec
    JOIN conn c ON c.CONNECTION_ID = nec.LAST_CONNECTION_ID
    WHERE nec._FIVETRAN_ACTIVE
      AND nec.CREATED_AT >= DATEADD('day', -185, CURRENT_DATE())
),
-- router custody record as of the start of the window
pit AS (
    SELECT e.account_id, e.dt,
           nc.DEVICE_ID, nc.STATUS AS status_at_win,
           nc.CUSTOMER_ID::VARCHAR AS custody_customer_id,
           cc.customer_id          AS current_conn_customer_id
    FROM eligible e
    LEFT JOIN T_WG_CUSTOMER w ON w.ACCOUNT_ID::VARCHAR = e.account_id
    LEFT JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
           ON UPPER(TRIM(nc.DEVICE_ID)) = UPPER(TRIM(w.DEVICE_ID))
          AND nc._FIVETRAN_START <= e.win_start
          AND (nc._FIVETRAN_END > e.win_start OR nc._FIVETRAN_END IS NULL)
    LEFT JOIN conn cc ON cc.CONNECTION_ID = nc.CURRENT_CONNECTION_ID
),
-- PUT already running at window start (no lookback cap), or pickup done in the 45 days before it
prior_nbrec AS (
    SELECT e.account_id, e.dt,
           MAX(IFF(n.STATE IN ('PENDING_PICKUP','IN_PROGRESS','VERIFICATION_PENDING')
                   OR n.UPDATED_AT >= e.win_start, 1, 0))                          AS has_open_nbrec,
           MAX(IFF(n.STATE = 'COMPLETED' AND n.UPDATED_AT < e.win_start
                   AND n.UPDATED_AT >= DATEADD('day', -45, e.win_start), 1, 0))    AS has_pickup_done
    FROM eligible e
    JOIN nbrec n ON n.account_id = e.account_id AND n.CREATED_AT < e.win_start
    GROUP BY 1, 2
),
classified AS (
    SELECT e.dt, e.account_id, e.last_otp_expiry, p.DEVICE_ID, p.status_at_win,
           CASE
             WHEN pn.has_open_nbrec  = 1                              THEN 'EXCL_OPEN_NBREC'
             WHEN p.status_at_win IS NULL                             THEN 'NO_CUSTODY_RECORD'
             WHEN p.status_at_win IN ('WRITTEN_OFF','LOST','DAMAGED') THEN 'EXCL_WRITTEN_OFF_LOST'
             WHEN p.status_at_win = 'DEPLOYED'
              AND COALESCE(p.current_conn_customer_id, p.custody_customer_id, '~')
                  <> e.account_id                                     THEN 'EXCL_DEPLOYED_OTHER_CUSTOMER'
             WHEN p.status_at_win = 'DEPLOYED'                        THEN 'NEEDS_PUT'
             -- router is no longer at the customer: label why (a re-install on the same
             -- customer after a pickup lands in NEEDS_PUT above, never here)
             WHEN pn.has_pickup_done = 1                              THEN 'EXCL_PICKUP_DONE'
             ELSE 'EXCL_NOT_AT_CUSTOMER'
           END AS bucket
    FROM eligible e
    LEFT JOIN pit p          ON p.account_id  = e.account_id AND p.dt  = e.dt
    LEFT JOIN prior_nbrec pn ON pn.account_id = e.account_id AND pn.dt = e.dt
    QUALIFY ROW_NUMBER() OVER (PARTITION BY e.account_id, e.dt
                               ORDER BY IFF(p.status_at_win = 'DEPLOYED', 0, 1)) = 1
),
-- numerator: NBREC created in the cron window (expiry+14 .. expiry+16, IST)
coverage AS (
    SELECT c.dt, c.account_id, c.bucket, c.DEVICE_ID, c.status_at_win,
           MAX(IFF(n.account_id IS NOT NULL, 1, 0)) AS has_nbrec
    FROM classified c
    LEFT JOIN nbrec n
           ON n.account_id = c.account_id
          AND n.created_ist_dt BETWEEN DATEADD('day', 14, c.last_otp_expiry)
                                   AND DATEADD('day', 16, c.last_otp_expiry)
    GROUP BY 1, 2, 3, 4, 5
),
daily AS (
    SELECT dt AS d,
           SUM(IFF(bucket = 'NEEDS_PUT', 1, 0))         AS eligible,
           SUM(IFF(bucket = 'NEEDS_PUT', has_nbrec, 0)) AS nbrec_present
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
