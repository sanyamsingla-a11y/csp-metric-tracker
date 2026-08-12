WITH payg_installs AS (
  SELECT
    router_nas_id AS nas_id,
    otp_expiry_time AS free_plan_expiry,
    TO_DATE(DATEADD(minute,330,otp_expiry_time)) AS expiry_date
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (
        PARTITION BY router_nas_id
        ORDER BY otp_issued_time
      ) AS rn
    FROM prod_db.public.t_router_user_mapping
    WHERE device_limit = '10'
      AND otp = 'DONE'
      AND mobile > '5999999999'
      AND store_group_id = 0
      AND created_by NOT IN (
        SELECT lco_account_id
        FROM test_lco_account_id
      )
      AND mobile NOT IN ('6900099267','7679376747')
  )
  WHERE rn = 1
    AND DATE(DATEADD(minute,330,otp_issued_time)) >= '2026-01-26'
),

next_recharge AS (
  SELECT
    pi.nas_id,
    pi.expiry_date,
    DATEDIFF(
      hour,
      pi.free_plan_expiry,
      MIN(trum.otp_issued_time)
    ) AS hours_to_recharge
  FROM payg_installs pi
  JOIN prod_db.public.t_router_user_mapping trum
    ON trum.router_nas_id = pi.nas_id
   AND trum.device_limit = '10'
   AND trum.otp = 'DONE'
   AND trum.mobile > '5999999999'
   AND trum.store_group_id = 0
   AND trum.otp_issued_time >= pi.free_plan_expiry
  GROUP BY
    pi.nas_id,
    pi.expiry_date,
    pi.free_plan_expiry
),

params AS (
  SELECT CAST(
    DATEADD(minute,330,CURRENT_TIMESTAMP()) AS DATE
  ) AS today
),

daily AS (
  SELECT
    pi.expiry_date AS d,
    ROUND(
      100.0 *
      COUNT(DISTINCT CASE
        WHEN nr.hours_to_recharge <= 24
        THEN pi.nas_id
      END)
      / NULLIF(COUNT(DISTINCT pi.nas_id),0),
      1
    ) AS pct_r1
  FROM payg_installs pi
  LEFT JOIN next_recharge nr
    ON pi.nas_id = nr.nas_id
  CROSS JOIN params t
  WHERE pi.expiry_date BETWEEN
        DATEADD(day,-93,t.today)
        AND DATEADD(day,-2,t.today)
  GROUP BY pi.expiry_date
),

with_periods AS (
  SELECT
    d, pct_r1,
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
  '% R1 (plan purchased within 24h)' AS "Metric",
  MAX(CASE WHEN d_period = 'D-1' THEN pct_r1 END) AS "D-1",
  MAX(CASE WHEN d_period = 'D-2' THEN pct_r1 END) AS "D-2",
  MAX(CASE WHEN d_period = 'D-3' THEN pct_r1 END) AS "D-3",
  ROUND(AVG(CASE WHEN w_period = 'W-1' THEN pct_r1 END),1) AS "W-1",
  ROUND(AVG(CASE WHEN w_period = 'W-2' THEN pct_r1 END),1) AS "W-2",
  ROUND(AVG(CASE WHEN w_period = 'W-3' THEN pct_r1 END),1) AS "W-3",
  ROUND(AVG(CASE WHEN m_period = 'M-1' THEN pct_r1 END),1) AS "M-1",
  ROUND(AVG(CASE WHEN m_period = 'M-2' THEN pct_r1 END),1) AS "M-2",
  ROUND(AVG(CASE WHEN m_period = 'M-3' THEN pct_r1 END),1) AS "M-3"
FROM with_periods
