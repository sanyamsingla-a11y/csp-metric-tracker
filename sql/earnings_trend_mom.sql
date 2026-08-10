WITH monthly AS (
    SELECT
        DATE_TRUNC('month', TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT))) AS month,
        ROUND(SUM(w.AMOUNT) / 100.0, 2) AS total_earnings,
        ROUND(SUM(CASE WHEN w.ENTRY_TYPE = 'BASE_PAYOUT' THEN w.AMOUNT ELSE 0 END) / 100.0, 2) AS base_payout,
        ROUND(SUM(CASE WHEN w.ENTRY_TYPE = 'BONUS_CREDIT' THEN w.AMOUNT ELSE 0 END) / 100.0, 2) AS bonus_credit,
        ROUND(SUM(CASE WHEN w.ENTRY_TYPE = 'INTERVENTION_CREDIT' THEN w.AMOUNT ELSE 0 END) / 100.0, 2) AS adhoc_payments,
        ROUND(SUM(CASE WHEN w.ENTRY_TYPE = 'RECOVERY_RETURN' THEN w.AMOUNT ELSE 0 END) / 100.0, 2) AS netbox_recovery
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE
      AND w.ENTRY_TYPE IN ('BASE_PAYOUT', 'BONUS_CREDIT', 'INTERVENTION_CREDIT', 'RECOVERY_RETURN')
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) >= DATEADD(month, -13, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1
)
SELECT
    metric,
    MAX(CASE WHEN month = DATE_TRUNC('month', CURRENT_DATE()) THEN val END) AS "M-0",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -1, CURRENT_DATE())) THEN val END) AS "M-1",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -2, CURRENT_DATE())) THEN val END) AS "M-2",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -3, CURRENT_DATE())) THEN val END) AS "M-3",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -4, CURRENT_DATE())) THEN val END) AS "M-4",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -5, CURRENT_DATE())) THEN val END) AS "M-5",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -6, CURRENT_DATE())) THEN val END) AS "M-6",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -7, CURRENT_DATE())) THEN val END) AS "M-7",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -8, CURRENT_DATE())) THEN val END) AS "M-8",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -9, CURRENT_DATE())) THEN val END) AS "M-9",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -10, CURRENT_DATE())) THEN val END) AS "M-10",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -11, CURRENT_DATE())) THEN val END) AS "M-11",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -12, CURRENT_DATE())) THEN val END) AS "M-12",
    MAX(CASE WHEN month = DATE_TRUNC('month', DATEADD(month, -13, CURRENT_DATE())) THEN val END) AS "M-13"
FROM monthly
UNPIVOT (val FOR metric IN (
    total_earnings,
    base_payout,
    bonus_credit,
    adhoc_payments,
    netbox_recovery
)) u
GROUP BY metric
ORDER BY CASE metric
    WHEN 'TOTAL_EARNINGS' THEN 1
    WHEN 'BASE_PAYOUT' THEN 2
    WHEN 'BONUS_CREDIT' THEN 3
    WHEN 'ADHOC_PAYMENTS' THEN 4
    WHEN 'NETBOX_RECOVERY' THEN 5
END
