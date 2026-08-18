/*
  CARRY FEE — Dynamic Cohort State Tracker v2 (9 AM IST snapshot)
  ────────────────────────────────────────────────────────────────
  Stock view: sum of all states per region per day = cohort size (constant).

  FIXES vs v1:
    1. Snapshot +1 day: each day's state = 9 AM IST NEXT day,
       so D0 captures changes DURING the cadence day.
    2. Days capped at < CURRENT_DATE() (need next day's 9 AM).
    3. Region uses cohort CSP_ID (cd.CSP_ID), not daily nc.CSP_ID,
       so region stays stable when devices transfer CSPs.

  COLUMNS:
    D-1 = baseline (all IDLE)
    D0  = cadence date    → state distribution after cadence day
    D1…D29 = cadence+1…+29
    Sum across states per region per day always = D-1 count.
*/

WITH cadence_dates AS (
    SELECT column1::DATE AS cohort_date
    FROM VALUES ('2026-08-16'), ('2026-09-01'), ('2026-09-16'), ('2026-10-01'), ('2026-10-16'), ('2026-11-01'), ('2026-11-16'), ('2026-12-01'), ('2026-12-16'), ('2027-01-01'), ('2027-01-16'), ('2027-02-01')
    WHERE column1::DATE <= CURRENT_DATE()
),
params AS (
    SELECT cohort_date,
        COALESCE(LAG(cohort_date) OVER (ORDER BY cohort_date), '1970-01-01'::DATE) AS prev_cadence_date,
        7 AS threshold_days, 25 AS hard_cap
    FROM cadence_dates
),
region_map AS (
    SELECT ca.CSP_ID,
        CASE WHEN sm.CITY = 'Delhi' THEN 'Delhi' WHEN sm.CITY = 'Mumbai' THEN 'Mumbai' ELSE 'Bharat' END AS region
    FROM (
        SELECT CSP_ID, PARTNER_ID FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
        WHERE PARTNER_ID IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY CSP_ID ORDER BY _FIVETRAN_START DESC) = 1
    ) ca
    LEFT JOIN PROD_DB.PUBLIC.SUPPLY_MODEL sm ON ca.PARTNER_ID = sm.PARTNER_ACCOUNT_ID
),
cohort_devices AS (
    SELECT cohort_date, DEVICE_ID, CSP_ID
    FROM (
        SELECT p.cohort_date, p.prev_cadence_date, nc.DEVICE_ID, nc.CSP_ID, nc.STATUS,
            nc.WAS_EVER_DEPLOYED, nc.IDLE_START_DATE, nc.CARRY_FEE_ACCRUAL_UNITS, nc.CARRY_FEE_STATE,
            DATEADD(day, p.threshold_days + 1, nc.IDLE_START_DATE::DATE) AS threshold_cross_date
        FROM params p
        INNER JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
            ON nc.UPDATED_AT < DATEADD(minute, 210, p.cohort_date::TIMESTAMP_NTZ)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY p.cohort_date, nc.DEVICE_ID ORDER BY nc.UPDATED_AT DESC) = 1
    ) snap
    WHERE STATUS = 'IDLE' AND WAS_EVER_DEPLOYED = true AND IDLE_START_DATE IS NOT NULL
        AND DATEDIFF(day, IDLE_START_DATE::DATE, cohort_date) > 7
        AND COALESCE(CARRY_FEE_ACCRUAL_UNITS, 0) < 25
        AND (CARRY_FEE_STATE IS NULL OR CARRY_FEE_STATE != 'PAUSED')
        AND (CASE WHEN DAY(threshold_cross_date) IN (1,16) THEN threshold_cross_date WHEN DAY(threshold_cross_date) BETWEEN 2 AND 15 THEN DATEADD(day, 15, DATE_TRUNC('month', threshold_cross_date))::DATE ELSE DATE_TRUNC('month', DATEADD(month, 1, threshold_cross_date))::DATE END) <= cohort_date
        AND (CASE WHEN DAY(threshold_cross_date) IN (1,16) THEN threshold_cross_date WHEN DAY(threshold_cross_date) BETWEEN 2 AND 15 THEN DATEADD(day, 15, DATE_TRUNC('month', threshold_cross_date))::DATE ELSE DATE_TRUNC('month', DATEADD(month, 1, threshold_cross_date))::DATE END) > prev_cadence_date
),
days AS (
    SELECT cd.cohort_date, DATEADD(day, s.seq - 1, cd.cohort_date)::DATE AS day_date, s.seq AS day_num
    FROM cadence_dates cd
    CROSS JOIN (SELECT SEQ4() AS seq FROM TABLE(GENERATOR(ROWCOUNT => 31))) s
    WHERE DATEADD(day, s.seq - 1, cd.cohort_date)::DATE <= CURRENT_DATE()
),
device_daily_status AS (
    SELECT d.cohort_date, d.day_date, d.day_num, nc.DEVICE_ID, cd.CSP_ID, nc.STATUS
    FROM cohort_devices cd
    INNER JOIN days d ON d.cohort_date = cd.cohort_date
    INNER JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
        ON nc.DEVICE_ID = cd.DEVICE_ID
        AND nc.UPDATED_AT < DATEADD(minute, 210, DATEADD(day, 1, d.day_date)::TIMESTAMP_NTZ)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY d.cohort_date, d.day_date, nc.DEVICE_ID ORDER BY nc.UPDATED_AT DESC) = 1
)
SELECT
    dds.cohort_date,
    COALESCE(rm.region, 'Bharat') AS region,
    CASE WHEN dds.STATUS = 'IDLE' THEN 'Idle' WHEN dds.STATUS = 'RETRIEVAL_PENDING' THEN 'Retrieval Pending' WHEN dds.STATUS = 'RETURNED' THEN 'Returned' WHEN dds.STATUS = 'DEPLOYED' THEN 'Deployed' WHEN dds.STATUS = 'LOST' THEN 'Lost' ELSE 'Other' END AS state,
    COUNT(DISTINCT CASE WHEN day_num = 0  THEN dds.DEVICE_ID END) AS "D-1",
    COUNT(DISTINCT CASE WHEN day_num = 1  THEN dds.DEVICE_ID END) AS "D0",
    COUNT(DISTINCT CASE WHEN day_num = 2  THEN dds.DEVICE_ID END) AS "D1",
    COUNT(DISTINCT CASE WHEN day_num = 3  THEN dds.DEVICE_ID END) AS "D2",
    COUNT(DISTINCT CASE WHEN day_num = 4  THEN dds.DEVICE_ID END) AS "D3",
    COUNT(DISTINCT CASE WHEN day_num = 5  THEN dds.DEVICE_ID END) AS "D4",
    COUNT(DISTINCT CASE WHEN day_num = 6  THEN dds.DEVICE_ID END) AS "D5",
    COUNT(DISTINCT CASE WHEN day_num = 7  THEN dds.DEVICE_ID END) AS "D6",
    COUNT(DISTINCT CASE WHEN day_num = 8  THEN dds.DEVICE_ID END) AS "D7",
    COUNT(DISTINCT CASE WHEN day_num = 9  THEN dds.DEVICE_ID END) AS "D8",
    COUNT(DISTINCT CASE WHEN day_num = 10 THEN dds.DEVICE_ID END) AS "D9",
    COUNT(DISTINCT CASE WHEN day_num = 11 THEN dds.DEVICE_ID END) AS "D10",
    COUNT(DISTINCT CASE WHEN day_num = 12 THEN dds.DEVICE_ID END) AS "D11",
    COUNT(DISTINCT CASE WHEN day_num = 13 THEN dds.DEVICE_ID END) AS "D12",
    COUNT(DISTINCT CASE WHEN day_num = 14 THEN dds.DEVICE_ID END) AS "D13",
    COUNT(DISTINCT CASE WHEN day_num = 15 THEN dds.DEVICE_ID END) AS "D14",
    COUNT(DISTINCT CASE WHEN day_num = 16 THEN dds.DEVICE_ID END) AS "D15",
    COUNT(DISTINCT CASE WHEN day_num = 17 THEN dds.DEVICE_ID END) AS "D16",
    COUNT(DISTINCT CASE WHEN day_num = 18 THEN dds.DEVICE_ID END) AS "D17",
    COUNT(DISTINCT CASE WHEN day_num = 19 THEN dds.DEVICE_ID END) AS "D18",
    COUNT(DISTINCT CASE WHEN day_num = 20 THEN dds.DEVICE_ID END) AS "D19",
    COUNT(DISTINCT CASE WHEN day_num = 21 THEN dds.DEVICE_ID END) AS "D20",
    COUNT(DISTINCT CASE WHEN day_num = 22 THEN dds.DEVICE_ID END) AS "D21",
    COUNT(DISTINCT CASE WHEN day_num = 23 THEN dds.DEVICE_ID END) AS "D22",
    COUNT(DISTINCT CASE WHEN day_num = 24 THEN dds.DEVICE_ID END) AS "D23",
    COUNT(DISTINCT CASE WHEN day_num = 25 THEN dds.DEVICE_ID END) AS "D24",
    COUNT(DISTINCT CASE WHEN day_num = 26 THEN dds.DEVICE_ID END) AS "D25",
    COUNT(DISTINCT CASE WHEN day_num = 27 THEN dds.DEVICE_ID END) AS "D26",
    COUNT(DISTINCT CASE WHEN day_num = 28 THEN dds.DEVICE_ID END) AS "D27",
    COUNT(DISTINCT CASE WHEN day_num = 29 THEN dds.DEVICE_ID END) AS "D28",
    COUNT(DISTINCT CASE WHEN day_num = 30 THEN dds.DEVICE_ID END) AS "D29",
    COUNT(DISTINCT dds.DEVICE_ID) AS cohort_size
FROM device_daily_status dds
LEFT JOIN region_map rm ON dds.CSP_ID = rm.CSP_ID
GROUP BY dds.cohort_date, rm.region,
    CASE WHEN dds.STATUS = 'IDLE' THEN 'Idle' WHEN dds.STATUS = 'RETRIEVAL_PENDING' THEN 'Retrieval Pending' WHEN dds.STATUS = 'RETURNED' THEN 'Returned' WHEN dds.STATUS = 'DEPLOYED' THEN 'Deployed' WHEN dds.STATUS = 'LOST' THEN 'Lost' ELSE 'Other' END
ORDER BY dds.cohort_date,
    CASE COALESCE(rm.region, 'Bharat') WHEN 'Delhi' THEN 1 WHEN 'Mumbai' THEN 2 WHEN 'Bharat' THEN 3 ELSE 4 END,
    CASE state WHEN 'Idle' THEN 1 WHEN 'Retrieval Pending' THEN 2 WHEN 'Returned' THEN 3 WHEN 'Deployed' THEN 4 WHEN 'Lost' THEN 5 ELSE 6 END
