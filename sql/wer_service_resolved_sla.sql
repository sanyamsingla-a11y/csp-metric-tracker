WITH csp_universe AS (
    SELECT DISTINCT CSP_ID
    FROM PROD_DB.CSP_GATEWAY_SERVICE_CSP_GATEWAY_SERVICE.CSP_ACCOUNT
    WHERE _FIVETRAN_ACTIVE = TRUE
      AND STATUS = 'ACTIVE'
      AND PARTNER_ID IS NOT NULL
),

period_def AS (
    SELECT
        'D-2' AS period,
        DATEADD(day, -2, CURRENT_DATE())::DATE AS p_start,
        DATEADD(day, -2, CURRENT_DATE())::DATE AS p_end

    UNION ALL

    SELECT
        'D-3',
        DATEADD(day, -3, CURRENT_DATE())::DATE,
        DATEADD(day, -3, CURRENT_DATE())::DATE

    UNION ALL

    SELECT
        'D-4',
        DATEADD(day, -4, CURRENT_DATE())::DATE,
        DATEADD(day, -4, CURRENT_DATE())::DATE

    UNION ALL

    SELECT
        'Week-1',
        DATEADD(day, -7, DATE_TRUNC('week', CURRENT_DATE()))::DATE,
        DATEADD(day, -1, DATE_TRUNC('week', CURRENT_DATE()))::DATE

    UNION ALL

    SELECT
        'Week-2',
        DATEADD(day, -14, DATE_TRUNC('week', CURRENT_DATE()))::DATE,
        DATEADD(day, -8, DATE_TRUNC('week', CURRENT_DATE()))::DATE

    UNION ALL

    SELECT
        'Week-3',
        DATEADD(day, -21, DATE_TRUNC('week', CURRENT_DATE()))::DATE,
        DATEADD(day, -15, DATE_TRUNC('week', CURRENT_DATE()))::DATE

    UNION ALL

    SELECT
        'M-1',
        DATE_TRUNC('month', DATEADD(month, -1, CURRENT_DATE()))::DATE,
        LAST_DAY(DATEADD(month, -1, CURRENT_DATE()))::DATE

    UNION ALL

    SELECT
        'M-2',
        DATE_TRUNC('month', DATEADD(month, -2, CURRENT_DATE()))::DATE,
        LAST_DAY(DATEADD(month, -2, CURRENT_DATE()))::DATE

    UNION ALL

    SELECT
        'M-3',
        DATE_TRUNC('month', DATEADD(month, -3, CURRENT_DATE()))::DATE,
        LAST_DAY(DATEADD(month, -3, CURRENT_DATE()))::DATE
),

base AS (
    SELECT
        CONVERT_TIMEZONE('Asia/Kolkata', c.CREATED_AT)::DATE AS created_dt_ist,
        c.WITHIN_TAT,

        CASE
            WHEN c.SECONDARY_SUBTYPE IN ('NEW_PREMISES', 'WITHIN_PREMISES')
                THEN 'SHIFTING'
            ELSE COALESCE(c.SECONDARY_SUBTYPE, 'UNKNOWN')
        END AS entry_type,

        (
            c.WITHIN_TAT IS NOT NULL
            OR c.SLA_AT < CURRENT_TIMESTAMP()
        ) AS is_mature

    FROM PROD_DB.CSP_SUPPORT_RESOLUTION_SERVICE_CSP_SUPPORT_RESOLUTION_SERVICE.COMPLAINTS c

    INNER JOIN csp_universe u
        ON u.CSP_ID = c.CSP_ID

    WHERE c._FIVETRAN_ACTIVE = TRUE
      AND c.PRIMARY_CLASS IN ('SERVICE_ISSUE', 'SHIFTING')
      AND c.TICKET_ID IS NOT NULL
      AND REGEXP_LIKE(c.TICKET_ID, '^[0-9]+$')
      AND c.TICKET_ID NOT ILIKE '%prod%'
      AND c.TICKET_ID NOT ILIKE '%test%'
      AND c.TICKET_ID NOT ILIKE '%manual%'
),

stacked AS (
    SELECT
        entry_type,
        created_dt_ist,
        WITHIN_TAT,
        is_mature
    FROM base

    UNION ALL

    SELECT
        '% Resolved within TAT',
        created_dt_ist,
        WITHIN_TAT,
        is_mature
    FROM base
    WHERE entry_type IN (
        'NO_INTERNET',
        'RECHARGE_DONE_NO_INTERNET',
        'FREQUENT_DISCONNECTION',
        'SLOW_INTERNET',
        'OPTICAL_POWER_OUT_OF_RANGE',
        'SHIFTING'
    )
),

agg AS (
    SELECT
        s.entry_type,
        p.period,

        COUNT_IF(s.is_mature) AS mature_n,

        ROUND(
            100.0 * COUNT_IF(
                s.is_mature
                AND s.WITHIN_TAT = 1
            ) / NULLIF(COUNT_IF(s.is_mature), 0),
            1
        ) AS pct

    FROM stacked s

    JOIN period_def p
        ON s.created_dt_ist BETWEEN p.p_start AND p.p_end

    GROUP BY
        1, 2
)

SELECT
    CASE
        WHEN entry_type = '% Resolved within TAT'
            THEN '% Resolved within TAT'
        ELSE entry_type
    END AS "Entry Type",

    MAX(CASE WHEN period = 'D-2'    THEN pct END) AS "D-2",
    MAX(CASE WHEN period = 'D-3'    THEN pct END) AS "D-3",
    MAX(CASE WHEN period = 'D-4'    THEN pct END) AS "D-4",

    MAX(CASE WHEN period = 'Week-1' THEN pct END) AS "Week-1",
    MAX(CASE WHEN period = 'Week-2' THEN pct END) AS "Week-2",
    MAX(CASE WHEN period = 'Week-3' THEN pct END) AS "Week-3",

    MAX(CASE WHEN period = 'M-1'    THEN pct END) AS "M-1",
    MAX(CASE WHEN period = 'M-2'    THEN pct END) AS "M-2",
    MAX(CASE WHEN period = 'M-3'    THEN pct END) AS "M-3"

FROM agg

GROUP BY
    entry_type,
    CASE entry_type
        WHEN '% Resolved within TAT'        THEN 0
        WHEN 'NO_INTERNET'                  THEN 1
        WHEN 'RECHARGE_DONE_NO_INTERNET'    THEN 2
        WHEN 'FREQUENT_DISCONNECTION'       THEN 3
        WHEN 'SLOW_INTERNET'                THEN 4
        WHEN 'OPTICAL_POWER_OUT_OF_RANGE'   THEN 5
        WHEN 'SHIFTING'                     THEN 6
        ELSE 7
    END

ORDER BY
    CASE entry_type
        WHEN '% Resolved within TAT'        THEN 0
        WHEN 'NO_INTERNET'                  THEN 1
        WHEN 'RECHARGE_DONE_NO_INTERNET'    THEN 2
        WHEN 'FREQUENT_DISCONNECTION'       THEN 3
        WHEN 'SLOW_INTERNET'                THEN 4
        WHEN 'OPTICAL_POWER_OUT_OF_RANGE'   THEN 5
        WHEN 'SHIFTING'                     THEN 6
        ELSE 7
    END,
    "Entry Type"
