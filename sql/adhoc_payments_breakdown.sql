WITH

period_def AS (
    SELECT 'D-1' AS period, DATEADD(day,-1,CURRENT_DATE()) AS p_start, DATEADD(day,-1,CURRENT_DATE()) AS p_end
    UNION ALL SELECT 'D-2', DATEADD(day,-2,CURRENT_DATE()), DATEADD(day,-2,CURRENT_DATE())
    UNION ALL SELECT 'D-3', DATEADD(day,-3,CURRENT_DATE()), DATEADD(day,-3,CURRENT_DATE())
    UNION ALL SELECT 'D-4', DATEADD(day,-4,CURRENT_DATE()), DATEADD(day,-4,CURRENT_DATE())
    UNION ALL SELECT 'D-5', DATEADD(day,-5,CURRENT_DATE()), DATEADD(day,-5,CURRENT_DATE())
    UNION ALL SELECT 'D-6', DATEADD(day,-6,CURRENT_DATE()), DATEADD(day,-6,CURRENT_DATE())
    UNION ALL SELECT 'D-7', DATEADD(day,-7,CURRENT_DATE()), DATEADD(day,-7,CURRENT_DATE())
    UNION ALL SELECT 'D-8', DATEADD(day,-8,CURRENT_DATE()), DATEADD(day,-8,CURRENT_DATE())
    UNION ALL SELECT 'W-1', DATEADD(day,-7,CURRENT_DATE()), DATEADD(day,-1,CURRENT_DATE())
    UNION ALL SELECT 'W-2', DATEADD(day,-14,CURRENT_DATE()), DATEADD(day,-8,CURRENT_DATE())
    UNION ALL SELECT 'M-1', DATE_TRUNC('month',DATEADD(month,-1,CURRENT_DATE())), LAST_DAY(DATEADD(month,-1,CURRENT_DATE()))
    UNION ALL SELECT 'M-2', DATE_TRUNC('month',DATEADD(month,-2,CURRENT_DATE())), LAST_DAY(DATEADD(month,-2,CURRENT_DATE()))
),

raw_data AS (
    SELECT
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) AS event_date,
        ROUND(w.AMOUNT / 100.0, 2) AS amount_rs,
        PARSE_JSON(w.REMARKS):intervention_id::STRING AS raw_iid
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE
      AND w.ENTRY_TYPE IN ('INTERVENTION_CREDIT','ADHOC_ADJUSTMENT_CREDIT')
),

adhoc_data AS (
    SELECT
        event_date,
        amount_rs,
        CASE
            WHEN raw_iid ILIKE 'april-unclaimedbonus-payout-2026%'       THEN 'april-unclaimedbonus-payout-2026'
            WHEN raw_iid ILIKE 'csp-shifting-payout-jul21-2026%'         THEN 'csp-shifting-payout-jul21-2026'
            WHEN raw_iid ILIKE 'csp-migration-payout-jul21-2026%'        THEN 'csp-migration-payout-jul21-2026'
            WHEN raw_iid ILIKE 'csp-migration-shifting-payout-jul21-2026%' THEN 'csp-migration-shifting-payout-jul21-2026'
            WHEN raw_iid ILIKE 'guarantee_program%'                      THEN 'guarantee_program'
            WHEN raw_iid ILIKE 'pnm-isp-refund-jul2026%'                THEN 'pnm-isp-refund-jul2026'
            WHEN raw_iid ILIKE 'pnm-isp-refund-jul15%'                  THEN 'pnm-isp-refund-jul15'
            WHEN raw_iid ILIKE 'pnm-isp-refund-jul31%'                  THEN 'pnm-isp-refund-jul31'
            WHEN raw_iid ILIKE 'pnm-isp-refund%'                        THEN REGEXP_SUBSTR(raw_iid, '^pnm-isp-refund-[a-z0-9]+', 1, 1, 'i')
            WHEN raw_iid ILIKE 'installpayouts%'                         THEN 'installpayouts'
            ELSE raw_iid
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
    MAX(CASE WHEN period='D-1' THEN total_amount END) AS "D-1",
    MAX(CASE WHEN period='D-2' THEN total_amount END) AS "D-2",
    MAX(CASE WHEN period='D-3' THEN total_amount END) AS "D-3",
    MAX(CASE WHEN period='D-4' THEN total_amount END) AS "D-4",
    MAX(CASE WHEN period='D-5' THEN total_amount END) AS "D-5",
    MAX(CASE WHEN period='D-6' THEN total_amount END) AS "D-6",
    MAX(CASE WHEN period='D-7' THEN total_amount END) AS "D-7",
    MAX(CASE WHEN period='D-8' THEN total_amount END) AS "D-8",
    MAX(CASE WHEN period='W-1' THEN total_amount END) AS "W-1",
    MAX(CASE WHEN period='W-2' THEN total_amount END) AS "W-2",
    MAX(CASE WHEN period='M-1' THEN total_amount END) AS "M-1",
    MAX(CASE WHEN period='M-2' THEN total_amount END) AS "M-2"
FROM agg
GROUP BY remark_group
ORDER BY remark_group
