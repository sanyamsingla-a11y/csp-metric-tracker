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
           trum.ROUTER_NAS_ID,
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
        CASE WHEN first_pre_cron  IS NOT NULL THEN DATE(cron_time)
             WHEN first_immediate IS NOT NULL THEN DATE(first_immediate)
             WHEN first_post_isp  IS NOT NULL THEN DATE(first_post_isp)
        END AS expected_date,
        CASE WHEN first_pre_cron  IS NOT NULL THEN 'PROACTIVE'
             WHEN first_immediate IS NOT NULL THEN 'PROACTIVE'
             WHEN first_post_isp  IS NOT NULL THEN 'REACTIVE'
        END AS expected_type
    FROM classified
    WHERE first_pre_cron IS NOT NULL OR first_immediate IS NOT NULL OR first_post_isp IS NOT NULL
),
actual_any AS (
    SELECT DISTINCT connection_id, DATE(CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT)) AS created_date
    FROM CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
    WHERE _FIVETRAN_ACTIVE
      AND CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT) >= CURRENT_DATE - 38
      AND connection_id IN (SELECT DISTINCT connection_id FROM all_expected)
),
actual_typed AS (
    SELECT connection_id, WINDOW_END AS window_end_raw, REASON,
           DATE(CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT)) AS created_date
    FROM CSP_CUSTOMER_ACCESS_SERVICE_CSP_CUSTOMER_ACCESS_SERVICE.SUPPLY_RECHARGE_OBLIGATIONS
    WHERE _FIVETRAN_ACTIVE
      AND CONVERT_TIMEZONE('Asia/Calcutta', CREATED_AT) >= CURRENT_DATE - 38
      AND connection_id IN (SELECT DISTINCT connection_id FROM all_expected)
),
total_match AS (
    SELECT ae.connection_id, ae.isp_end, ae.expected_date, ae.expected_type,
           MAX(CASE WHEN aa.created_date BETWEEN DATEADD('day',-2,ae.expected_date)
                                             AND DATEADD('day', 2,ae.expected_date)
                    THEN 1 ELSE 0 END) AS is_matched_total
    FROM all_expected ae
    LEFT JOIN actual_any aa ON aa.connection_id = ae.connection_id
    GROUP BY ae.connection_id, ae.isp_end, ae.expected_date, ae.expected_type
),
typed_match AS (
    SELECT ae.connection_id, ae.isp_end, ae.expected_date, ae.expected_type,
           MAX(CASE
               WHEN ae.expected_type='PROACTIVE' AND at.REASON='PROACTIVE'
                    AND CONVERT_TIMEZONE('Asia/Calcutta', at.window_end_raw)::TIMESTAMP_NTZ = ae.isp_end
                    AND at.created_date BETWEEN DATEADD('day',-2,ae.expected_date) AND DATEADD('day',2,ae.expected_date)
               THEN 1
               WHEN ae.expected_type='REACTIVE' AND at.REASON='REACTIVE'
                    AND at.created_date BETWEEN DATEADD('day',-2,ae.expected_date) AND DATEADD('day',2,ae.expected_date)
               THEN 1 ELSE 0
           END) AS is_matched_typed
    FROM all_expected ae
    LEFT JOIN actual_typed at ON at.connection_id = ae.connection_id
    GROUP BY ae.connection_id, ae.isp_end, ae.expected_date, ae.expected_type
),
daily AS (
    SELECT tm.expected_date AS dt, tm.expected_type,
           COUNT(*)                  AS expected_cnt,
           SUM(tm.is_matched_total)  AS matched_total,
           SUM(ty.is_matched_typed)  AS matched_typed
    FROM total_match tm
    JOIN typed_match ty ON ty.connection_id = tm.connection_id AND ty.isp_end = tm.isp_end
    GROUP BY 1, 2
),
unpivoted AS (
    SELECT dt, 2 AS srt, '% Created - Proactive' AS metric,
           ROUND(100.0 * matched_typed / NULLIF(expected_cnt, 0), 1) AS val
    FROM daily WHERE expected_type = 'PROACTIVE'
    UNION ALL
    SELECT dt, 3,        '% Created - Reactive',
           ROUND(100.0 * matched_typed / NULLIF(expected_cnt, 0), 1)
    FROM daily WHERE expected_type = 'REACTIVE'
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
    ROUND(AVG(val), 1)                                             AS "30D Avg",
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY val), 1)    AS "30D Median",
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY val), 1)    AS "30D P90"
FROM unpivoted
WHERE dt >= CURRENT_DATE - 30 AND dt < CURRENT_DATE
GROUP BY srt, metric
ORDER BY srt
