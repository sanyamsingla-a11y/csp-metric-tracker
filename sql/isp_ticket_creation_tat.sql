WITH iw AS (
    SELECT DISTINCT connection_id,
           CONVERT_TIMEZONE('Asia/Calcutta', window_end)::TIMESTAMP_NTZ AS isp_end,
           DATEADD('hour',6, DATEADD('day',-2,
               DATE_TRUNC('day', CONVERT_TIMEZONE('Asia/Calcutta', window_end)::TIMESTAMP_NTZ)
           )) AS cron_time
    FROM PROD_DB.CSP_RV_SERVICE_CSP_RV_SERVICE.RECHARGE_GATES
    WHERE _FIVETRAN_ACTIVE
      AND CONVERT_TIMEZONE('Asia/Calcutta', window_end)::TIMESTAMP_NTZ >= CURRENT_DATE - 35
      AND CONVERT_TIMEZONE('Asia/Calcutta', window_end)::TIMESTAMP_NTZ <  CURRENT_DATE + 3
),
cp AS (
    SELECT c.connection_id,
           DATEADD('minute',330, trum.CREATED_ON)      AS plan_purchased_at,
           DATEADD('minute',330, trum.OTP_EXPIRY_TIME) AS plan_end
    FROM PUBLIC.T_ROUTER_USER_MAPPING trum
    JOIN PUBLIC.t_wg_customer tg ON trum.mobile = tg.mobile
    JOIN PROD_DB.CSP_CONNECTION_LIFECYCLE_SERVICE_CSP_CONNECTION_LIFECYCLE_SERVICE.CONNECTIONS c
        ON c.customer_id = tg.account_id AND c._FIVETRAN_ACTIVE
    WHERE trum.device_limit = 10 AND trum.otp = 'DONE' AND trum.mobile > '5999999999'
      AND trum.CREATED_ON >= CURRENT_DATE - 150
      AND c.connection_id IN (SELECT DISTINCT connection_id FROM iw)
),
classified AS (
    SELECT iw.connection_id, iw.isp_end, iw.cron_time,
        MIN(CASE WHEN DATE_TRUNC('minute', cp.plan_end) > DATE_TRUNC('minute', iw.isp_end)
                      AND cp.plan_purchased_at < iw.cron_time
                 THEN cp.plan_purchased_at END) AS first_pre_cron,
        MIN(CASE WHEN DATE_TRUNC('minute', cp.plan_end) > DATE_TRUNC('minute', iw.isp_end)
                      AND cp.plan_purchased_at >= iw.cron_time
                      AND cp.plan_purchased_at < iw.isp_end
                 THEN cp.plan_purchased_at END) AS first_immediate,
        MIN(CASE WHEN cp.plan_purchased_at > iw.isp_end
                 THEN cp.plan_purchased_at END) AS first_post_isp
    FROM iw LEFT JOIN cp ON cp.connection_id = iw.connection_id
    GROUP BY iw.connection_id, iw.isp_end, iw.cron_time
),
all_expected AS (
    SELECT connection_id, isp_end,
        CASE WHEN first_pre_cron  IS NOT NULL THEN cron_time
             WHEN first_immediate IS NOT NULL THEN first_immediate
             WHEN first_post_isp  IS NOT NULL THEN first_post_isp
        END AS expected_ts,
        DATE(CASE WHEN first_pre_cron  IS NOT NULL THEN cron_time
                  WHEN first_immediate IS NOT NULL THEN first_immediate
                  WHEN first_post_isp  IS NOT NULL THEN first_post_isp
             END) AS expected_date,
        CASE WHEN first_pre_cron  IS NOT NULL THEN 'CRON_PROACTIVE'
             WHEN first_immediate IS NOT NULL THEN 'IMMEDIATE_PROACTIVE'
             WHEN first_post_isp  IS NOT NULL THEN 'REACTIVE'
        END AS expected_type
    FROM classified
    WHERE first_pre_cron IS NOT NULL OR first_immediate IS NOT NULL OR first_post_isp IS NOT NULL
),
actual_typed AS (
    SELECT connection_id, WINDOW_END AS window_end_raw, REASON,
           CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT)::TIMESTAMP_NTZ AS created_at_ist
    FROM CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
    WHERE _FIVETRAN_ACTIVE
      AND CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT) >= CURRENT_DATE - 38
      AND connection_id IN (SELECT DISTINCT connection_id FROM all_expected)
),
first_match AS (
    SELECT ae.connection_id, ae.isp_end, ae.expected_ts, ae.expected_date, ae.expected_type,
           MIN(CASE
               WHEN ae.expected_type IN ('CRON_PROACTIVE','IMMEDIATE_PROACTIVE')
                    AND at.REASON = 'PROACTIVE'
                    AND CONVERT_TIMEZONE('Asia/Calcutta', at.window_end_raw)::TIMESTAMP_NTZ = ae.isp_end
                    AND at.created_at_ist BETWEEN DATEADD('hour',-48,ae.expected_ts) AND DATEADD('hour',48,ae.expected_ts)
               THEN at.created_at_ist
               WHEN ae.expected_type = 'REACTIVE'
                    AND at.REASON = 'REACTIVE'
                    AND at.created_at_ist BETWEEN DATEADD('hour',-48,ae.expected_ts) AND DATEADD('hour',48,ae.expected_ts)
               THEN at.created_at_ist
               ELSE NULL
           END) AS match_ts
    FROM all_expected ae
    LEFT JOIN actual_typed at ON at.connection_id = ae.connection_id
    GROUP BY ae.connection_id, ae.isp_end, ae.expected_ts, ae.expected_date, ae.expected_type
),
tat AS (
    SELECT expected_date AS dt, expected_type,
           DATEDIFF('minute', expected_ts, match_ts) AS tat_min
    FROM first_match
    WHERE match_ts IS NOT NULL
      AND expected_type IN ('IMMEDIATE_PROACTIVE', 'REACTIVE')
),
daily_tat AS (
    SELECT dt, expected_type,
           COUNT(*)                                                        AS ticket_cnt,
           ROUND(AVG(tat_min), 0)                                          AS avg_tat,
           ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY tat_min), 0) AS p50_tat,
           ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY tat_min), 0) AS p75_tat,
           ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY tat_min), 0) AS p90_tat,
           ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY tat_min), 0) AS p99_tat
    FROM tat
    GROUP BY dt, expected_type
),
unpivoted AS (
    SELECT dt, 1  AS srt, 'Tickets Created - Immediate Proactive' AS metric, ticket_cnt::FLOAT AS val FROM daily_tat WHERE expected_type='IMMEDIATE_PROACTIVE'
    UNION ALL
    SELECT dt, 3,         'P50 TAT (min) - Immediate Proactive',   p50_tat::FLOAT  FROM daily_tat WHERE expected_type='IMMEDIATE_PROACTIVE'
    UNION ALL
    SELECT dt, 4,         'P75 TAT (min) - Immediate Proactive',   p75_tat::FLOAT  FROM daily_tat WHERE expected_type='IMMEDIATE_PROACTIVE'
    UNION ALL
    SELECT dt, 5,         'P90 TAT (min) - Immediate Proactive',   p90_tat::FLOAT  FROM daily_tat WHERE expected_type='IMMEDIATE_PROACTIVE'
    UNION ALL
    SELECT dt, 6,         'P99 TAT (min) - Immediate Proactive',   p99_tat::FLOAT  FROM daily_tat WHERE expected_type='IMMEDIATE_PROACTIVE'
    UNION ALL
    SELECT dt, 7,         'Tickets Created - Reactive',            ticket_cnt::FLOAT FROM daily_tat WHERE expected_type='REACTIVE'
    UNION ALL
    SELECT dt, 9,         'P50 TAT (min) - Reactive',              p50_tat::FLOAT  FROM daily_tat WHERE expected_type='REACTIVE'
    UNION ALL
    SELECT dt, 10,        'P75 TAT (min) - Reactive',              p75_tat::FLOAT  FROM daily_tat WHERE expected_type='REACTIVE'
    UNION ALL
    SELECT dt, 11,        'P90 TAT (min) - Reactive',              p90_tat::FLOAT  FROM daily_tat WHERE expected_type='REACTIVE'
    UNION ALL
    SELECT dt, 12,        'P99 TAT (min) - Reactive',              p99_tat::FLOAT  FROM daily_tat WHERE expected_type='REACTIVE'
)
SELECT metric AS "Metric",
    MAX(CASE WHEN dt=DATEADD(day,-1,CURRENT_DATE()) THEN val END) AS "T-1",
    MAX(CASE WHEN dt=DATEADD(day,-2,CURRENT_DATE()) THEN val END) AS "T-2",
    MAX(CASE WHEN dt=DATEADD(day,-3,CURRENT_DATE()) THEN val END) AS "T-3",
    MAX(CASE WHEN dt=DATEADD(day,-4,CURRENT_DATE()) THEN val END) AS "T-4",
    MAX(CASE WHEN dt=DATEADD(day,-5,CURRENT_DATE()) THEN val END) AS "T-5",
    MAX(CASE WHEN dt=DATEADD(day,-6,CURRENT_DATE()) THEN val END) AS "T-6",
    MAX(CASE WHEN dt=DATEADD(day,-7,CURRENT_DATE()) THEN val END) AS "T-7",
    MAX(CASE WHEN dt=DATEADD(day,-8,CURRENT_DATE()) THEN val END) AS "T-8",
    ROUND(AVG(val), 0)                                             AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 0)    AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 0)    AS "30D P90"
FROM unpivoted
WHERE dt >= CURRENT_DATE - 30 AND dt < CURRENT_DATE
GROUP BY srt, metric
ORDER BY srt
