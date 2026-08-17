-- ============================================================
-- CARRY FEE DAILY HEALTH CHECK v5
-- ============================================================
--
-- Reconciles "should charge" (NETBOX_CUSTODY state at 9 AM IST)
-- vs "actually charged" (WALLET_LEDGER + LIABILITY_LEDGER).
--
-- Key tables:
--   WALLET_LEDGER_ENTRIES   → ENTRY_TYPE = 'CARRY_FEE'          (wallet debit)
--   LIABILITY_LEDGER_ENTRIES → ENTRY_TYPE = 'CARRY_FEE_OVERFLOW' (liability overflow)
--   NETBOX_CUSTODY           → CARRY_FEE_STATE + STATUS          (device eligibility)
--
-- Snapshot logic:
--   Charge job runs at 9 AM IST daily. "Should" side reconstructs
--   each device's state just before the job via Fivetran SCD2 rows
--   (latest UPDATED_AT strictly < 9 AM IST on charge date).
--   UPDATED_AT is stored in UTC. 9 AM IST = 03:30 UTC.
--
-- gap_reason column:
--   Auto-diagnoses the device gap based on observed patterns:
--   • 0         → system healthy, exact match
--   • 1-10      → race condition (returns filed within seconds of 9 AM)
--   • >10       → split batch on cadence day, or bulk returns before charge
--   • negative  → should never happen; investigate
--
-- Rate: ₹2/device/day   |   Cadence dates: 1st & 16th
-- ============================================================

WITH dates AS (
    SELECT DATEADD(day, SEQ4(), '2026-08-14'::DATE)::DATE AS dt
    FROM TABLE(GENERATOR(ROWCOUNT => 365))
    WHERE DATEADD(day, SEQ4(), '2026-08-14'::DATE)::DATE <= CURRENT_DATE()
),

-- Reconstruct each device's state just before the charge job.
-- Cutoff: strictly < 9 AM IST (i.e. state as of 08:59:59.999 IST).
-- Any UPDATED_AT at 09:00:xx is either the charge job's own write
-- or a concurrent state change (return/lost) during the job window.
device_state_at_9am AS (
    SELECT charge_date, DEVICE_ID, STATUS, CARRY_FEE_STATE, WAS_EVER_DEPLOYED
    FROM (
        SELECT
            d.dt                  AS charge_date,
            nc.DEVICE_ID,
            nc.STATUS,
            nc.CARRY_FEE_STATE,
            nc.WAS_EVER_DEPLOYED
        FROM dates d
        INNER JOIN PROD_DB.CSP_ASSET_CUSTODY_SERVICE_CSP_ASSET_CUSTODY_SERVICE.NETBOX_CUSTODY nc
            ON nc.UPDATED_AT < DATEADD(minute, 210, d.dt::TIMESTAMP_NTZ)
            -- 210 min = 3h 30m → 9 AM IST in UTC
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY d.dt, nc.DEVICE_ID
            ORDER BY nc.UPDATED_AT DESC
        ) = 1
    )
),

-- Devices that SHOULD be charged on each date
daily_should AS (
    SELECT charge_date AS dt, COUNT(*) AS should_devices
    FROM device_state_at_9am
    WHERE STATUS = 'IDLE'
      AND (
          CARRY_FEE_STATE = 'CARRY_FEE_ACTIVE'
          OR (CARRY_FEE_STATE = 'PENDING_CADENCE' AND DAY(charge_date) IN (1, 16))
      )
    GROUP BY 1
),

-- Total idle context
daily_idle AS (
    SELECT charge_date AS dt, COUNT(*) AS total_idle_devices
    FROM device_state_at_9am
    WHERE STATUS = 'IDLE' AND WAS_EVER_DEPLOYED = true
    GROUP BY 1
),

-- ACTUAL: wallet debit entries
daily_wallet AS (
    SELECT
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', wle.CREATED_AT)) AS dt,
        COUNT(DISTINCT wle.CSP_ID)                                AS wallet_csps,
        SUM(ARRAY_SIZE(SPLIT(
            PARSE_JSON(wle.REMARKS):device_id::STRING, ','
        )))                                                       AS wallet_devices,
        SUM(ABS(wle.AMOUNT)) / 100.0                             AS from_wallet_rs,
        COUNT_IF(wle.REASON_CODE = 'CARRY_FEE_DEBIT_PARTIAL')    AS wallet_short_csps
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES wle
    WHERE wle.ENTRY_TYPE   = 'CARRY_FEE'
      AND wle._FIVETRAN_ACTIVE = true
      AND wle.REMARKS IS NOT NULL
    GROUP BY 1
),

-- ACTUAL: liability overflow entries
daily_liability AS (
    SELECT
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', lle.CREATED_AT)) AS dt,
        COUNT(DISTINCT lle.CSP_ID)                                AS liability_csps,
        SUM(ABS(lle.AMOUNT)) / 100.0                             AS to_liability_rs
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.LIABILITY_LEDGER_ENTRIES lle
    WHERE lle._FIVETRAN_ACTIVE = true
      AND lle.ENTRY_TYPE = 'CARRY_FEE_OVERFLOW'
    GROUP BY 1
),

-- ACTUAL: unique CSPs charged (wallet ∪ liability)
daily_charged_csps AS (
    SELECT dt, COUNT(DISTINCT csp_id) AS charged_csps
    FROM (
        SELECT TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt, CSP_ID
        FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES
        WHERE _FIVETRAN_ACTIVE = true AND ENTRY_TYPE = 'CARRY_FEE'
        UNION
        SELECT TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS dt, CSP_ID
        FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.LIABILITY_LEDGER_ENTRIES
        WHERE _FIVETRAN_ACTIVE = true AND ENTRY_TYPE = 'CARRY_FEE_OVERFLOW'
    )
    GROUP BY 1
),

-- Compute all metrics first
metrics AS (
    SELECT
        d.dt                                                        AS date,
        CASE WHEN DAY(d.dt) IN (1, 16) THEN 'CADENCE' ELSE '' END AS cadence,
        COALESCE(i.total_idle_devices, 0)                           AS total_idle,
        COALESCE(s.should_devices, 0)                               AS should_devices,
        ROUND(COALESCE(s.should_devices, 0) * 2.0, 2)              AS should_amount_rs,
        COALESCE(cc.charged_csps, 0)                                AS charged_csps,
        ROUND((COALESCE(w.from_wallet_rs, 0)
             + COALESCE(l.to_liability_rs, 0)) / 2.0, 0)           AS actual_devices,
        ROUND(COALESCE(w.from_wallet_rs, 0), 2)                     AS from_wallet_rs,
        ROUND(COALESCE(l.to_liability_rs, 0), 2)                    AS to_liability_rs,
        ROUND(COALESCE(w.from_wallet_rs, 0)
            + COALESCE(l.to_liability_rs, 0), 2)                    AS actual_total_rs,
        ROUND(COALESCE(s.should_devices, 0) * 2.0
            - (COALESCE(w.from_wallet_rs, 0)
             + COALESCE(l.to_liability_rs, 0)), 2)                  AS amount_gap_rs,
        COALESCE(s.should_devices, 0)
            - ROUND((COALESCE(w.from_wallet_rs, 0)
                   + COALESCE(l.to_liability_rs, 0)) / 2.0, 0)     AS device_gap
    FROM dates d
    LEFT JOIN daily_idle          i  ON d.dt = i.dt
    LEFT JOIN daily_should        s  ON d.dt = s.dt
    LEFT JOIN daily_wallet        w  ON d.dt = w.dt
    LEFT JOIN daily_liability     l  ON d.dt = l.dt
    LEFT JOIN daily_charged_csps  cc ON d.dt = cc.dt
)

SELECT
    m.*,
    CASE
        WHEN m.should_devices = 0 AND m.actual_devices = 0
            THEN ''
        WHEN m.device_gap = 0
            THEN 'healthy: exact match'
        WHEN m.device_gap BETWEEN 1 AND 10
            THEN m.device_gap || ' dev: state changed to RETRIEVAL_PENDING within seconds of 9AM charge'
        WHEN m.device_gap > 10 AND m.cadence = 'CADENCE'
            THEN m.device_gap || ' dev: split charge batch on cadence day — devices left IDLE between batches'
        WHEN m.device_gap > 10
            THEN m.device_gap || ' dev: bulk returns/lost/deployed filed before charge batch completed'
        WHEN m.device_gap BETWEEN -10 AND -1
            THEN ABS(m.device_gap) || ' dev extra: threshold crossings charged same day (not in 9AM snapshot)'
        WHEN m.device_gap < -10
            THEN ABS(m.device_gap) || ' dev extra: investigate — actual exceeds should'
        ELSE ''
    END AS gap_reason
FROM metrics m
ORDER BY m.date
