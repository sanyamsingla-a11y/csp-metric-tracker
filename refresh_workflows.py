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
    COUNT(DISTINCT CASE WHEN cr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                 AS clos_count,
    COUNT(DISTINCT CASE WHEN dr.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                 AS das_count,
    COUNT(DISTINCT CASE WHEN tc.CONNECTION_ID IS NOT NULL THEN bb.CONNECTION_ID END)                 AS tas_count
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
    e.current_state,
    e.failure_reason,
    e.reason_code
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES e
  INNER JOIN bookings_base bb ON bb.CONNECTION_ID = e.connection_id
  WHERE e._fivetran_active
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
    MAX(CASE WHEN ed.event_name = 'install_task_assigned'                                                THEN 1 ELSE 0 END) AS tech_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_TECHNICIAN_ASSIGNED'     THEN 1 ELSE 0 END) AS tech_pn_delivered
  FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
  WHERE ed.event_name IN (
      'install_task_created', 'pn_delivered', 'fpn_delivered',
      'install_customer_slot_confirmed', 'install_task_assigned'
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
  SELECT booking_date AS dt,
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
  GROUP BY 1
)

SELECT sort_ord, metric_name,
  MAX(CASE WHEN dt = CURRENT_DATE - 1 THEN val END)                                                                              AS "T-1",
  MAX(CASE WHEN dt = CURRENT_DATE - 2 THEN val END)                                                                              AS "T-2",
  MAX(CASE WHEN dt = CURRENT_DATE - 3 THEN val END)                                                                              AS "T-3",
  MAX(CASE WHEN dt = CURRENT_DATE - 4 THEN val END)                                                                              AS "T-4",
  MAX(CASE WHEN dt = CURRENT_DATE - 5 THEN val END)                                                                              AS "T-5",
  MAX(CASE WHEN dt = CURRENT_DATE - 6 THEN val END)                                                                              AS "T-6",
  MAX(CASE WHEN dt = CURRENT_DATE - 7 THEN val END)                                                                              AS "T-7",
  MAX(CASE WHEN dt = CURRENT_DATE - 8 THEN val END)                                                                              AS "T-8",
  ROUND(AVG(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1)                                 AS "Average",
  MEDIAN(CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END)                                        AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CASE WHEN dt BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "P90"
FROM (
  SELECT  0 sort_ord, '# Bookings Confirmed'                          metric_name, dt, total_bookings        val FROM daily_conn
  UNION ALL SELECT  1, 'H1: # Connections Created (CLOS)',                         dt, clos_count               FROM daily_conn
  UNION ALL SELECT  2, 'H2: # Connections Reached DAS',                           dt, das_count                FROM daily_conn
  UNION ALL SELECT  3, 'H3: # Tasks Created (TAS)',                               dt, tas_count                FROM daily_conn
  UNION ALL SELECT  4, '# Total Candidates (all cohort)',                          dt, total_candidates         FROM daily_cand
  UNION ALL SELECT  5, 'PN: # Sent to CSP',                                       dt, pn_sent_count            FROM daily_cand
  UNION ALL SELECT  6, 'PN: # Delivered',                                         dt, pn_delivered_count       FROM daily_cand
  UNION ALL SELECT  7, 'FPN: # Delivered',                                        dt, fpn_delivered_count      FROM daily_cand
  UNION ALL SELECT  8, 'Task Attention (PN or FPN delivered)',                     dt, attention_count          FROM daily_cand
  UNION ALL SELECT  9, 'Slot Confirm PN: # Sent',                                 dt, slot_pn_sent_count       FROM daily_cand
  UNION ALL SELECT 10, 'Slot Confirm PN: # Delivered',                            dt, slot_pn_delivered_count  FROM daily_cand
  UNION ALL SELECT 11, 'Tech Assigned PN: # Sent',                                dt, tech_pn_sent_count       FROM daily_cand
  UNION ALL SELECT 12, 'Tech Assigned PN: # Delivered',                           dt, tech_pn_delivered_count  FROM daily_cand
  UNION ALL SELECT 13, 'P41: # Eligible (no slot proposed, deadline hit)',         dt, p41_eligible_count       FROM daily_cand
  UNION ALL SELECT 14, 'P41: # Timeout Triggered',                                dt, p41_timeout_count        FROM daily_cand
  UNION ALL SELECT 15, 'P74: # Eligible (slot confirmed, 72h deadline hit)',       dt, p74_eligible_count       FROM daily_cand
  UNION ALL SELECT 16, 'P74: # Timeout Triggered',                                dt, p74_timeout_count        FROM daily_cand
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
  WHERE TO_DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE-1
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
    MAX(CASE WHEN ed.event_name = 'install_task_assigned'                                                THEN 1 ELSE 0 END) AS tech_pn_sent,
    MAX(CASE WHEN ed.event_name = 'pn_delivered'
              AND TRY_PARSE_JSON(ed.properties):pn_type::STRING = 'ES_INSTALL_TECHNICIAN_ASSIGNED'     THEN 1 ELSE 0 END) AS tech_pn_delivered
  FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
  WHERE ed.event_name IN (
      'install_task_created', 'pn_delivered', 'pn_clicked', 'fpn_delivered', 'fpn_action_taken',
      'install_candidate_opened',
      'install_customer_slot_confirmed', 'install_task_assigned'
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
  ROUND(AVG(CASE WHEN dt BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "Average",
  MEDIAN(CASE WHEN dt BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1 THEN val::FLOAT END)        AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY CASE WHEN dt BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1 THEN val::FLOAT END), 1) AS "P90"
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
    SELECT CONNECTION_ID, MOBILE, DATE(BOOKING_CONFIRM_DATE) AS booking_date
    FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
    WHERE DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
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
        COUNT(DISTINCT b.MOBILE) AS bookings,
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

# ── B2I Efficiency Counts (absolute numbers) ─────────────────────

QUERIES["b2i_efficiency_counts"] = r"""
WITH bookings_base AS (
    SELECT CONNECTION_ID, DATE(BOOKING_CONFIRM_DATE) AS booking_date
    FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
    WHERE DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
),
all_candidates AS (
    SELECT
        iec.EXECUTION_CANDIDATE_ID, iec.CONNECTION_ID, b.booking_date,
        iec.P41_DEADLINE_AT, iec.P74_DEADLINE_AT, iec.CONFIRMED_SLOT_AT,
        iec.PROPOSED_SLOT_DATE, iec.EXECUTOR_ID, iec.CURRENT_STATE,
        iec.COMPLETED_STEP, iec.SECURITY_FEE_PAID_AT, iec.OTP_VERIFIED,
        iec.CUSTOMER_RATING, iec.FAILURE_REASON
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES iec
    JOIN bookings_base b ON b.CONNECTION_ID = iec.CONNECTION_ID
    WHERE iec._FIVETRAN_ACTIVE = TRUE
),
ct_events AS (
    SELECT
        JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id')                               AS execution_id,
        MAX(CASE WHEN EVENT_NAME = 'install_task_created'                                THEN 1 ELSE 0 END) AS pn_sent,
        MAX(CASE WHEN EVENT_NAME = 'pn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS pn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'pn_clicked'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS pn_clicked,
        MAX(CASE WHEN EVENT_NAME = 'fpn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS fpn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'fpn_action_taken'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS fpn_action_taken,
        MAX(CASE WHEN EVENT_NAME = 'install_candidate_opened'                            THEN 1 ELSE 0 END) AS install_candidate_opened
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA
    WHERE JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') IS NOT NULL
      AND JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') != ''
    GROUP BY 1
),
candidate_level AS (
    SELECT
        ac.booking_date,
        COALESCE(ct.pn_sent, 0)                                                                           AS pn_sent,
        COALESCE(ct.pn_delivered, 0)                                                                      AS pn_delivered,
        CASE WHEN COALESCE(ct.pn_delivered,0)=1 AND COALESCE(ct.pn_clicked,0)=1         THEN 1 ELSE 0 END AS pn_clicked,
        COALESCE(ct.fpn_delivered, 0)                                                                     AS fpn_delivered,
        CASE WHEN COALESCE(ct.fpn_delivered,0)=1 AND COALESCE(ct.fpn_action_taken,0)=1  THEN 1 ELSE 0 END AS fpn_action_taken,
        COALESCE(ct.install_candidate_opened, 0)                                                          AS drilldown_open,
        CASE WHEN COALESCE(ct.fpn_delivered,0)=1
              OR  COALESCE(ct.install_candidate_opened,0)=1                              THEN 1 ELSE 0 END AS install_task_open,
        CASE WHEN ac.CURRENT_STATE = 'DECLINED'       THEN 1 ELSE 0 END AS slot_declined,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NOT NULL   THEN 1 ELSE 0 END AS slot_proposed,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL    THEN 1 ELSE 0 END AS slot_confirmed,
        CASE WHEN ac.EXECUTOR_ID IS NOT NULL          THEN 1 ELSE 0 END AS tech_assigned,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 1  THEN 1 ELSE 0 END AS step_selfie,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 2  THEN 1 ELSE 0 END AS step_aadhaar,
        CASE WHEN ac.SECURITY_FEE_PAID_AT IS NOT NULL THEN 1 ELSE 0 END AS step_fee,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 4  THEN 1 ELSE 0 END AS step_shared,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 5  THEN 1 ELSE 0 END AS step_conn_info,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 6  THEN 1 ELSE 0 END AS step_device_photo,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 7  THEN 1 ELSE 0 END AS step_speed_test,
        CASE WHEN ac.OTP_VERIFIED = TRUE              THEN 1 ELSE 0 END AS step_otp_verified,
        CASE WHEN ac.CUSTOMER_RATING IS NOT NULL      THEN 1 ELSE 0 END AS step_rating,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_CUSTOMER' THEN 1 ELSE 0 END AS cancelled_cx,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS cancelled_upstream,
        CASE WHEN ac.FAILURE_REASON IS NOT NULL        THEN 1 ELSE 0 END AS install_failed,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NULL
              AND ac.P41_DEADLINE_AT IS NOT NULL
              AND ac.P41_DEADLINE_AT < CURRENT_TIMESTAMP
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS p41_timeout,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT < CURRENT_TIMESTAMP
              AND COALESCE(ac.COMPLETED_STEP,0) < 8
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS p74_timeout
    FROM all_candidates ac
    LEFT JOIN ct_events ct ON ct.execution_id = ac.EXECUTION_CANDIDATE_ID
),
daily_cand AS (
    SELECT
        booking_date,
        COUNT(*)                  AS total_candidates,
        SUM(pn_sent)              AS pn_sent,
        SUM(pn_delivered)         AS pn_delivered,
        SUM(pn_clicked)           AS pn_clicked,
        SUM(fpn_delivered)        AS fpn_delivered,
        SUM(fpn_action_taken)     AS fpn_action_taken,
        SUM(drilldown_open)       AS drilldown_open,
        SUM(install_task_open)    AS install_task_open,
        SUM(slot_declined)        AS slot_declined,
        SUM(slot_proposed)        AS slot_proposed,
        SUM(slot_confirmed)       AS slot_confirmed,
        SUM(tech_assigned)        AS tech_assigned,
        SUM(step_selfie)          AS step_selfie,
        SUM(step_aadhaar)         AS step_aadhaar,
        SUM(step_fee)             AS step_fee,
        SUM(step_shared)          AS step_shared,
        SUM(step_conn_info)       AS step_conn_info,
        SUM(step_device_photo)    AS step_device_photo,
        SUM(step_speed_test)      AS step_speed_test,
        SUM(step_otp_verified)    AS step_otp_verified,
        SUM(step_rating)          AS step_rating,
        SUM(cancelled_cx)         AS cancelled_cx,
        SUM(cancelled_upstream)   AS cancelled_upstream,
        SUM(install_failed)       AS install_failed,
        SUM(p41_timeout)          AS p41_timeout,
        SUM(p74_timeout)          AS p74_timeout
    FROM candidate_level
    GROUP BY 1
),
counts_long AS (
    SELECT  0 AS sort_ord, '# Total Candidates'      AS metric_name, booking_date, total_candidates  AS val FROM daily_cand
    UNION ALL SELECT  1, '# PN Sent',                booking_date, pn_sent             FROM daily_cand
    UNION ALL SELECT  2, '# PN Delivered',            booking_date, pn_delivered        FROM daily_cand
    UNION ALL SELECT  3, '# PN Clicked',              booking_date, pn_clicked          FROM daily_cand
    UNION ALL SELECT  4, '# FPN Delivered',           booking_date, fpn_delivered       FROM daily_cand
    UNION ALL SELECT  5, '# FPN Action Taken',        booking_date, fpn_action_taken    FROM daily_cand
    UNION ALL SELECT  6, '# Drilldown Open',          booking_date, drilldown_open      FROM daily_cand
    UNION ALL SELECT  7, '# Install Task Open',       booking_date, install_task_open   FROM daily_cand
    UNION ALL SELECT  8, '# Slot Declined',           booking_date, slot_declined       FROM daily_cand
    UNION ALL SELECT  9, '# Slot Proposed',           booking_date, slot_proposed       FROM daily_cand
    UNION ALL SELECT 10, '# Slot Confirmed',          booking_date, slot_confirmed      FROM daily_cand
    UNION ALL SELECT 11, '# Tech Assigned',           booking_date, tech_assigned       FROM daily_cand
    UNION ALL SELECT 12, '# Tech Arrived (Selfie)',   booking_date, step_selfie         FROM daily_cand
    UNION ALL SELECT 13, '# Aadhaar Submitted',       booking_date, step_aadhaar        FROM daily_cand
    UNION ALL SELECT 14, '# SD Fee Paid',             booking_date, step_fee            FROM daily_cand
    UNION ALL SELECT 15, '# ISP Account Created',     booking_date, step_shared         FROM daily_cand
    UNION ALL SELECT 16, '# Device ID Entry',         booking_date, step_conn_info      FROM daily_cand
    UNION ALL SELECT 17, '# Device Photo',            booking_date, step_device_photo   FROM daily_cand
    UNION ALL SELECT 18, '# Speed Test',              booking_date, step_speed_test     FROM daily_cand
    UNION ALL SELECT 19, '# OTP Verified',            booking_date, step_otp_verified   FROM daily_cand
    UNION ALL SELECT 20, '# Customer Rating',         booking_date, step_rating         FROM daily_cand
    UNION ALL SELECT 21, '# Install Failed',          booking_date, install_failed      FROM daily_cand
    UNION ALL SELECT 22, '# Cancelled by Customer',   booking_date, cancelled_cx        FROM daily_cand
    UNION ALL SELECT 23, '# Cancelled by Upstream',   booking_date, cancelled_upstream  FROM daily_cand
    UNION ALL SELECT 24, '# P41 Timeout',             booking_date, p41_timeout         FROM daily_cand
    UNION ALL SELECT 25, '# P74 Timeout',             booking_date, p74_timeout         FROM daily_cand
)
SELECT
    metric_name                                                     AS METRIC_NAME,
    MAX(CASE WHEN booking_date = CURRENT_DATE-1 THEN val END)      AS "T-1",
    MAX(CASE WHEN booking_date = CURRENT_DATE-2 THEN val END)      AS "T-2",
    MAX(CASE WHEN booking_date = CURRENT_DATE-3 THEN val END)      AS "T-3",
    MAX(CASE WHEN booking_date = CURRENT_DATE-4 THEN val END)      AS "T-4",
    MAX(CASE WHEN booking_date = CURRENT_DATE-5 THEN val END)      AS "T-5",
    MAX(CASE WHEN booking_date = CURRENT_DATE-6 THEN val END)      AS "T-6",
    MAX(CASE WHEN booking_date = CURRENT_DATE-7 THEN val END)      AS "T-7",
    MAX(CASE WHEN booking_date = CURRENT_DATE-8 THEN val END)      AS "T-8",
    ROUND(AVG(val::FLOAT), 1)                                      AS "Mean",
    MEDIAN(val::FLOAT)                                              AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val::FLOAT), 1) AS "P90"
FROM counts_long
GROUP BY sort_ord, metric_name
ORDER BY sort_ord
"""

# ── B2I Efficiency Rates (conversion %ages) ──────────────────────

QUERIES["b2i_efficiency"] = r"""
WITH bookings_base AS (
    SELECT CONNECTION_ID, DATE(BOOKING_CONFIRM_DATE) AS booking_date
    FROM PROD_DB.PUBLIC.COMPANY_B_CONNECTION_BOOKING_ENRICHED
    WHERE DATE(BOOKING_CONFIRM_DATE) BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
),
all_candidates AS (
    SELECT
        iec.EXECUTION_CANDIDATE_ID, iec.CONNECTION_ID, b.booking_date,
        iec.P41_DEADLINE_AT, iec.P74_DEADLINE_AT, iec.CONFIRMED_SLOT_AT,
        iec.PROPOSED_SLOT_DATE, iec.EXECUTOR_ID, iec.CURRENT_STATE,
        iec.COMPLETED_STEP, iec.SECURITY_FEE_PAID_AT, iec.OTP_VERIFIED,
        iec.CUSTOMER_RATING, iec.FAILURE_REASON
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES iec
    JOIN bookings_base b ON b.CONNECTION_ID = iec.CONNECTION_ID
    WHERE iec._FIVETRAN_ACTIVE = TRUE
),
ct_events AS (
    SELECT
        JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id')                               AS execution_id,
        MAX(CASE WHEN EVENT_NAME = 'install_task_created'                                THEN 1 ELSE 0 END) AS pn_sent,
        MAX(CASE WHEN EVENT_NAME = 'pn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS pn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'pn_clicked'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS pn_clicked,
        MAX(CASE WHEN EVENT_NAME = 'fpn_delivered'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS fpn_delivered,
        MAX(CASE WHEN EVENT_NAME = 'fpn_action_taken'
                  AND JSON_EXTRACT_PATH_TEXT(PROPERTIES,'pn_type') = 'ES_INSTALL_CANDIDATE_CREATED'
                                                                                         THEN 1 ELSE 0 END) AS fpn_action_taken,
        MAX(CASE WHEN EVENT_NAME = 'install_candidate_opened'                            THEN 1 ELSE 0 END) AS install_candidate_opened
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA
    WHERE JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') IS NOT NULL
      AND JSON_EXTRACT_PATH_TEXT(PROPERTIES, 'execution_id') != ''
    GROUP BY 1
),
candidate_level AS (
    SELECT
        ac.booking_date,
        COALESCE(ct.pn_sent, 0)                                                                           AS pn_sent,
        COALESCE(ct.pn_delivered, 0)                                                                      AS pn_delivered,
        CASE WHEN COALESCE(ct.pn_delivered,0)=1 AND COALESCE(ct.pn_clicked,0)=1         THEN 1 ELSE 0 END AS pn_clicked,
        COALESCE(ct.fpn_delivered, 0)                                                                     AS fpn_delivered,
        CASE WHEN COALESCE(ct.fpn_delivered,0)=1 AND COALESCE(ct.fpn_action_taken,0)=1  THEN 1 ELSE 0 END AS fpn_action_taken,
        COALESCE(ct.install_candidate_opened, 0)                                                          AS drilldown_open,
        CASE WHEN COALESCE(ct.fpn_delivered,0)=1
              OR  COALESCE(ct.install_candidate_opened,0)=1                              THEN 1 ELSE 0 END AS install_task_open,
        CASE WHEN ac.CURRENT_STATE = 'DECLINED'       THEN 1 ELSE 0 END AS slot_declined,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NOT NULL   THEN 1 ELSE 0 END AS slot_proposed,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL    THEN 1 ELSE 0 END AS slot_confirmed,
        CASE WHEN ac.EXECUTOR_ID IS NOT NULL          THEN 1 ELSE 0 END AS tech_assigned,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 1  THEN 1 ELSE 0 END AS step_selfie,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 2  THEN 1 ELSE 0 END AS step_aadhaar,
        CASE WHEN ac.SECURITY_FEE_PAID_AT IS NOT NULL THEN 1 ELSE 0 END AS step_fee,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 4  THEN 1 ELSE 0 END AS step_shared,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 5  THEN 1 ELSE 0 END AS step_conn_info,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 6  THEN 1 ELSE 0 END AS step_device_photo,
        CASE WHEN COALESCE(ac.COMPLETED_STEP,0) >= 7  THEN 1 ELSE 0 END AS step_speed_test,
        CASE WHEN ac.OTP_VERIFIED = TRUE              THEN 1 ELSE 0 END AS step_otp_verified,
        CASE WHEN ac.CUSTOMER_RATING IS NOT NULL      THEN 1 ELSE 0 END AS step_rating,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_CUSTOMER' THEN 1 ELSE 0 END AS cancelled_cx,
        CASE WHEN ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS cancelled_upstream,
        CASE WHEN ac.FAILURE_REASON IS NOT NULL        THEN 1 ELSE 0 END AS install_failed,
        CASE WHEN ac.PROPOSED_SLOT_DATE IS NULL
              AND ac.P41_DEADLINE_AT IS NOT NULL
              AND ac.P41_DEADLINE_AT < CURRENT_TIMESTAMP
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS p41_timeout,
        CASE WHEN ac.CONFIRMED_SLOT_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT IS NOT NULL
              AND ac.P74_DEADLINE_AT < CURRENT_TIMESTAMP
              AND COALESCE(ac.COMPLETED_STEP,0) < 8
              AND ac.CURRENT_STATE = 'CANCELLED_BY_UPSTREAM' THEN 1 ELSE 0 END AS p74_timeout
    FROM all_candidates ac
    LEFT JOIN ct_events ct ON ct.execution_id = ac.EXECUTION_CANDIDATE_ID
),
daily_cand AS (
    SELECT
        booking_date,
        COUNT(*)                  AS total_candidates,
        SUM(pn_sent)              AS pn_sent,
        SUM(pn_delivered)         AS pn_delivered,
        SUM(pn_clicked)           AS pn_clicked,
        SUM(fpn_delivered)        AS fpn_delivered,
        SUM(fpn_action_taken)     AS fpn_action_taken,
        SUM(drilldown_open)       AS drilldown_open,
        SUM(install_task_open)    AS install_task_open,
        SUM(slot_declined)        AS slot_declined,
        SUM(slot_proposed)        AS slot_proposed,
        SUM(slot_confirmed)       AS slot_confirmed,
        SUM(tech_assigned)        AS tech_assigned,
        SUM(step_selfie)          AS step_selfie,
        SUM(step_aadhaar)         AS step_aadhaar,
        SUM(step_fee)             AS step_fee,
        SUM(step_shared)          AS step_shared,
        SUM(step_conn_info)       AS step_conn_info,
        SUM(step_device_photo)    AS step_device_photo,
        SUM(step_speed_test)      AS step_speed_test,
        SUM(step_otp_verified)    AS step_otp_verified,
        SUM(step_rating)          AS step_rating,
        SUM(cancelled_cx)         AS cancelled_cx,
        SUM(cancelled_upstream)   AS cancelled_upstream,
        SUM(install_failed)       AS install_failed,
        SUM(p41_timeout)          AS p41_timeout,
        SUM(p74_timeout)          AS p74_timeout
    FROM candidate_level
    GROUP BY 1
),
rates_joined AS (
    SELECT
        booking_date,
        pn_clicked         * 1.0 / NULLIF(pn_delivered, 0)       AS pn_click_rate,
        fpn_delivered      * 1.0 / NULLIF(total_candidates, 0)   AS fpn_delivery_rate,
        fpn_action_taken   * 1.0 / NULLIF(fpn_delivered, 0)      AS fpn_action_rate,
        drilldown_open     * 1.0 / NULLIF(total_candidates, 0)   AS drilldown_open_rate,
        install_task_open  * 1.0 / NULLIF(total_candidates, 0)   AS task_open_rate,
        (slot_proposed + slot_declined) * 1.0 / NULLIF(install_task_open, 0) AS response_rate,
        slot_declined      * 1.0 / NULLIF(install_task_open, 0)  AS task_decline_rate,
        p41_timeout        * 1.0 / NULLIF(total_candidates, 0)   AS p41_rate_l2,
        slot_proposed      * 1.0 / NULLIF(install_task_open, 0)  AS slot_proposed_rate,
        slot_confirmed     * 1.0 / NULLIF(slot_proposed, 0)      AS slot_confirmed_rate,
        tech_assigned      * 1.0 / NULLIF(slot_confirmed, 0)     AS tech_assigned_rate,
        step_selfie        * 1.0 / NULLIF(tech_assigned, 0)      AS arrival_rate,
        step_aadhaar       * 1.0 / NULLIF(step_selfie, 0)        AS aadhaar_rate,
        step_fee           * 1.0 / NULLIF(step_aadhaar, 0)       AS fee_rate,
        step_shared        * 1.0 / NULLIF(step_fee, 0)           AS isp_creation_rate,
        step_conn_info     * 1.0 / NULLIF(step_shared, 0)        AS device_id_rate,
        step_device_photo  * 1.0 / NULLIF(step_conn_info, 0)     AS device_photo_rate,
        step_speed_test    * 1.0 / NULLIF(step_device_photo, 0)  AS speed_test_rate,
        step_otp_verified  * 1.0 / NULLIF(step_speed_test, 0)    AS happy_code_rate,
        step_rating        * 1.0 / NULLIF(step_otp_verified, 0)  AS happy_code_entered_rate,
        install_failed     * 1.0 / NULLIF(total_candidates, 0)   AS install_fail_rate,
        cancelled_cx       * 1.0 / NULLIF(total_candidates, 0)   AS cancelled_cx_rate,
        cancelled_upstream * 1.0 / NULLIF(total_candidates, 0)   AS cancelled_upstream_rate,
        p74_timeout        * 1.0 / NULLIF(slot_proposed, 0)      AS p74_rate_l2
    FROM daily_cand
),
rates_long AS (
    SELECT 1  AS sort_ord, 'Install PN Click Rate'                          AS metric, booking_date, pn_click_rate             AS rate FROM rates_joined
    UNION ALL SELECT 2,  'FPN Delivery Rate (/Task Created)',               booking_date, fpn_delivery_rate      FROM rates_joined
    UNION ALL SELECT 3,  'FPN Action Taken Rate (/FPN Delivered)',          booking_date, fpn_action_rate        FROM rates_joined
    UNION ALL SELECT 4,  'Drilldown Open Rate',                             booking_date, drilldown_open_rate    FROM rates_joined
    UNION ALL SELECT 5,  'Task Open Rate',                                  booking_date, task_open_rate         FROM rates_joined
    UNION ALL SELECT 6,  'Response Rate ((Proposed+Declined)/Task Open)',   booking_date, response_rate          FROM rates_joined
    UNION ALL SELECT 7,  'Task Decline Rate',                               booking_date, task_decline_rate      FROM rates_joined
    UNION ALL SELECT 8,  'P41 Timeout Rate (L2: /Task Created)',            booking_date, p41_rate_l2            FROM rates_joined
    UNION ALL SELECT 9,  'Slot Proposed Rate',                              booking_date, slot_proposed_rate     FROM rates_joined
    UNION ALL SELECT 10, 'Slot Confirmed Rate',                             booking_date, slot_confirmed_rate    FROM rates_joined
    UNION ALL SELECT 11, 'Technician Assignment Rate',                      booking_date, tech_assigned_rate     FROM rates_joined
    UNION ALL SELECT 12, 'Technician Arrival Rate',                         booking_date, arrival_rate           FROM rates_joined
    UNION ALL SELECT 13, 'Aadhaar Submitted Rate',                          booking_date, aadhaar_rate           FROM rates_joined
    UNION ALL SELECT 14, 'SD Fee Submitted Rate',                           booking_date, fee_rate               FROM rates_joined
    UNION ALL SELECT 15, 'ISP Account Creation Rate',                       booking_date, isp_creation_rate      FROM rates_joined
    UNION ALL SELECT 16, 'Device ID Entry Rate',                            booking_date, device_id_rate         FROM rates_joined
    UNION ALL SELECT 17, 'Device Photo Rate',                               booking_date, device_photo_rate      FROM rates_joined
    UNION ALL SELECT 18, 'Speed Test Rate',                                 booking_date, speed_test_rate        FROM rates_joined
    UNION ALL SELECT 19, 'Happy Code Received Rate',                        booking_date, happy_code_rate        FROM rates_joined
    UNION ALL SELECT 20, 'Happy Code Entered Rate',                         booking_date, happy_code_entered_rate FROM rates_joined
    UNION ALL SELECT 21, 'Install Fail Reported Rate',                      booking_date, install_fail_rate      FROM rates_joined
    UNION ALL SELECT 22, 'Cancelled by Customer Rate',                      booking_date, cancelled_cx_rate      FROM rates_joined
    UNION ALL SELECT 23, 'Cancelled by Upstream Rate',                      booking_date, cancelled_upstream_rate FROM rates_joined
    UNION ALL SELECT 24, 'P74 Timeout Rate (L2: /Slot Proposed)',           booking_date, p74_rate_l2            FROM rates_joined
)
SELECT
    metric                                                                   AS METRIC_NAME,
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

# ── ISP Recharge ────────────────────────────────────────────────

QUERIES["isp_recharge_health"] = r"""
WITH params AS (
  SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today
),
obl AS (
  SELECT CONNECTION_ID AS cid, REASON,
         TO_DATE(DATEADD(minute,330,CREATED_AT))       AS ob_date,
         DATEDIFF('hour', CREATED_AT, WINDOW_END)/24.0 AS days_before_expiry
  FROM CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
  WHERE _FIVETRAN_ACTIVE
    AND STATUS IN ('OPEN','RESOLVED')
    AND CREATED_AT >= DATEADD('day',-15,CURRENT_DATE())
),
recharged AS (
  SELECT DISTINCT CONNECTION_ID AS cid
  FROM CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES
  WHERE _FIVETRAN_ACTIVE AND DETECTION_SOURCE='CSP'
    AND CREATED_AT >= DATEADD('day',-15,CURRENT_DATE())
),
resumed AS (
  SELECT DISTINCT CONNECTION_ID AS cid
  FROM CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
  WHERE EVENT_TYPE='RECHARGE_CONFIRMED'
    AND PROCESSING_OUTCOME IN ('TRANSITIONED','RECORDED_ONLY')
    AND CREATED_AT >= DATEADD('day',-15,CURRENT_DATE())
),
ontime AS (
  SELECT DISTINCT CONNECTION_ID AS cid
  FROM CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
  WHERE EVENT_TYPE='RECHARGE_CONFIRMED' AND PREVIOUS_STATE='ACTIVE'
    AND PROCESSING_OUTCOME='RECORDED_ONLY'
    AND CREATED_AT >= DATEADD('day',-15,CURRENT_DATE())
),
per_day AS (
  SELECT
    o.ob_date                                                 AS d,
    COUNT(*)                                                  AS obligations,
    SUM(IFF(ot.cid IS NOT NULL,1,0))                          AS ontime,
    SUM(IFF(r.cid  IS NOT NULL,1,0))                          AS recharged,
    SUM(IFF(r.cid  IS NOT NULL AND res.cid IS NOT NULL,1,0))  AS resumed_recharged
  FROM obl o
  LEFT JOIN recharged r  ON r.cid=o.cid
  LEFT JOIN resumed  res ON res.cid=o.cid
  LEFT JOIN ontime   ot  ON ot.cid=o.cid
  GROUP BY o.ob_date
),
daily_rates AS (
  SELECT
    d,
    ROUND(100.0*ontime    /NULLIF(obligations,0),1) AS ontime_rate,
    ROUND(100.0*recharged /NULLIF(obligations,0),1) AS recharge_rate,
    ROUND(100.0*resumed_recharged/NULLIF(recharged,0),1) AS resume_rate
  FROM per_day
),
date_range AS (
  SELECT DATEADD('day', -(ROW_NUMBER() OVER (ORDER BY 1) - 1),
                 (SELECT today FROM params)) AS dt
  FROM TABLE(GENERATOR(ROWCOUNT => 8))
),
covered_connections AS (
  SELECT DISTINCT r.connection_id, d.dt
  FROM PROD_DB.CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES r
  JOIN date_range d ON d.dt BETWEEN r.WINDOW_START::date AND r.WINDOW_END::date
),
active_connections AS (
  SELECT DISTINCT c.connection_id, d.dt
  FROM T_ROUTER_USER_MAPPING trum
  JOIN t_wg_customer tg ON trum.mobile = tg.mobile
  JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
    ON c.customer_id = tg.account_id
  JOIN date_range d ON d.dt BETWEEN trum.OTP_ISSUED_TIME::date AND trum.OTP_EXPIRY_TIME::date
),
isp_expired_daily AS (
  SELECT
    d.dt,
    ROUND(
      100.0 * COUNT(DISTINCT CASE WHEN cc.connection_id IS NULL THEN ac.connection_id END)
            / NULLIF(COUNT(DISTINCT ac.connection_id), 0),
    1) AS isp_expired_pct
  FROM date_range d
  JOIN active_connections ac ON ac.dt = d.dt
  LEFT JOIN covered_connections cc ON cc.connection_id = ac.connection_id AND cc.dt = d.dt
  GROUP BY d.dt
),
commission_daily AS (
  SELECT
    DATE(DATEADD(minute, 330, UPDATED_AT)) AS d,
    ROUND(100.0 * SUM(CASE WHEN state = 'ACTION_REQUIRED' THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 2) AS commission_open_rate
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RECHARGE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE
    AND commission_status = 'DISBURSED'
    AND UPDATED_AT >= DATEADD('day', -15, CURRENT_DATE())
  GROUP BY DATE(DATEADD(minute, 330, UPDATED_AT))
),
migrated_customers AS (
  SELECT account_id, mobile
  FROM T_WG_CUSTOMER
  WHERE lco_account_id IN (
    SELECT DISTINCT partner_id
    FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _fivetran_active
  )
),
puts_all AS (
  SELECT
    n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
    n.created_at AS put_created_at, n.state AS nbrec_state, n.reason_code, c.customer_id
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
  JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
    ON c.connection_id = n.LAST_CONNECTION_ID AND c._fivetran_active
  WHERE n._fivetran_active
    AND n.created_at >= CURRENT_DATE - 90
    AND n.created_at <= CURRENT_DATE - 21
),
puts_with_customer AS (
  SELECT p.*, mc.mobile
  FROM puts_all p
  JOIN migrated_customers mc ON mc.account_id = p.customer_id
),
puts_no_recharge_in_21d AS (
  SELECT pw.*
  FROM puts_with_customer pw
  WHERE NOT EXISTS (
    SELECT 1 FROM T_ROUTER_USER_MAPPING trum
    WHERE trum.mobile = pw.mobile AND trum.otp = 'DONE'
      AND trum.store_group_id = 0 AND trum.device_limit = 10
      AND trum.mobile > '5999999999'
      AND trum.OTP_ISSUED_TIME > pw.put_created_at
      AND trum.OTP_ISSUED_TIME <= DATEADD(day,21,pw.put_created_at)
  )
),
first_recharge_post_21d AS (
  SELECT
    p.EXECUTION_CANDIDATE_ID, p.DEVICE_ID, p.LAST_CONNECTION_ID,
    p.put_created_at, p.nbrec_state, p.reason_code, p.mobile,
    MIN(trum.OTP_ISSUED_TIME) AS recharge_at
  FROM puts_no_recharge_in_21d p
  JOIN T_ROUTER_USER_MAPPING trum
    ON trum.mobile = p.mobile AND trum.otp = 'DONE'
    AND trum.store_group_id = 0 AND trum.device_limit = 10
    AND trum.mobile > '5999999999'
    AND trum.OTP_ISSUED_TIME > DATEADD(day,21,p.put_created_at)
  GROUP BY p.EXECUTION_CANDIDATE_ID, p.DEVICE_ID, p.LAST_CONNECTION_ID,
           p.put_created_at, p.nbrec_state, p.reason_code, p.mobile
),
acs_transition AS (
  SELECT device_id, created_at AS acs_transition_at
  FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG
  WHERE to_state = 'DEPLOYED' AND created_at >= CURRENT_DATE - 91
),
clos_transition AS (
  SELECT connection_id, created_at AS clos_transition_at
  FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
  WHERE RESULTING_STATE IN ('ACTIVE','PAUSED') AND created_at >= CURRENT_DATE - 91
),
nbrec_daily AS (
  SELECT
    DATE(DATEADD(minute,330,pr.recharge_at)) AS d,
    ROUND(COUNT(CASE WHEN pr.nbrec_state = 'FAILED' THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 2) AS nbrec_failed_pct,
    ROUND(COUNT(CASE WHEN at2.acs_transition_at IS NOT NULL THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 2) AS acs_deployed_pct,
    ROUND(COUNT(CASE WHEN ct.clos_transition_at IS NOT NULL THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 2) AS clos_active_pct
  FROM first_recharge_post_21d pr
  LEFT JOIN acs_transition at2
    ON at2.device_id = pr.DEVICE_ID
    AND ABS(DATEDIFF(day, pr.recharge_at, at2.acs_transition_at)) <= 1
  LEFT JOIN clos_transition ct
    ON ct.connection_id = pr.LAST_CONNECTION_ID
    AND ABS(DATEDIFF(day, pr.recharge_at, ct.clos_transition_at)) <= 1
  GROUP BY DATE(DATEADD(minute,330,pr.recharge_at))
),
agg AS (
  SELECT
    MAX(IFF(d=p.today,   ontime_rate,NULL)) AS ot_d0,
    MAX(IFF(d=p.today-1, ontime_rate,NULL)) AS ot_d1,
    MAX(IFF(d=p.today-2, ontime_rate,NULL)) AS ot_d2,
    MAX(IFF(d=p.today-3, ontime_rate,NULL)) AS ot_d3,
    MAX(IFF(d=p.today-4, ontime_rate,NULL)) AS ot_d4,
    MAX(IFF(d=p.today-5, ontime_rate,NULL)) AS ot_d5,
    MAX(IFF(d=p.today-6, ontime_rate,NULL)) AS ot_d6,
    MAX(IFF(d=p.today-7, ontime_rate,NULL)) AS ot_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, ontime_rate,NULL)),1) AS ot_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, ontime_rate,NULL)),1) AS ot_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, ontime_rate,NULL)),1) AS ot_p90,
    MAX(IFF(d=p.today,   recharge_rate,NULL)) AS rc_d0,
    MAX(IFF(d=p.today-1, recharge_rate,NULL)) AS rc_d1,
    MAX(IFF(d=p.today-2, recharge_rate,NULL)) AS rc_d2,
    MAX(IFF(d=p.today-3, recharge_rate,NULL)) AS rc_d3,
    MAX(IFF(d=p.today-4, recharge_rate,NULL)) AS rc_d4,
    MAX(IFF(d=p.today-5, recharge_rate,NULL)) AS rc_d5,
    MAX(IFF(d=p.today-6, recharge_rate,NULL)) AS rc_d6,
    MAX(IFF(d=p.today-7, recharge_rate,NULL)) AS rc_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, recharge_rate,NULL)),1) AS rc_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, recharge_rate,NULL)),1) AS rc_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, recharge_rate,NULL)),1) AS rc_p90
  FROM daily_rates CROSS JOIN params p
),
isp_agg AS (
  SELECT
    MAX(IFF(dt=p.today,   isp_expired_pct,NULL)) AS pa_d0,
    MAX(IFF(dt=p.today-1, isp_expired_pct,NULL)) AS pa_d1,
    MAX(IFF(dt=p.today-2, isp_expired_pct,NULL)) AS pa_d2,
    MAX(IFF(dt=p.today-3, isp_expired_pct,NULL)) AS pa_d3,
    MAX(IFF(dt=p.today-4, isp_expired_pct,NULL)) AS pa_d4,
    MAX(IFF(dt=p.today-5, isp_expired_pct,NULL)) AS pa_d5,
    MAX(IFF(dt=p.today-6, isp_expired_pct,NULL)) AS pa_d6,
    MAX(IFF(dt=p.today-7, isp_expired_pct,NULL)) AS pa_d7,
    ROUND(AVG(IFF(dt BETWEEN p.today-7 AND p.today, isp_expired_pct,NULL)),1) AS pa_avg,
    ROUND(MEDIAN(IFF(dt BETWEEN p.today-7 AND p.today, isp_expired_pct,NULL)),1) AS pa_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(dt BETWEEN p.today-7 AND p.today, isp_expired_pct,NULL)),1) AS pa_p90
  FROM isp_expired_daily CROSS JOIN params p
),
commission_agg AS (
  SELECT
    MAX(IFF(d=p.today,   commission_open_rate,NULL)) AS cm_d0,
    MAX(IFF(d=p.today-1, commission_open_rate,NULL)) AS cm_d1,
    MAX(IFF(d=p.today-2, commission_open_rate,NULL)) AS cm_d2,
    MAX(IFF(d=p.today-3, commission_open_rate,NULL)) AS cm_d3,
    MAX(IFF(d=p.today-4, commission_open_rate,NULL)) AS cm_d4,
    MAX(IFF(d=p.today-5, commission_open_rate,NULL)) AS cm_d5,
    MAX(IFF(d=p.today-6, commission_open_rate,NULL)) AS cm_d6,
    MAX(IFF(d=p.today-7, commission_open_rate,NULL)) AS cm_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, commission_open_rate,NULL)),1) AS cm_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, commission_open_rate,NULL)),1) AS cm_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, commission_open_rate,NULL)),1) AS cm_p90
  FROM commission_daily CROSS JOIN params p
),
nbrec_agg AS (
  SELECT
    MAX(IFF(d=p.today,   nbrec_failed_pct,NULL)) AS nb_d0,
    MAX(IFF(d=p.today-1, nbrec_failed_pct,NULL)) AS nb_d1,
    MAX(IFF(d=p.today-2, nbrec_failed_pct,NULL)) AS nb_d2,
    MAX(IFF(d=p.today-3, nbrec_failed_pct,NULL)) AS nb_d3,
    MAX(IFF(d=p.today-4, nbrec_failed_pct,NULL)) AS nb_d4,
    MAX(IFF(d=p.today-5, nbrec_failed_pct,NULL)) AS nb_d5,
    MAX(IFF(d=p.today-6, nbrec_failed_pct,NULL)) AS nb_d6,
    MAX(IFF(d=p.today-7, nbrec_failed_pct,NULL)) AS nb_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, nbrec_failed_pct,NULL)),1) AS nb_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, nbrec_failed_pct,NULL)),1) AS nb_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, nbrec_failed_pct,NULL)),1) AS nb_p90,
    MAX(IFF(d=p.today,   acs_deployed_pct,NULL)) AS acs_d0,
    MAX(IFF(d=p.today-1, acs_deployed_pct,NULL)) AS acs_d1,
    MAX(IFF(d=p.today-2, acs_deployed_pct,NULL)) AS acs_d2,
    MAX(IFF(d=p.today-3, acs_deployed_pct,NULL)) AS acs_d3,
    MAX(IFF(d=p.today-4, acs_deployed_pct,NULL)) AS acs_d4,
    MAX(IFF(d=p.today-5, acs_deployed_pct,NULL)) AS acs_d5,
    MAX(IFF(d=p.today-6, acs_deployed_pct,NULL)) AS acs_d6,
    MAX(IFF(d=p.today-7, acs_deployed_pct,NULL)) AS acs_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, acs_deployed_pct,NULL)),1) AS acs_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, acs_deployed_pct,NULL)),1) AS acs_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, acs_deployed_pct,NULL)),1) AS acs_p90,
    MAX(IFF(d=p.today,   clos_active_pct,NULL)) AS cl_d0,
    MAX(IFF(d=p.today-1, clos_active_pct,NULL)) AS cl_d1,
    MAX(IFF(d=p.today-2, clos_active_pct,NULL)) AS cl_d2,
    MAX(IFF(d=p.today-3, clos_active_pct,NULL)) AS cl_d3,
    MAX(IFF(d=p.today-4, clos_active_pct,NULL)) AS cl_d4,
    MAX(IFF(d=p.today-5, clos_active_pct,NULL)) AS cl_d5,
    MAX(IFF(d=p.today-6, clos_active_pct,NULL)) AS cl_d6,
    MAX(IFF(d=p.today-7, clos_active_pct,NULL)) AS cl_d7,
    ROUND(AVG(IFF(d BETWEEN p.today-7 AND p.today, clos_active_pct,NULL)),1) AS cl_avg,
    ROUND(MEDIAN(IFF(d BETWEEN p.today-7 AND p.today, clos_active_pct,NULL)),1) AS cl_med,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.today-7 AND p.today, clos_active_pct,NULL)),1) AS cl_p90
  FROM nbrec_daily CROSS JOIN params p
)
SELECT metric,
  "Today", "T-1", "T-2", "T-3", "T-4", "T-5", "T-6", "T-7",
  "Average", "Median", "P90"
FROM (
  SELECT 1 AS sort_ord, 'On-Time Recharge Rate' AS metric,
    ot_d0 AS "Today", ot_d1 AS "T-1", ot_d2 AS "T-2", ot_d3 AS "T-3",
    ot_d4 AS "T-4", ot_d5 AS "T-5", ot_d6 AS "T-6", ot_d7 AS "T-7",
    ot_avg AS "Average", ot_med AS "Median", ot_p90 AS "P90"
  FROM agg
  UNION ALL
  SELECT 2, 'Supply-Caused Pause Rate',
    pa_d0, pa_d1, pa_d2, pa_d3, pa_d4, pa_d5, pa_d6, pa_d7, pa_avg, pa_med, pa_p90
  FROM isp_agg
  UNION ALL
  SELECT 3, 'Recharge Completion Rate',
    rc_d0, rc_d1, rc_d2, rc_d3, rc_d4, rc_d5, rc_d6, rc_d7, rc_avg, rc_med, rc_p90
  FROM agg
  UNION ALL
  SELECT 4, 'Commission Claimed Ticket Open Rate',
    cm_d0, cm_d1, cm_d2, cm_d3, cm_d4, cm_d5, cm_d6, cm_d7, cm_avg, cm_med, cm_p90
  FROM commission_agg
  UNION ALL
  SELECT 5, 'NBREC - Failed (CX Recharged after 21 days of PUT creation)',
    nb_d0, nb_d1, nb_d2, nb_d3, nb_d4, nb_d5, nb_d6, nb_d7, nb_avg, nb_med, nb_p90
  FROM nbrec_agg
  UNION ALL
  SELECT 6, 'ACS - Deployed within 1d (CX Recharged after 21 days of PUT creation)',
    acs_d0, acs_d1, acs_d2, acs_d3, acs_d4, acs_d5, acs_d6, acs_d7, acs_avg, acs_med, acs_p90
  FROM nbrec_agg
  UNION ALL
  SELECT 7, 'CLOS - Active within 1d (CX Recharged after 21 days of PUT creation)',
    cl_d0, cl_d1, cl_d2, cl_d3, cl_d4, cl_d5, cl_d6, cl_d7, cl_avg, cl_med, cl_p90
  FROM nbrec_agg
) x
ORDER BY sort_ord
"""

QUERIES["isp_recharge_obligations_resolved"] = r"""
SELECT
    DATE(UPDATED_AT)                                                        AS resolved_dt,
    REASON,
    COUNT(*)                                                                AS resolved_count,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY DATEDIFF('hour', CREATED_AT, UPDATED_AT)), 1)  AS p50_hrs,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY DATEDIFF('hour', CREATED_AT, UPDATED_AT)), 1)  AS p90_hrs,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY DATEDIFF('hour', CREATED_AT, UPDATED_AT)), 1)  AS p99_hrs
FROM PROD_DB.CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
WHERE _FIVETRAN_ACTIVE = TRUE
  AND status = 'RESOLVED'
GROUP BY DATE(UPDATED_AT), REASON
ORDER BY resolved_dt DESC, REASON
LIMIT 10000
"""

QUERIES["isp_recharge_rdni"] = r"""
WITH rdni_complaints AS (
    SELECT
        connection_id,
        complaint_id,
        CREATED_AT AS complaint_time
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND SECONDARY_SUBTYPE = 'RECHARGE_DONE_NO_INTERNET'
),
resolved_tickets AS (
    SELECT
        DATE(UPDATED_AT)         AS resolved_dt,
        EXECUTION_CANDIDATE_ID,
        connection_id,
        UPDATED_AT               AS resolved_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RECHARGE_EXECUTION_CANDIDATES
    WHERE state = 'RESOLVED'
      AND _FIVETRAN_ACTIVE = TRUE
),
joined AS (
    SELECT
        rt.resolved_dt,
        rt.EXECUTION_CANDIDATE_ID,
        rt.connection_id,
        MAX(CASE WHEN rc.complaint_id IS NOT NULL THEN 1 ELSE 0 END) AS had_rdni
    FROM resolved_tickets rt
    LEFT JOIN rdni_complaints rc
        ON  rc.connection_id  = rt.connection_id
        AND rc.complaint_time >= rt.resolved_at
        AND rc.complaint_time <  DATEADD(day, 3, rt.resolved_at)
    GROUP BY rt.resolved_dt, rt.EXECUTION_CANDIDATE_ID, rt.connection_id
)
SELECT
    resolved_dt,
    COUNT(*)                                                              AS total_resolved_tickets,
    SUM(had_rdni)                                                         AS tickets_with_rdni_within_3d,
    ROUND(100.0 * SUM(had_rdni) / NULLIF(COUNT(*), 0), 1)               AS rdni_within_3d_pct
FROM joined
GROUP BY resolved_dt
ORDER BY resolved_dt DESC
LIMIT 10000
"""

# ── Device Ordering ──────────────────────────────────────────────

QUERIES["device_ordering_health_counts"] = r"""
WITH
orders AS (
    SELECT
        do.REQUEST_ID,
        do.STATUS                                                 AS order_status,
        TO_DATE(DATEADD(minute, 330, do.UPDATED_AT))              AS order_date,
        f.value::STRING                                           AS device_id
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.DEVICE_ORDERS do,
         LATERAL FLATTEN(input => TRY_PARSE_JSON(do.NETBOX_IDS)) f
    WHERE do.STATUS IN ('DISPATCHED', 'FULFILLED')
      AND do.NETBOX_IDS IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY do.REQUEST_ID, do.STATUS ORDER BY do.UPDATED_AT) = 1
),
nc_history AS (
    SELECT DEVICE_ID, STATUS,
           TO_DATE(DATEADD(minute, 330, UPDATED_AT)) AS nc_date
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY
),
device_checks AS (
    SELECT o.order_status, o.order_date, o.device_id,
        CASE WHEN o.order_status = 'DISPATCHED' AND EXISTS (
            SELECT 1 FROM nc_history nc
            WHERE nc.DEVICE_ID = o.device_id AND nc.STATUS = 'PENDING_CSP_RECEIPT' AND nc.nc_date = o.order_date
        ) THEN 1 ELSE 0 END AS dispatched_ok,
        CASE WHEN o.order_status = 'FULFILLED' AND EXISTS (
            SELECT 1 FROM nc_history nc
            WHERE nc.DEVICE_ID = o.device_id AND nc.STATUS = 'CUSTODIED' AND nc.nc_date = o.order_date
        ) THEN 1 ELSE 0 END AS fulfilled_ok
    FROM orders o
    WHERE o.order_date BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
),
q1 AS (
    SELECT order_date AS dt,
        'Dispatched -> Pending CSP Receipt' AS metric,
        SUM(CASE WHEN order_status='DISPATCHED' THEN 1 ELSE 0 END) AS total,
        SUM(dispatched_ok)                                          AS matched
    FROM device_checks GROUP BY 1
    UNION ALL
    SELECT order_date,
        'Fulfilled -> Custodied',
        SUM(CASE WHEN order_status='FULFILLED' THEN 1 ELSE 0 END),
        SUM(fulfilled_ok)
    FROM device_checks GROUP BY 1
),
wallet_deductions AS (
    SELECT DATE(DATEADD(minute, 330, created_at)) AS dt, ABS(SUM(amount)) AS amt_deducted
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES
    WHERE _fivetran_active AND entry_type = 'NETBOX_SECURITY_DEDUCTION'
      AND DATE(DATEADD(minute, 330, created_at)) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
    GROUP BY 1
),
deposit_additions AS (
    SELECT DATE(DATEADD(minute, 330, created_at)) AS dt, SUM(amount) AS amt_added
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.DEPOSIT_LEDGER_ENTRIES
    WHERE _fivetran_active AND entry_type = 'SECURITY_FROM_WALLET'
      AND DATE(DATEADD(minute, 330, created_at)) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
    GROUP BY 1
),
q2 AS (
    SELECT COALESCE(w.dt, d.dt) AS dt,
        'Wallet Deducted -> Deposit Added'   AS metric,
        COALESCE(w.amt_deducted, 0)         AS total,
        COALESCE(d.amt_added, 0)            AS matched
    FROM wallet_deductions w
    FULL OUTER JOIN deposit_additions d ON w.dt = d.dt
),
t1 AS (
    SELECT DATE(modified_time) AS dt, da.device_id
    FROM PROD_DB.POSTGRES_RDS_INVENTORY_INVENTORY.T_DEVICE_AUDIT da
    WHERE da.status = 'IN_WAREHOUSE'
      AND DATE(modified_time) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
      AND EXISTS (
          SELECT 1 FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
          WHERE nc.DEVICE_ID = da.device_id
      )
),
t2 AS (
    SELECT DATE(created_at) AS dt, device_id
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG
    WHERE to_state = 'RETURNED'
      AND DATE(created_at) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
),
t1_daily AS (SELECT dt, COUNT(DISTINCT device_id) AS t1_ct FROM t1 GROUP BY dt),
t2_daily AS (SELECT dt, COUNT(DISTINCT device_id) AS t2_ct FROM t2 GROUP BY dt),
matched  AS (
    SELECT t1.dt, COUNT(DISTINCT t1.device_id) AS matched_ct
    FROM t1 INNER JOIN t2 ON t1.dt = t2.dt AND t1.device_id = t2.device_id
    GROUP BY t1.dt
),
q3 AS (
    SELECT COALESCE(t1_daily.dt, t2_daily.dt) AS dt,
        'Returned to Warehouse Match Rate'     AS metric,
        COALESCE(t1_daily.t1_ct, 0)           AS total,
        COALESCE(matched.matched_ct, 0)        AS matched
    FROM t1_daily
    FULL OUTER JOIN t2_daily ON t1_daily.dt = t2_daily.dt
    LEFT JOIN matched ON matched.dt = COALESCE(t1_daily.dt, t2_daily.dt)
),
all_metrics AS (
    SELECT * FROM q1
    UNION ALL SELECT * FROM q2
    UNION ALL SELECT * FROM q3
)
SELECT
    metric,
    MAX(CASE WHEN dt = CURRENT_DATE-1 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-1",
    MAX(CASE WHEN dt = CURRENT_DATE-2 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-2",
    MAX(CASE WHEN dt = CURRENT_DATE-3 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-3",
    MAX(CASE WHEN dt = CURRENT_DATE-4 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-4",
    MAX(CASE WHEN dt = CURRENT_DATE-5 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-5",
    MAX(CASE WHEN dt = CURRENT_DATE-6 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-6",
    MAX(CASE WHEN dt = CURRENT_DATE-7 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-7",
    MAX(CASE WHEN dt = CURRENT_DATE-8 THEN total::VARCHAR || ' | ' || matched::VARCHAR END) AS "T-8"
FROM all_metrics
GROUP BY metric
ORDER BY metric
"""

QUERIES["device_ordering_health"] = r"""
WITH
orders AS (
    SELECT
        do.REQUEST_ID,
        do.STATUS                                                 AS order_status,
        TO_DATE(DATEADD(minute, 330, do.UPDATED_AT))              AS order_date,
        f.value::STRING                                           AS device_id
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.DEVICE_ORDERS do,
         LATERAL FLATTEN(input => TRY_PARSE_JSON(do.NETBOX_IDS)) f
    WHERE do.STATUS IN ('DISPATCHED', 'FULFILLED')
      AND do.NETBOX_IDS IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY do.REQUEST_ID, do.STATUS ORDER BY do.UPDATED_AT) = 1
),
nc_history AS (
    SELECT DEVICE_ID, STATUS,
           TO_DATE(DATEADD(minute, 330, UPDATED_AT)) AS nc_date
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY
),
device_checks AS (
    SELECT o.order_status, o.order_date, o.device_id,
        CASE WHEN o.order_status = 'DISPATCHED' AND EXISTS (
            SELECT 1 FROM nc_history nc
            WHERE nc.DEVICE_ID = o.device_id AND nc.STATUS = 'PENDING_CSP_RECEIPT' AND nc.nc_date = o.order_date
        ) THEN 1 ELSE 0 END AS dispatched_ok,
        CASE WHEN o.order_status = 'FULFILLED' AND EXISTS (
            SELECT 1 FROM nc_history nc
            WHERE nc.DEVICE_ID = o.device_id AND nc.STATUS = 'CUSTODIED' AND nc.nc_date = o.order_date
        ) THEN 1 ELSE 0 END AS fulfilled_ok
    FROM orders o
    WHERE o.order_date BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
),
q1 AS (
    SELECT order_date AS dt,
        'Dispatched -> Pending CSP Receipt'  AS metric,
        ROUND(100.0 * SUM(dispatched_ok) / NULLIF(SUM(CASE WHEN order_status='DISPATCHED' THEN 1 ELSE 0 END), 0), 2) AS pct
    FROM device_checks GROUP BY 1
    UNION ALL
    SELECT order_date,
        'Fulfilled -> Custodied',
        ROUND(100.0 * SUM(fulfilled_ok) / NULLIF(SUM(CASE WHEN order_status='FULFILLED' THEN 1 ELSE 0 END), 0), 2)
    FROM device_checks GROUP BY 1
),
wallet_deductions AS (
    SELECT DATE(DATEADD(minute, 330, created_at)) AS dt, ABS(SUM(amount)) AS amt_deducted
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES
    WHERE _fivetran_active AND entry_type = 'NETBOX_SECURITY_DEDUCTION'
      AND DATE(DATEADD(minute, 330, created_at)) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
    GROUP BY 1
),
deposit_additions AS (
    SELECT DATE(DATEADD(minute, 330, created_at)) AS dt, SUM(amount) AS amt_added
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.DEPOSIT_LEDGER_ENTRIES
    WHERE _fivetran_active AND entry_type = 'SECURITY_FROM_WALLET'
      AND DATE(DATEADD(minute, 330, created_at)) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
    GROUP BY 1
),
q2 AS (
    SELECT COALESCE(w.dt, d.dt) AS dt,
        'Wallet Deducted -> Deposit Added' AS metric,
        CASE WHEN COALESCE(w.amt_deducted, 0) = 0 THEN NULL
             ELSE ROUND(COALESCE(d.amt_added, 0) / w.amt_deducted * 100, 2)
        END AS pct
    FROM wallet_deductions w
    FULL OUTER JOIN deposit_additions d ON w.dt = d.dt
),
t1 AS (
    SELECT DATE(modified_time) AS dt, da.device_id
    FROM PROD_DB.POSTGRES_RDS_INVENTORY_INVENTORY.T_DEVICE_AUDIT da
    WHERE da.status = 'IN_WAREHOUSE'
      AND DATE(modified_time) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
      AND EXISTS (
          SELECT 1 FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
          WHERE nc.DEVICE_ID = da.device_id
      )
),
t2 AS (
    SELECT DATE(created_at) AS dt, device_id
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG
    WHERE to_state = 'RETURNED'
      AND DATE(created_at) BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 1
),
t1_daily AS (SELECT dt, COUNT(DISTINCT device_id) AS t1_ct FROM t1 GROUP BY dt),
t2_daily AS (SELECT dt, COUNT(DISTINCT device_id) AS t2_ct FROM t2 GROUP BY dt),
matched  AS (
    SELECT t1.dt, COUNT(DISTINCT t1.device_id) AS matched_ct
    FROM t1 INNER JOIN t2 ON t1.dt = t2.dt AND t1.device_id = t2.device_id
    GROUP BY t1.dt
),
q3 AS (
    SELECT COALESCE(t1_daily.dt, t2_daily.dt) AS dt,
        'Returned to Warehouse Match Rate' AS metric,
        ROUND(100.0 * COALESCE(matched.matched_ct, 0) / NULLIF(COALESCE(t1_daily.t1_ct, 0), 0), 2) AS pct
    FROM t1_daily
    FULL OUTER JOIN t2_daily ON t1_daily.dt = t2_daily.dt
    LEFT JOIN matched ON matched.dt = COALESCE(t1_daily.dt, t2_daily.dt)
),
all_metrics AS (
    SELECT * FROM q1
    UNION ALL SELECT * FROM q2
    UNION ALL SELECT * FROM q3
)
SELECT
    metric,
    MAX(CASE WHEN dt = CURRENT_DATE - 1 THEN pct END) AS "T-1",
    MAX(CASE WHEN dt = CURRENT_DATE - 2 THEN pct END) AS "T-2",
    MAX(CASE WHEN dt = CURRENT_DATE - 3 THEN pct END) AS "T-3",
    MAX(CASE WHEN dt = CURRENT_DATE - 4 THEN pct END) AS "T-4",
    MAX(CASE WHEN dt = CURRENT_DATE - 5 THEN pct END) AS "T-5",
    MAX(CASE WHEN dt = CURRENT_DATE - 6 THEN pct END) AS "T-6",
    MAX(CASE WHEN dt = CURRENT_DATE - 7 THEN pct END) AS "T-7",
    MAX(CASE WHEN dt = CURRENT_DATE - 8 THEN pct END) AS "T-8",
    ROUND(AVG(pct), 1)                                 AS "Mean",
    MEDIAN(pct)                                        AS "Median",
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY pct)   AS "P90"
FROM all_metrics
GROUP BY metric
ORDER BY metric
"""

QUERIES["service_tickets_health"] = r"""
SELECT * FROM (
  WITH migrated AS (
    SELECT DISTINCT ca.CSP_ID
    FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT ca
    WHERE ca._FIVETRAN_ACTIVE = TRUE AND ca.STATUS = 'ACTIVE'
  ),
  csp_partner AS (
    SELECT DISTINCT ca.PARTNER_ID
    FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT ca
    WHERE ca._FIVETRAN_ACTIVE = TRUE AND ca.STATUS = 'ACTIVE' AND ca.PARTNER_ID IS NOT NULL
  ),
  kap AS (
    SELECT TICKET_ID, DATE(DATEADD(MINUTE, 330, TICKET_ADDED_TIME::TIMESTAMP_NTZ)) AS dt
    FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL
    WHERE LAST_TITLE ILIKE 'Internet Issues%'
      AND CURRENT_PARTNER_ACCOUNT_ID IN (SELECT PARTNER_ID FROM csp_partner)
      AND DATE(DATEADD(MINUTE, 330, TICKET_ADDED_TIME::TIMESTAMP_NTZ)) >= DATEADD('day', -30, CURRENT_DATE())
  ),
  comp_ids AS (
    SELECT DISTINCT TICKET_ID
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID NOT LIKE 'prod-test%'
      AND SECONDARY_SUBTYPE IN ('OPTICAL_POWER_OUT_OF_RANGE','RECHARGE_DONE_NO_INTERNET','FREQUENT_DISCONNECTION','SLOW_INTERNET','NO_INTERNET')
      AND CSP_ID IN (SELECT CSP_ID FROM migrated)
  ),
  base AS (
    SELECT k.dt, k.TICKET_ID AS entity_id, CASE WHEN c.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS flag
    FROM kap k LEFT JOIN comp_ids c ON k.TICKET_ID = c.TICKET_ID
  ),
  daily AS (
    SELECT dt, ROUND(100.0 * COUNT(DISTINCT CASE WHEN flag = 1 THEN entity_id END) / NULLIF(COUNT(DISTINCT entity_id), 0), 1) AS val
    FROM base GROUP BY dt
  )
  SELECT 'Service Ticket (Kapture-SRS-TAS) Match Rate' AS metric,
    MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM daily
)
UNION ALL
SELECT * FROM (
  WITH csp_universe AS (
    SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
  ),
  tas_deduped AS (
    SELECT TICKET_ID, DATE(DATEADD(MINUTE, 330, MIN(CREATED_AT) OVER (PARTITION BY TICKET_ID))) AS dt,
      SECONDARY_SUBTYPE, CUSTOMER_MOBILE, DEVICE_ID, CUSTOMER_ADDRESS
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
      AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
  ),
  daily AS (
    SELECT dt, ROUND((
      ROUND(100.0 * COUNT(DISTINCT CASE WHEN SECONDARY_SUBTYPE IS NOT NULL AND SECONDARY_SUBTYPE != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1)
      + ROUND(100.0 * COUNT(DISTINCT CASE WHEN CUSTOMER_MOBILE IS NOT NULL AND CUSTOMER_MOBILE != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1)
      + ROUND(100.0 * COUNT(DISTINCT CASE WHEN DEVICE_ID IS NOT NULL AND DEVICE_ID != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1)
      + ROUND(100.0 * COUNT(DISTINCT CASE WHEN CUSTOMER_ADDRESS IS NOT NULL AND CUSTOMER_ADDRESS != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1)
    ) / 4.0, 1) AS val
    FROM tas_deduped WHERE dt >= DATEADD('day', -30, CURRENT_DATE()) GROUP BY dt
  )
  SELECT 'Enrichment Rate' AS metric,
    MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM daily
)
UNION ALL
SELECT * FROM (
  WITH csp_universe AS (
    SELECT DISTINCT PARTNER_ID, CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
  ),
  kap_base AS (
    SELECT stm.TICKET_ID, DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt, stm.IS_RESOLVED AS kap_closed
    FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
    INNER JOIN csp_universe csp ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
    WHERE stm.TICKET_ID IS NOT NULL AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
      AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
      AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -30, CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
  ),
  srs_latest AS (
    SELECT TICKET_ID, CASE WHEN STATUS = 'CLOSED' THEN 1 ELSE 0 END AS srs_closed
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY CREATED_AT DESC, VERSION DESC) = 1
  ),
  tas_latest AS (
    SELECT TICKET_ID, CASE WHEN STATE = 'COMPLETED' THEN 1 ELSE 0 END AS tas_closed
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
  ),
  joined AS (
    SELECT k.dt, k.TICKET_ID, k.kap_closed, COALESCE(s.srs_closed, 0) AS srs_closed, COALESCE(t.tas_closed, 0) AS tas_closed,
      CASE WHEN s.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_srs, CASE WHEN t.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_tas
    FROM kap_base k LEFT JOIN srs_latest s ON s.TICKET_ID = k.TICKET_ID LEFT JOIN tas_latest t ON t.TICKET_ID = k.TICKET_ID
  ),
  daily AS (
    SELECT dt,
      ROUND(100.0 * SUM(CASE WHEN kap_closed=1 AND in_srs=1 THEN srs_closed ELSE 0 END) / NULLIF(SUM(kap_closed), 0), 1) AS kap_closed_to_srs_closed_pct,
      ROUND(100.0 * SUM(CASE WHEN kap_closed=1 AND in_tas=1 THEN tas_closed ELSE 0 END) / NULLIF(SUM(kap_closed), 0), 1) AS kap_closed_to_tas_completed_pct,
      ROUND(100.0 * SUM(CASE WHEN srs_closed=1 THEN kap_closed ELSE 0 END) / NULLIF(SUM(CASE WHEN in_srs=1 AND srs_closed=1 THEN 1 ELSE 0 END), 0), 1) AS srs_closed_to_kap_resolved_pct,
      ROUND(100.0 * SUM(CASE WHEN tas_closed=1 THEN kap_closed ELSE 0 END) / NULLIF(SUM(CASE WHEN in_tas=1 AND tas_closed=1 THEN 1 ELSE 0 END), 0), 1) AS tas_completed_to_kap_resolved_pct
    FROM joined GROUP BY dt
  ),
  daily_avg AS (
    SELECT dt, ROUND((kap_closed_to_srs_closed_pct + kap_closed_to_tas_completed_pct + srs_closed_to_kap_resolved_pct + tas_completed_to_kap_resolved_pct) / 4.0, 1) AS val
    FROM daily
  )
  SELECT 'Ticket Closure Match Rate' AS metric,
    MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM daily_avg
)
UNION ALL
SELECT * FROM (
  WITH csp_universe AS (
    SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
  ),
  srs_deduped AS (
    SELECT TICKET_ID, SECONDARY_SUBTYPE,
      CASE
        WHEN SECONDARY_SUBTYPE IN ('NO_INTERNET','RECHARGE_DONE_NO_INTERNET') THEN '4_WORKING_HRS'
        WHEN SECONDARY_SUBTYPE IN ('OPTICAL_POWER_OUT_OF_RANGE','FREQUENT_DISCONNECTION','SLOW_INTERNET') THEN '24_CAL_HRS'
        WHEN SECONDARY_SUBTYPE IN ('WITHIN_PREMISES','NEW_PREMISES') THEN '96_CAL_HRS'
      END AS sla_rule,
      CREATED_AT, SLA_AT, DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%'
      AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$') AND SLA_AT IS NOT NULL AND SECONDARY_SUBTYPE IS NOT NULL
      AND SECONDARY_SUBTYPE IN ('NO_INTERNET','RECHARGE_DONE_NO_INTERNET','OPTICAL_POWER_OUT_OF_RANGE','FREQUENT_DISCONNECTION','SLOW_INTERNET','WITHIN_PREMISES','NEW_PREMISES')
      AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
      AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD('day', -30, CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY CREATED_AT DESC, VERSION DESC) = 1
  ),
  srs_ist AS (
    SELECT *, CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT) AS created_ist, CONVERT_TIMEZONE('Asia/Kolkata', SLA_AT) AS actual_sla_ist,
      EXTRACT(HOUR FROM CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) * 60 + EXTRACT(MINUTE FROM CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS created_mins
    FROM srs_deduped
  ),
  with_expected AS (
    SELECT *,
      CASE
        WHEN sla_rule = '4_WORKING_HRS' THEN
          CASE
            WHEN created_mins < 660 THEN DATEADD(MINUTE, 900, DATE_TRUNC('day', created_ist))
            WHEN (1260 - created_mins) >= 240 THEN DATEADD(MINUTE, 240, created_ist)
            ELSE DATEADD(MINUTE, 660 + (240 - GREATEST(0, 1260 - created_mins)), DATEADD(DAY, 1, DATE_TRUNC('day', created_ist)))
          END
        WHEN sla_rule = '24_CAL_HRS' THEN DATEADD(HOUR, 24, created_ist)
        WHEN sla_rule = '96_CAL_HRS' THEN DATEADD(HOUR, 96, created_ist)
      END AS expected_sla_ist
    FROM srs_ist
  ),
  with_deviation AS (
    SELECT dt,
      CASE SECONDARY_SUBTYPE WHEN 'WITHIN_PREMISES' THEN 'OTHERS' WHEN 'NEW_PREMISES' THEN 'OTHERS' ELSE SECONDARY_SUBTYPE END AS category,
      sla_rule, CASE WHEN ABS(DATEDIFF(MINUTE, expected_sla_ist, actual_sla_ist)) <= 5 THEN 1 ELSE 0 END AS is_correct
    FROM with_expected WHERE expected_sla_ist IS NOT NULL
  ),
  daily AS (
    SELECT dt, category, sla_rule, ROUND(100.0 * SUM(is_correct) / NULLIF(COUNT(*), 0), 1) AS correct_pct
    FROM with_deviation GROUP BY dt, category, sla_rule
  ),
  daily_avg AS (
    SELECT dt, ROUND(AVG(correct_pct), 1) AS val FROM daily GROUP BY dt
  )
  SELECT 'TAT Calculation Accuracy' AS metric,
    MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM daily_avg
)
UNION ALL
SELECT * FROM (
  WITH complaints AS (
    SELECT complaint_id, TO_DATE(DATEADD(MINUTE, 330, CREATED_AT)) AS d
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID NOT LIKE 'prod-test%'
      AND SECONDARY_SUBTYPE IN ('OPTICAL_POWER_OUT_OF_RANGE','RECHARGE_DONE_NO_INTERNET','FREQUENT_DISCONNECTION','SLOW_INTERNET','NO_INTERNET')
      AND TO_DATE(DATEADD(MINUTE, 330, CREATED_AT)) >= DATEADD('day', -30, CURRENT_DATE())
  ),
  tickets AS (SELECT d, COUNT(*) AS tickets_created FROM complaints GROUP BY d),
  csp_pn AS (
    SELECT c.d, COUNT(DISTINCT pn.exec_cand_id) AS pn_delivered
    FROM (
      SELECT PARSE_JSON(properties):execution_id::STRING AS exec_cand_id
      FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
      JOIN PROD_DB.CLEVERTAP_CSP_API.PROFILE_DATA pd ON ed.clevertap_id = pd.clevertap_id
      WHERE ed.event_name = 'pn_delivered' AND PARSE_JSON(properties):wzrk_id::STRING LIKE '1778236503%'
    ) pn
    JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES rec ON pn.exec_cand_id = rec.EXECUTION_CANDIDATE_ID
    JOIN complaints c ON rec.COMPLAINT_ID = c.complaint_id
    GROUP BY c.d
  ),
  delivery_rate AS (
    SELECT t.d, ROUND(100.0 * COALESCE(c.pn_delivered, 0) / NULLIF(t.tickets_created, 0), 1) AS val
    FROM tickets t LEFT JOIN csp_pn c ON t.d = c.d
  )
  SELECT 'Service Ticket-PN Delivery Rate (%)' AS metric,
    MAX(CASE WHEN d = DATEADD('day', -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN d = DATEADD('day', -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN d = DATEADD('day', -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN d = DATEADD('day', -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN d = DATEADD('day', -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN d = DATEADD('day', -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN d = DATEADD('day', -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN d = DATEADD('day', -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM delivery_rate
)
UNION ALL
SELECT * FROM (
  WITH daily AS (
    SELECT
      DATEDIFF(day, TO_DATE(DATEADD(minute, 330, CREATED_AT)), CAST(DATEADD(minute, 330, CURRENT_TIMESTAMP()) AS DATE)) AS DAYS_AGO,
      ROUND(100.0 * SUM(CASE WHEN PARSE_JSON(NEW_ADDRESS):address::STRING IS NOT NULL AND PARSE_JSON(NEW_ADDRESS):address::STRING <> '' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS MATCH_RATE_PCT
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
    WHERE _FIVETRAN_ACTIVE AND SECONDARY_SUBTYPE IN ('NEW_PREMISES','WITHIN_PREMISES')
      AND TO_DATE(DATEADD(minute, 330, CREATED_AT)) >= DATEADD(day, -30, CAST(DATEADD(minute, 330, CURRENT_TIMESTAMP()) AS DATE))
    GROUP BY DAYS_AGO
  )
  SELECT 'Shifting Tickets Address Fill Rate' AS metric,
    MAX(CASE WHEN DAYS_AGO = 1 THEN MATCH_RATE_PCT END) AS "T-1",
    MAX(CASE WHEN DAYS_AGO = 2 THEN MATCH_RATE_PCT END) AS "T-2",
    MAX(CASE WHEN DAYS_AGO = 3 THEN MATCH_RATE_PCT END) AS "T-3",
    MAX(CASE WHEN DAYS_AGO = 4 THEN MATCH_RATE_PCT END) AS "T-4",
    MAX(CASE WHEN DAYS_AGO = 5 THEN MATCH_RATE_PCT END) AS "T-5",
    MAX(CASE WHEN DAYS_AGO = 6 THEN MATCH_RATE_PCT END) AS "T-6",
    MAX(CASE WHEN DAYS_AGO = 7 THEN MATCH_RATE_PCT END) AS "T-7",
    MAX(CASE WHEN DAYS_AGO = 8 THEN MATCH_RATE_PCT END) AS "T-8",
    ROUND(AVG(MATCH_RATE_PCT), 1) AS "Mean",
    ROUND(MEDIAN(MATCH_RATE_PCT), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY MATCH_RATE_PCT), 1) AS "P90"
  FROM daily
)
UNION ALL
SELECT * FROM (
  WITH csp_universe AS (
    SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
  ),
  srs_reopens AS (
    SELECT COMPLAINT_ID, TICKET_ID, CREATED_AT AS srs_created_at, DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt
    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
    WHERE _FIVETRAN_ACTIVE = TRUE AND IS_REOPEN = TRUE AND COMPLAINT_ID IS NOT NULL AND TICKET_ID IS NOT NULL
      AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
      AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
      AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD(DAY, -30, CURRENT_DATE())
  ),
  tas_by_complaint AS (
    SELECT COMPLAINT_ID, MIN(CREATED_AT) AS tas_created_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
    WHERE COMPLAINT_ID IS NOT NULL GROUP BY COMPLAINT_ID
  ),
  daily AS (
    SELECT s.dt,
      ROUND(100.0 * COUNT(DISTINCT CASE WHEN t.COMPLAINT_ID IS NOT NULL AND ABS(DATEDIFF(MINUTE, s.srs_created_at, t.tas_created_at)) <= 60 THEN s.COMPLAINT_ID END)
        / NULLIF(COUNT(DISTINCT s.COMPLAINT_ID), 0), 1) AS val
    FROM srs_reopens s LEFT JOIN tas_by_complaint t ON s.COMPLAINT_ID = t.COMPLAINT_ID GROUP BY s.dt
  )
  SELECT 'Reopen Ticket (SRS-TAS) Match Rate' AS metric,
    MAX(CASE WHEN dt = DATEADD(DAY, -1, CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(DAY, -2, CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(DAY, -3, CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(DAY, -4, CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(DAY, -5, CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(DAY, -6, CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(DAY, -7, CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(DAY, -8, CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
  FROM daily
)
"""

QUERIES["st_detail_match_rate"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID, CSP_ID
  FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
kap_base AS (
  SELECT stm.TICKET_ID, DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt,
    CASE
      WHEN stm.LAST_TITLE IN ('Internet Issues | Frequent Disconnection','Internet Issues|Frequent Disconnection') THEN 'FREQUENT_DISCONNECTION'
      WHEN stm.LAST_TITLE IN ('Internet Issues | Internet Supply Down','Internet Issues|Internet Supply Down') THEN 'NO_INTERNET'
      WHEN stm.LAST_TITLE = 'Internet Issues|Optical Power Out of Range' THEN 'OPTICAL_POWER_OUT_OF_RANGE'
      WHEN stm.LAST_TITLE = 'Internet Issues|Recharge done but internet not working' THEN 'RECHARGE_DONE_NO_INTERNET'
      WHEN stm.LAST_TITLE = 'Internet Issues|Slow Speed/Range Issues' THEN 'SLOW_INTERNET'
      ELSE 'OTHERS'
    END AS category
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -30, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
srs_ids AS (
  SELECT DISTINCT TICKET_ID FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
),
tas_ids AS (
  SELECT DISTINCT TICKET_ID FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
),
daily AS (
  SELECT k.dt, k.category, COUNT(DISTINCT k.TICKET_ID) AS kap_cnt,
    COUNT(DISTINCT CASE WHEN s.TICKET_ID IS NOT NULL THEN k.TICKET_ID END) AS srs_cnt,
    COUNT(DISTINCT CASE WHEN t.TICKET_ID IS NOT NULL THEN k.TICKET_ID END) AS tas_cnt
  FROM kap_base k LEFT JOIN srs_ids s ON s.TICKET_ID = k.TICKET_ID LEFT JOIN tas_ids t ON t.TICKET_ID = k.TICKET_ID
  GROUP BY k.dt, k.category
),
with_pct AS (
  SELECT *, ROUND(100.0 * srs_cnt / NULLIF(kap_cnt, 0), 1) AS srs_pct, ROUND(100.0 * tas_cnt / NULLIF(kap_cnt, 0), 1) AS tas_pct FROM daily
),
unpivoted AS (
  SELECT dt, category, 'SRS Match %' AS metric, srs_pct AS val FROM with_pct
  UNION ALL SELECT dt, category, 'TAS Match %', tas_pct FROM with_pct
)
SELECT category AS "Ticket Type", metric AS "Metric",
  MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val), 1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
FROM unpivoted GROUP BY category, metric
ORDER BY CASE category WHEN 'OPTICAL_POWER_OUT_OF_RANGE' THEN 1 WHEN 'RECHARGE_DONE_NO_INTERNET' THEN 2 WHEN 'NO_INTERNET' THEN 3 WHEN 'FREQUENT_DISCONNECTION' THEN 4 WHEN 'SLOW_INTERNET' THEN 5 ELSE 6 END,
  CASE metric WHEN 'SRS Match %' THEN 1 WHEN 'TAS Match %' THEN 2 END
"""

QUERIES["st_detail_enrichment"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
tas_deduped AS (
  SELECT TICKET_ID, DATE(DATEADD(MINUTE, 330, MIN(CREATED_AT) OVER (PARTITION BY TICKET_ID))) AS dt,
    PRIMARY_CLASS, SECONDARY_SUBTYPE, CUSTOMER_MOBILE, DEVICE_ID, CUSTOMER_ADDRESS
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
daily AS (
  SELECT dt, COUNT(DISTINCT TICKET_ID) AS total_tickets,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN SECONDARY_SUBTYPE IS NOT NULL AND SECONDARY_SUBTYPE != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1) AS secondary_subtype_fill_pct,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN CUSTOMER_MOBILE IS NOT NULL AND CUSTOMER_MOBILE != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1) AS customer_mobile_fill_pct,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN DEVICE_ID IS NOT NULL AND DEVICE_ID != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1) AS device_id_fill_pct,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN CUSTOMER_ADDRESS IS NOT NULL AND CUSTOMER_ADDRESS != '' THEN TICKET_ID END) / NULLIF(COUNT(DISTINCT TICKET_ID), 0), 1) AS address_fill_pct
  FROM tas_deduped WHERE dt >= DATEADD('day', -30, CURRENT_DATE()) GROUP BY dt
),
unpivoted AS (
  SELECT dt, 'Total tickets' AS metric, total_tickets::FLOAT AS val FROM daily
  UNION ALL SELECT dt, 'Secondary subtype %', secondary_subtype_fill_pct FROM daily
  UNION ALL SELECT dt, 'Customer mobile %', customer_mobile_fill_pct FROM daily
  UNION ALL SELECT dt, 'Device ID %', device_id_fill_pct FROM daily
  UNION ALL SELECT dt, 'Address %', address_fill_pct FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val), 1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'Total tickets' THEN 1 WHEN 'Secondary subtype %' THEN 2 WHEN 'Customer mobile %' THEN 3 WHEN 'Device ID %' THEN 4 WHEN 'Address %' THEN 5 END
"""

QUERIES["st_detail_closure"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID, CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
kap_base AS (
  SELECT stm.TICKET_ID, DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt, stm.IS_RESOLVED AS kap_closed
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -30, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
srs_latest AS (
  SELECT TICKET_ID, CASE WHEN STATUS = 'CLOSED' THEN 1 ELSE 0 END AS srs_closed
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY CREATED_AT DESC, VERSION DESC) = 1
),
tas_latest AS (
  SELECT TICKET_ID, CASE WHEN STATE = 'COMPLETED' THEN 1 ELSE 0 END AS tas_closed
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
joined AS (
  SELECT k.dt, k.TICKET_ID, k.kap_closed, COALESCE(s.srs_closed, 0) AS srs_closed, COALESCE(t.tas_closed, 0) AS tas_closed,
    CASE WHEN s.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_srs, CASE WHEN t.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_tas
  FROM kap_base k LEFT JOIN srs_latest s ON s.TICKET_ID = k.TICKET_ID LEFT JOIN tas_latest t ON t.TICKET_ID = k.TICKET_ID
),
daily AS (
  SELECT dt, SUM(kap_closed) AS kap_resolved_cnt,
    ROUND(100.0 * SUM(CASE WHEN kap_closed=1 AND in_srs=1 THEN srs_closed ELSE 0 END) / NULLIF(SUM(kap_closed), 0), 1) AS kap_closed_to_srs_closed_pct,
    ROUND(100.0 * SUM(CASE WHEN kap_closed=1 AND in_tas=1 THEN tas_closed ELSE 0 END) / NULLIF(SUM(kap_closed), 0), 1) AS kap_closed_to_tas_completed_pct,
    ROUND(100.0 * SUM(CASE WHEN srs_closed=1 THEN kap_closed ELSE 0 END) / NULLIF(SUM(CASE WHEN in_srs=1 AND srs_closed=1 THEN 1 ELSE 0 END), 0), 1) AS srs_closed_to_kap_resolved_pct,
    ROUND(100.0 * SUM(CASE WHEN tas_closed=1 THEN kap_closed ELSE 0 END) / NULLIF(SUM(CASE WHEN in_tas=1 AND tas_closed=1 THEN 1 ELSE 0 END), 0), 1) AS tas_completed_to_kap_resolved_pct
  FROM joined GROUP BY dt
),
unpivoted AS (
  SELECT dt, 'Kapture resolved (count)' AS metric, kap_resolved_cnt::FLOAT AS val FROM daily
  UNION ALL SELECT dt, 'Kap closed → SRS closed %', kap_closed_to_srs_closed_pct FROM daily
  UNION ALL SELECT dt, 'Kap closed → TAS completed %', kap_closed_to_tas_completed_pct FROM daily
  UNION ALL SELECT dt, 'SRS closed → Kap resolved %', srs_closed_to_kap_resolved_pct FROM daily
  UNION ALL SELECT dt, 'TAS completed → Kap resolved %', tas_completed_to_kap_resolved_pct FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val), 1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'Kapture resolved (count)' THEN 1 WHEN 'Kap closed → SRS closed %' THEN 2 WHEN 'Kap closed → TAS completed %' THEN 3 WHEN 'SRS closed → Kap resolved %' THEN 6 WHEN 'TAS completed → Kap resolved %' THEN 7 END
"""

QUERIES["st_detail_tat_accuracy"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
srs_deduped AS (
  SELECT TICKET_ID, SECONDARY_SUBTYPE,
    CASE
      WHEN SECONDARY_SUBTYPE IN ('NO_INTERNET','RECHARGE_DONE_NO_INTERNET') THEN '4_WORKING_HRS'
      WHEN SECONDARY_SUBTYPE IN ('OPTICAL_POWER_OUT_OF_RANGE','FREQUENT_DISCONNECTION','SLOW_INTERNET') THEN '24_CAL_HRS'
      WHEN SECONDARY_SUBTYPE IN ('WITHIN_PREMISES','NEW_PREMISES') THEN '96_CAL_HRS'
    END AS sla_rule,
    CREATED_AT, SLA_AT, DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%'
    AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$') AND SLA_AT IS NOT NULL AND SECONDARY_SUBTYPE IS NOT NULL
    AND SECONDARY_SUBTYPE IN ('NO_INTERNET','RECHARGE_DONE_NO_INTERNET','OPTICAL_POWER_OUT_OF_RANGE','FREQUENT_DISCONNECTION','SLOW_INTERNET','WITHIN_PREMISES','NEW_PREMISES')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD('day', -30, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY CREATED_AT DESC, VERSION DESC) = 1
),
srs_ist AS (
  SELECT *, CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT) AS created_ist, CONVERT_TIMEZONE('Asia/Kolkata', SLA_AT) AS actual_sla_ist,
    EXTRACT(HOUR FROM CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) * 60 + EXTRACT(MINUTE FROM CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS created_mins
  FROM srs_deduped
),
with_expected AS (
  SELECT *,
    CASE
      WHEN sla_rule = '4_WORKING_HRS' THEN
        CASE
          WHEN created_mins < 660 THEN DATEADD(MINUTE, 900, DATE_TRUNC('day', created_ist))
          WHEN (1260 - created_mins) >= 240 THEN DATEADD(MINUTE, 240, created_ist)
          ELSE DATEADD(MINUTE, 660 + (240 - GREATEST(0, 1260 - created_mins)), DATEADD(DAY, 1, DATE_TRUNC('day', created_ist)))
        END
      WHEN sla_rule = '24_CAL_HRS' THEN DATEADD(HOUR, 24, created_ist)
      WHEN sla_rule = '96_CAL_HRS' THEN DATEADD(HOUR, 96, created_ist)
    END AS expected_sla_ist
  FROM srs_ist
),
with_deviation AS (
  SELECT dt,
    CASE SECONDARY_SUBTYPE WHEN 'WITHIN_PREMISES' THEN 'OTHERS' WHEN 'NEW_PREMISES' THEN 'OTHERS' ELSE SECONDARY_SUBTYPE END AS category,
    sla_rule, CASE WHEN ABS(DATEDIFF(MINUTE, expected_sla_ist, actual_sla_ist)) <= 5 THEN 1 ELSE 0 END AS is_correct
  FROM with_expected WHERE expected_sla_ist IS NOT NULL
),
daily AS (
  SELECT dt, category, sla_rule, ROUND(100.0 * SUM(is_correct) / NULLIF(COUNT(*), 0), 1) AS correct_pct
  FROM with_deviation GROUP BY dt, category, sla_rule
)
SELECT category AS "Category", MAX(sla_rule) AS "Rule",
  MAX(CASE WHEN dt = DATEADD('day', -1, CURRENT_DATE()) THEN correct_pct END) AS "T-1",
  MAX(CASE WHEN dt = DATEADD('day', -2, CURRENT_DATE()) THEN correct_pct END) AS "T-2",
  MAX(CASE WHEN dt = DATEADD('day', -3, CURRENT_DATE()) THEN correct_pct END) AS "T-3",
  MAX(CASE WHEN dt = DATEADD('day', -4, CURRENT_DATE()) THEN correct_pct END) AS "T-4",
  MAX(CASE WHEN dt = DATEADD('day', -5, CURRENT_DATE()) THEN correct_pct END) AS "T-5",
  MAX(CASE WHEN dt = DATEADD('day', -6, CURRENT_DATE()) THEN correct_pct END) AS "T-6",
  MAX(CASE WHEN dt = DATEADD('day', -7, CURRENT_DATE()) THEN correct_pct END) AS "T-7",
  MAX(CASE WHEN dt = DATEADD('day', -8, CURRENT_DATE()) THEN correct_pct END) AS "T-8",
  ROUND(AVG(correct_pct), 1) AS "Mean",
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY correct_pct), 1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY correct_pct), 1) AS "P90"
FROM daily GROUP BY category
ORDER BY CASE category WHEN 'NO_INTERNET' THEN 1 WHEN 'RECHARGE_DONE_NO_INTERNET' THEN 2 WHEN 'OPTICAL_POWER_OUT_OF_RANGE' THEN 3 WHEN 'FREQUENT_DISCONNECTION' THEN 4 WHEN 'SLOW_INTERNET' THEN 5 ELSE 6 END
"""

QUERIES["st_raw_match_rate"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID, CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
kap_base AS (
  SELECT stm.TICKET_ID, DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt,
    CASE
      WHEN stm.LAST_TITLE IN ('Internet Issues | Frequent Disconnection','Internet Issues|Frequent Disconnection') THEN 'FREQUENT_DISCONNECTION'
      WHEN stm.LAST_TITLE IN ('Internet Issues | Internet Supply Down','Internet Issues|Internet Supply Down') THEN 'NO_INTERNET'
      WHEN stm.LAST_TITLE = 'Internet Issues|Optical Power Out of Range' THEN 'OPTICAL_POWER_OUT_OF_RANGE'
      WHEN stm.LAST_TITLE = 'Internet Issues|Recharge done but internet not working' THEN 'RECHARGE_DONE_NO_INTERNET'
      WHEN stm.LAST_TITLE = 'Internet Issues|Slow Speed/Range Issues' THEN 'SLOW_INTERNET'
      ELSE 'OTHERS'
    END AS category
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -30, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
srs_ids AS (
  SELECT DISTINCT TICKET_ID FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
),
tas_ids AS (
  SELECT DISTINCT TICKET_ID FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
),
daily AS (
  SELECT k.dt, k.category, COUNT(DISTINCT k.TICKET_ID) AS kap_cnt,
    COUNT(DISTINCT CASE WHEN s.TICKET_ID IS NOT NULL THEN k.TICKET_ID END) AS srs_cnt,
    COUNT(DISTINCT CASE WHEN t.TICKET_ID IS NOT NULL THEN k.TICKET_ID END) AS tas_cnt
  FROM kap_base k LEFT JOIN srs_ids s ON s.TICKET_ID = k.TICKET_ID LEFT JOIN tas_ids t ON t.TICKET_ID = k.TICKET_ID
  GROUP BY k.dt, k.category
),
with_pct AS (
  SELECT *, ROUND(100.0*srs_cnt/NULLIF(kap_cnt,0),1) AS srs_pct, ROUND(100.0*tas_cnt/NULLIF(kap_cnt,0),1) AS tas_pct FROM daily
),
unpivoted AS (
  SELECT dt, category, 'Kapture Count' AS metric, kap_cnt::FLOAT AS val FROM with_pct
  UNION ALL SELECT dt, category, 'SRS Count', srs_cnt::FLOAT FROM with_pct
  UNION ALL SELECT dt, category, 'TAS Count', tas_cnt::FLOAT FROM with_pct
)
SELECT category AS "Ticket Type", metric AS "Metric",
  MAX(CASE WHEN dt=DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt=DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt=DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt=DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt=DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt=DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt=DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt=DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM unpivoted GROUP BY category, metric
ORDER BY CASE category WHEN 'OPTICAL_POWER_OUT_OF_RANGE' THEN 1 WHEN 'RECHARGE_DONE_NO_INTERNET' THEN 2 WHEN 'NO_INTERNET' THEN 3 WHEN 'FREQUENT_DISCONNECTION' THEN 4 WHEN 'SLOW_INTERNET' THEN 5 ELSE 6 END,
  CASE metric WHEN 'Kapture Count' THEN 1 WHEN 'SRS Count' THEN 2 WHEN 'TAS Count' THEN 3 END
"""

QUERIES["st_raw_enrichment"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
tas_deduped AS (
  SELECT TICKET_ID, DATE(DATEADD(MINUTE, 330, MIN(CREATED_AT) OVER (PARTITION BY TICKET_ID))) AS dt,
    PRIMARY_CLASS, SECONDARY_SUBTYPE, CUSTOMER_MOBILE, DEVICE_ID, CUSTOMER_ADDRESS
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
daily AS (
  SELECT dt, COUNT(DISTINCT TICKET_ID) AS total_tickets,
    COUNT(DISTINCT CASE WHEN SECONDARY_SUBTYPE IS NOT NULL AND SECONDARY_SUBTYPE != '' THEN TICKET_ID END) AS secondary_subtype_cnt,
    COUNT(DISTINCT CASE WHEN CUSTOMER_MOBILE IS NOT NULL AND CUSTOMER_MOBILE != '' THEN TICKET_ID END) AS customer_mobile_cnt,
    COUNT(DISTINCT CASE WHEN DEVICE_ID IS NOT NULL AND DEVICE_ID != '' THEN TICKET_ID END) AS device_id_cnt,
    COUNT(DISTINCT CASE WHEN CUSTOMER_ADDRESS IS NOT NULL AND CUSTOMER_ADDRESS != '' THEN TICKET_ID END) AS address_cnt
  FROM tas_deduped WHERE dt >= DATEADD('day', -30, CURRENT_DATE()) GROUP BY dt
),
unpivoted AS (
  SELECT dt, 'Total tickets' AS metric, total_tickets::FLOAT AS val FROM daily
  UNION ALL SELECT dt, 'Secondary subtype filled', secondary_subtype_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'Customer mobile filled', customer_mobile_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'Device ID filled', device_id_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'Address filled', address_cnt::FLOAT FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN dt=DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt=DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt=DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt=DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt=DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt=DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt=DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt=DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'Total tickets' THEN 1 WHEN 'Secondary subtype filled' THEN 2 WHEN 'Customer mobile filled' THEN 3 WHEN 'Device ID filled' THEN 4 WHEN 'Address filled' THEN 5 END
"""

QUERIES["st_raw_closure"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT PARTNER_ID, CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
kap_base AS (
  SELECT stm.TICKET_ID, DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) AS dt, stm.IS_RESOLVED AS kap_closed
  FROM PROD_DB.PUBLIC.SERVICE_TICKET_MODEL stm
  INNER JOIN csp_universe csp ON csp.PARTNER_ID::INT = COALESCE(stm.CURRENT_PARTNER_ACCOUNT_ID::INT, stm.LCO_ACCOUNT_ID::INT)
  WHERE stm.TICKET_ID IS NOT NULL AND REGEXP_LIKE(stm.TICKET_ID, '^[0-9]+$')
    AND (stm.LAST_TITLE ILIKE 'Internet Issues|%' OR stm.LAST_TITLE ILIKE 'Internet Issues |%')
    AND DATE(DATEADD(MINUTE, 330, stm.TICKET_ADDED_TIME)) >= DATEADD('day', -30, CURRENT_DATE())
  QUALIFY ROW_NUMBER() OVER (PARTITION BY stm.TICKET_ID ORDER BY stm.TICKET_ADDED_TIME DESC) = 1
),
srs_latest AS (
  SELECT TICKET_ID, CASE WHEN STATUS='CLOSED' THEN 1 ELSE 0 END AS srs_closed
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY CREATED_AT DESC, VERSION DESC) = 1
),
tas_latest AS (
  SELECT TICKET_ID, CASE WHEN STATE='COMPLETED' THEN 1 ELSE 0 END AS tas_closed
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID IS NOT NULL AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY TICKET_ID ORDER BY UPDATED_AT DESC, STATE_VERSION DESC) = 1
),
joined AS (
  SELECT k.dt, k.TICKET_ID, k.kap_closed, COALESCE(s.srs_closed,0) AS srs_closed, COALESCE(t.tas_closed,0) AS tas_closed,
    CASE WHEN s.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_srs, CASE WHEN t.TICKET_ID IS NOT NULL THEN 1 ELSE 0 END AS in_tas
  FROM kap_base k LEFT JOIN srs_latest s ON s.TICKET_ID=k.TICKET_ID LEFT JOIN tas_latest t ON t.TICKET_ID=k.TICKET_ID
),
daily AS (
  SELECT dt, SUM(kap_closed) AS kap_resolved_cnt,
    SUM(CASE WHEN kap_closed=1 AND in_srs=1 THEN srs_closed ELSE 0 END) AS kap_closed_and_srs_closed_cnt,
    SUM(CASE WHEN kap_closed=1 AND in_tas=1 THEN tas_closed ELSE 0 END) AS kap_closed_and_tas_completed_cnt,
    SUM(CASE WHEN in_srs=1 AND srs_closed=1 THEN 1 ELSE 0 END) AS srs_closed_cnt,
    SUM(CASE WHEN in_tas=1 AND tas_closed=1 THEN 1 ELSE 0 END) AS tas_completed_cnt,
    SUM(CASE WHEN srs_closed=1 AND kap_closed=1 THEN 1 ELSE 0 END) AS srs_closed_and_kap_resolved_cnt,
    SUM(CASE WHEN tas_closed=1 AND kap_closed=1 THEN 1 ELSE 0 END) AS tas_completed_and_kap_resolved_cnt
  FROM joined GROUP BY dt
),
unpivoted AS (
  SELECT dt, 'Kapture resolved' AS metric, kap_resolved_cnt::FLOAT AS val FROM daily
  UNION ALL SELECT dt, 'Kap closed & SRS closed', kap_closed_and_srs_closed_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'Kap closed & TAS completed', kap_closed_and_tas_completed_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'SRS closed', srs_closed_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'TAS completed', tas_completed_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'SRS closed & Kap resolved', srs_closed_and_kap_resolved_cnt::FLOAT FROM daily
  UNION ALL SELECT dt, 'TAS completed & Kap resolved', tas_completed_and_kap_resolved_cnt::FLOAT FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN dt=DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt=DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt=DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt=DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt=DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt=DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt=DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt=DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'Kapture resolved' THEN 1 WHEN 'Kap closed & SRS closed' THEN 2 WHEN 'Kap closed & TAS completed' THEN 3 WHEN 'SRS closed' THEN 4 WHEN 'TAS completed' THEN 5 WHEN 'SRS closed & Kap resolved' THEN 6 WHEN 'TAS completed & Kap resolved' THEN 7 END
"""

QUERIES["st_raw_pn_delivery"] = r"""
WITH params AS (
  SELECT today AS d0, today-1 AS d1, today-2 AS d2, today-3 AS d3, today-4 AS d4, today-5 AS d5, today-6 AS d6, today-7 AS d7
  FROM (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today)
),
complaints AS (
  SELECT complaint_id, TO_DATE(DATEADD(MINUTE, 330, CREATED_AT)) AS d
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND TICKET_ID NOT LIKE 'prod-test%'
    AND SECONDARY_SUBTYPE IN ('OPTICAL_POWER_OUT_OF_RANGE','RECHARGE_DONE_NO_INTERNET','FREQUENT_DISCONNECTION','SLOW_INTERNET','NO_INTERNET')
),
tickets AS (SELECT d, COUNT(*) AS cnt FROM complaints GROUP BY 1),
csp_pn AS (
  SELECT c.d, COUNT(DISTINCT pn.exec_cand_id) AS cnt
  FROM (
    SELECT PARSE_JSON(properties):execution_id::STRING AS exec_cand_id
    FROM PROD_DB.CLEVERTAP_CSP_API.EVENTS_DATA ed
    JOIN PROD_DB.CLEVERTAP_CSP_API.PROFILE_DATA pd ON ed.clevertap_id = pd.clevertap_id
    WHERE ed.event_name = 'pn_delivered' AND PARSE_JSON(properties):wzrk_id::STRING LIKE '1778236503%'
  ) pn
  JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES rec ON pn.exec_cand_id = rec.EXECUTION_CANDIDATE_ID
  JOIN complaints c ON rec.COMPLAINT_ID = c.complaint_id
  GROUP BY 1
),
long AS (
  SELECT 1 AS metric_order, 'Tickets Created' AS metric, d, cnt::FLOAT AS val FROM tickets
  UNION ALL SELECT 2, 'CSP PN Delivered', d, cnt::FLOAT FROM csp_pn
)
SELECT metric AS "Metric",
  MAX(IFF(d=p.d0,val,NULL)) AS "Today",
  MAX(IFF(d=p.d1,val,NULL)) AS "T-1",
  MAX(IFF(d=p.d2,val,NULL)) AS "T-2",
  MAX(IFF(d=p.d3,val,NULL)) AS "T-3",
  MAX(IFF(d=p.d4,val,NULL)) AS "T-4",
  MAX(IFF(d=p.d5,val,NULL)) AS "T-5",
  MAX(IFF(d=p.d6,val,NULL)) AS "T-6",
  MAX(IFF(d=p.d7,val,NULL)) AS "T-7",
  ROUND(AVG(IFF(d BETWEEN p.d7 AND p.d0, val, NULL)),1) AS "Average",
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.d7 AND p.d0, val, NULL)),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY IFF(d BETWEEN p.d7 AND p.d0, val, NULL)),1) AS "P90"
FROM long CROSS JOIN params p
GROUP BY metric_order, metric ORDER BY metric_order
"""

QUERIES["st_raw_shifting_address"] = r"""
WITH daily AS (
  SELECT DATEDIFF(day, TO_DATE(DATEADD(minute, 330, CREATED_AT)), CAST(DATEADD(minute, 330, CURRENT_TIMESTAMP()) AS DATE)) AS DAYS_AGO,
    COUNT(*) AS shifting_tickets,
    SUM(CASE WHEN PARSE_JSON(NEW_ADDRESS):address::STRING IS NOT NULL AND PARSE_JSON(NEW_ADDRESS):address::STRING <> '' THEN 1 ELSE 0 END) AS address_filled
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE _FIVETRAN_ACTIVE AND SECONDARY_SUBTYPE IN ('NEW_PREMISES','WITHIN_PREMISES')
    AND TO_DATE(DATEADD(minute, 330, CREATED_AT)) >= DATEADD(day, -30, CAST(DATEADD(minute, 330, CURRENT_TIMESTAMP()) AS DATE))
  GROUP BY DAYS_AGO
),
unpivoted AS (
  SELECT DAYS_AGO, 'Shifting tickets created' AS metric, shifting_tickets::FLOAT AS val FROM daily
  UNION ALL SELECT DAYS_AGO, 'Address filled', address_filled::FLOAT FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN DAYS_AGO=1 THEN val END) AS "T-1",
  MAX(CASE WHEN DAYS_AGO=2 THEN val END) AS "T-2",
  MAX(CASE WHEN DAYS_AGO=3 THEN val END) AS "T-3",
  MAX(CASE WHEN DAYS_AGO=4 THEN val END) AS "T-4",
  MAX(CASE WHEN DAYS_AGO=5 THEN val END) AS "T-5",
  MAX(CASE WHEN DAYS_AGO=6 THEN val END) AS "T-6",
  MAX(CASE WHEN DAYS_AGO=7 THEN val END) AS "T-7",
  MAX(CASE WHEN DAYS_AGO=8 THEN val END) AS "T-8",
  ROUND(AVG(val),1) AS "Mean", ROUND(MEDIAN(val),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'Shifting tickets created' THEN 1 WHEN 'Address filled' THEN 2 END
"""

QUERIES["st_raw_reopen"] = r"""
WITH csp_universe AS (
  SELECT DISTINCT CSP_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
  WHERE _FIVETRAN_ACTIVE = TRUE AND STATUS = 'ACTIVE' AND PARTNER_ID IS NOT NULL
),
srs_reopens AS (
  SELECT COMPLAINT_ID, TICKET_ID, CREATED_AT AS srs_created_at, DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt
  FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS
  WHERE _FIVETRAN_ACTIVE = TRUE AND IS_REOPEN = TRUE AND COMPLAINT_ID IS NOT NULL AND TICKET_ID IS NOT NULL
    AND TICKET_ID NOT LIKE 'prod-test%' AND REGEXP_LIKE(TICKET_ID, '^[0-9]+$')
    AND CSP_ID IN (SELECT CSP_ID FROM csp_universe)
    AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) >= DATEADD('day', -30, CURRENT_DATE())
),
tas_by_complaint AS (
  SELECT COMPLAINT_ID, MIN(CREATED_AT) AS tas_created_at
  FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.RESTORE_EXECUTION_CANDIDATES
  WHERE COMPLAINT_ID IS NOT NULL GROUP BY COMPLAINT_ID
),
daily AS (
  SELECT s.dt, COUNT(DISTINCT s.COMPLAINT_ID) AS srs_reopen_cnt,
    COUNT(DISTINCT CASE WHEN t.COMPLAINT_ID IS NOT NULL AND ABS(DATEDIFF('minute', s.srs_created_at, t.tas_created_at)) <= 60 THEN s.COMPLAINT_ID END) AS tas_within_1hr_cnt
  FROM srs_reopens s LEFT JOIN tas_by_complaint t ON t.COMPLAINT_ID = s.COMPLAINT_ID GROUP BY s.dt
),
unpivoted AS (
  SELECT dt, 'SRS reopened' AS metric, srs_reopen_cnt::FLOAT AS val FROM daily
  UNION ALL SELECT dt, 'TAS within 1hr', tas_within_1hr_cnt::FLOAT FROM daily
)
SELECT metric AS "Metric",
  MAX(CASE WHEN dt=DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
  MAX(CASE WHEN dt=DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
  MAX(CASE WHEN dt=DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
  MAX(CASE WHEN dt=DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
  MAX(CASE WHEN dt=DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
  MAX(CASE WHEN dt=DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
  MAX(CASE WHEN dt=DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
  MAX(CASE WHEN dt=DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
  ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM unpivoted GROUP BY metric
ORDER BY CASE metric WHEN 'SRS reopened' THEN 1 WHEN 'TAS within 1hr' THEN 2 END
"""

QUERIES["pickup_tickets_health"] = r"""
WITH
q1_nbrec AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.created_at AS nbrec_created_at,
        DATE(n.created_at + INTERVAL '330 minutes') AS created_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._fivetran_active AND n.created_at >= CURRENT_DATE - 60
),
q1_acs AS (
    SELECT cal.device_id, cal.created_at AS ts
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'CUSTOMER_RECOVERY_PENDING' AND cal.created_at >= CURRENT_DATE - 61
),
q1_clos AS (
    SELECT ceh.connection_id, ceh.created_at AS ts
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE = 'PENDING_DEACTIVATION' AND ceh.created_at >= CURRENT_DATE - 61
),
q1_daily AS (
    SELECT nc.created_dt AS dt, COUNT(*) AS denom,
        COUNT(CASE WHEN a.ts IS NOT NULL AND ABS(DATEDIFF(day, nc.nbrec_created_at, a.ts)) <= 1 THEN 1 END) AS acs_n,
        COUNT(CASE WHEN c.ts IS NOT NULL AND ABS(DATEDIFF(day, nc.nbrec_created_at, c.ts)) <= 1 THEN 1 END) AS clos_n
    FROM q1_nbrec nc
    LEFT JOIN q1_acs  a ON a.device_id     = nc.device_id         AND ABS(DATEDIFF(day, nc.nbrec_created_at, a.ts)) <= 1
    LEFT JOIN q1_clos c ON c.connection_id = nc.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, nc.nbrec_created_at, c.ts)) <= 1
    GROUP BY 1
),
q1_metrics AS (
    SELECT dt, 'ACS CustRecPend Match %' AS metric, ROUND(acs_n  * 100.0 / NULLIF(denom, 0), 1) AS val FROM q1_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
    UNION ALL
    SELECT dt, 'CLOS PendDeact Match %',             ROUND(clos_n * 100.0 / NULLIF(denom, 0), 1)        FROM q1_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
),
pivot_1 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q1_metrics GROUP BY metric
),
q2_rescued AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.updated_at AS rescued_at,
        DATE(n.updated_at + INTERVAL '330 minutes') AS recharged_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._fivetran_active AND n.state = 'CANCELLED' AND n.reason_code = 'DEVICE_RESCUED'
        AND n.updated_at >= CURRENT_DATE - 60
),
q2_acs AS (
    SELECT cal.device_id, cal.created_at AS ts
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'DEPLOYED' AND cal.created_at >= CURRENT_DATE - 61
),
q2_clos AS (
    SELECT ceh.connection_id, ceh.created_at AS ts
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE IN ('ACTIVE','PAUSED') AND ceh.created_at >= CURRENT_DATE - 61
),
q2_daily AS (
    SELECT r.recharged_dt AS dt, COUNT(*) AS denom,
        COUNT(CASE WHEN a.ts IS NOT NULL AND ABS(DATEDIFF(day, r.rescued_at, a.ts)) <= 1 THEN 1 END) AS acs_n,
        COUNT(CASE WHEN c.ts IS NOT NULL AND ABS(DATEDIFF(day, r.rescued_at, c.ts)) <= 1 THEN 1 END) AS clos_n
    FROM q2_rescued r
    LEFT JOIN q2_acs  a ON a.device_id     = r.device_id         AND ABS(DATEDIFF(day, r.rescued_at, a.ts)) <= 1
    LEFT JOIN q2_clos c ON c.connection_id = r.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, r.rescued_at, c.ts)) <= 1
    GROUP BY 1
),
q2_metrics AS (
    SELECT dt, 'ACS Deployed Match %'       AS metric, ROUND(acs_n  * 100.0 / NULLIF(denom, 0), 1) AS val FROM q2_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
    UNION ALL
    SELECT dt, 'CLOS Active/Paused Match %',            ROUND(clos_n * 100.0 / NULLIF(denom, 0), 1)        FROM q2_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
),
pivot_2 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q2_metrics GROUP BY metric
),
q3_all_tickets AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.created_at AS put_created_at, n.state AS current_nbrec_state, n.updated_at,
        DATE(n.created_at + INTERVAL '330 minutes') AS created_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._fivetran_active AND n.created_at >= CURRENT_DATE - 90 AND n.created_at <= CURRENT_DATE - 22
),
q3_not_terminal AS (
    SELECT * FROM q3_all_tickets
    WHERE NOT (current_nbrec_state IN ('COMPLETED','CANCELLED','FAILED')
               AND updated_at <= put_created_at + INTERVAL '21 days')
),
q3_acs AS (
    SELECT cal.device_id, cal.created_at AS ts
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'LOST' AND cal.created_at >= CURRENT_DATE - 91
),
q3_clos AS (
    SELECT ceh.connection_id, ceh.created_at AS ts
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE = 'PENDING_DEACTIVATION' AND ceh.created_at >= CURRENT_DATE - 91
),
q3_daily AS (
    SELECT nt.created_dt AS dt, COUNT(*) AS denom,
        COUNT(CASE WHEN nt.current_nbrec_state = 'FAILED'
            AND nt.updated_at >= nt.put_created_at + INTERVAL '21 days'
            AND nt.updated_at <= nt.put_created_at + INTERVAL '22 days' THEN 1 END) AS nbrec_failed_d22,
        COUNT(CASE WHEN a.ts IS NOT NULL THEN 1 END)                                 AS acs_lost_d22,
        COUNT(CASE WHEN c.ts IS NOT NULL THEN 1 END)                                 AS clos_pd_d22
    FROM q3_not_terminal nt
    LEFT JOIN q3_acs  a ON a.device_id     = nt.DEVICE_ID         AND a.ts >= nt.put_created_at + INTERVAL '21 days' AND a.ts <= nt.put_created_at + INTERVAL '22 days'
    LEFT JOIN q3_clos c ON c.connection_id = nt.LAST_CONNECTION_ID AND c.ts >= nt.put_created_at + INTERVAL '21 days' AND c.ts <= nt.put_created_at + INTERVAL '22 days'
    GROUP BY 1
),
q3_metrics AS (
    SELECT dt, 'NBREC Failed Day22 %'  AS metric, ROUND(nbrec_failed_d22 * 100.0 / NULLIF(denom, 0), 1) AS val FROM q3_daily WHERE dt BETWEEN DATEADD('day',-52,CURRENT_DATE()) AND DATEADD('day',-22,CURRENT_DATE())
    UNION ALL
    SELECT dt, 'ACS Lost Day22 %',                ROUND(acs_lost_d22     * 100.0 / NULLIF(denom, 0), 1)        FROM q3_daily WHERE dt BETWEEN DATEADD('day',-52,CURRENT_DATE()) AND DATEADD('day',-22,CURRENT_DATE())
    UNION ALL
    SELECT dt, 'CLOS PendDeact Day22 %',          ROUND(clos_pd_d22      * 100.0 / NULLIF(denom, 0), 1)        FROM q3_daily WHERE dt BETWEEN DATEADD('day',-52,CURRENT_DATE()) AND DATEADD('day',-22,CURRENT_DATE())
),
pivot_3 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q3_metrics GROUP BY metric
),
q4_completed AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.updated_at AS completed_at,
        DATE(n.updated_at + INTERVAL '330 minutes') AS completed_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._fivetran_active AND n.state = 'COMPLETED' AND n.updated_at >= CURRENT_DATE - 60
),
q4_acs AS (
    SELECT cal.device_id, cal.created_at AS ts
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'IDLE' AND cal.created_at >= CURRENT_DATE - 61
),
q4_clos AS (
    SELECT ceh.connection_id, ceh.created_at AS ts
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE = 'PENDING_DEACTIVATION' AND ceh.created_at >= CURRENT_DATE - 61
),
q4_daily AS (
    SELECT c.completed_dt AS dt, COUNT(*) AS denom,
        COUNT(CASE WHEN a.ts  IS NOT NULL AND ABS(DATEDIFF(day, c.completed_at, a.ts))  <= 1 THEN 1 END) AS acs_n,
        COUNT(CASE WHEN cl.ts IS NOT NULL AND ABS(DATEDIFF(day, c.completed_at, cl.ts)) <= 1 THEN 1 END) AS clos_n
    FROM q4_completed c
    LEFT JOIN q4_acs  a  ON a.device_id      = c.device_id         AND ABS(DATEDIFF(day, c.completed_at, a.ts))  <= 1
    LEFT JOIN q4_clos cl ON cl.connection_id = c.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, c.completed_at, cl.ts)) <= 1
    GROUP BY 1
),
q4_metrics AS (
    SELECT dt, 'ACS IDLE Match %'      AS metric, ROUND(acs_n  * 100.0 / NULLIF(denom, 0), 1) AS val FROM q4_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
    UNION ALL
    SELECT dt, 'CLOS PendDeact Match %',           ROUND(clos_n * 100.0 / NULLIF(denom, 0), 1)        FROM q4_daily WHERE dt >= DATEADD('day',-30,CURRENT_DATE())
),
pivot_4 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q4_metrics GROUP BY metric
),
q5_completed AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID,
        n.updated_at AS completed_at,
        DATE(n.updated_at + INTERVAL '330 minutes') AS completed_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._fivetran_active AND n.state = 'COMPLETED' AND n.reason_code = 'DEVICE_RECOVERED_VERIFIED'
        AND n.updated_at >= CURRENT_DATE - 60
),
q5_daily AS (
    SELECT cp.completed_dt AS dt,
        COUNT(DISTINCT cp.EXECUTION_CANDIDATE_ID) AS total_pickups,
        COUNT(DISTINCT w.ID)                       AS total_payments
    FROM q5_completed cp
    LEFT JOIN PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
        ON w.ENTRY_TYPE IN ('RECOVERY_RETURN','RECOVERY_PICKUP')
        AND w._fivetran_active
        AND cp.DEVICE_ID = PARSE_JSON(w.REMARKS):"device_id"::STRING
        AND ABS(DATEDIFF(day, cp.completed_at, w.created_at)) <= 1
    GROUP BY 1
),
q5_metrics AS (
    SELECT dt, 'Payout Match %' AS metric,
        ROUND(total_payments * 100.0 / NULLIF(total_pickups, 0), 1) AS val
    FROM q5_daily WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
),
pivot_5 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q5_metrics GROUP BY metric
),
q6_expired AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID,
        n.updated_at AS expired_at,
        DATE(n.updated_at + INTERVAL '330 minutes') AS expired_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.STATE = 'FAILED' AND n.UPDATED_AT >= CURRENT_DATE - 60
),
q6_acs_lost AS (
    SELECT cal.DEVICE_ID, cal.CREATED_AT AS lost_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.TO_STATE = 'LOST' AND cal.CREATED_AT >= CURRENT_DATE - 61
),
q6_daily AS (
    SELECT ep.expired_dt AS dt,
        COUNT(DISTINCT CASE WHEN al.lost_at IS NOT NULL THEN ep.EXECUTION_CANDIDATE_ID END)                          AS acs_lost,
        COUNT(DISTINCT CASE WHEN al.lost_at IS NOT NULL AND rd.DEVICE_ID IS NOT NULL THEN ep.EXECUTION_CANDIDATE_ID END) AS lost_and_recoverable
    FROM q6_expired ep
    LEFT JOIN q6_acs_lost al
        ON al.DEVICE_ID = ep.DEVICE_ID
        AND ABS(DATEDIFF(day, ep.expired_at, al.lost_at)) <= 1
    LEFT JOIN PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.RECOVERABLE_DUE rd
        ON rd.DEVICE_ID = ep.DEVICE_ID AND rd._FIVETRAN_ACTIVE
    GROUP BY 1
),
q6_metrics AS (
    SELECT dt, 'Lost -> Recoverable Due %' AS metric,
        ROUND(lost_and_recoverable * 100.0 / NULLIF(acs_lost, 0), 1) AS val
    FROM q6_daily WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
),
pivot_6 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q6_metrics GROUP BY metric
),
q7_migrated AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
        WHERE _fivetran_active
    )
),
q7_recharges AS (
    SELECT tg.account_id, trum.created_on AS recharge_time
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0 AND trum.device_limit = 10
        AND trum.mobile > '5999999999' AND trum.created_on >= CURRENT_DATE - 31
),
q7_tickets AS (
    SELECT exec.EXECUTION_CANDIDATE_ID, c.customer_id AS account_id,
        exec.created_at AS ticket_created_at, exec.updated_at AS ticket_updated_at,
        exec.state, exec.reason_code
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.connection_id = exec.last_connection_id AND c._fivetran_active
    JOIN q7_migrated mc ON mc.account_id = c.customer_id
    WHERE exec._fivetran_active AND exec.created_at >= CURRENT_DATE - 31
),
q7_first_recharge AS (
    SELECT pt.EXECUTION_CANDIDATE_ID, pt.account_id,
        DATE(pt.ticket_created_at + INTERVAL '330 minutes') AS ticket_dt,
        pt.ticket_created_at,
        MIN(r.recharge_time) AS first_recharge_after_ticket,
        pt.state, pt.reason_code, pt.ticket_updated_at
    FROM q7_tickets pt
    JOIN q7_recharges r ON r.account_id = pt.account_id AND r.recharge_time > pt.ticket_created_at
    GROUP BY 1,2,3,4,6,7,8
),
q7_flagged AS (
    SELECT *,
        CASE WHEN state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED' THEN 1 ELSE 0 END AS rescued,
        CASE WHEN state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED'
                  AND ticket_updated_at >= first_recharge_after_ticket
                  AND ticket_updated_at <= DATEADD(hour, 1, first_recharge_after_ticket)
             THEN 1 ELSE 0 END AS rescued_within_1h
    FROM q7_first_recharge
),
q7_daily AS (
    SELECT ticket_dt AS dt,
        SUM(rescued)           AS put_closed,
        SUM(rescued_within_1h) AS closed_within_1h
    FROM q7_flagged GROUP BY 1
),
q7_metrics AS (
    SELECT dt, 'PUT Closed Within 1h %' AS metric,
        ROUND(closed_within_1h * 100.0 / NULLIF(put_closed, 0), 1) AS val
    FROM q7_daily WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
),
pivot_7 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q7_metrics GROUP BY metric
),
q8_migrated AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
        WHERE _fivetran_active
    )
),
q8_sd_per_customer AS (
    SELECT
        DATE(CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at)) AS sd_creation_date,
        sc.CUSTOMER_ACCOUNT_ID,
        MAX(CASE
            WHEN exec.created_at IS NOT NULL
                 AND ABS(DATEDIFF(minute,
                         exec.created_at,
                         CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at))) <= 720
            THEN 1 ELSE 0
        END) AS has_nbrec_within_12h
    FROM PROD_DB.CUSTOMER_DB_CUSTOMER_PROFILE_SERVICE_AUDIT_PUBLIC.SECURITY_DEPOSIT_ORDERS sc
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.customer_id = sc.CUSTOMER_ACCOUNT_ID AND c._fivetran_active
    JOIN q8_migrated mc ON mc.account_id = sc.CUSTOMER_ACCOUNT_ID
    LEFT JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
        ON c.connection_id = exec.last_connection_id AND exec._fivetran_active
    WHERE sc._fivetran_active
        AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at)) >= CURRENT_DATE - 31
    GROUP BY 1, 2
),
q8_daily AS (
    SELECT sd_creation_date AS dt,
        COUNT(*)                   AS total_sd,
        SUM(has_nbrec_within_12h)  AS nbrec_match
    FROM q8_sd_per_customer GROUP BY 1
),
q8_metrics AS (
    SELECT dt, 'SD -> NBREC Match %' AS metric,
        ROUND(nbrec_match * 100.0 / NULLIF(total_sd, 0), 1) AS val
    FROM q8_daily WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
),
pivot_8 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q8_metrics GROUP BY metric
),
q9_migrated AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
        WHERE _fivetran_active
    )
),
q9_last_trum_expiry AS (
    SELECT tg.account_id,
           MAX(trum.OTP_EXPIRY_TIME) AS last_trum_expiry_time
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0 AND trum.device_limit = 10
        AND trum.mobile > '5999999999'
    GROUP BY 1
),
q9_last_isp_expiry AS (
    SELECT c.customer_id AS account_id,
           MAX(rg.WINDOW_END) AS last_isp_expiry_time
    FROM PROD_DB.CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES rg
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.connection_id = rg.CONNECTION_ID AND c._fivetran_active
    WHERE rg._FIVETRAN_ACTIVE = TRUE
    GROUP BY 1
),
q9_eligible AS (
    SELECT
        mc.account_id,
        DATEADD(day, 15,
            CASE
                WHEN le.last_trum_expiry_time IS NULL THEN ie.last_isp_expiry_time
                WHEN ie.last_isp_expiry_time IS NULL THEN le.last_trum_expiry_time
                ELSE LEAST(le.last_trum_expiry_time, ie.last_isp_expiry_time)
            END
        ) AS system_trigger_date
    FROM q9_migrated mc
    LEFT JOIN q9_last_trum_expiry le ON le.account_id = mc.account_id
    LEFT JOIN q9_last_isp_expiry  ie ON ie.account_id  = mc.account_id
    WHERE
        (le.last_trum_expiry_time IS NOT NULL AND DATEADD(day, 15, le.last_trum_expiry_time) <= CURRENT_DATE)
        OR
        (ie.last_isp_expiry_time  IS NOT NULL AND DATEADD(day, 15, ie.last_isp_expiry_time)  <= CURRENT_DATE)
),
q9_eligible_window AS (
    SELECT * FROM q9_eligible
    WHERE DATE(system_trigger_date) BETWEEN CURRENT_DATE - 31 AND CURRENT_DATE
),
q9_coverage AS (
    SELECT
        e.account_id,
        e.system_trigger_date,
        MAX(CASE WHEN sc.CUSTOMER_ACCOUNT_ID IS NOT NULL THEN 1 ELSE 0 END) AS has_sd,
        MAX(CASE WHEN exec.last_connection_id IS NOT NULL THEN 1 ELSE 0 END) AS has_nbrec,
        MAX(CASE
            WHEN sc.CUSTOMER_ACCOUNT_ID IS NOT NULL
                 AND exec.last_connection_id IS NOT NULL
                 AND ABS(DATEDIFF(minute,
                         exec.created_at,
                         CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at))) <= 720
            THEN 1 ELSE 0
        END) AS has_both_within_12h
    FROM q9_eligible_window e
    LEFT JOIN PROD_DB.CUSTOMER_DB_CUSTOMER_PROFILE_SERVICE_AUDIT_PUBLIC.SECURITY_DEPOSIT_ORDERS sc
        ON sc.CUSTOMER_ACCOUNT_ID = e.account_id AND sc._fivetran_active
    LEFT JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.customer_id = e.account_id AND c._fivetran_active
    LEFT JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
        ON exec.last_connection_id = c.connection_id AND exec._fivetran_active
    GROUP BY 1, 2
),
q9_daily AS (
    SELECT DATE(system_trigger_date) AS dt,
        COUNT(*)                     AS eligible,
        SUM(has_both_within_12h)     AS both_12h
    FROM q9_coverage GROUP BY 1
),
q9_metrics AS (
    SELECT dt, 'PUT Creation Rate %' AS metric,
        ROUND(both_12h * 100.0 / NULLIF(eligible, 0), 1) AS val
    FROM q9_daily WHERE dt >= DATEADD('day', -30, CURRENT_DATE())
),
pivot_9 AS (
    SELECT metric AS "Metric",
      MAX(CASE WHEN dt = DATEADD('day',-1,CURRENT_DATE()) THEN val END) AS "T-1",
      MAX(CASE WHEN dt = DATEADD('day',-2,CURRENT_DATE()) THEN val END) AS "T-2",
      MAX(CASE WHEN dt = DATEADD('day',-3,CURRENT_DATE()) THEN val END) AS "T-3",
      MAX(CASE WHEN dt = DATEADD('day',-4,CURRENT_DATE()) THEN val END) AS "T-4",
      MAX(CASE WHEN dt = DATEADD('day',-5,CURRENT_DATE()) THEN val END) AS "T-5",
      MAX(CASE WHEN dt = DATEADD('day',-6,CURRENT_DATE()) THEN val END) AS "T-6",
      MAX(CASE WHEN dt = DATEADD('day',-7,CURRENT_DATE()) THEN val END) AS "T-7",
      MAX(CASE WHEN dt = DATEADD('day',-8,CURRENT_DATE()) THEN val END) AS "T-8",
      ROUND(AVG(val), 1) AS "Mean",
      ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
      ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
    FROM q9_metrics GROUP BY metric
)

SELECT 'PUT Creation State Alignment'                AS "Metric",
    ROUND(AVG("T-1"),1) AS "T-1", ROUND(AVG("T-2"),1) AS "T-2", ROUND(AVG("T-3"),1) AS "T-3", ROUND(AVG("T-4"),1) AS "T-4",
    ROUND(AVG("T-5"),1) AS "T-5", ROUND(AVG("T-6"),1) AS "T-6", ROUND(AVG("T-7"),1) AS "T-7", ROUND(AVG("T-8"),1) AS "T-8",
    ROUND(AVG("Mean"),1) AS "Mean", ROUND(AVG("Median"),1) AS "Median", ROUND(AVG("P90"),1) AS "P90"
FROM pivot_1
UNION ALL
SELECT 'PUT Closure (Recharge Done) State Alignment',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_2
UNION ALL
SELECT 'PUT Expiry State Alignment',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_3
UNION ALL
SELECT 'PUT Closure (Pickup Done) State Alignment',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_4
UNION ALL
SELECT 'Pickup Done vs Payout Made',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_5
UNION ALL
SELECT 'Device Lost -> Recoverable Due',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_6
UNION ALL
SELECT 'Recharge Done -> PUT Closed Within 1h',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_7
UNION ALL
SELECT 'Security Deposit -> NBREC Match Rate',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_8
UNION ALL
SELECT 'PUT Creation Rate',
    ROUND(AVG("T-1"),1), ROUND(AVG("T-2"),1), ROUND(AVG("T-3"),1), ROUND(AVG("T-4"),1),
    ROUND(AVG("T-5"),1), ROUND(AVG("T-6"),1), ROUND(AVG("T-7"),1), ROUND(AVG("T-8"),1),
    ROUND(AVG("Mean"),1), ROUND(AVG("Median"),1), ROUND(AVG("P90"),1)
FROM pivot_9
"""

QUERIES["put_raw_creation_alignment"] = r"""
WITH nbrec_created AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.created_at AS nbrec_created_at, DATE(n.created_at + INTERVAL '330 minutes') AS created_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.created_at >= CURRENT_DATE - 60
),
acs_transition AS (
    SELECT cal.device_id, cal.created_at AS acs_transition_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'CUSTOMER_RECOVERY_PENDING' AND cal.created_at >= CURRENT_DATE - 61
),
clos_transition AS (
    SELECT ceh.connection_id, ceh.created_at AS clos_transition_at
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE = 'PENDING_DEACTIVATION' AND ceh.created_at >= CURRENT_DATE - 61
),
daily_metrics AS (
    SELECT nc.created_dt AS dt, COUNT(*) AS nbrec_puts,
        COUNT(CASE WHEN at2.acs_transition_at IS NOT NULL AND ABS(DATEDIFF(day, nc.nbrec_created_at, at2.acs_transition_at)) <= 1 THEN 1 END) AS acs_cust_rec_pend_within_1d,
        COUNT(CASE WHEN ct.clos_transition_at IS NOT NULL AND ABS(DATEDIFF(day, nc.nbrec_created_at, ct.clos_transition_at)) <= 1 THEN 1 END) AS clos_pend_deact_within_1d
    FROM nbrec_created nc
    LEFT JOIN acs_transition at2 ON at2.device_id = nc.device_id AND ABS(DATEDIFF(day, nc.nbrec_created_at, at2.acs_transition_at)) <= 1
    LEFT JOIN clos_transition ct ON ct.connection_id = nc.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, nc.nbrec_created_at, ct.clos_transition_at)) <= 1
    GROUP BY 1
),
metrics AS (
    SELECT dt, 'NBREC PUTs' AS metric, nbrec_puts AS val FROM daily_metrics
    UNION ALL SELECT dt, 'ACS Customer Recovery Pending (Within 1D)', acs_cust_rec_pend_within_1d FROM daily_metrics
    UNION ALL SELECT dt, 'CLOS Pending Deactivation (Within 1D)', clos_pend_deact_within_1d FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric
"""

QUERIES["put_raw_closure_recharge"] = r"""
WITH rescued AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.updated_at AS rescued_at, DATE(n.updated_at + INTERVAL '330 minutes') AS recharged_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.state = 'CANCELLED' AND n.reason_code = 'DEVICE_RESCUED' AND n.updated_at >= CURRENT_DATE - 60
),
acs_transition AS (
    SELECT cal.device_id, cal.created_at AS acs_transition_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'DEPLOYED' AND cal.created_at >= CURRENT_DATE - 61
),
clos_transition AS (
    SELECT ceh.connection_id, ceh.created_at AS clos_transition_at
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE IN ('ACTIVE','PAUSED') AND ceh.created_at >= CURRENT_DATE - 61
),
daily_metrics AS (
    SELECT r.recharged_dt AS dt, COUNT(*) AS nbec_cancelled,
        COUNT(CASE WHEN at2.acs_transition_at IS NOT NULL AND ABS(DATEDIFF(day, r.rescued_at, at2.acs_transition_at)) <= 1 THEN 1 END) AS acs_deployed_within_1d,
        COUNT(CASE WHEN ct.clos_transition_at IS NOT NULL AND ABS(DATEDIFF(day, r.rescued_at, ct.clos_transition_at)) <= 1 THEN 1 END) AS clos_active_within_1d
    FROM rescued r
    LEFT JOIN acs_transition at2 ON at2.device_id = r.device_id AND ABS(DATEDIFF(day, r.rescued_at, at2.acs_transition_at)) <= 1
    LEFT JOIN clos_transition ct ON ct.connection_id = r.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, r.rescued_at, ct.clos_transition_at)) <= 1
    GROUP BY 1
),
metrics AS (
    SELECT dt, 'NBEC Cancelled (Rescued)' AS metric, nbec_cancelled AS val FROM daily_metrics
    UNION ALL SELECT dt, 'ACS Deployed (Within 1D)', acs_deployed_within_1d FROM daily_metrics
    UNION ALL SELECT dt, 'CLOS Active/Paused (Within 1D)', clos_active_within_1d FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric
"""

QUERIES["put_raw_expiry"] = r"""
WITH failed_nbrec AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.CREATED_AT AS ticket_created_at, n.UPDATED_AT AS failed_at,
        DATE(DATEADD(MINUTE, 330, n.CREATED_AT)) AS created_dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.STATE = 'FAILED'
      AND n.CREATED_AT >= CURRENT_DATE - 90 AND n.CREATED_AT <= CURRENT_DATE - 1
),
acs_lost AS (
    SELECT DEVICE_ID, CREATED_AT AS lost_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG
    WHERE TO_STATE = 'LOST'
),
clos_pd AS (
    SELECT CONNECTION_ID, CREATED_AT AS pd_at
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY
    WHERE RESULTING_STATE = 'PENDING_DEACTIVATION'
)
SELECT f.created_dt,
    COUNT(DISTINCT f.EXECUTION_CANDIDATE_ID) AS failed_nbrec,
    COUNT(DISTINCT CASE WHEN al.DEVICE_ID IS NOT NULL THEN f.EXECUTION_CANDIDATE_ID END) AS acs_lost,
    COUNT(DISTINCT CASE WHEN cp.CONNECTION_ID IS NOT NULL THEN f.EXECUTION_CANDIDATE_ID END) AS clos_pending_deactivation
FROM failed_nbrec f
LEFT JOIN acs_lost al ON al.DEVICE_ID = f.DEVICE_ID AND ABS(DATEDIFF('minute', al.lost_at, f.failed_at)) <= 120
LEFT JOIN clos_pd cp ON cp.CONNECTION_ID = f.LAST_CONNECTION_ID AND ABS(DATEDIFF('hour', cp.pd_at, f.ticket_created_at)) <= 1
GROUP BY 1 ORDER BY 1 DESC LIMIT 8
"""

QUERIES["put_raw_closure_pickup"] = r"""
WITH completed AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.updated_at AS completed_at, DATE(n.updated_at + INTERVAL '330 minutes') AS dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.state = 'COMPLETED' AND n.updated_at >= CURRENT_DATE - 60
),
acs_transition AS (
    SELECT cal.device_id, cal.created_at AS acs_transition_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.to_state = 'IDLE' AND cal.created_at >= CURRENT_DATE - 61
),
clos_transition AS (
    SELECT ceh.connection_id, ceh.created_at AS clos_transition_at
    FROM PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTION_EVENT_HISTORY ceh
    WHERE ceh.RESULTING_STATE = 'PENDING_DEACTIVATION' AND ceh.created_at >= CURRENT_DATE - 61
),
daily_metrics AS (
    SELECT c.dt, COUNT(*) AS nbrec_completed,
        COUNT(CASE WHEN at2.acs_transition_at IS NOT NULL AND ABS(DATEDIFF(day, c.completed_at, at2.acs_transition_at)) <= 1 THEN 1 END) AS acs_idle_within_1d,
        COUNT(CASE WHEN ct.clos_transition_at IS NOT NULL AND ABS(DATEDIFF(day, c.completed_at, ct.clos_transition_at)) <= 1 THEN 1 END) AS clos_deact_within_1d
    FROM completed c
    LEFT JOIN acs_transition at2 ON at2.device_id = c.device_id AND ABS(DATEDIFF(day, c.completed_at, at2.acs_transition_at)) <= 1
    LEFT JOIN clos_transition ct ON ct.connection_id = c.LAST_CONNECTION_ID AND ABS(DATEDIFF(day, c.completed_at, ct.clos_transition_at)) <= 1
    GROUP BY 1
),
metrics AS (
    SELECT dt, 'NBREC Completed' AS metric, nbrec_completed AS val FROM daily_metrics
    UNION ALL SELECT dt, 'ACS IDLE (Within 1D)', acs_idle_within_1d FROM daily_metrics
    UNION ALL SELECT dt, 'CLOS Pending Deactivation (Within 1D)', clos_deact_within_1d FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric
"""

QUERIES["put_raw_payout"] = r"""
WITH completed_pickups AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID,
        n.updated_at AS completed_at, DATE(n.updated_at + INTERVAL '330 minutes') AS dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.state = 'COMPLETED' AND n.reason_code = 'DEVICE_RECOVERED_VERIFIED'
        AND n.updated_at >= CURRENT_DATE - 60
),
daily_metrics AS (
    SELECT cp.dt, COUNT(DISTINCT cp.EXECUTION_CANDIDATE_ID) AS total_pickups,
        COUNT(DISTINCT w.ID) AS total_payments,
        SUM(COALESCE(ROUND(w.AMOUNT / 100, 0), 0)) AS total_amount
    FROM completed_pickups cp
    LEFT JOIN PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
        ON w.ENTRY_TYPE IN ('RECOVERY_RETURN', 'RECOVERY_PICKUP') AND w._FIVETRAN_ACTIVE
        AND cp.DEVICE_ID = PARSE_JSON(w.REMARKS):"device_id"::STRING
        AND ABS(DATEDIFF(day, cp.completed_at, w.created_at)) <= 1
    GROUP BY 1
),
metrics AS (
    SELECT dt, 'Completed Pickups' AS metric, total_pickups AS val FROM daily_metrics
    UNION ALL SELECT dt, 'Recovery Payments', total_payments FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric
"""

QUERIES["put_raw_device_lost"] = r"""
WITH expired_puts AS (
    SELECT n.EXECUTION_CANDIDATE_ID, n.DEVICE_ID, n.LAST_CONNECTION_ID,
        n.updated_at AS expired_at, DATE(n.updated_at + INTERVAL '330 minutes') AS dt
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES n
    WHERE n._FIVETRAN_ACTIVE AND n.STATE = 'FAILED' AND n.UPDATED_AT >= CURRENT_DATE - 60
),
acs_lost AS (
    SELECT cal.DEVICE_ID, cal.CREATED_AT AS lost_at
    FROM PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.CUSTODY_AUDIT_LOG cal
    WHERE cal.TO_STATE = 'LOST' AND cal.CREATED_AT >= CURRENT_DATE - 61
),
daily_metrics AS (
    SELECT ep.dt,
        COUNT(DISTINCT ep.EXECUTION_CANDIDATE_ID) AS total_expired_nbrec_failed,
        COUNT(DISTINCT CASE WHEN al.lost_at IS NOT NULL THEN ep.EXECUTION_CANDIDATE_ID END) AS acs_lost_within_1d,
        COUNT(DISTINCT CASE WHEN rd.DEVICE_ID IS NOT NULL THEN ep.EXECUTION_CANDIDATE_ID END) AS has_recoverable_due
    FROM expired_puts ep
    LEFT JOIN acs_lost al ON al.DEVICE_ID = ep.DEVICE_ID AND ABS(DATEDIFF(day, ep.expired_at, al.lost_at)) <= 1
    LEFT JOIN PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.RECOVERABLE_DUE rd
        ON rd.DEVICE_ID = ep.DEVICE_ID AND rd._FIVETRAN_ACTIVE
    GROUP BY 1
),
metrics AS (
    SELECT dt, 'Expired NBREC Failed' AS metric, total_expired_nbrec_failed AS val FROM daily_metrics
    UNION ALL SELECT dt, 'ACS Lost (Within 1D)', acs_lost_within_1d FROM daily_metrics
    UNION ALL SELECT dt, 'Has Recoverable Due', has_recoverable_due FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric
"""

QUERIES["put_raw_closed_within_1h"] = r"""
WITH migrated_customers AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT WHERE _FIVETRAN_ACTIVE
    )
),
recharges AS (
    SELECT tg.account_id, trum.created_on AS recharge_time
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0 AND trum.device_limit = 10
        AND trum.mobile > '5999999999' AND trum.created_on >= CURRENT_DATE - 31
),
pickup_tickets AS (
    SELECT exec.EXECUTION_CANDIDATE_ID, c.customer_id AS account_id,
        exec.created_at AS ticket_created_at, exec.updated_at AS ticket_updated_at, exec.state, exec.reason_code
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.connection_id = exec.last_connection_id AND c._FIVETRAN_ACTIVE
    JOIN migrated_customers mc ON mc.account_id = c.customer_id
    WHERE exec._FIVETRAN_ACTIVE AND exec.created_at >= CURRENT_DATE - 31
),
first_recharge_after AS (
    SELECT pt.EXECUTION_CANDIDATE_ID, pt.account_id,
        DATE(pt.ticket_created_at + INTERVAL '330 minutes') AS dt,
        pt.ticket_created_at, MIN(r.recharge_time) AS first_recharge_after_ticket,
        pt.state, pt.reason_code, pt.ticket_updated_at
    FROM pickup_tickets pt
    JOIN recharges r ON r.account_id = pt.account_id AND r.recharge_time > pt.ticket_created_at
    GROUP BY 1,2,3,4,6,7,8
),
flagged AS (
    SELECT *,
        CASE WHEN state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED' THEN 1 ELSE 0 END AS rescued,
        CASE WHEN state = 'CANCELLED' AND reason_code = 'DEVICE_RESCUED'
                  AND ticket_updated_at >= first_recharge_after_ticket
                  AND ticket_updated_at <= DATEADD(hour, 2, first_recharge_after_ticket)
             THEN 1 ELSE 0 END AS rescued_within_2h
    FROM first_recharge_after
),
daily_metrics AS (
    SELECT dt, COUNT(*) AS total_recharged_after_ticket,
        SUM(rescued) AS put_closed, SUM(rescued_within_2h) AS closed_within_2h
    FROM flagged GROUP BY 1
),
metrics AS (
    SELECT dt, 'Total Recharged After Ticket' AS metric, total_recharged_after_ticket AS val FROM daily_metrics
    UNION ALL SELECT dt, 'PUT Closed (Device Rescued)', put_closed FROM daily_metrics
    UNION ALL SELECT dt, 'PUT Closed Within 2 Hours', closed_within_2h FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean", ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30 GROUP BY metric ORDER BY metric desc
"""

QUERIES["put_raw_sd_nbrec"] = r"""
WITH migrated_customers AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT WHERE _FIVETRAN_ACTIVE
    )
),
sd_per_customer AS (
    SELECT DATE(CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at)) AS dt,
        sc.CUSTOMER_ACCOUNT_ID,
        MAX(CASE WHEN exec.created_at IS NOT NULL
                 AND ABS(DATEDIFF(minute, exec.created_at, CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at))) <= 60
            THEN 1 ELSE 0 END) AS has_nbrec_within_1h
    FROM PROD_DB.CUSTOMER_DB_CUSTOMER_PROFILE_SERVICE_AUDIT_PUBLIC.SECURITY_DEPOSIT_ORDERS sc
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.customer_id = sc.CUSTOMER_ACCOUNT_ID AND c._FIVETRAN_ACTIVE
    JOIN migrated_customers mc ON mc.account_id = sc.CUSTOMER_ACCOUNT_ID
    LEFT JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
        ON c.connection_id = exec.last_connection_id AND exec._FIVETRAN_ACTIVE
    WHERE sc._FIVETRAN_ACTIVE
        AND DATE(CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at)) >= CURRENT_DATE - 31
    GROUP BY 1, 2
),
daily_metrics AS (
    SELECT dt, COUNT(*) AS total_sd_tickets, SUM(has_nbrec_within_1h) AS in_nbrec_within_1h
    FROM sd_per_customer GROUP BY 1
),
metrics AS (
    SELECT dt, 'Total Security Deposit Tickets' AS metric, total_sd_tickets AS val FROM daily_metrics
    UNION ALL
    SELECT dt, 'NBREC Created Within 1 Hour', in_nbrec_within_1h FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30
GROUP BY metric ORDER BY metric desc
"""

QUERIES["put_raw_creation_rate"] = r"""
WITH migrated_customers AS (
    SELECT account_id FROM T_WG_CUSTOMER
    WHERE lco_account_id IN (
        SELECT DISTINCT partner_id
        FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT WHERE _FIVETRAN_ACTIVE
    )
),
last_trum_expiry AS (
    SELECT tg.account_id, MAX(trum.OTP_EXPIRY_TIME) AS last_trum_expiry_time
    FROM T_ROUTER_USER_MAPPING trum
    JOIN T_WG_CUSTOMER tg ON tg.mobile = trum.mobile
    WHERE trum.otp = 'DONE' AND trum.store_group_id = 0 AND trum.device_limit = 10
        AND trum.mobile > '5999999999'
    GROUP BY 1
),
last_isp_expiry AS (
    SELECT c.customer_id AS account_id, MAX(rg.WINDOW_END) AS last_isp_expiry_time
    FROM PROD_DB.CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES rg
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.connection_id = rg.CONNECTION_ID AND c._FIVETRAN_ACTIVE
    WHERE rg._FIVETRAN_ACTIVE GROUP BY 1
),
eligible_customers AS (
    SELECT mc.account_id,
        DATEADD(day, 15, CASE
            WHEN le.last_trum_expiry_time IS NULL THEN ie.last_isp_expiry_time
            WHEN ie.last_isp_expiry_time IS NULL THEN le.last_trum_expiry_time
            ELSE LEAST(le.last_trum_expiry_time, ie.last_isp_expiry_time)
        END) AS system_trigger_date
    FROM migrated_customers mc
    LEFT JOIN last_trum_expiry le ON le.account_id = mc.account_id
    LEFT JOIN last_isp_expiry ie ON ie.account_id = mc.account_id
    WHERE (le.last_trum_expiry_time IS NOT NULL AND DATEADD(day,15,le.last_trum_expiry_time) <= CURRENT_DATE)
        OR (ie.last_isp_expiry_time IS NOT NULL AND DATEADD(day,15,ie.last_isp_expiry_time) <= CURRENT_DATE)
),
eligible_in_window AS (
    SELECT * FROM eligible_customers
    WHERE DATE(system_trigger_date) BETWEEN CURRENT_DATE - 31 AND CURRENT_DATE
),
customer_coverage AS (
    SELECT DATE(e.system_trigger_date) AS dt, e.account_id,
        MAX(CASE WHEN sc.CUSTOMER_ACCOUNT_ID IS NOT NULL THEN 1 ELSE 0 END) AS has_sd,
        MAX(CASE WHEN exec.last_connection_id IS NOT NULL THEN 1 ELSE 0 END) AS has_nbrec,
        MAX(CASE WHEN sc.CUSTOMER_ACCOUNT_ID IS NOT NULL AND exec.last_connection_id IS NOT NULL
                 AND ABS(DATEDIFF(minute, exec.created_at, CONVERT_TIMEZONE('Asia/Kolkata', sc.created_at))) <= 720
            THEN 1 ELSE 0 END) AS has_both_within_12h
    FROM eligible_in_window e
    LEFT JOIN PROD_DB.CUSTOMER_DB_CUSTOMER_PROFILE_SERVICE_AUDIT_PUBLIC.SECURITY_DEPOSIT_ORDERS sc
        ON sc.CUSTOMER_ACCOUNT_ID = e.account_id AND sc._FIVETRAN_ACTIVE
    LEFT JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.customer_id = e.account_id AND c._FIVETRAN_ACTIVE
    LEFT JOIN PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES exec
        ON exec.last_connection_id = c.connection_id AND exec._FIVETRAN_ACTIVE
    GROUP BY 1, 2
),
daily_metrics AS (
    SELECT dt, COUNT(*) AS eligible_customers, SUM(has_sd) AS has_sd_ticket,
        SUM(has_nbrec) AS has_nbrec, SUM(has_both_within_12h) AS has_both_within_12h,
        ROUND(SUM(has_both_within_12h) * 100.0 / NULLIF(COUNT(*),0), 1) AS pct_both_within_12h
    FROM customer_coverage GROUP BY 1
),
metrics AS (
    SELECT dt, 'Eligible Customers' AS metric, eligible_customers AS val FROM daily_metrics
    UNION ALL SELECT dt, 'Has SD Ticket', has_sd_ticket FROM daily_metrics
    UNION ALL SELECT dt, 'Has NBREC', has_nbrec FROM daily_metrics
    UNION ALL SELECT dt, 'Has Both Within 1 Hours', has_both_within_12h FROM daily_metrics
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt = DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt = DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt = DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt = DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt = DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt = DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt = DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt = DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val),1) AS "Mean",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val),1) AS "Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val),1) AS "P90"
FROM metrics WHERE dt >= CURRENT_DATE - 30
GROUP BY metric ORDER BY metric
"""

# ── Add more workflow queries here ────────────────────────────────
QUERIES["pickup_tickets_efficiency"] = r"""
WITH params AS (SELECT DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata',CURRENT_TIMESTAMP())) AS today),
t1 AS (
    SELECT
        DATE(CREATED_AT + INTERVAL '330 minutes') + 30                                     AS d,
        EXECUTION_CANDIDATE_ID,
        CREATED_AT,
        MAX(CASE WHEN REASON_CODE = 'DEVICE_RECOVERED_VERIFIED' THEN 1 ELSE 0 END)         AS is_recovered,
        MAX(CASE WHEN REASON_CODE = 'DEVICE_RESCUED'            THEN 1 ELSE 0 END)         AS is_rescued,
        MIN(CASE WHEN REASON_CODE IN ('DEVICE_RESCUED','DEVICE_RECOVERED_VERIFIED')
                 THEN UPDATED_AT END)                                                       AS pickup_at
    FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.NBREC_EXECUTION_CANDIDATES
    GROUP BY 1, 2, 3
),
base AS (
    SELECT
        d,
        CASE WHEN pickup_at < CREATED_AT + INTERVAL '30 days' THEN is_recovered ELSE 0 END   AS num,
        1 - CASE WHEN pickup_at < CREATED_AT + INTERVAL '30 days' THEN is_rescued ELSE 0 END  AS den,
        CASE WHEN pickup_at < CREATED_AT + INTERVAL '30 days' AND pickup_at IS NOT NULL
             THEN ROUND(DATEDIFF('hour', CREATED_AT, pickup_at) / 24.0, 1) END               AS tat_days
    FROM t1
),
tat_daily AS (
    SELECT d,
        ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_days), 1) AS p50,
        ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY tat_days), 1) AS p75,
        ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY tat_days), 1) AS p99
    FROM base WHERE tat_days IS NOT NULL
    GROUP BY 1
),
rec_daily AS (
    SELECT d, ROUND(100.0 * SUM(num) / NULLIF(SUM(den), 0), 1) AS val
    FROM base GROUP BY 1
),
all_metrics AS (
    SELECT 1 AS sort_order, 'P50 TAT (days)'     AS metric, d, p50 AS val FROM tat_daily
    UNION ALL
    SELECT 2,               'P75 TAT (days)',                d, p75        FROM tat_daily
    UNION ALL
    SELECT 3,               'P99 TAT (days)',                d, p99        FROM tat_daily
    UNION ALL
    SELECT 4,               'Recovery Rate 30d %',           d, val        FROM rec_daily
),
stats AS (
    SELECT metric,
        ROUND(AVG(val),   1) AS avg_val,
        ROUND(MEDIAN(val),1) AS med_val,
        ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1) AS p90_val
    FROM all_metrics
    WHERE d >= DATEADD('day', -90, (SELECT today FROM params))
      AND d <  (SELECT today FROM params)
    GROUP BY metric
)
SELECT
    m.sort_order,
    m.metric                                             AS metric,
    MAX(CASE WHEN d = p.today   THEN m.val END)         AS "Today",
    MAX(CASE WHEN d = p.today-1 THEN m.val END)         AS "T-1",
    MAX(CASE WHEN d = p.today-2 THEN m.val END)         AS "T-2",
    MAX(CASE WHEN d = p.today-3 THEN m.val END)         AS "T-3",
    MAX(CASE WHEN d = p.today-4 THEN m.val END)         AS "T-4",
    MAX(CASE WHEN d = p.today-5 THEN m.val END)         AS "T-5",
    MAX(CASE WHEN d = p.today-6 THEN m.val END)         AS "T-6",
    MAX(CASE WHEN d = p.today-7 THEN m.val END)         AS "T-7",
    s.avg_val                                            AS "Average",
    s.med_val                                            AS "Median",
    s.p90_val                                            AS "P90"
FROM all_metrics m
CROSS JOIN params p
LEFT JOIN stats s ON s.metric = m.metric
GROUP BY m.sort_order, m.metric, s.avg_val, s.med_val, s.p90_val
ORDER BY m.sort_order
"""

QUERIES["b2i_sla"] = r"""
WITH
sla_base AS (
    SELECT
        DATE(BOOKING_CONFIRM_TIME) AS booking_confirm_date,
        DATEDIFF('minute', BOOKING_CONFIRM_TIME, INSTALL_TIME) AS tat_mins
    FROM prod_db.public.COMPANY_B_CONNECTION_BOOKING_ENRICHED
    WHERE MOBILE > '5999999999'
      AND IS_INSTALLED = 1
      AND BOOKING_CONFIRM_TIME IS NOT NULL
      AND INSTALL_TIME IS NOT NULL
      AND DATEDIFF('minute', BOOKING_CONFIRM_TIME, INSTALL_TIME) >= 0
      AND DATE(BOOKING_CONFIRM_TIME) >= DATEADD('day', -37, CURRENT_DATE)
),
bucketed AS (
    SELECT
        tat_mins,
        CASE
            WHEN booking_confirm_date = DATEADD('day',-1, CURRENT_DATE) THEN 'D-1'
            WHEN booking_confirm_date = DATEADD('day',-2, CURRENT_DATE) THEN 'D-2'
            WHEN booking_confirm_date = DATEADD('day',-3, CURRENT_DATE) THEN 'D-3'
            WHEN booking_confirm_date = DATEADD('day',-4, CURRENT_DATE) THEN 'D-4'
            WHEN booking_confirm_date = DATEADD('day',-5, CURRENT_DATE) THEN 'D-5'
            WHEN booking_confirm_date = DATEADD('day',-6, CURRENT_DATE) THEN 'D-6'
            WHEN booking_confirm_date = DATEADD('day',-7, CURRENT_DATE) THEN 'D-7'
            WHEN booking_confirm_date = DATEADD('day',-8, CURRENT_DATE) THEN 'D-8'
        END AS day_bucket,
        CASE
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATE_TRUNC('week', CURRENT_DATE)                     THEN 'W'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-1, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-1'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-2, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-2'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-3, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-3'
        END AS week_bucket,
        IFF(booking_confirm_date >= DATEADD('day',-30, CURRENT_DATE), 1, 0) AS in_30d
    FROM sla_base
),
per_bucket AS (
    SELECT bucket,
        ROUND(COUNT(CASE WHEN tat_mins <= 30   THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS pct_30min,
        ROUND(COUNT(CASE WHEN tat_mins <= 60   THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS pct_1hr,
        ROUND(COUNT(CASE WHEN tat_mins <= 240  THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS pct_4hr,
        ROUND(COUNT(CASE WHEN tat_mins <= 1440 THEN 1 END) * 100.0 / NULLIF(COUNT(*),0), 1) AS pct_24hr,
        COUNT(*) AS installs
    FROM (
        SELECT day_bucket  AS bucket, tat_mins FROM bucketed WHERE day_bucket  IS NOT NULL
        UNION ALL
        SELECT week_bucket AS bucket, tat_mins FROM bucketed WHERE week_bucket IS NOT NULL
        UNION ALL
        SELECT '30d'       AS bucket, tat_mins FROM bucketed WHERE in_30d = 1
    ) x
    GROUP BY bucket
)
SELECT
    stat_ord, stat AS METRIC_NAME,
    MAX(CASE WHEN bucket='D-1' THEN val END) AS "D-1",
    MAX(CASE WHEN bucket='D-2' THEN val END) AS "D-2",
    MAX(CASE WHEN bucket='D-3' THEN val END) AS "D-3",
    MAX(CASE WHEN bucket='D-4' THEN val END) AS "D-4",
    MAX(CASE WHEN bucket='D-5' THEN val END) AS "D-5",
    MAX(CASE WHEN bucket='D-6' THEN val END) AS "D-6",
    MAX(CASE WHEN bucket='D-7' THEN val END) AS "D-7",
    MAX(CASE WHEN bucket='D-8' THEN val END) AS "D-8",
    MAX(CASE WHEN bucket='W'   THEN val END) AS "W",
    MAX(CASE WHEN bucket='W-1' THEN val END) AS "W-1",
    MAX(CASE WHEN bucket='W-2' THEN val END) AS "W-2",
    MAX(CASE WHEN bucket='W-3' THEN val END) AS "W-3",
    MAX(CASE WHEN bucket='30d' THEN val END) AS "30d"
FROM (
    SELECT 0 AS stat_ord, '≤ 30 min (B2I)' AS stat, bucket, pct_30min  AS val FROM per_bucket
    UNION ALL SELECT 1, '≤ 1 hr (B2I)',  bucket, pct_1hr  FROM per_bucket
    UNION ALL SELECT 2, '≤ 4 hrs (B2I)', bucket, pct_4hr  FROM per_bucket
    UNION ALL SELECT 3, '≤ 24 hrs (B2I)',bucket, pct_24hr FROM per_bucket
    UNION ALL SELECT 4, 'Total installs', bucket, installs::FLOAT FROM per_bucket
) x
GROUP BY stat_ord, stat
ORDER BY stat_ord
"""

QUERIES["b2i_tat"] = r"""
WITH
bb AS (
    SELECT
        e.mobile,
        ROW_NUMBER() OVER (PARTITION BY e.mobile ORDER BY e.booking_confirm_time) AS wn,
        e.booking_confirm_time AS fee_time,
        COALESCE(e.next_booking_time, DATEADD(minute,330,CURRENT_TIMESTAMP())) AS wend,
        e.booking_confirm_time AS confirm_time
    FROM prod_db.public.COMPANY_B_CONNECTION_BOOKING_ENRICHED e
    WHERE e.mobile > '5999999999'
      AND DATE(e.booking_confirm_time) BETWEEN '2026-05-01' AND CURRENT_DATE
),
wp AS (
    SELECT DISTINCT b.mobile, b.wn, e.account_id AS partner_id
    FROM bb b
    JOIN prod_db.public.taskvanilla_audit e
      ON e.mobile=b.mobile AND e.account_id IS NOT NULL
     AND DATEADD(minute,330,e.added_time) >= b.fee_time
     AND DATEADD(minute,330,e.added_time) <  b.wend
     AND UPPER(e.event_name) IN ('INTERESTED','AWAITING_SLOT_PROPOSAL','AWAITING_CUSTOMER_SLOT_CONFIRMATION')
),
tp AS (
    SELECT wp.mobile, wp.wn, wp.partner_id,
        MIN(CASE WHEN UPPER(e.event_name) IN ('REACHED_HOME','ARRIVED_AT_SITE') THEN DATEADD(minute,330,e.added_time) END) arrived_time,
        MIN(CASE WHEN UPPER(e.event_name)='SELFIE'          THEN DATEADD(minute,330,e.added_time) END) selfie_time,
        MIN(CASE WHEN UPPER(e.event_name)='AADHAR'          THEN DATEADD(minute,330,e.added_time) END) aadhar_time,
        MIN(CASE WHEN UPPER(e.event_name)='SHARED'          THEN DATEADD(minute,330,e.added_time) END) shared_time,
        MIN(CASE WHEN UPPER(e.event_name)='CONNECTION_INFO'  THEN DATEADD(minute,330,e.added_time) END) connection_info_time,
        MIN(CASE WHEN UPPER(e.event_name)='DEVICE_PHOTO'    THEN DATEADD(minute,330,e.added_time) END) device_photo_time,
        MIN(CASE WHEN UPPER(e.event_name)='SPEED_TEST'      THEN DATEADD(minute,330,e.added_time) END) speed_test_time,
        MIN(CASE WHEN UPPER(e.event_name)='OTP_VERIFIED'    THEN DATEADD(minute,330,e.added_time) END) install_time,
        MIN(CASE WHEN UPPER(e.event_name)='RATING'          THEN DATEADD(minute,330,e.added_time) END) rating_time
    FROM wp
    JOIN bb b ON b.mobile=wp.mobile AND b.wn=wp.wn
    JOIN prod_db.public.taskvanilla_audit e
      ON e.mobile=wp.mobile AND e.account_id=wp.partner_id
     AND DATEADD(minute,330,e.added_time) >= b.fee_time
     AND DATEADD(minute,330,e.added_time) <  b.wend
    GROUP BY wp.mobile, wp.wn, wp.partner_id
),
bl AS (
    SELECT b.mobile, b.wn,
        MIN(CASE WHEN LOWER(bl.event_name)='sd_payment_received'
                 THEN DATEADD(minute,330,bl.added_time) END) install_fee_time
    FROM bb b
    JOIN prod_db.public.bookingvanilla_audit bl
      ON bl.mobile=b.mobile
     AND DATEADD(minute,330,bl.added_time) >= b.fee_time
     AND DATEADD(minute,330,bl.added_time) <  b.wend
    GROUP BY b.mobile, b.wn
),
win_exec AS (
    SELECT DISTINCT b.mobile, b.wn, t.execution_candidate_id AS exec_id
    FROM bb b
    JOIN prod_db.public.taskvanilla_audit t
      ON t.mobile=b.mobile AND t.execution_candidate_id IS NOT NULL
     AND DATEADD(minute,330,t.added_time) >= b.fee_time
     AND DATEADD(minute,330,t.added_time) <  b.wend
),
isp AS (
    SELECT mobile, wn,
        MIN(CASE WHEN ev='speed_test_completed' THEN ts END) speed_test_csp_time
    FROM (
        SELECT b.mobile, b.wn, e.event_name ev, TRY_TO_TIMESTAMP(e.timestamp) ts
        FROM win_exec we
        JOIN prod_db.CLEVERTAP_CSP_API.EVENTS_DATA e
          ON TRY_PARSE_JSON(e.properties):execution_id::string = we.exec_id
         AND e.event_name = 'speed_test_completed'
        JOIN bb b ON b.mobile=we.mobile AND b.wn=we.wn
         AND TRY_TO_TIMESTAMP(e.timestamp)>=b.fee_time AND TRY_TO_TIMESTAMP(e.timestamp)<b.wend
    ) u
    GROUP BY mobile, wn
),
bl AS (
    SELECT b.mobile, b.wn,
        MIN(CASE WHEN LOWER(bl.event_name)='sd_payment_received' THEN DATEADD(minute,330,bl.added_time) END) install_fee_time
    FROM bb b
    JOIN prod_db.public.bookingvanilla_audit bl ON bl.mobile=b.mobile
     AND DATEADD(minute,330,bl.added_time)>=b.fee_time AND DATEADD(minute,330,bl.added_time)<b.wend
    GROUP BY b.mobile, b.wn
),
pw AS (
    SELECT
        b.mobile, b.wn, b.confirm_time,
        tp.arrived_time, tp.selfie_time, tp.aadhar_time, tp.shared_time,
        tp.device_photo_time, tp.connection_info_time,
        COALESCE(tp.speed_test_time, isp.speed_test_csp_time) AS speed_test_time,
        tp.install_time,
        CASE WHEN tp.arrived_time IS NOT NULL THEN bl.install_fee_time ELSE NULL END AS install_fee_time,
        tp.rating_time
    FROM bb b
    LEFT JOIN wp   ON wp.mobile=b.mobile AND wp.wn=b.wn
    LEFT JOIN tp   ON tp.mobile=b.mobile AND tp.wn=b.wn AND tp.partner_id=wp.partner_id
    LEFT JOIN isp  ON isp.mobile=b.mobile AND isp.wn=b.wn
    LEFT JOIN bl   ON bl.mobile=b.mobile AND bl.wn=b.wn
),
base AS (
    SELECT
        p.mobile, p.wn,
        DATE(p.confirm_time) AS booking_confirm_date,
        MAX(p.install_time) AS install_time,
        DATEDIFF('minute', MIN(CASE WHEN p.arrived_time IS NOT NULL THEN p.arrived_time END),
                           MIN(CASE WHEN p.selfie_time  IS NOT NULL THEN p.selfie_time  END)) AS tat_arrived_to_selfie_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.selfie_time  IS NOT NULL THEN p.selfie_time  END),
                           MIN(CASE WHEN p.aadhar_time  IS NOT NULL THEN p.aadhar_time  END)) AS tat_selfie_to_aadhar_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.aadhar_time  IS NOT NULL THEN p.aadhar_time  END),
                           MAX(p.install_fee_time))                                            AS tat_aadhar_to_fee_mins,
        DATEDIFF('minute', MAX(p.install_fee_time),
                           MIN(CASE WHEN p.shared_time  IS NOT NULL THEN p.shared_time  END)) AS tat_fee_to_shared_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.shared_time          IS NOT NULL THEN p.shared_time          END),
                           MIN(CASE WHEN p.connection_info_time IS NOT NULL THEN p.connection_info_time END)) AS tat_shared_to_conn_info_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.connection_info_time IS NOT NULL THEN p.connection_info_time END),
                           MIN(CASE WHEN p.device_photo_time    IS NOT NULL THEN p.device_photo_time    END)) AS tat_conn_info_to_device_photo_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.device_photo_time    IS NOT NULL THEN p.device_photo_time    END),
                           MIN(CASE WHEN p.speed_test_time      IS NOT NULL THEN p.speed_test_time      END)) AS tat_device_photo_to_speed_test_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.speed_test_time      IS NOT NULL THEN p.speed_test_time      END),
                           MAX(p.install_time))                                                AS tat_speed_test_to_install_mins,
        DATEDIFF('minute', MAX(p.install_time),
                           MIN(CASE WHEN p.rating_time IS NOT NULL THEN p.rating_time END))    AS tat_install_to_rating_mins,
        DATEDIFF('minute', MIN(CASE WHEN p.arrived_time IS NOT NULL THEN p.arrived_time END),
                           MIN(CASE WHEN p.rating_time  IS NOT NULL THEN p.rating_time  END))  AS tat_arrived_to_rating_mins
    FROM pw p
    GROUP BY p.mobile, p.wn, DATE(p.confirm_time)
),
unpivoted AS (
    SELECT booking_confirm_date, 0 AS step_ord, 'Arrive -> Selfie'          AS step_name, tat_arrived_to_selfie_mins           AS tat_mins FROM base WHERE install_time IS NOT NULL AND tat_arrived_to_selfie_mins IS NOT NULL           AND tat_arrived_to_selfie_mins >= 0
    UNION ALL SELECT booking_confirm_date, 1, 'Selfie -> Aadhar',            tat_selfie_to_aadhar_mins          FROM base WHERE install_time IS NOT NULL AND tat_selfie_to_aadhar_mins IS NOT NULL           AND tat_selfie_to_aadhar_mins >= 0
    UNION ALL SELECT booking_confirm_date, 2, 'Aadhar -> Install Fee',       tat_aadhar_to_fee_mins             FROM base WHERE install_time IS NOT NULL AND tat_aadhar_to_fee_mins IS NOT NULL              AND tat_aadhar_to_fee_mins >= 0
    UNION ALL SELECT booking_confirm_date, 3, 'Install Fee -> Shared',       tat_fee_to_shared_mins             FROM base WHERE install_time IS NOT NULL AND tat_fee_to_shared_mins IS NOT NULL              AND tat_fee_to_shared_mins >= 0
    UNION ALL SELECT booking_confirm_date, 4, 'Shared -> Conn Info',         tat_shared_to_conn_info_mins       FROM base WHERE install_time IS NOT NULL AND tat_shared_to_conn_info_mins IS NOT NULL        AND tat_shared_to_conn_info_mins >= 0
    UNION ALL SELECT booking_confirm_date, 5, 'Conn Info -> Device Photo',   tat_conn_info_to_device_photo_mins FROM base WHERE install_time IS NOT NULL AND tat_conn_info_to_device_photo_mins IS NOT NULL  AND tat_conn_info_to_device_photo_mins >= 0
    UNION ALL SELECT booking_confirm_date, 6, 'Device Photo -> Speed Test',  tat_device_photo_to_speed_test_mins FROM base WHERE install_time IS NOT NULL AND tat_device_photo_to_speed_test_mins IS NOT NULL AND tat_device_photo_to_speed_test_mins >= 0
    UNION ALL SELECT booking_confirm_date, 7, 'Speed Test -> Install',       tat_speed_test_to_install_mins     FROM base WHERE install_time IS NOT NULL AND tat_speed_test_to_install_mins IS NOT NULL      AND tat_speed_test_to_install_mins >= 0
    UNION ALL SELECT booking_confirm_date, 8, 'Install -> Rating',           tat_install_to_rating_mins         FROM base WHERE install_time IS NOT NULL AND tat_install_to_rating_mins IS NOT NULL          AND tat_install_to_rating_mins >= 0
    UNION ALL SELECT booking_confirm_date, 9, 'Arrived -> Rating (Total)',   tat_arrived_to_rating_mins         FROM base WHERE install_time IS NOT NULL AND tat_arrived_to_rating_mins IS NOT NULL          AND tat_arrived_to_rating_mins >= 0
),
bucketed AS (
    SELECT
        step_ord, step_name, tat_mins,
        CASE
            WHEN booking_confirm_date = DATEADD('day',-1, CURRENT_DATE) THEN 'D-1'
            WHEN booking_confirm_date = DATEADD('day',-2, CURRENT_DATE) THEN 'D-2'
            WHEN booking_confirm_date = DATEADD('day',-3, CURRENT_DATE) THEN 'D-3'
            WHEN booking_confirm_date = DATEADD('day',-4, CURRENT_DATE) THEN 'D-4'
            WHEN booking_confirm_date = DATEADD('day',-5, CURRENT_DATE) THEN 'D-5'
            WHEN booking_confirm_date = DATEADD('day',-6, CURRENT_DATE) THEN 'D-6'
            WHEN booking_confirm_date = DATEADD('day',-7, CURRENT_DATE) THEN 'D-7'
            WHEN booking_confirm_date = DATEADD('day',-8, CURRENT_DATE) THEN 'D-8'
        END AS day_bucket,
        CASE
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATE_TRUNC('week', CURRENT_DATE)                     THEN 'W'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-1, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-1'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-2, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-2'
            WHEN DATE_TRUNC('week', booking_confirm_date) = DATEADD('week',-3, DATE_TRUNC('week', CURRENT_DATE)) THEN 'W-3'
        END AS week_bucket,
        IFF(booking_confirm_date >= DATEADD('day',-30, CURRENT_DATE), 1, 0) AS in_30d
    FROM unpivoted
    WHERE booking_confirm_date >= DATEADD('day', -37, CURRENT_DATE)
),
daily_stats AS (
    SELECT step_ord, step_name, day_bucket AS bucket,
        ROUND(AVG(tat_mins), 1)    AS mean_val,
        ROUND(MEDIAN(tat_mins), 1) AS median_val,
        ROUND(STDDEV(tat_mins), 1) AS stddev_val
    FROM bucketed WHERE day_bucket IS NOT NULL
    GROUP BY step_ord, step_name, day_bucket
),
weekly_stats AS (
    SELECT step_ord, step_name, week_bucket AS bucket,
        ROUND(AVG(tat_mins), 1)    AS mean_val,
        ROUND(MEDIAN(tat_mins), 1) AS median_val,
        ROUND(STDDEV(tat_mins), 1) AS stddev_val
    FROM bucketed WHERE week_bucket IS NOT NULL
    GROUP BY step_ord, step_name, week_bucket
),
monthly_stats AS (
    SELECT step_ord, step_name, '30d' AS bucket,
        ROUND(AVG(tat_mins), 1)    AS mean_val,
        ROUND(MEDIAN(tat_mins), 1) AS median_val,
        ROUND(STDDEV(tat_mins), 1) AS stddev_val
    FROM bucketed WHERE in_30d = 1
    GROUP BY step_ord, step_name
),
all_stat_rows AS (
    SELECT step_ord, step_name, bucket, 0 AS stat_ord, 'Mean (min)'   AS stat, mean_val   AS val FROM daily_stats
    UNION ALL SELECT step_ord, step_name, bucket, 1, 'Median (min)',   median_val FROM daily_stats
    UNION ALL SELECT step_ord, step_name, bucket, 2, 'StdDev',         stddev_val FROM daily_stats
    UNION ALL SELECT step_ord, step_name, bucket, 0, 'Mean (min)',     mean_val   FROM weekly_stats
    UNION ALL SELECT step_ord, step_name, bucket, 1, 'Median (min)',   median_val FROM weekly_stats
    UNION ALL SELECT step_ord, step_name, bucket, 2, 'StdDev',         stddev_val FROM weekly_stats
    UNION ALL SELECT step_ord, step_name, bucket, 0, 'Mean (min)',     mean_val   FROM monthly_stats
    UNION ALL SELECT step_ord, step_name, bucket, 1, 'Median (min)',   median_val FROM monthly_stats
    UNION ALL SELECT step_ord, step_name, bucket, 2, 'StdDev',         stddev_val FROM monthly_stats
)
SELECT
    step_ord * 3 + stat_ord                            AS sort_ord,
    step_name                                          AS STEP_TRANSITION,
    stat                                               AS STAT,
    MAX(CASE WHEN bucket='D-1' THEN val END)           AS "D-1",
    MAX(CASE WHEN bucket='D-2' THEN val END)           AS "D-2",
    MAX(CASE WHEN bucket='D-3' THEN val END)           AS "D-3",
    MAX(CASE WHEN bucket='D-4' THEN val END)           AS "D-4",
    MAX(CASE WHEN bucket='D-5' THEN val END)           AS "D-5",
    MAX(CASE WHEN bucket='D-6' THEN val END)           AS "D-6",
    MAX(CASE WHEN bucket='D-7' THEN val END)           AS "D-7",
    MAX(CASE WHEN bucket='D-8' THEN val END)           AS "D-8",
    MAX(CASE WHEN bucket='W'   THEN val END)           AS "W",
    MAX(CASE WHEN bucket='W-1' THEN val END)           AS "W-1",
    MAX(CASE WHEN bucket='W-2' THEN val END)           AS "W-2",
    MAX(CASE WHEN bucket='W-3' THEN val END)           AS "W-3",
    MAX(CASE WHEN bucket='30d' THEN val END)           AS "30d"
FROM all_stat_rows
GROUP BY step_ord, step_name, stat_ord, stat
ORDER BY step_ord, stat_ord
"""


# ── Earnings queries (loaded from sql/ directory) ─────────────────

def _load_sql(filename):
    path = os.path.join(DIR, "sql", filename)
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

EARNINGS_HEALTH_QUERIES = [
    ("earnings_health",               "earnings_q1_on_time_error_free.sql"),
    ("earnings_health",               "earnings_q2_d1_timely_credit.sql"),
    ("earnings_health",               "earnings_q3_d2_error_free_credit.sql"),
    ("earnings_health",               "earnings_q4_d3_timely_debit.sql"),
    ("earnings_health",               "earnings_q5_d4_error_free_debit.sql"),
    ("earnings_health",               "earnings_q6_i1_sync_reliability.sql"),
    ("earnings_health",               "earnings_q7_i2_settlement_rails.sql"),
    ("earnings_health",               "earnings_q8_i4_notification.sql"),
]

EARNINGS_SUBTABLE_QUERIES = {
    "earnings_health_sync_breakup":   "earnings_i1_sync_breakup.sql",
    "earnings_error_free_debit_by_type": "earnings_q9_error_free_debit_by_type.sql",
    "earnings_timely_debit_by_type":  "earnings_q10_timely_debit_by_type.sql",
    "earnings_error_free_credit_by_type": "earnings_q11_error_free_credit_by_type.sql",
    "earnings_timely_credit_by_type": "earnings_q12_timely_credit_by_type.sql",
    "earnings_raw":                   "earnings_raw_amounts.sql",
}


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

    # ── Earnings health: run 8 queries and merge rows into one list ──
    earnings_health_rows = []
    for key, filename in EARNINGS_HEALTH_QUERIES:
        print(f"  Querying earnings: {filename}...")
        try:
            rows = mb_native(_load_sql(filename))
            earnings_health_rows.extend(rows)
            print(f"  -> {len(rows)} rows")
        except Exception as e:
            print(f"  ERROR on {filename}: {e}")
    data["earnings_health"] = earnings_health_rows

    # ── Earnings sub-tables (sync breakup + raw amounts) ────────────
    for key, filename in EARNINGS_SUBTABLE_QUERIES.items():
        print(f"  Querying earnings: {filename}...")
        try:
            rows = mb_native(_load_sql(filename))
            data[key] = rows
            print(f"  -> {len(rows)} rows")
        except Exception as e:
            print(f"  ERROR on {filename}: {e}")
            data[key] = []

    # b2i_tat: rename for frontend
    if data.get("b2i_tat"):
        for row in data["b2i_tat"]:
            if "STEP_TRANSITION" in row:
                row["STEP"] = row.pop("STEP_TRANSITION")

    if not any(data[k] for k in data):
        print("ERROR: All queries returned empty — not overwriting workflow_data.js")
        raise SystemExit(1)

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
