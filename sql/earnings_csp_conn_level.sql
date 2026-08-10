WITH monthly_earnings AS (
    SELECT
        DATE_TRUNC('month', TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT))) AS month,
        COUNT(DISTINCT w.CSP_ID)::NUMBER(18,2) AS csp_count,
        ROUND(SUM(w.AMOUNT) / 100.0, 2)::NUMBER(18,2) AS total_earnings
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE
      AND w.ENTRY_TYPE IN ('BASE_PAYOUT', 'BONUS_CREDIT', 'INTERVENTION_CREDIT', 'RECOVERY_RETURN')
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) >= DATEADD(month, -13, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1
),

months AS (
    SELECT
        DATE_TRUNC('month', DATEADD(month, -seq, CURRENT_DATE())) AS m_start,
        LAST_DAY(DATEADD(month, -seq, CURRENT_DATE())) AS m_end
    FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS seq
        FROM TABLE(GENERATOR(ROWCOUNT => 100))
    )
    WHERE DATE_TRUNC('month', DATEADD(month, -seq, CURRENT_DATE())) >= DATEADD(month, -13, DATE_TRUNC('month', CURRENT_DATE()))
),

active_conns AS (
    SELECT
        m.m_start AS month,
        COUNT(DISTINCT c.CONNECTION_ID) AS active_conns
    FROM months m,
    PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
    WHERE c._FIVETRAN_ACTIVE = TRUE
      AND c.ACTIVATED_AT IS NOT NULL
      AND c.CURRENT_STATE IN ('ACTIVE', 'PAUSED')
      AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.ACTIVATED_AT)) <= m.m_end
      AND (
          c.CURRENT_STATE = 'ACTIVE'
          OR (c.CURRENT_STATE = 'PAUSED' AND TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', c.UPDATED_AT)) >= m.m_start)
      )
    GROUP BY 1
),

combined AS (
    SELECT
        e.month,
        e.csp_count,
        e.total_earnings,
        COALESCE(a.active_conns, 0)::NUMBER(18,2) AS active_conns,
        ROUND(e.total_earnings / e.csp_count, 2)::NUMBER(18,2) AS earnings_per_csp,
        ROUND(e.total_earnings / NULLIF(a.active_conns, 0), 2)::NUMBER(18,2) AS earnings_per_conn
    FROM monthly_earnings e
    LEFT JOIN active_conns a ON e.month = a.month
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
FROM combined
UNPIVOT (val FOR metric IN (
    csp_count,
    total_earnings,
    active_conns,
    earnings_per_csp,
    earnings_per_conn
)) u
GROUP BY metric
ORDER BY CASE metric
    WHEN 'CSP_COUNT' THEN 5
    WHEN 'TOTAL_EARNINGS' THEN 3
    WHEN 'ACTIVE_CONNS' THEN 4
    WHEN 'EARNINGS_PER_CSP' THEN 2
    WHEN 'EARNINGS_PER_CONN' THEN 1
END
