WITH params AS (
  SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today
),

test_partner_mobiles AS (
  SELECT DISTINCT MOBILE AS mobile
  FROM PROD_DB.PUBLIC.T_ROUTER_USER_MAPPING
  WHERE CREATED_BY IN (SELECT LCO_ACCOUNT_ID FROM PROD_DB.PUBLIC.TEST_LCO_ACCOUNT_ID)

  UNION

  SELECT DISTINCT w.mobile
  FROM PROD_DB.PUBLIC.T_WG_CUSTOMER w
  JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
    ON c.customer_id = w.account_id
   AND c._FIVETRAN_ACTIVE
  WHERE LOWER(c.CSP_ID) IN ('a0a0b1','a0a6w1')
),

recharges_raw AS (
  SELECT
    w.mobile,
    w.nasid,
    w.account_id,
    DATEADD(minute,330,t.otp_issued_time)::timestamp_ntz AS recharge_ts,
    DATEADD(minute,330,t.otp_expiry_time)::timestamp_ntz AS expiry_ts
  FROM PROD_DB.PUBLIC.T_ROUTER_USER_MAPPING t
  JOIN PROD_DB.PUBLIC.T_WG_CUSTOMER w
    ON t.router_nas_id = w.nasid
  WHERE t.otp = 'DONE'
    AND t.device_limit = 10
    AND t.store_group_id = 0
    AND t.mobile > '5999999999'
    AND t.otp_issued_time >= DATEADD(day,-100,CURRENT_TIMESTAMP())
),

recharges_with_prev AS (
  SELECT
    *,
    LAG(expiry_ts) OVER (
      PARTITION BY nasid
      ORDER BY recharge_ts
    ) AS prev_expiry_ts
  FROM recharges_raw
),

recharges AS (
  SELECT
    r.nasid,
    r.mobile,
    r.account_id,
    r.recharge_ts,
    DATE(r.recharge_ts) AS d
  FROM recharges_with_prev r
  LEFT JOIN test_partner_mobiles tp
    ON tp.mobile = r.mobile
  WHERE tp.mobile IS NULL
    AND DATE(r.recharge_ts) BETWEEN DATEADD(day,-93,(SELECT today FROM params))
                                AND DATEADD(day,-2,(SELECT today FROM params))
    AND (
      r.prev_expiry_ts IS NULL
      OR r.recharge_ts >= DATEADD(minute,15,r.prev_expiry_ts)
    )
),

ping_24h AS (
  SELECT DISTINCT
    r.nasid,
    r.recharge_ts
  FROM recharges r
  JOIN PROD_DB.PUBLIC.HOURLY_DEVICE_PING_INFLUX p
    ON TO_VARCHAR(p.nas_id) = TO_VARCHAR(r.nasid)
  WHERE p.total_pings_received > 0
    AND p.first_ping_ts_ist <= DATEADD(hour,24,r.recharge_ts)
    AND p.last_ping_ts_ist >= r.recharge_ts
),

daily AS (
  SELECT
    r.d,
    ROUND(
      100.0 * (COUNT(*) - COUNT(p.nasid)) / COUNT(*),
      1
    ) AS pct_no_ping_24h
  FROM recharges r
  LEFT JOIN ping_24h p
    ON p.nasid = r.nasid
   AND p.recharge_ts = r.recharge_ts
  GROUP BY r.d
),

with_periods AS (
  SELECT
    d, pct_no_ping_24h,
    CASE
      WHEN d = DATEADD(day,-2,(SELECT today FROM params)) THEN 'D-1'
      WHEN d = DATEADD(day,-3,(SELECT today FROM params)) THEN 'D-2'
      WHEN d = DATEADD(day,-4,(SELECT today FROM params)) THEN 'D-3'
    END AS d_period,
    CASE
      WHEN d BETWEEN DATEADD(day,-8,(SELECT today FROM params))
                 AND DATEADD(day,-2,(SELECT today FROM params)) THEN 'W-1'
      WHEN d BETWEEN DATEADD(day,-15,(SELECT today FROM params))
                 AND DATEADD(day,-9,(SELECT today FROM params)) THEN 'W-2'
      WHEN d BETWEEN DATEADD(day,-22,(SELECT today FROM params))
                 AND DATEADD(day,-16,(SELECT today FROM params)) THEN 'W-3'
    END AS w_period,
    CASE
      WHEN d BETWEEN DATEADD(day,-32,(SELECT today FROM params))
                 AND DATEADD(day,-2,(SELECT today FROM params)) THEN 'M-1'
      WHEN d BETWEEN DATEADD(day,-62,(SELECT today FROM params))
                 AND DATEADD(day,-33,(SELECT today FROM params)) THEN 'M-2'
      WHEN d BETWEEN DATEADD(day,-93,(SELECT today FROM params))
                 AND DATEADD(day,-63,(SELECT today FROM params)) THEN 'M-3'
    END AS m_period
  FROM daily
)

SELECT
  'ISP- % No Ping 24h' AS "Metric",
  MAX(CASE WHEN d_period = 'D-1' THEN pct_no_ping_24h END) AS "D-1",
  MAX(CASE WHEN d_period = 'D-2' THEN pct_no_ping_24h END) AS "D-2",
  MAX(CASE WHEN d_period = 'D-3' THEN pct_no_ping_24h END) AS "D-3",
  ROUND(AVG(CASE WHEN w_period = 'W-1' THEN pct_no_ping_24h END), 1) AS "W-1",
  ROUND(AVG(CASE WHEN w_period = 'W-2' THEN pct_no_ping_24h END), 1) AS "W-2",
  ROUND(AVG(CASE WHEN w_period = 'W-3' THEN pct_no_ping_24h END), 1) AS "W-3",
  ROUND(AVG(CASE WHEN m_period = 'M-1' THEN pct_no_ping_24h END), 1) AS "M-1",
  ROUND(AVG(CASE WHEN m_period = 'M-2' THEN pct_no_ping_24h END), 1) AS "M-2",
  ROUND(AVG(CASE WHEN m_period = 'M-3' THEN pct_no_ping_24h END), 1) AS "M-3"
FROM with_periods
