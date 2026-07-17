"""
Refresh workflow dashboard data from Metabase.
Run: python refresh_workflows.py
"""
import json, urllib.request, os
from datetime import datetime

DIR = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(DIR, ".env")) as f:
    env = f.read()
API_KEY = env.split(":")[1].strip().strip("'").strip()

METABASE_URL = "https://metabase.wiom.in"
DATABASE_ID = 113

def mb_native(sql):
    payload = {"database": DATABASE_ID, "type": "native", "native": {"query": sql}}
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        METABASE_URL + "/api/dataset",
        data=data,
        headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        result = json.loads(resp.read())
    cols = [c["name"] for c in result["data"]["cols"]]
    return [dict(zip(cols, row)) for row in result["data"]["rows"]]

# ── Queries keyed by workflow_metric ──────────────────────────────

QUERIES = {}

QUERIES["b2i_health"] = r"""
WITH
bookings_base AS (
  SELECT DISTINCT CONNECTION_ID,
    TO_DATE(BOOKING_CONFIRM_DATE) AS booking_date
  FROM PROD_DB.DBT.COMPANY_B_CONNECTION_BOOKING_ENRICHED
  WHERE TO_DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
  QUALIFY ROW_NUMBER() OVER (PARTITION BY CONNECTION_ID ORDER BY RUN_DATE DESC) = 1
),
clos_reached AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
  WHERE EVENT_TYPE = 'CONNECTION_REQUEST' AND _FIVETRAN_DELETED = FALSE
),
das_reached AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_DEMAND_ALLOCATION_SERVICE_CSP_DEMAND_ALLOCATION_SERVICE.CONNECTION_ALLOCATIONS
  WHERE ALLOCATION_STATE IN ('ASSIGNED','ACCEPTED','ACTIVE','RELEASED')
),
tas_created AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.DBT_CSP.TAS_INSTALL_EXECUTION_CANDIDATES WHERE ETL_CURRENT = TRUE
),
daily_conn AS (
  SELECT bb.booking_date AS dt,
    COUNT(DISTINCT bb.CONNECTION_ID)                                                                  AS total_bookings,
    COUNT(DISTINCT CASE WHEN cr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                  AS clos_count,
    COUNT(DISTINCT CASE WHEN dr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                  AS das_count,
    COUNT(DISTINCT CASE WHEN tc.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                  AS tas_count
  FROM bookings_base bb
  LEFT JOIN clos_reached cr ON cr.CONNECTION_ID = bb.CONNECTION_ID
  LEFT JOIN das_reached  dr ON dr.CONNECTION_ID = bb.CONNECTION_ID
  LEFT JOIN tas_created  tc ON tc.CONNECTION_ID = bb.CONNECTION_ID
  GROUP BY 1
),
all_candidates AS (
  SELECT
    e.execution_candidate_id,
    e.connection_id,
    TO_DATE(DATEADD(MINUTE, 330, e.created_at)) AS candidate_date,
    e.p41_deadline_at,
    e.p74_deadline_at,
    e.confirmed_slot_at,
    e.current_state,
    e.failure_reason,
    e.reason_code
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
  WHERE e._fivetran_active
    AND DATEADD(MINUTE, 330, e.created_at) >= DATEADD('day', -8, CURRENT_DATE())
),
ct_events AS (
  SELECT
    TRY_PARSE_JSON(ed.properties):execution_id::STRING                                                AS execution_candidate_id,
    MAX(CASE WHEN ed.event_name = 'install_task_created'                                               THEN 1 ELSE 0 END) AS pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_CANDIDATE_CREATED'       THEN 1 ELSE 0 END) AS pn_delivered,
    MAX(CASE WHEN ed.event_name = 'fpn_delivered'                                                      THEN 1 ELSE 0 END) AS fpn_delivered,
    MAX(CASE WHEN ed.event_name = 'install_customer_slot_confirmed'                                    THEN 1 ELSE 0 END) AS slot_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_CUSTOMER_SLOT_CONFIRMED' THEN 1 ELSE 0 END) AS slot_pn_delivered,
    MAX(CASE WHEN ed.event_name = 'technician_assigned'                                                THEN 1 ELSE 0 END) AS tech_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_TECHNICIAN_ASSIGNED'     THEN 1 ELSE 0 END) AS tech_pn_delivered
  FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
  WHERE ed.event_name IN (
      'install_task_created', 'pn_delivered', 'fpn_delivered',
      'install_customer_slot_confirmed', 'technician_assigned'
    )
    AND TRY_PARSE_JSON(ed.properties):execution_id::STRING IN (SELECT execution_candidate_id FROM all_candidates)
  GROUP BY 1
),
candidate_level AS (
  SELECT
    ac.candidate_date,
    ac.execution_candidate_id,
    ac.connection_id,
    COALESCE(ct.pn_sent,           0) AS pn_sent,
    COALESCE(ct.pn_delivered,      0) AS pn_delivered,
    COALESCE(ct.fpn_delivered,     0) AS fpn_delivered,
    COALESCE(ct.slot_pn_sent,      0) AS slot_pn_sent,
    COALESCE(ct.slot_pn_delivered, 0) AS slot_pn_delivered,
    COALESCE(ct.tech_pn_sent,      0) AS tech_pn_sent,
    COALESCE(ct.tech_pn_delivered, 0) AS tech_pn_delivered,
    CASE WHEN COALESCE(ct.pn_delivered,0)=1 OR COALESCE(ct.fpn_delivered,0)=1
         THEN 1 ELSE 0 END            AS attention_delivered,
    CASE WHEN ac.p41_deadline_at IS NOT NULL
          AND ac.p41_deadline_at < CURRENT_TIMESTAMP
          AND ac.confirmed_slot_at IS NULL
          AND ac.current_state NOT IN (
              'CANCELLED_BY_CUSTOMER','DECLINED','CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED',
              'AWAITING_CUSTOMER_SLOT_CONFIRMATION','SLOT_CONFIRMED',
              'TECHNICIAN_ASSIGNED','TECHNICIAN_EN_ROUTE','INSTALLATION_IN_PROGRESS'
          )
          AND NOT (ac.current_state = 'CANCELLED_BY_UPSTREAM' AND COALESCE(ac.reason_code,'') != 'TIMEOUT_P41')
         THEN 1 ELSE 0 END            AS p41_eligible,
    CASE WHEN ac.p74_deadline_at IS NOT NULL
          AND ac.p74_deadline_at < CURRENT_TIMESTAMP
          AND ac.confirmed_slot_at IS NOT NULL
          AND ac.current_state NOT IN ('CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED','CANCELLED_BY_CUSTOMER','DECLINED')
          AND NOT (ac.current_state = 'CANCELLED_BY_UPSTREAM' AND COALESCE(ac.failure_reason,'') != 'TIMEOUT_P74')
         THEN 1 ELSE 0 END            AS p74_eligible,
    ac.reason_code,
    ac.failure_reason
  FROM all_candidates ac
  LEFT JOIN ct_events ct ON ac.execution_candidate_id = ct.execution_candidate_id
),
daily_cand AS (
  SELECT candidate_date AS dt,
    COUNT(*)                                                                          AS total_candidates,
    SUM(pn_sent)                                                                      AS pn_sent_count,
    SUM(pn_delivered)                                                                 AS pn_delivered_count,
    SUM(fpn_delivered)                                                                AS fpn_delivered_count,
    SUM(attention_delivered)                                                          AS attention_count,
    SUM(slot_pn_sent)                                                                 AS slot_pn_sent_count,
    SUM(slot_pn_delivered)                                                            AS slot_pn_delivered_count,
    SUM(tech_pn_sent)                                                                 AS tech_pn_sent_count,
    SUM(tech_pn_delivered)                                                            AS tech_pn_delivered_count,
    SUM(p41_eligible)                                                                 AS p41_eligible_count,
    SUM(CASE WHEN p41_eligible=1 AND reason_code='TIMEOUT_P41'    THEN 1 ELSE 0 END) AS p41_timeout_count,
    SUM(p74_eligible)                                                                 AS p74_eligible_count,
    SUM(CASE WHEN p74_eligible=1 AND failure_reason='TIMEOUT_P74' THEN 1 ELSE 0 END) AS p74_timeout_count
  FROM candidate_level
  WHERE candidate_date < CURRENT_DATE()
  GROUP BY 1
)

SELECT sort_ord, metric_name,
  MAX(CASE WHEN dt = CURRENT_DATE - 1 THEN val END)                                                                         AS "Today",
  MAX(CASE WHEN dt = CURRENT_DATE - 2 THEN val END)                                                                         AS "T-1",
  MAX(CASE WHEN dt = CURRENT_DATE - 3 THEN val END)                                                                         AS "T-2",
  MAX(CASE WHEN dt = CURRENT_DATE - 4 THEN val END)                                                                         AS "T-3",
  MAX(CASE WHEN dt = CURRENT_DATE - 5 THEN val END)                                                                         AS "T-4",
  MAX(CASE WHEN dt = CURRENT_DATE - 6 THEN val END)                                                                         AS "T-5",
  MAX(CASE WHEN dt = CURRENT_DATE - 7 THEN val END)                                                                         AS "T-6",
  MAX(CASE WHEN dt = CURRENT_DATE - 8 THEN val END)                                                                         AS "T-7",
  ROUND(AVG(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1)                            AS "Average",
  MEDIAN(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END)                                   AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "P90"
FROM (
  SELECT  0 sort_ord, '# Bookings Confirmed'                             metric_name, dt, total_bookings        val FROM daily_conn
  UNION ALL SELECT  1, 'H1: # Connections Created (CLOS)',                            dt, clos_count               FROM daily_conn
  UNION ALL SELECT  2, 'H2: # Connections Reached DAS',                              dt, das_count                FROM daily_conn
  UNION ALL SELECT  3, 'H3: # Tasks Created (TAS)',                                  dt, tas_count                FROM daily_conn
  UNION ALL SELECT  4, '# Total Candidates',                                         dt, total_candidates         FROM daily_cand
  UNION ALL SELECT  5, 'PN: # Sent to CSP',                                          dt, pn_sent_count            FROM daily_cand
  UNION ALL SELECT  6, 'PN: # Delivered',                                            dt, pn_delivered_count       FROM daily_cand
  UNION ALL SELECT  7, 'FPN: # Delivered',                                           dt, fpn_delivered_count      FROM daily_cand
  UNION ALL SELECT  8, 'Task Attention (PN or FPN delivered)',                        dt, attention_count          FROM daily_cand
  UNION ALL SELECT  9, 'Slot Confirm PN: # Sent',                                    dt, slot_pn_sent_count       FROM daily_cand
  UNION ALL SELECT 10, 'Slot Confirm PN: # Delivered',                               dt, slot_pn_delivered_count  FROM daily_cand
  UNION ALL SELECT 11, 'Tech Assigned PN: # Sent',                                   dt, tech_pn_sent_count       FROM daily_cand
  UNION ALL SELECT 12, 'Tech Assigned PN: # Delivered',                              dt, tech_pn_delivered_count  FROM daily_cand
  UNION ALL SELECT 13, 'P41: # Eligible (no slot proposed, deadline hit)',            dt, p41_eligible_count       FROM daily_cand
  UNION ALL SELECT 14, 'P41: # Timeout Triggered',                                   dt, p41_timeout_count        FROM daily_cand
  UNION ALL SELECT 15, 'P74: # Eligible (slot confirmed, 72h deadline hit)',          dt, p74_eligible_count       FROM daily_cand
  UNION ALL SELECT 16, 'P74: # Timeout Triggered',                                   dt, p74_timeout_count        FROM daily_cand
) m
GROUP BY sort_ord, metric_name
ORDER BY sort_ord
LIMIT 10000
"""

# ── B2I Funnel ────────────────────────────────────────────────────

QUERIES["b2i_funnel"] = r"""
WITH
bookings_base AS (
  SELECT  CONNECTION_ID, MOBILE,
    TO_DATE(BOOKING_CONFIRM_DATE) AS booking_date
  FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
  WHERE TO_DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE-1
),
clos_reached AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
  WHERE EVENT_TYPE = 'CONNECTION_REQUEST' AND _FIVETRAN_DELETED = FALSE
),
das_reached AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_DEMAND_ALLOCATION_SERVICE_CSP_DEMAND_ALLOCATION_SERVICE.CONNECTION_ALLOCATIONS
  WHERE ALLOCATION_STATE IN ('ASSIGNED','ACCEPTED','ACTIVE','RELEASED')
),
tas_created AS (
  SELECT DISTINCT CONNECTION_ID
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
  WHERE _fivetran_active
),
daily_conn AS (
  SELECT bb.booking_date AS dt,
    COUNT( DISTINCT BB.MOBILE)                                                                 AS total_bookings,
    COUNT(DISTINCT CASE WHEN cr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)           AS clos_count,
    COUNT(DISTINCT CASE WHEN dr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)           AS das_count,
    COUNT(DISTINCT CASE WHEN tc.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)           AS tas_count
  FROM bookings_base bb
  LEFT JOIN clos_reached cr ON cr.CONNECTION_ID = bb.CONNECTION_ID
  LEFT JOIN das_reached  dr ON dr.CONNECTION_ID = bb.CONNECTION_ID
  LEFT JOIN tas_created  tc ON tc.CONNECTION_ID = bb.CONNECTION_ID
  GROUP BY 1
),
all_candidates AS (
  SELECT
    e.execution_candidate_id,
    e.connection_id,
    bb.booking_date,
    e.p41_deadline_at,
    e.p74_deadline_at,
    e.confirmed_slot_at,
    e.proposed_slot_date,
    e.executor_id,
    e.current_state,
    e.completed_step,
    e.security_fee_paid_at,
    e.otp_verified,
    e.customer_rating,
    e.failure_reason,
    e.reason_code
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
  INNER JOIN bookings_base bb ON bb.CONNECTION_ID = e.connection_id
  WHERE e._fivetran_active
),
slot_timing AS (
  SELECT
    execution_candidate_id,
    MIN(CASE WHEN current_state = 'AWAITING_SLOT_PROPOSAL'              THEN updated_at END) AS awaiting_slot_at,
    MIN(CASE WHEN current_state = 'AWAITING_CUSTOMER_SLOT_CONFIRMATION' THEN updated_at END) AS slot_proposed_at,
    MIN(CASE WHEN current_state = 'TECHNICIAN_ASSIGNED'                 THEN updated_at END) AS tech_assigned_at
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
  WHERE execution_candidate_id IN (SELECT execution_candidate_id FROM all_candidates)
  GROUP BY 1
),
slot_remind AS (
  SELECT DISTINCT execution_candidate_id
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_ATTENTION_EVENT_LOG
  WHERE reason_code = 'SLOT_PROPOSAL_URGENT'
    AND execution_candidate_id IN (SELECT execution_candidate_id FROM all_candidates)
),
tech_remind AS (
  SELECT DISTINCT execution_candidate_id
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_ATTENTION_EVENT_LOG
  WHERE reason_code = 'TECHNICIAN_ASSIGNMENT_URGENT'
    AND execution_candidate_id IN (SELECT execution_candidate_id FROM all_candidates)
),
ct_events AS (
  SELECT
    TRY_PARSE_JSON(ed.properties):execution_id::STRING                                                AS execution_candidate_id,
    MAX(CASE WHEN ed.event_name = 'install_task_created'                                               THEN 1 ELSE 0 END) AS pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_CANDIDATE_CREATED'       THEN 1 ELSE 0 END) AS pn_delivered,
    MAX(CASE WHEN ed.event_name = 'pn_clicked'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_CANDIDATE_CREATED'       THEN 1 ELSE 0 END) AS pn_clicked,
    MAX(CASE WHEN ed.event_name = 'fpn_delivered'                                                      THEN 1 ELSE 0 END) AS fpn_delivered,
    MAX(CASE WHEN ed.event_name = 'fpn_action_taken'                                                   THEN 1 ELSE 0 END) AS fpn_clicked,
    MAX(CASE WHEN ed.event_name = 'install_candidate_opened'                                           THEN 1 ELSE 0 END) AS drilldown_opened,
    MAX(CASE WHEN ed.event_name = 'install_customer_slot_confirmed'                                    THEN 1 ELSE 0 END) AS slot_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_CUSTOMER_SLOT_CONFIRMED' THEN 1 ELSE 0 END) AS slot_pn_delivered,
    MAX(CASE WHEN ed.event_name = 'technician_assigned'                                                THEN 1 ELSE 0 END) AS tech_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_TECHNICIAN_ASSIGNED'     THEN 1 ELSE 0 END) AS tech_pn_delivered
  FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
  WHERE ed.event_name IN (
      'install_task_created', 'pn_delivered', 'pn_clicked', 'fpn_delivered', 'fpn_action_taken',
      'install_candidate_opened',
      'install_customer_slot_confirmed', 'technician_assigned'
    )
    AND TRY_PARSE_JSON(ed.properties):execution_id::STRING IN (SELECT execution_candidate_id FROM all_candidates)
  GROUP BY 1
),
candidate_level AS (
  SELECT
    ac.booking_date,
    ac.execution_candidate_id,
    ac.connection_id,
    COALESCE(ct.pn_sent,           0) AS pn_sent,
    COALESCE(ct.pn_delivered,      0) AS pn_delivered,
    COALESCE(ct.pn_clicked,        0) AS pn_clicked,
    COALESCE(ct.fpn_delivered,     0) AS fpn_delivered,
    COALESCE(ct.fpn_clicked,       0) AS fpn_clicked,
    COALESCE(ct.drilldown_opened,  0) AS drilldown_opened,
    COALESCE(ct.slot_pn_sent,      0) AS slot_pn_sent,
    COALESCE(ct.slot_pn_delivered, 0) AS slot_pn_delivered,
    COALESCE(ct.tech_pn_sent,      0) AS tech_pn_sent,
    COALESCE(ct.tech_pn_delivered, 0) AS tech_pn_delivered,
    CASE WHEN COALESCE(ct.pn_delivered,0)=1 OR COALESCE(ct.fpn_delivered,0)=1
         THEN 1 ELSE 0 END            AS attention_delivered,
    CASE WHEN COALESCE(ct.fpn_delivered,0)=1 OR COALESCE(ct.drilldown_opened,0)=1
         THEN 1 ELSE 0 END            AS install_task_open,
    CASE WHEN ac.proposed_slot_date IS NOT NULL THEN 1 ELSE 0 END AS slot_proposed,
    CASE WHEN ac.current_state = 'DECLINED'     THEN 1 ELSE 0 END AS slot_declined,
    CASE WHEN st.awaiting_slot_at IS NOT NULL
          AND (
            (st.slot_proposed_at IS NULL AND DATEDIFF('minute', st.awaiting_slot_at, CURRENT_TIMESTAMP) > 60)
            OR DATEDIFF('minute', st.awaiting_slot_at, st.slot_proposed_at) > 60
          )
         THEN 1 ELSE 0 END            AS no_slot_within_1h,
    CASE WHEN sr.execution_candidate_id IS NOT NULL THEN 1 ELSE 0 END AS slot_remind_sent,
    CASE WHEN ac.confirmed_slot_at IS NOT NULL  THEN 1 ELSE 0 END AS slot_confirmed,
    CASE WHEN ac.executor_id IS NOT NULL        THEN 1 ELSE 0 END AS tech_assigned,
    CASE WHEN ac.confirmed_slot_at IS NOT NULL
          AND (
            (st.tech_assigned_at IS NULL AND DATEDIFF('minute', ac.confirmed_slot_at, CURRENT_TIMESTAMP) > 60)
            OR DATEDIFF('minute', ac.confirmed_slot_at, st.tech_assigned_at) > 60
          )
         THEN 1 ELSE 0 END            AS no_tech_within_1h,
    CASE WHEN tr.execution_candidate_id IS NOT NULL THEN 1 ELSE 0 END AS tech_remind_sent,
    CASE WHEN ac.current_state = 'ARRIVED_AT_SITE' OR COALESCE(ac.completed_step,0) >= 1 THEN 1 ELSE 0 END AS tech_arrived,
    CASE WHEN COALESCE(ac.completed_step,0) >= 1 THEN 1 ELSE 0 END AS step_selfie,
    CASE WHEN COALESCE(ac.completed_step,0) >= 2 THEN 1 ELSE 0 END AS step_aadhar,
    CASE WHEN ac.security_fee_paid_at IS NOT NULL               THEN 1 ELSE 0 END AS step_sec_fee,
    CASE WHEN COALESCE(ac.completed_step,0) >= 3 THEN 1 ELSE 0 END AS step_shared,
    CASE WHEN COALESCE(ac.completed_step,0) >= 4 THEN 1 ELSE 0 END AS step_conn_info,
    CASE WHEN COALESCE(ac.completed_step,0) >= 5 THEN 1 ELSE 0 END AS step_device_photo,
    CASE WHEN COALESCE(ac.completed_step,0) >= 6 THEN 1 ELSE 0 END AS step_speed_test,
    CASE WHEN COALESCE(ac.completed_step,0) >= 6
          AND NOT (ac.otp_verified = TRUE OR COALESCE(ac.completed_step,0) >= 7) THEN 1 ELSE 0 END AS step_hc_pending,
    CASE WHEN ac.otp_verified = TRUE OR COALESCE(ac.completed_step,0) >= 7 THEN 1 ELSE 0 END AS step_otp,
    CASE WHEN ac.customer_rating IS NOT NULL OR COALESCE(ac.completed_step,0) >= 8 THEN 1 ELSE 0 END AS step_rating,
    CASE WHEN ac.current_state = 'CANCELLED_BY_CUSTOMER'        THEN 1 ELSE 0 END AS cancelled_by_customer,
    CASE WHEN ac.current_state = 'CANCELLED_BY_UPSTREAM'        THEN 1 ELSE 0 END AS cancelled_by_upstream,
    CASE WHEN ac.current_state = 'INSTALLATION_REPORTED_FAILED' THEN 1 ELSE 0 END AS install_failed,
    CASE WHEN ac.p41_deadline_at IS NOT NULL
          AND ac.p41_deadline_at < CURRENT_TIMESTAMP
          AND ac.confirmed_slot_at IS NULL
          AND ac.current_state NOT IN (
              'CANCELLED_BY_CUSTOMER','DECLINED','CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED',
              'AWAITING_CUSTOMER_SLOT_CONFIRMATION','SLOT_CONFIRMED',
              'TECHNICIAN_ASSIGNED','TECHNICIAN_EN_ROUTE','INSTALLATION_IN_PROGRESS'
          )
          AND NOT (ac.current_state = 'CANCELLED_BY_UPSTREAM' AND COALESCE(ac.reason_code,'') != 'TIMEOUT_P41')
         THEN 1 ELSE 0 END            AS p41_eligible,
    CASE WHEN ac.p74_deadline_at IS NOT NULL
          AND ac.p74_deadline_at < CURRENT_TIMESTAMP
          AND ac.confirmed_slot_at IS NOT NULL
          AND ac.current_state NOT IN ('CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED','CANCELLED_BY_CUSTOMER','DECLINED')
          AND NOT (ac.current_state = 'CANCELLED_BY_UPSTREAM' AND COALESCE(ac.failure_reason,'') != 'TIMEOUT_P74')
         THEN 1 ELSE 0 END            AS p74_eligible,
    ac.reason_code,
    ac.failure_reason
  FROM all_candidates ac
  LEFT JOIN ct_events  ct ON ac.execution_candidate_id = ct.execution_candidate_id
  LEFT JOIN slot_timing st ON ac.execution_candidate_id = st.execution_candidate_id
  LEFT JOIN slot_remind sr ON ac.execution_candidate_id = sr.execution_candidate_id
  LEFT JOIN tech_remind tr ON ac.execution_candidate_id = tr.execution_candidate_id
),
daily_cand AS (
  SELECT booking_date AS dt,
    COUNT(*)                                                                          AS total_candidates,
    SUM(pn_sent)                                                                      AS pn_sent_count,
    SUM(pn_delivered)                                                                 AS pn_delivered_count,
    SUM(CASE WHEN pn_delivered=1 AND pn_clicked=1 THEN 1 ELSE 0 END)                 AS pn_clicked_count,
    SUM(fpn_delivered)                                                                AS fpn_delivered_count,
    SUM(CASE WHEN fpn_delivered=1 AND fpn_clicked=1 THEN 1 ELSE 0 END)               AS fpn_clicked_count,
    SUM(attention_delivered)                                                          AS attention_count,
    SUM(drilldown_opened)                                                             AS drilldown_opened_count,
    SUM(install_task_open)                                                            AS install_task_open_count,
    SUM(slot_proposed)                                                                AS slot_proposed_count,
    SUM(slot_declined)                                                                AS slot_declined_count,
    SUM(no_slot_within_1h)                                                            AS no_slot_within_1h_count,
    SUM(slot_remind_sent)                                                             AS slot_remind_sent_count,
    SUM(slot_confirmed)                                                               AS slot_confirmed_count,
    SUM(slot_pn_sent)                                                                 AS slot_pn_sent_count,
    SUM(slot_pn_delivered)                                                            AS slot_pn_delivered_count,
    SUM(tech_assigned)                                                                AS tech_assigned_count,
    SUM(tech_pn_sent)                                                                 AS tech_pn_sent_count,
    SUM(tech_pn_delivered)                                                            AS tech_pn_delivered_count,
    SUM(no_tech_within_1h)                                                            AS no_tech_within_1h_count,
    SUM(tech_remind_sent)                                                             AS tech_remind_sent_count,
    SUM(tech_arrived)                                                                 AS tech_arrived_count,
    SUM(step_selfie)                                                                  AS step_selfie_count,
    SUM(step_aadhar)                                                                  AS step_aadhar_count,
    SUM(step_sec_fee)                                                                 AS step_sec_fee_count,
    SUM(step_shared)                                                                  AS step_shared_count,
    SUM(step_conn_info)                                                               AS step_conn_info_count,
    SUM(step_device_photo)                                                            AS step_device_photo_count,
    SUM(step_speed_test)                                                              AS step_speed_test_count,
    SUM(step_hc_pending)                                                              AS step_hc_pending_count,
    SUM(step_otp)                                                                     AS step_otp_count,
    SUM(step_rating)                                                                  AS step_rating_count,
    SUM(cancelled_by_customer)                                                        AS cancelled_by_customer_count,
    SUM(cancelled_by_upstream)                                                        AS cancelled_by_upstream_count,
    SUM(install_failed)                                                               AS install_failed_count,
    SUM(p41_eligible)                                                                 AS p41_eligible_count,
    SUM(CASE WHEN p41_eligible=1 AND reason_code='TIMEOUT_P41'    THEN 1 ELSE 0 END) AS p41_timeout_count,
    SUM(p74_eligible)                                                                 AS p74_eligible_count,
    SUM(CASE WHEN p74_eligible=1 AND failure_reason='TIMEOUT_P74' THEN 1 ELSE 0 END) AS p74_timeout_count
  FROM candidate_level
  GROUP BY 1
)

SELECT sort_ord, metric_name,
  MAX(CASE WHEN dt = CURRENT_DATE - 1 THEN val END) AS "T-1",
  MAX(CASE WHEN dt = CURRENT_DATE - 2 THEN val END) AS "T-2",
  MAX(CASE WHEN dt = CURRENT_DATE - 3 THEN val END) AS "T-3",
  MAX(CASE WHEN dt = CURRENT_DATE - 4 THEN val END) AS "T-4",
  MAX(CASE WHEN dt = CURRENT_DATE - 5 THEN val END) AS "T-5",
  MAX(CASE WHEN dt = CURRENT_DATE - 6 THEN val END) AS "T-6",
  MAX(CASE WHEN dt = CURRENT_DATE - 7 THEN val END) AS "T-7",
  MAX(CASE WHEN dt = CURRENT_DATE - 8 THEN val END) AS "T-8",
  ROUND(AVG(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "Average",
  MEDIAN(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END)        AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "P90"
FROM (
  SELECT  0, '# Bookings Confirmed',                                        dt, total_bookings              FROM daily_conn
  UNION ALL SELECT  1, 'H1: # Connections Created (CLOS)',                  dt, clos_count                  FROM daily_conn
  UNION ALL SELECT  2, 'H2: # Connections Reached DAS',                     dt, das_count                   FROM daily_conn
  UNION ALL SELECT  3, 'H3: # Tasks Created (TAS)',                         dt, tas_count                   FROM daily_conn
  UNION ALL SELECT  4, '# Total Candidates (all cohort)',                   dt, total_candidates            FROM daily_cand
  UNION ALL SELECT  5, 'PN: # Sent to CSP',                                 dt, pn_sent_count               FROM daily_cand
  UNION ALL SELECT  6, 'PN: # Delivered',                                   dt, pn_delivered_count          FROM daily_cand
  UNION ALL SELECT  7, 'PN: # Clicked',                                     dt, pn_clicked_count            FROM daily_cand
  UNION ALL SELECT  8, 'FPN: # Delivered',                                  dt, fpn_delivered_count         FROM daily_cand
  UNION ALL SELECT  9, 'FPN: # Clicked',                                    dt, fpn_clicked_count           FROM daily_cand
  UNION ALL SELECT 10, 'Task Attention (PN or FPN delivered)',               dt, attention_count             FROM daily_cand
  UNION ALL SELECT 11, 'Drilldown Open',                                    dt, drilldown_opened_count      FROM daily_cand
  UNION ALL SELECT 12, 'Install Task Open (FPN delivered or Drilldown)',    dt, install_task_open_count     FROM daily_cand
  UNION ALL SELECT 13, 'Slot Proposed by CSP',                              dt, slot_proposed_count         FROM daily_cand
  UNION ALL SELECT 14, 'Slot Declined by Customer',                         dt, slot_declined_count         FROM daily_cand
  UNION ALL SELECT 15, 'No Slot Proposed within 1h',                        dt, no_slot_within_1h_count     FROM daily_cand
  UNION ALL SELECT 16, 'Slot Propose Reminder Sent',                        dt, slot_remind_sent_count      FROM daily_cand
  UNION ALL SELECT 17, 'Slot Confirmed by Customer',                        dt, slot_confirmed_count        FROM daily_cand
  UNION ALL SELECT 18, 'Slot Confirm PN: # Sent',                           dt, slot_pn_sent_count          FROM daily_cand
  UNION ALL SELECT 19, 'Slot Confirm PN: # Delivered',                      dt, slot_pn_delivered_count     FROM daily_cand
  UNION ALL SELECT 20, 'Technician Assigned',                               dt, tech_assigned_count         FROM daily_cand
  UNION ALL SELECT 21, 'Tech Assigned PN: # Sent',                          dt, tech_pn_sent_count          FROM daily_cand
  UNION ALL SELECT 22, 'Tech Assigned PN: # Delivered',                     dt, tech_pn_delivered_count     FROM daily_cand
  UNION ALL SELECT 23, 'No Tech Assigned within 1h',                        dt, no_tech_within_1h_count     FROM daily_cand
  UNION ALL SELECT 24, 'Tech Assignment Urgent Reminder Sent',               dt, tech_remind_sent_count      FROM daily_cand
  UNION ALL SELECT 25, 'Technician Arrived at Site',                        dt, tech_arrived_count          FROM daily_cand
  UNION ALL SELECT 26, 'Step: Selfie',                                      dt, step_selfie_count           FROM daily_cand
  UNION ALL SELECT 27, 'Step: Aadhaar',                                     dt, step_aadhar_count           FROM daily_cand
  UNION ALL SELECT 28, 'Step: Security Fee Paid',                           dt, step_sec_fee_count          FROM daily_cand
  UNION ALL SELECT 29, 'Step: Shared',                                      dt, step_shared_count           FROM daily_cand
  UNION ALL SELECT 30, 'Step: Connection Info',                             dt, step_conn_info_count        FROM daily_cand
  UNION ALL SELECT 31, 'Step: Device Photo',                                dt, step_device_photo_count     FROM daily_cand
  UNION ALL SELECT 32, 'Step: Speed Test',                                  dt, step_speed_test_count       FROM daily_cand
  UNION ALL SELECT 33, 'Step: Happy Code Pending',                          dt, step_hc_pending_count       FROM daily_cand
  UNION ALL SELECT 34, 'Step: Happy Code Verified (OTP)',                   dt, step_otp_count              FROM daily_cand
  UNION ALL SELECT 35, 'Step: Customer Rating',                             dt, step_rating_count           FROM daily_cand
  UNION ALL SELECT 36, 'Cancelled by Customer',                             dt, cancelled_by_customer_count FROM daily_cand
  UNION ALL SELECT 37, 'Cancelled by Upstream',                             dt, cancelled_by_upstream_count FROM daily_cand
  UNION ALL SELECT 38, 'Installation Reported Failed',                      dt, install_failed_count        FROM daily_cand
  UNION ALL SELECT 39, 'P41: # Eligible (no slot proposed, deadline hit)',   dt, p41_eligible_count          FROM daily_cand
  UNION ALL SELECT 40, 'P41: # Timeout Triggered',                          dt, p41_timeout_count           FROM daily_cand
  UNION ALL SELECT 41, 'P74: # Eligible (slot confirmed, 72h deadline hit)', dt, p74_eligible_count          FROM daily_cand
  UNION ALL SELECT 42, 'P74: # Timeout Triggered',                          dt, p74_timeout_count           FROM daily_cand
) m (sort_ord, metric_name, dt, val)
GROUP BY sort_ord, metric_name
ORDER BY sort_ord
LIMIT 10000
"""

# ── B2I Health Rates ──────────────────────────────────────────────

QUERIES["b2i_health_rates"] = r"""
WITH bookings_base AS (
    SELECT CONNECTION_ID, DATE(BOOKING_CONFIRM_DATE) AS booking_date
    FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
    WHERE DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
),
clos_reached AS (
    SELECT DISTINCT CONNECTION_ID
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
    WHERE EVENT_TYPE = 'CONNECTION_REQUEST' AND _FIVETRAN_DELETED = FALSE
),
das_reached AS (
    SELECT DISTINCT CONNECTION_ID
    FROM PROD_DB.CSP_DEMAND_ALLOCATION_SERVICE_CSP_DEMAND_ALLOCATION_SERVICE.CONNECTION_ALLOCATIONS
    WHERE ALLOCATION_STATE IN ('ASSIGNED','ACCEPTED','ACTIVE','RELEASED')
),
tas_created AS (
    SELECT DISTINCT CONNECTION_ID
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
    WHERE _FIVETRAN_ACTIVE = TRUE
),
daily_conn AS (
    SELECT
        b.booking_date,
        COUNT(DISTINCT b.CONNECTION_ID) AS bookings,
        COUNT(DISTINCT c.CONNECTION_ID) AS clos_cnt,
        COUNT(DISTINCT d.CONNECTION_ID) AS das_cnt,
        COUNT(DISTINCT t.CONNECTION_ID) AS tas_cnt
    FROM bookings_base b
    LEFT JOIN clos_reached c ON c.CONNECTION_ID = b.CONNECTION_ID
    LEFT JOIN das_reached  d ON d.CONNECTION_ID = b.CONNECTION_ID
    LEFT JOIN tas_created  t ON t.CONNECTION_ID = b.CONNECTION_ID
    GROUP BY 1
),
all_candidates AS (
    SELECT
        iec.EXECUTION_CANDIDATE_ID, iec.CONNECTION_ID, b.booking_date,
        iec.P41_DEADLINE_AT, iec.P74_DEADLINE_AT, iec.CONFIRMED_SLOT_AT,
        iec.PROPOSED_SLOT_DATE, iec.EXECUTOR_ID, iec.CURRENT_STATE,
        iec.COMPLETED_STEP, iec.SECURITY_FEE_PAID_AT, iec.OTP_VERIFIED,
        iec.CUSTOMER_RATING, iec.FAILURE_REASON, iec.REASON_CODE, iec.CREATED_AT
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES iec
    JOIN bookings_base b ON b.CONNECTION_ID = iec.CONNECTION_ID
    WHERE iec._FIVETRAN_ACTIVE = TRUE
),
slot_timing AS (
    SELECT
        EXECUTION_CANDIDATE_ID,
        MIN(CASE WHEN CURRENT_STATE = 'AWAITING_SLOT_PROPOSAL'              THEN UPDATED_AT END) AS awaiting_slot_at,
        MIN(CASE WHEN CURRENT_STATE = 'AWAITING_CUSTOMER_SLOT_CONFIRMATION'  THEN UPDATED_AT END) AS slot_proposed_at,
        MIN(CASE WHEN CURRENT_STATE = 'TECHNICIAN_ASSIGNED'                  THEN UPDATED_AT END) AS tech_assigned_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
    GROUP BY 1
),
slot_remind AS (
    SELECT DISTINCT EXECUTION_CANDIDATE_ID
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_ATTENTION_EVENT_LOG
    WHERE REASON_CODE = 'SLOT_PROPOSAL_URGENT'
),
tech_remind AS (
    SELECT DISTINCT EXECUTION_CANDIDATE_ID
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_ATTENTION_EVENT_LOG
    WHERE REASON_CODE = 'TECHNICIAN_ASSIGNMENT_URGENT'
),
ct_events AS (
    SELECT
        JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') AS execution_id,
        MAX(CASE WHEN EVENT_NAME = 'install_task_created'
             THEN 1 ELSE 0 END)                                                    AS pn_sent_flag,
        MAX(CASE WHEN EVENT_NAME = 'pn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
             THEN 1 ELSE 0 END)                                                    AS pn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'pn_clicked'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'page_name') = 'INSTALL_TASK_DRILLDOWN'
             THEN 1 ELSE 0 END)                                                    AS pn_clicked,
        MAX(CASE WHEN EVENT_NAME = 'install_task_created'
             THEN 1 ELSE 0 END)                                                    AS fpn_sent_flag,
        MAX(CASE WHEN EVENT_NAME = 'fpn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
             THEN 1 ELSE 0 END)                                                    AS fpn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'fpn_action_taken'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
             THEN 1 ELSE 0 END)                                                    AS fpn_action_taken,
        MAX(CASE WHEN EVENT_NAME = 'install_candidate_opened'
             THEN 1 ELSE 0 END)                                                    AS install_candidate_opened,
        MAX(CASE WHEN EVENT_NAME = 'install_customer_slot_confirmed'
             THEN 1 ELSE 0 END)                                                    AS install_customer_slot_confirmed,
        MAX(CASE WHEN EVENT_NAME = 'pn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') IN (
                      'ES_INSTALL_CUSTOMER_SLOT_CONFIRMED',
                      'ES_INSTALL_CUSTOMER_SLOT_CONFIRMED_ESCALATION'
                  )
             THEN 1 ELSE 0 END)                                                    AS slot_confirm_pn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'pn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') IN (
                      'ES_INSTALL_TECHNICIAN_ASSIGNED',
                      'ES_INSTALL_TECHNICIAN_ASSIGNED_ESCALATION'
                  )
             THEN 1 ELSE 0 END)                                                    AS tech_pn_delivered
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA
    WHERE JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') IS NOT NULL
      AND JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') != ''
    GROUP BY 1
),
candidate_level AS (
    SELECT
        ac.booking_date,
        ac.execution_candidate_id,
        COALESCE(ct.pn_sent_flag, 0)               AS pn_sent,
        COALESCE(ct.pn_delivered, 0)                AS pn_delivered,
        COALESCE(ct.pn_clicked, 0)                  AS pn_clicked,
        COALESCE(ct.fpn_sent_flag, 0)               AS fpn_sent,
        COALESCE(ct.fpn_delivered, 0)               AS fpn_delivered,
        COALESCE(ct.fpn_action_taken, 0)            AS fpn_action_taken,
        CASE WHEN COALESCE(ct.pn_delivered,0)=1
              OR COALESCE(ct.fpn_delivered,0)=1     THEN 1 ELSE 0 END AS task_attention,
        COALESCE(ct.install_candidate_opened, 0)    AS drilldown_open,
        CASE WHEN COALESCE(ct.fpn_delivered,0)=1
              OR COALESCE(ct.install_candidate_opened,0)=1
                                                    THEN 1 ELSE 0 END AS install_task_open,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NOT NULL THEN 1 ELSE 0 END AS slot_proposed,
        CASE WHEN (
            (st.slot_proposed_at IS NULL
                AND DATEDIFF('minute', st.awaiting_slot_at, CURRENT_TIMESTAMP) > 60)
            OR (st.slot_proposed_at IS NOT NULL
                AND DATEDIFF('minute', st.awaiting_slot_at, st.slot_proposed_at) > 60)
        )                                           THEN 1 ELSE 0 END AS no_slot_within_1h,
        CASE WHEN sr.EXECUTION_CANDIDATE_ID IS NOT NULL THEN 1 ELSE 0 END AS slot_remind_sent,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL  THEN 1 ELSE 0 END AS slot_confirmed,
        COALESCE(ct.slot_confirm_pn_delivered, 0)  AS slot_confirm_pn_delivered,
        CASE WHEN ac.EXECUTOR_ID IS NOT NULL        THEN 1 ELSE 0 END AS tech_assigned,
        COALESCE(ct.tech_pn_delivered, 0)          AS tech_pn_delivered,
        CASE WHEN tr.EXECUTION_CANDIDATE_ID IS NOT NULL THEN 1 ELSE 0 END AS tech_remind_sent,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 1 THEN 1 ELSE 0 END AS step_selfie,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 2 THEN 1 ELSE 0 END AS step_aadhaar,
        CASE WHEN ac.SECURITY_FEE_PAID_AT IS NOT NULL THEN 1 ELSE 0 END AS step_security_fee,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 4 THEN 1 ELSE 0 END AS step_shared,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 5 THEN 1 ELSE 0 END AS step_conn_info,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 6 THEN 1 ELSE 0 END AS step_device_photo,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 7 THEN 1 ELSE 0 END AS step_speed_test,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 8 THEN 1 ELSE 0 END AS step_happy_pending,
        CASE WHEN ac.OTP_VERIFIED = TRUE            THEN 1 ELSE 0 END AS step_otp_verified,
        CASE WHEN ac.CUSTOMER_RATING IS NOT NULL    THEN 1 ELSE 0 END AS step_rating,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_CUSTOMER'   THEN 1 ELSE 0 END AS cancelled_by_customer,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM'   THEN 1 ELSE 0 END AS cancelled_by_upstream,
        CASE WHEN ac.FAILURE_REASON IS NOT NULL                 THEN 1 ELSE 0 END AS install_failed,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NULL
              AND ac.P41_DEADLINE_AT IS NOT NULL
              AND ac.P41_DEADLINE_AT < CURRENT_TIMESTAMP
              AND ac.CURRENT_STATE NOT IN ('DECLINED','CANCELLED_BY_CUSTOMER')
             THEN 1 ELSE 0 END AS p41_eligible,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NULL
              AND ac.P41_DEADLINE_AT IS NOT NULL
              AND ac.P41_DEADLINE_AT < CURRENT_TIMESTAMP
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM'
             THEN 1 ELSE 0 END AS p41_timeout,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT < CURRENT_TIMESTAMP
              AND COALESCE(ac.COMPLETED_STEP,0) < 8
              AND ac.CURRENT_STATE NOT IN ('INSTALLATION_REPORTED_FAILED','CANCELLED_BY_CUSTOMER')
             THEN 1 ELSE 0 END AS p74_eligible,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT < CURRENT_TIMESTAMP
              AND COALESCE(ac.COMPLETED_STEP,0) < 8
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM'
             THEN 1 ELSE 0 END AS p74_timeout
    FROM all_candidates ac
    LEFT JOIN slot_timing st ON st.EXECUTION_CANDIDATE_ID = ac.EXECUTION_CANDIDATE_ID
    LEFT JOIN slot_remind  sr ON sr.EXECUTION_CANDIDATE_ID = ac.EXECUTION_CANDIDATE_ID
    LEFT JOIN tech_remind  tr ON tr.EXECUTION_CANDIDATE_ID = ac.EXECUTION_CANDIDATE_ID
    LEFT JOIN ct_events    ct ON ct.execution_id = ac.EXECUTION_CANDIDATE_ID
),
daily_cand AS (
    SELECT
        booking_date,
        COUNT(*)                       AS total_candidates,
        SUM(pn_sent)                   AS pn_sent,
        SUM(pn_delivered)              AS pn_delivered,
        SUM(pn_clicked)                AS pn_clicked,
        SUM(fpn_sent)                  AS fpn_sent,
        SUM(fpn_delivered)             AS fpn_delivered,
        SUM(fpn_action_taken)          AS fpn_action_taken,
        SUM(task_attention)            AS task_attention,
        SUM(drilldown_open)            AS drilldown_open,
        SUM(install_task_open)         AS install_task_open,
        SUM(slot_proposed)             AS slot_proposed,
        SUM(no_slot_within_1h)         AS no_slot_within_1h,
        SUM(slot_remind_sent)          AS slot_remind_sent,
        SUM(slot_confirmed)            AS slot_confirmed,
        SUM(slot_confirm_pn_delivered) AS slot_confirm_pn_delivered,
        SUM(tech_assigned)             AS tech_assigned,
        SUM(tech_pn_delivered)         AS tech_pn_delivered,
        SUM(tech_remind_sent)          AS tech_remind_sent,
        SUM(step_selfie)               AS step_selfie,
        SUM(step_aadhaar)              AS step_aadhaar,
        SUM(step_security_fee)         AS step_security_fee,
        SUM(step_shared)               AS step_shared,
        SUM(step_conn_info)            AS step_conn_info,
        SUM(step_device_photo)         AS step_device_photo,
        SUM(step_speed_test)           AS step_speed_test,
        SUM(step_happy_pending)        AS step_happy_pending,
        SUM(step_otp_verified)         AS step_otp_verified,
        SUM(step_rating)               AS step_rating,
        SUM(cancelled_by_customer)     AS cancelled_by_customer,
        SUM(cancelled_by_upstream)     AS cancelled_by_upstream,
        SUM(install_failed)            AS install_failed,
        SUM(p41_eligible)              AS p41_eligible,
        SUM(p41_timeout)               AS p41_timeout,
        SUM(p74_eligible)              AS p74_eligible,
        SUM(p74_timeout)               AS p74_timeout
    FROM candidate_level
    GROUP BY 1
),
rates_joined AS (
    SELECT
        dc.booking_date,
        dc.clos_cnt * 1.0 / NULLIF(dc.bookings, 0)                       AS conn_creation_rate,
        dc.das_cnt  * 1.0 / NULLIF(dc.clos_cnt, 0)                       AS conn_assigned_rate,
        dc.tas_cnt  * 1.0 / NULLIF(dc.das_cnt, 0)                        AS task_creation_rate,
        cd.pn_sent        * 1.0 / NULLIF(cd.total_candidates, 0)         AS pn_sent_rate,
        cd.pn_delivered   * 1.0 / NULLIF(cd.pn_sent, 0)                  AS pn_delivery_rate,
        cd.fpn_sent       * 1.0 / NULLIF(cd.total_candidates, 0)         AS fpn_sent_rate,
        cd.fpn_delivered  * 1.0 / NULLIF(cd.fpn_sent, 0)                 AS fpn_delivery_rate,
        cd.task_attention * 1.0 / NULLIF(cd.total_candidates, 0)         AS task_reach_rate,
        cd.p41_timeout    * 1.0 / NULLIF(cd.p41_eligible, 0)             AS p41_timeout_rate,
        cd.slot_remind_sent * 1.0 / NULLIF(cd.no_slot_within_1h, 0)      AS slot_remind_rate,
        cd.slot_confirm_pn_delivered * 1.0 / NULLIF(cd.slot_proposed, 0) AS slot_confirm_pn_delivery_rate,
        cd.tech_remind_sent * 1.0 / NULLIF(cd.slot_confirmed, 0)         AS tech_remind_rate,
        cd.tech_pn_delivered * 1.0 / NULLIF(cd.tech_assigned, 0)         AS tech_pn_delivery_rate,
        cd.p74_timeout      * 1.0 / NULLIF(cd.p74_eligible, 0)           AS p74_timeout_rate,
        cd.step_rating      * 1.0 / NULLIF(cd.step_otp_verified, 0)      AS conn_active_rate
    FROM daily_conn dc
    JOIN daily_cand cd ON cd.booking_date = dc.booking_date
),
rates_long AS (
    SELECT 1  AS sort_ord, 'Connection Creation Rate'       AS metric, booking_date, conn_creation_rate        AS rate FROM rates_joined
    UNION ALL SELECT 2,  'Connection Assigned Rate',        booking_date, conn_assigned_rate         FROM rates_joined
    UNION ALL SELECT 3,  'Task Creation Rate',              booking_date, task_creation_rate          FROM rates_joined
    UNION ALL SELECT 4,  'Install PN Sent Rate',            booking_date, pn_sent_rate                FROM rates_joined
    UNION ALL SELECT 5,  'Install PN Delivery Rate',        booking_date, pn_delivery_rate            FROM rates_joined
    UNION ALL SELECT 6,  'FPN Sent Rate',                   booking_date, fpn_sent_rate               FROM rates_joined
    UNION ALL SELECT 7,  'FPN Delivery Rate',               booking_date, fpn_delivery_rate           FROM rates_joined
    UNION ALL SELECT 8,  'Task Reach Rate',                 booking_date, task_reach_rate             FROM rates_joined
    UNION ALL SELECT 9,  'P41 Timeout Rate',                booking_date, p41_timeout_rate            FROM rates_joined
    UNION ALL SELECT 10, 'Slot Proposal Reminder Rate',     booking_date, slot_remind_rate            FROM rates_joined
    UNION ALL SELECT 11, 'Slot Confirm PN Delivery Rate',   booking_date, slot_confirm_pn_delivery_rate FROM rates_joined
    UNION ALL SELECT 12, 'Tech Assignment Reminder Rate',   booking_date, tech_remind_rate            FROM rates_joined
    UNION ALL SELECT 13, 'Tech PN Delivery Rate',           booking_date, tech_pn_delivery_rate       FROM rates_joined
    UNION ALL SELECT 14, 'P74 Timeout Rate',                booking_date, p74_timeout_rate            FROM rates_joined
    UNION ALL SELECT 15, 'Connection Active Rate',          booking_date, conn_active_rate            FROM rates_joined
)
SELECT
    metric AS METRIC_NAME,
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-1 THEN rate END)*100,1) AS "T-1",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-2 THEN rate END)*100,1) AS "T-2",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-3 THEN rate END)*100,1) AS "T-3",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-4 THEN rate END)*100,1) AS "T-4",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-5 THEN rate END)*100,1) AS "T-5",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-6 THEN rate END)*100,1) AS "T-6",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-7 THEN rate END)*100,1) AS "T-7",
    ROUND(MAX(CASE WHEN booking_date = CURRENT_DATE-8 THEN rate END)*100,1) AS "T-8",
    ROUND(AVG(rate)*100, 1)                                                  AS "Mean",
    ROUND(MEDIAN(rate)*100, 1)                                               AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY rate)*100, 1)         AS "P90"
FROM rates_long
GROUP BY sort_ord, metric
ORDER BY sort_ord
"""

# ── Add more workflow queries here ────────────────────────────────
# QUERIES["service_tickets_health"] = r"""..."""
# QUERIES["pickup_tickets_health"] = r"""..."""
# etc.


def refresh():
    ts = datetime.now().strftime("%Y-%m-%d %H:%M IST")
    data = {}

    for key, sql in QUERIES.items():
        print(f"  Querying {key}...")
        try:
            rows = mb_native(sql)
            data[key] = rows
            print(f"  -> {len(rows)} rows")
        except Exception as e:
            print(f"  ERROR on {key}: {e}")
            data[key] = []

    out = f"// Auto-generated by refresh_workflows.py on {ts}\n"
    out += f"const WORKFLOW_REFRESH_TS = {json.dumps(ts)};\n"
    out += f"const WORKFLOW_DATA = {json.dumps(data, indent=2, default=str)};\n"

    out_path = os.path.join(DIR, "workflow_data.js")
    with open(out_path, "w") as f:
        f.write(out)
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    print("Refreshing workflow dashboard data...")
    refresh()
    print("Done.")
