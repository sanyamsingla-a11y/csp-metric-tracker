WITH period_def AS (
    SELECT 'D-1' AS period, 1 AS sort_order, DATEADD(day,-1,CURRENT_DATE()) AS p_start, DATEADD(day,-1,CURRENT_DATE()) AS p_end
    UNION ALL SELECT 'D-2', 2, DATEADD(day,-2,CURRENT_DATE()), DATEADD(day,-2,CURRENT_DATE())
    UNION ALL SELECT 'D-3', 3, DATEADD(day,-3,CURRENT_DATE()), DATEADD(day,-3,CURRENT_DATE())
    UNION ALL SELECT 'W-1', 4, DATEADD(day,-7,CURRENT_DATE()), DATEADD(day,-1,CURRENT_DATE())
    UNION ALL SELECT 'W-2', 5, DATEADD(day,-14,CURRENT_DATE()), DATEADD(day,-8,CURRENT_DATE())
    UNION ALL SELECT 'W-3', 6, DATEADD(day,-21,CURRENT_DATE()), DATEADD(day,-15,CURRENT_DATE())
    UNION ALL SELECT 'M-1', 7, DATE_TRUNC('month',DATEADD(month,-1,CURRENT_DATE())), LAST_DAY(DATEADD(month,-1,CURRENT_DATE()))
    UNION ALL SELECT 'M-2', 8, DATE_TRUNC('month',DATEADD(month,-2,CURRENT_DATE())), LAST_DAY(DATEADD(month,-2,CURRENT_DATE()))
    UNION ALL SELECT 'M-3', 9, DATE_TRUNC('month',DATEADD(month,-3,CURRENT_DATE())), LAST_DAY(DATEADD(month,-3,CURRENT_DATE()))
),
first_iec AS (
    SELECT CONNECTION_ID, EXECUTION_CANDIDATE_ID, CSP_ID,
           TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', CREATED_AT)) AS booking_date,
           CURRENT_STATE
    FROM (
        SELECT CONNECTION_ID, EXECUTION_CANDIDATE_ID, CSP_ID, CREATED_AT, CURRENT_STATE,
               ROW_NUMBER() OVER (PARTITION BY CONNECTION_ID ORDER BY CREATED_AT) AS rn
        FROM PROD_DB.CSP_TAS_SERVICE_CSP_TAS_SERVICE.INSTALL_EXECUTION_CANDIDATES
        WHERE _FIVETRAN_ACTIVE = TRUE
          AND CSP_ID NOT IN ('a0a0b1','a0a0m0','a0a6w1')
    )
    WHERE rn = 1
),
period_data AS (
    SELECT
        pd.period,
        pd.sort_order,
        COUNT(*) AS total_bookings,
        SUM(CASE
            WHEN f.booking_date < '2026-07-24' THEN
                CASE WHEN f.CURRENT_STATE IN (
                    'AWAITING_CUSTOMER_SLOT_CONFIRMATION',
                    'TECHNICIAN_ASSIGNED','ARRIVED_AT_SITE','AWAITING_CUSTOMER_OTP',
                    'INSTALLATION_IN_PROGRESS_PRE_FEE','FEE_COLLECTION_PENDING',
                    'INSTALLATION_IN_PROGRESS_POST_FEE','RATING_PENDING',
                    'CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED'
                ) THEN 1 ELSE 0 END
            ELSE
                CASE WHEN f.CURRENT_STATE IN (
                    'TECHNICIAN_ASSIGNED','ARRIVED_AT_SITE','AWAITING_CUSTOMER_OTP',
                    'INSTALLATION_IN_PROGRESS_PRE_FEE','FEE_COLLECTION_PENDING',
                    'INSTALLATION_IN_PROGRESS_POST_FEE','RATING_PENDING',
                    'CONNECTION_ACTIVE','INSTALLATION_REPORTED_FAILED'
                ) THEN 1 ELSE 0 END
        END) AS first_csp_accepted,
        SUM(CASE WHEN f.CURRENT_STATE IN (
                'DECLINED','CANCELLED_BY_UPSTREAM',
                'AWAITING_SLOT_PROPOSAL','AWAITING_TECHNICIAN_ASSIGNMENT'
            )
            OR (f.booking_date >= '2026-07-24' AND f.CURRENT_STATE = 'AWAITING_CUSTOMER_SLOT_CONFIRMATION')
            THEN 1 ELSE 0 END) AS first_csp_not_accepted,
        SUM(CASE WHEN f.CURRENT_STATE = 'CANCELLED_BY_CUSTOMER' THEN 1 ELSE 0 END) AS cancelled_by_customer
    FROM first_iec f
    JOIN period_def pd ON f.booking_date BETWEEN pd.p_start AND pd.p_end
    GROUP BY pd.period, pd.sort_order
),
unpivoted AS (
    SELECT period, sort_order, 'Routing Efficiency % (First CSP to receive booking accepts)' AS "Metric", 1 AS metric_order,
           CAST(ROUND(100.0 * first_csp_accepted / NULLIF(total_bookings, 0), 1) AS VARCHAR) AS val
    FROM period_data
)
SELECT
    "Metric",
    MAX(CASE WHEN period = 'D-1' THEN val END) AS "D-1",
    MAX(CASE WHEN period = 'D-2' THEN val END) AS "D-2",
    MAX(CASE WHEN period = 'D-3' THEN val END) AS "D-3",
    MAX(CASE WHEN period = 'W-1' THEN val END) AS "W-1",
    MAX(CASE WHEN period = 'W-2' THEN val END) AS "W-2",
    MAX(CASE WHEN period = 'W-3' THEN val END) AS "W-3",
    MAX(CASE WHEN period = 'M-1' THEN val END) AS "M-1",
    MAX(CASE WHEN period = 'M-2' THEN val END) AS "M-2",
    MAX(CASE WHEN period = 'M-3' THEN val END) AS "M-3"
FROM unpivoted
GROUP BY "Metric", metric_order
ORDER BY metric_order
