WITH w AS (SELECT DATE(DATEADD(minute,330,CURRENT_TIMESTAMP()))-1 d1,DATE(DATEADD(minute,330,CURRENT_TIMESTAMP()))-2 d2,DATE(DATEADD(minute,330,CURRENT_TIMESTAMP()))-3 d3,
  DATEADD('day',-7,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w1f, DATEADD('day',-1,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w1t,
  DATEADD('day',-14,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w2f, DATEADD('day',-8,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w2t,
  DATEADD('day',-21,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w3f, DATEADD('day',-15,DATE_TRUNC('week',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) w3t,
  DATEADD('month',-1,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) m1f, DATEADD('day',-1,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) m1t,
  DATEADD('month',-2,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) m2f, DATEADD('day',-1,DATEADD('month',-1,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP()))))) m2t,
  DATEADD('month',-3,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP())))) m3f, DATEADD('day',-1,DATEADD('month',-2,DATE_TRUNC('month',DATE(DATEADD(minute,330,CURRENT_TIMESTAMP()))))) m3t),
Total_Connections AS (
  SELECT DISTINCT cs.connection_id, cs.csp_id,
    TO_DATE(DATEADD(MINUTE,330,cs.created_at)) AS Connection_created_date
  FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS AS cs
  JOIN (SELECT DISTINCT account_id, mobile FROM PROD_DB.DYNAMODB.BOOKING WHERE mobile > '5999999999') AS twg ON twg.account_id = cs.customer_id
  WHERE cs._fivetran_active AND (cs.csp_id IS NULL OR (cs.csp_id <> 'a0a0b1' AND cs.csp_id <> 'a0a6w1'))
    AND TO_DATE(DATEADD(MINUTE,330,cs.created_at)) BETWEEN '2026-05-07' AND CURRENT_DATE() AND twg.mobile > '5999999999'
),
New_connections AS (SELECT connection_id AS New_connection_id FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY WHERE event_type = 'CONNECTION_REQUEST'),
uni AS (SELECT t.connection_id, t.Connection_created_date cdate FROM Total_Connections t JOIN New_connections n ON t.connection_id=n.New_connection_id),
cand AS (SELECT DISTINCT connection_id, execution_candidate_id FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES),
ev AS (
  SELECT TRY_PARSE_JSON(e.properties):execution_id::string AS eid,
    MAX(IFF(e.event_name='install_task_created',1,0)) AS sent,
    MAX(CASE WHEN e.event_name='pn_delivered' AND TRY_PARSE_JSON(e.properties):pn_type::string='ES_INSTALL_CANDIDATE_CREATED' THEN 1
             WHEN e.event_name='fpn_delivered' THEN 1 ELSE 0 END) AS deliv
  FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA e
  WHERE e.timestamp >= DATE_TRUNC('month', DATEADD('month',-3,CURRENT_DATE()))
    AND (e.event_name='install_task_created' OR e.event_name='pn_delivered' OR e.event_name='fpn_delivered')
  GROUP BY 1
),
f AS (
  SELECT u.connection_id, u.cdate,
    MAX(COALESCE(ev.sent,0)) OVER (PARTITION BY u.connection_id) pn_sent,
    MAX(COALESCE(ev.deliv,0)) OVER (PARTITION BY u.connection_id) pn_recv
  FROM uni u
  LEFT JOIN cand c ON c.connection_id=u.connection_id
  LEFT JOIN ev ON ev.eid=c.execution_candidate_id
),
fd AS (SELECT DISTINCT connection_id,cdate,pn_sent,pn_recv FROM f WHERE pn_sent=1)
SELECT 'Booking-to-Task Notif Receive Rate %' "KPI",
 ROUND(SUM(CASE WHEN cdate=w.d1 THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate=w.d1 THEN 1 END),0),2) "D-1",
 ROUND(SUM(CASE WHEN cdate=w.d2 THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate=w.d2 THEN 1 END),0),2) "D-2",
 ROUND(SUM(CASE WHEN cdate=w.d3 THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate=w.d3 THEN 1 END),0),2) "D-3",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.w1f AND w.w1t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.w1f AND w.w1t THEN 1 END),0),2) "W-1",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.w2f AND w.w2t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.w2f AND w.w2t THEN 1 END),0),2) "W-2",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.w3f AND w.w3t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.w3f AND w.w3t THEN 1 END),0),2) "W-3",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.m1f AND w.m1t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.m1f AND w.m1t THEN 1 END),0),2) "M-1",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.m2f AND w.m2t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.m2f AND w.m2t THEN 1 END),0),2) "M-2",
 ROUND(SUM(CASE WHEN cdate BETWEEN w.m3f AND w.m3t THEN pn_recv END)*100.0/NULLIF(SUM(CASE WHEN cdate BETWEEN w.m3f AND w.m3t THEN 1 END),0),2) "M-3"
FROM fd CROSS JOIN w
