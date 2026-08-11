WITH params AS (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today),
eligible AS (
  SELECT DISTINCT DEVICE_ID, RECOVERY_METHOD, csp_id,UPDATED_AT+INTERVAL '330 minutes' AS date
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES
  WHERE STATE = 'COMPLETED'
    AND RECOVERY_METHOD IN ('CSP_PICKUP','RETURNED_TO_WAREHOUSE','CUSTOMER_RETURN')
    QUALIFY row_number() over(PARTITION BY EXECUTION_CANDIDATE_ID ORDER BY updated_at) = 1
),
paid AS (
  SELECT csp_id, CAST(remarks:device_id AS varchar) AS device_id, CREATED_AT+INTERVAL '330 minutes' AS date
FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES
  WHERE _FIVETRAN_ACTIVE = TRUE AND ENTRY_TYPE = 'RECOVERY_RETURN'
),
base AS (
SELECT date(e.date) as d,
       COUNT(*)                      AS den,
       COUNT(p.DEVICE_ID)            AS num,
       COUNT(*) - COUNT(p.DEVICE_ID) AS missing_payout
FROM eligible e LEFT JOIN paid p ON e.DEVICE_ID = p.DEVICE_ID AND e.csp_id = p.csp_id AND p.date BETWEEN e.date-INTERVAL '1 day' AND e.date+INTERVAL '1 day'
GROUP BY 1)
SELECT 'Pickup Auto Credit Rate' AS kpi,
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
