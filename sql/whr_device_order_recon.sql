WITH params AS (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today),
  base AS (SELECT distinct date(psd.BOXCREATIONONDATETIME) AS d, count(DISTINCT orderid) AS den , count(DISTINCT do.DISPATCH_REF) AS num
FROM (SELECT * FROM PROD_DB.PYROPS.PYROPS_SALE_DETAIL psd WHERE psd.NO_2 IN ('ONT','Router')
                                                                                                                                                                                AND psd.DESCRIPTION_2 = 'Normal BAU'
                                                                                                                                                                                AND psd.orderid LIKE 'o_%'
                                                                                                                                                                                AND date(psd.BOXCREATIONONDATETIME)  >='2026-07-01'
                                                                                                                                                                                ) psd
left JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.DEVICE_ORDERS do  on do.DISPATCH_REF = psd.orderid
                                                                                                                                                                                AND do._FIVETRAN_ACTIVE
GROUP BY 1)
 SELECT 'Device Order Reconciliation Rate' AS kpi,
  1.0*SUM(CASE WHEN d = p.today-1 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-1 THEN den END),0)*100 AS "D-1",
  1.0*SUM(CASE WHEN d = p.today-2 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-2 THEN den END),0)*100 AS "D-2",
  1.0*SUM(CASE WHEN d = p.today-3 THEN num END)/NULLIF(SUM(CASE WHEN d = p.today-3 THEN den END),0)*100 AS "D-3",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-7, DATE_TRUNC('week',p.today)) AND DATEADD('day',-1, DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-1",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-14,DATE_TRUNC('week',p.today)) AND DATEADD('day',-8, DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-2",
  1.0*SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN d BETWEEN DATEADD('day',-21,DATE_TRUNC('week',p.today)) AND DATEADD('day',-15,DATE_TRUNC('week',p.today)) THEN den END),0)*100 AS "W-3",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-1,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-1",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-2,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-2",
  1.0*SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN num END)/NULLIF(SUM(CASE WHEN DATE_TRUNC('month',d) = DATEADD('month',-3,DATE_TRUNC('month',p.today)) THEN den END),0)*100 AS "M-3"
 FROM base CROSS JOIN params p;
