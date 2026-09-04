-- Service Ticket Reopen Funnel (cohort view)
-- Grain: TICKET_ID. Anchored on original complaint creation date.
-- D/W/M buckets are independent full periods (a ticket can appear in D-1 AND W-1 AND M-1).
-- STM row = Kapture Internet Issues tickets for migrated CSPs (5 LAST_TITLE subtypes).
-- SRS rows = ALL non-REDIRECTED complaints for migrated CSPs (no subtype filter).
-- Reopen count = distinct COMPLAINT_IDs with IS_REOPEN=TRUE per TICKET_ID (active snapshot).

WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID, CSP_ID
  FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),

-- Row 0: STM (Kapture) total tickets
kap_dedup AS (
  SELECT
    stm.TICKET_ID,
    DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp
    ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL
    AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('month', -3, DATE_TRUNC('month', CURRENT_DATE()))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
kap_daily AS (
  SELECT dt, COUNT(DISTINCT TICKET_ID) AS cnt FROM kap_dedup GROUP BY dt
),
stm_agg AS (
  SELECT
    SUM(IFF(dt = DATEADD('day',-1,CURRENT_DATE()), cnt, 0)) AS d1,
    SUM(IFF(dt = DATEADD('day',-2,CURRENT_DATE()), cnt, 0)) AS d2,
    SUM(IFF(dt = DATEADD('day',-3,CURRENT_DATE()), cnt, 0)) AS d3,
    SUM(IFF(dt >= DATE_TRUNC('week',DATEADD('week',-1,CURRENT_DATE())) AND dt < DATE_TRUNC('week',CURRENT_DATE()), cnt, 0)) AS w1,
    SUM(IFF(dt >= DATE_TRUNC('week',DATEADD('week',-2,CURRENT_DATE())) AND dt < DATE_TRUNC('week',DATEADD('week',-1,CURRENT_DATE())), cnt, 0)) AS w2,
    SUM(IFF(dt >= DATE_TRUNC('week',DATEADD('week',-3,CURRENT_DATE())) AND dt < DATE_TRUNC('week',DATEADD('week',-2,CURRENT_DATE())), cnt, 0)) AS w3,
    SUM(IFF(dt >= DATE_TRUNC('month',DATEADD('month',-1,CURRENT_DATE())) AND dt < DATE_TRUNC('month',CURRENT_DATE()), cnt, 0)) AS m1,
    SUM(IFF(dt >= DATE_TRUNC('month',DATEADD('month',-2,CURRENT_DATE())) AND dt < DATE_TRUNC('month',DATEADD('month',-1,CURRENT_DATE())), cnt, 0)) AS m2,
    SUM(IFF(dt >= DATE_TRUNC('month',DATEADD('month',-3,CURRENT_DATE())) AND dt < DATE_TRUNC('month',DATEADD('month',-2,CURRENT_DATE())), cnt, 0)) AS m3
  FROM kap_daily
),

-- Rows 1-7: SRS reopen funnel
ticket_base AS (
  SELECT TICKET_ID,
    MIN(CASE WHEN (IS_REOPEN = FALSE OR IS_REOPEN IS NULL)
             THEN CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT) END) AS first_ist
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND TICKET_ID NOT LIKE 'prod-test%'
    AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
    AND STATUS <> 'REDIRECTED'
  GROUP BY TICKET_ID
  HAVING first_ist IS NOT NULL
),
reopen_counts AS (
  SELECT TICKET_ID, COUNT(*) AS rc
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND IS_REOPEN = TRUE
    AND TICKET_ID NOT LIKE 'prod-test%'
    AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
  GROUP BY TICKET_ID
),
combined AS (
  SELECT DATE(b.first_ist) AS dt, b.TICKET_ID, COALESCE(r.rc, 0) AS rc
  FROM ticket_base b
  LEFT JOIN reopen_counts r ON r.TICKET_ID = b.TICKET_ID
  WHERE DATE(b.first_ist) >= DATEADD('month', -3, DATE_TRUNC('month', CURRENT_DATE()))
),
flagged AS (
  SELECT *,
    dt = DATEADD('day',-1,CURRENT_DATE()) AS is_d1,
    dt = DATEADD('day',-2,CURRENT_DATE()) AS is_d2,
    dt = DATEADD('day',-3,CURRENT_DATE()) AS is_d3,
    dt >= DATE_TRUNC('week',DATEADD('week',-1,CURRENT_DATE())) AND dt < DATE_TRUNC('week',CURRENT_DATE()) AS is_w1,
    dt >= DATE_TRUNC('week',DATEADD('week',-2,CURRENT_DATE())) AND dt < DATE_TRUNC('week',DATEADD('week',-1,CURRENT_DATE())) AS is_w2,
    dt >= DATE_TRUNC('week',DATEADD('week',-3,CURRENT_DATE())) AND dt < DATE_TRUNC('week',DATEADD('week',-2,CURRENT_DATE())) AS is_w3,
    dt >= DATE_TRUNC('month',DATEADD('month',-1,CURRENT_DATE())) AND dt < DATE_TRUNC('month',CURRENT_DATE()) AS is_m1,
    dt >= DATE_TRUNC('month',DATEADD('month',-2,CURRENT_DATE())) AND dt < DATE_TRUNC('month',DATEADD('month',-1,CURRENT_DATE())) AS is_m2,
    dt >= DATE_TRUNC('month',DATEADD('month',-3,CURRENT_DATE())) AND dt < DATE_TRUNC('month',DATEADD('month',-2,CURRENT_DATE())) AS is_m3
  FROM combined
),
agg AS (
  SELECT
    SUM(IFF(is_d1,1,0)) AS d1c, SUM(IFF(is_d1 AND rc>0,1,0)) AS d1r, ROUND(100.0*d1r/NULLIF(d1c,0),1) AS d1p,
    SUM(IFF(is_d1 AND rc=1,1,0)) AS d1x1, SUM(IFF(is_d1 AND rc=2,1,0)) AS d1x2, SUM(IFF(is_d1 AND rc=3,1,0)) AS d1x3, SUM(IFF(is_d1 AND rc>3,1,0)) AS d1x3p,
    SUM(IFF(is_d2,1,0)) AS d2c, SUM(IFF(is_d2 AND rc>0,1,0)) AS d2r, ROUND(100.0*d2r/NULLIF(d2c,0),1) AS d2p,
    SUM(IFF(is_d2 AND rc=1,1,0)) AS d2x1, SUM(IFF(is_d2 AND rc=2,1,0)) AS d2x2, SUM(IFF(is_d2 AND rc=3,1,0)) AS d2x3, SUM(IFF(is_d2 AND rc>3,1,0)) AS d2x3p,
    SUM(IFF(is_d3,1,0)) AS d3c, SUM(IFF(is_d3 AND rc>0,1,0)) AS d3r, ROUND(100.0*d3r/NULLIF(d3c,0),1) AS d3p,
    SUM(IFF(is_d3 AND rc=1,1,0)) AS d3x1, SUM(IFF(is_d3 AND rc=2,1,0)) AS d3x2, SUM(IFF(is_d3 AND rc=3,1,0)) AS d3x3, SUM(IFF(is_d3 AND rc>3,1,0)) AS d3x3p,
    SUM(IFF(is_w1,1,0)) AS w1c, SUM(IFF(is_w1 AND rc>0,1,0)) AS w1r, ROUND(100.0*w1r/NULLIF(w1c,0),1) AS w1p,
    SUM(IFF(is_w1 AND rc=1,1,0)) AS w1x1, SUM(IFF(is_w1 AND rc=2,1,0)) AS w1x2, SUM(IFF(is_w1 AND rc=3,1,0)) AS w1x3, SUM(IFF(is_w1 AND rc>3,1,0)) AS w1x3p,
    SUM(IFF(is_w2,1,0)) AS w2c, SUM(IFF(is_w2 AND rc>0,1,0)) AS w2r, ROUND(100.0*w2r/NULLIF(w2c,0),1) AS w2p,
    SUM(IFF(is_w2 AND rc=1,1,0)) AS w2x1, SUM(IFF(is_w2 AND rc=2,1,0)) AS w2x2, SUM(IFF(is_w2 AND rc=3,1,0)) AS w2x3, SUM(IFF(is_w2 AND rc>3,1,0)) AS w2x3p,
    SUM(IFF(is_w3,1,0)) AS w3c, SUM(IFF(is_w3 AND rc>0,1,0)) AS w3r, ROUND(100.0*w3r/NULLIF(w3c,0),1) AS w3p,
    SUM(IFF(is_w3 AND rc=1,1,0)) AS w3x1, SUM(IFF(is_w3 AND rc=2,1,0)) AS w3x2, SUM(IFF(is_w3 AND rc=3,1,0)) AS w3x3, SUM(IFF(is_w3 AND rc>3,1,0)) AS w3x3p,
    SUM(IFF(is_m1,1,0)) AS m1c, SUM(IFF(is_m1 AND rc>0,1,0)) AS m1r, ROUND(100.0*m1r/NULLIF(m1c,0),1) AS m1p,
    SUM(IFF(is_m1 AND rc=1,1,0)) AS m1x1, SUM(IFF(is_m1 AND rc=2,1,0)) AS m1x2, SUM(IFF(is_m1 AND rc=3,1,0)) AS m1x3, SUM(IFF(is_m1 AND rc>3,1,0)) AS m1x3p,
    SUM(IFF(is_m2,1,0)) AS m2c, SUM(IFF(is_m2 AND rc>0,1,0)) AS m2r, ROUND(100.0*m2r/NULLIF(m2c,0),1) AS m2p,
    SUM(IFF(is_m2 AND rc=1,1,0)) AS m2x1, SUM(IFF(is_m2 AND rc=2,1,0)) AS m2x2, SUM(IFF(is_m2 AND rc=3,1,0)) AS m2x3, SUM(IFF(is_m2 AND rc>3,1,0)) AS m2x3p,
    SUM(IFF(is_m3,1,0)) AS m3c, SUM(IFF(is_m3 AND rc>0,1,0)) AS m3r, ROUND(100.0*m3r/NULLIF(m3c,0),1) AS m3p,
    SUM(IFF(is_m3 AND rc=1,1,0)) AS m3x1, SUM(IFF(is_m3 AND rc=2,1,0)) AS m3x2, SUM(IFF(is_m3 AND rc=3,1,0)) AS m3x3, SUM(IFF(is_m3 AND rc>3,1,0)) AS m3x3p
  FROM flagged
)

SELECT * FROM (
  SELECT 0 AS "#", 'STM Tickets Created' AS "KPI",
    'Kapture Internet Issues, migrated CSPs' AS "DESC",
    s.d1 AS "D-1", s.d2 AS "D-2", s.d3 AS "D-3",
    s.w1 AS "W-1", s.w2 AS "W-2", s.w3 AS "W-3",
    s.m1 AS "M-1", s.m2 AS "M-2", s.m3 AS "M-3"
  FROM stm_agg s

  UNION ALL
  SELECT 1, 'SRS Complaints Created',
    'All non-redirected complaints, migrated CSPs',
    d1c, d2c, d3c, w1c, w2c, w3c, m1c, m2c, m3c FROM agg

  UNION ALL
  SELECT 2, 'Reopened Tickets',
    'Tickets later reopened (any count)',
    d1r, d2r, d3r, w1r, w2r, w3r, m1r, m2r, m3r FROM agg

  UNION ALL
  SELECT 3, 'Reopen Rate %',
    'Reopened / SRS Created × 100',
    d1p, d2p, d3p, w1p, w2p, w3p, m1p, m2p, m3p FROM agg

  UNION ALL
  SELECT 4, 'Reopened 1x',
    'Reopened exactly once',
    d1x1, d2x1, d3x1, w1x1, w2x1, w3x1, m1x1, m2x1, m3x1 FROM agg

  UNION ALL
  SELECT 5, 'Reopened 2x',
    'Reopened exactly twice',
    d1x2, d2x2, d3x2, w1x2, w2x2, w3x2, m1x2, m2x2, m3x2 FROM agg

  UNION ALL
  SELECT 6, 'Reopened 3x',
    'Reopened exactly three times',
    d1x3, d2x3, d3x3, w1x3, w2x3, w3x3, m1x3, m2x3, m3x3 FROM agg

  UNION ALL
  SELECT 7, 'Reopened 3+ times',
    'Reopened more than three times',
    d1x3p, d2x3p, d3x3p, w1x3p, w2x3p, w3x3p, m1x3p, m2x3p, m3x3p FROM agg
) ORDER BY "#"
