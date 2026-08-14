WITH w AS (
  SELECT
    DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP()))-1 AS d1,
    DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP()))-2 AS d2,
    DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP()))-3 AS d3,
    DATEADD('day',-7, DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w1f,
    DATEADD('day',-1, DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w1t,
    DATEADD('day',-14,DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w2f,
    DATEADD('day',-8, DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w2t,
    DATEADD('day',-21,DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w3f,
    DATEADD('day',-15,DATE_TRUNC('week',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS w3t,
    DATEADD('month',-1,DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS m1f,
    DATEADD('day',-1,  DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS m1t,
    DATEADD('month',-2,DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS m2f,
    DATEADD('day',-1,DATEADD('month',-1,DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP()))))) AS m2t,
    DATEADD('month',-3,DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP())))) AS m3f,
    DATEADD('day',-1,DATEADD('month',-2,DATE_TRUNC('month',DATE(DATEADD(MINUTE,330,CURRENT_TIMESTAMP()))))) AS m3t
),
bookings_base AS (
  SELECT CONNECTION_ID, MOBILE,
         TO_DATE(BOOKING_CONFIRM_DATE) AS booking_date
  FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
  WHERE TO_DATE(BOOKING_CONFIRM_DATE) BETWEEN (SELECT m3f FROM w) AND (SELECT d1 FROM w)
),
das_with_csp AS (
  SELECT DISTINCT aal.CONNECTION_ID
  FROM PROD_DB.CSP_DEMAND_ALLOCATION_SERVICE_CSP_DEMAND_ALLOCATION_SERVICE.ALLOCATION_AUDIT_LOG aal
  WHERE aal.candidate_csps_received IS NOT NULL
    AND aal._fivetran_deleted = FALSE
),
tas_created AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
  WHERE _fivetran_active
),
daily_conn AS (
  SELECT bb.booking_date AS dt,
    COUNT(DISTINCT bb.MOBILE)                                                          AS total_bookings,
    COUNT(DISTINCT CASE WHEN dwc.CONNECTION_ID IS NOT NULL THEN bb.MOBILE END)  AS das_with_csp_count,
    COUNT(DISTINCT CASE WHEN tc.CONNECTION_ID IS NOT NULL THEN bb.MOBILE END)    AS tas_count
  FROM bookings_base bb
  LEFT JOIN das_with_csp dwc ON dwc.CONNECTION_ID = bb.CONNECTION_ID
  LEFT JOIN tas_created  tc  ON tc.CONNECTION_ID  = bb.CONNECTION_ID
  GROUP BY 1
)
SELECT * FROM (
  SELECT 1 AS sort_ord, 'Booking-to-Task Task Creation Rate %' AS "KPI",
    ROUND(SUM(CASE WHEN dt=w.d1 THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d1 THEN total_bookings END),0), 2) AS "D-1",
    ROUND(SUM(CASE WHEN dt=w.d2 THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d2 THEN total_bookings END),0), 2) AS "D-2",
    ROUND(SUM(CASE WHEN dt=w.d3 THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d3 THEN total_bookings END),0), 2) AS "D-3",
    ROUND(SUM(CASE WHEN dt BETWEEN w.w1f AND w.w1t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w1f AND w.w1t THEN total_bookings END),0), 2) AS "W-1",
    ROUND(SUM(CASE WHEN dt BETWEEN w.w2f AND w.w2t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w2f AND w.w2t THEN total_bookings END),0), 2) AS "W-2",
    ROUND(SUM(CASE WHEN dt BETWEEN w.w3f AND w.w3t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w3f AND w.w3t THEN total_bookings END),0), 2) AS "W-3",
    ROUND(SUM(CASE WHEN dt BETWEEN w.m1f AND w.m1t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m1f AND w.m1t THEN total_bookings END),0), 2) AS "M-1",
    ROUND(SUM(CASE WHEN dt BETWEEN w.m2f AND w.m2t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m2f AND w.m2t THEN total_bookings END),0), 2) AS "M-2",
    ROUND(SUM(CASE WHEN dt BETWEEN w.m3f AND w.m3t THEN tas_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m3f AND w.m3t THEN total_bookings END),0), 2) AS "M-3"
  FROM daily_conn CROSS JOIN w GROUP BY "KPI"

  UNION ALL

  SELECT 2, 'Booking-to-Task CSP Assignment Rate %',
    ROUND(SUM(CASE WHEN dt=w.d1 THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d1 THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt=w.d2 THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d2 THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt=w.d3 THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt=w.d3 THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.w1f AND w.w1t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w1f AND w.w1t THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.w2f AND w.w2t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w2f AND w.w2t THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.w3f AND w.w3t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.w3f AND w.w3t THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.m1f AND w.m1t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m1f AND w.m1t THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.m2f AND w.m2t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m2f AND w.m2t THEN total_bookings END),0), 2),
    ROUND(SUM(CASE WHEN dt BETWEEN w.m3f AND w.m3t THEN das_with_csp_count END)*100.0 / NULLIF(SUM(CASE WHEN dt BETWEEN w.m3f AND w.m3t THEN total_bookings END),0), 2)
  FROM daily_conn CROSS JOIN w GROUP BY 2
) ORDER BY sort_ord
