-- Adhoc Payments — Subtype Breakdown (weekly periods, 12-week lookback)

WITH

period_def AS (
    SELECT 'W-0' AS period,
           DATE_TRUNC('week', CURRENT_DATE()) AS p_start,
           CURRENT_DATE() AS p_end
    UNION ALL SELECT 'W-1',
           DATEADD(week, -1, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATE_TRUNC('week', CURRENT_DATE()))
    UNION ALL SELECT 'W-2',
           DATEADD(week, -2, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -1, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-3',
           DATEADD(week, -3, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -2, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-4',
           DATEADD(week, -4, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -3, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-5',
           DATEADD(week, -5, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -4, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-6',
           DATEADD(week, -6, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -5, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-7',
           DATEADD(week, -7, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -6, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-8',
           DATEADD(week, -8, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -7, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-9',
           DATEADD(week, -9, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -8, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-10',
           DATEADD(week, -10, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -9, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-11',
           DATEADD(week, -11, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -10, DATE_TRUNC('week', CURRENT_DATE())))
    UNION ALL SELECT 'W-12',
           DATEADD(week, -12, DATE_TRUNC('week', CURRENT_DATE())),
           DATEADD(day, -1, DATEADD(week, -11, DATE_TRUNC('week', CURRENT_DATE())))
),

raw_data AS (
    SELECT
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) AS event_date,
        ROUND(w.AMOUNT / 100.0, 2) AS amount_rs,
        COALESCE(
            PARSE_JSON(w.REMARKS):intervention_id::STRING,
            w.PROGRAM_REF
        ) AS raw_iid
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE
      AND w.ENTRY_TYPE IN ('INTERVENTION_CREDIT','ADHOC_ADJUSTMENT_CREDIT')
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) >= DATEADD(week, -12, DATE_TRUNC('week', CURRENT_DATE()))
),

adhoc_data AS (
    SELECT
        event_date,
        amount_rs,
        CASE
            WHEN raw_iid IS NULL                                             THEN '(unknown)'
            WHEN raw_iid ILIKE 'wiom-sahayata-yogdan%'
              OR raw_iid = 'SAHAYATA-YOGDAN'                                THEN 'wiom-sahayata-yogdan'
            WHEN raw_iid ILIKE 'guarantee_program%'                          THEN 'guarantee_program'
            WHEN raw_iid ILIKE 'sehat_guarantee_program%'                    THEN 'sehat_guarantee_program'
            WHEN raw_iid ILIKE 'july_guarantee_adjustment%'                  THEN 'july_guarantee_adjustment'
            WHEN raw_iid ILIKE 'installpayouts%'                             THEN 'installpayouts'
            WHEN raw_iid ILIKE 'pnm-isp-refund%'
              OR raw_iid = 'PNM_ISP_REFUND'                                 THEN 'pnm-isp-refund'
            WHEN raw_iid ILIKE 'april-unclaimedbonus%'                       THEN 'april-unclaimedbonus-payout'
            WHEN raw_iid ILIKE 'csp-migration-shifting%'                     THEN 'csp-migration-shifting-payout'
            WHEN raw_iid ILIKE 'csp-migration-payout%'
              OR raw_iid = 'MIGRATION_PAYOUT'                               THEN 'csp-migration-payout'
            WHEN raw_iid ILIKE 'csp-shifting-payout%'                        THEN 'csp-shifting-payout'
            WHEN raw_iid = 'CARRY_FEE_REVERSAL'                             THEN 'carry-fee-reversal'
            WHEN raw_iid ILIKE 'BASE_PAYOUT%'
              OR raw_iid = 'SYSTEM_CORRECTION_BASE_PAYOUT'                  THEN 'base-payout-correction'
            WHEN raw_iid = 'SYSTEM_CORRECTION_NETBOX_ORDER_CANCEL'           THEN 'netbox-order-cancel'
            WHEN raw_iid = 'SYSTEM_CORRECTION_NETBOX_RECOVERY_RETURN'        THEN 'netbox-recovery-return'
            ELSE '(other: ' || LEFT(raw_iid, 30) || ')'
        END AS remark_group
    FROM raw_data
),

agg AS (
    SELECT
        d.remark_group,
        p.period,
        ROUND(SUM(d.amount_rs), 2) AS total_amount,
        COUNT(*) AS txn_count
    FROM adhoc_data d
    JOIN period_def p ON d.event_date BETWEEN p.p_start AND p.p_end
    GROUP BY 1, 2
)

SELECT
    remark_group AS remarks,
    MAX(CASE WHEN period='W-0'  THEN total_amount END) AS "W-0",
    MAX(CASE WHEN period='W-1'  THEN total_amount END) AS "W-1",
    MAX(CASE WHEN period='W-2'  THEN total_amount END) AS "W-2",
    MAX(CASE WHEN period='W-3'  THEN total_amount END) AS "W-3",
    MAX(CASE WHEN period='W-4'  THEN total_amount END) AS "W-4",
    MAX(CASE WHEN period='W-5'  THEN total_amount END) AS "W-5",
    MAX(CASE WHEN period='W-6'  THEN total_amount END) AS "W-6",
    MAX(CASE WHEN period='W-7'  THEN total_amount END) AS "W-7",
    MAX(CASE WHEN period='W-8'  THEN total_amount END) AS "W-8",
    MAX(CASE WHEN period='W-9'  THEN total_amount END) AS "W-9",
    MAX(CASE WHEN period='W-10' THEN total_amount END) AS "W-10",
    MAX(CASE WHEN period='W-11' THEN total_amount END) AS "W-11",
    MAX(CASE WHEN period='W-12' THEN total_amount END) AS "W-12",
    MAX(CASE WHEN period='W-0'  THEN txn_count END) AS "W-0_txns",
    MAX(CASE WHEN period='W-1'  THEN txn_count END) AS "W-1_txns",
    MAX(CASE WHEN period='W-2'  THEN txn_count END) AS "W-2_txns",
    MAX(CASE WHEN period='W-3'  THEN txn_count END) AS "W-3_txns"
FROM agg
GROUP BY remark_group
ORDER BY remark_group
