WITH

period_def AS (
    SELECT 'D-1' AS period, DATEADD(day,-1,CURRENT_DATE()) AS p_start, DATEADD(day,-1,CURRENT_DATE()) AS p_end
    UNION ALL SELECT 'D-2', DATEADD(day,-2,CURRENT_DATE()), DATEADD(day,-2,CURRENT_DATE())
    UNION ALL SELECT 'D-3', DATEADD(day,-3,CURRENT_DATE()), DATEADD(day,-3,CURRENT_DATE())
    UNION ALL SELECT 'W-1', DATEADD(day,-7,CURRENT_DATE()), DATEADD(day,-1,CURRENT_DATE())
    UNION ALL SELECT 'W-2', DATEADD(day,-14,CURRENT_DATE()), DATEADD(day,-8,CURRENT_DATE())
    UNION ALL SELECT 'W-3', DATEADD(day,-21,CURRENT_DATE()), DATEADD(day,-15,CURRENT_DATE())
    UNION ALL SELECT 'M-1', DATE_TRUNC('month',DATEADD(month,-1,CURRENT_DATE())), LAST_DAY(DATEADD(month,-1,CURRENT_DATE()))
    UNION ALL SELECT 'M-2', DATE_TRUNC('month',DATEADD(month,-2,CURRENT_DATE())), LAST_DAY(DATEADD(month,-2,CURRENT_DATE()))
    UNION ALL SELECT 'M-3', DATE_TRUNC('month',DATEADD(month,-3,CURRENT_DATE())), LAST_DAY(DATEADD(month,-3,CURRENT_DATE()))
),

carry_fee_test_ids AS (
    SELECT v.id FROM (VALUES
        ('4bb6284c-d34c-4d4e-9c1c-3a39a39ca7b0'),
        ('a4bb22d4-b86e-4816-b933-96383152bd15'),
        ('e1e55563-05c2-4d74-96c4-96163d0b46d3'),
        ('7abce769-08eb-42d2-ab11-13cddf92bba1'),
        ('d201ef6a-b659-45e7-883e-cf058c6634d6'),
        ('da0869a5-2a36-4c6c-9228-5f2207961fb4'),
        ('dbe95ac6-c9f1-4430-8a37-566f55d016de'),
        ('dff58c09-cd76-47e5-891f-c20b7a75872a'),
        ('f33f7d5a-4c42-433e-ac73-105a00ff0c24'),
        ('0bdd7beb-2e0e-451e-a698-c7e95feb5774'),
        ('07833f5f-708a-438b-ae25-dc515c4de7fe'),
        ('2cf3c937-e7c2-4030-a0be-73acd05430c6'),
        ('8506383a-85ad-43d4-be67-095729d5e802'),
        ('08b84320-b87a-40b6-b321-8e22541a4350'),
        ('71cd0f4f-7177-4775-ac69-fdfd5bc1df31'),
        ('96d2d8eb-45ae-49c9-842e-003380139969'),
        ('aa564383-78df-44f9-be8b-8ea6d9a1ee2d'),
        ('9788a32a-5296-424e-b51d-e2096c7a86a9'),
        ('37635e83-a61a-4fa6-b66e-6f62b380ce2e'),
        ('a6b219c3-6fa5-41eb-b6f9-0c425b7eae5e'),
        ('bc11b853-0b65-454a-9f4f-69d32aba81f2'),
        ('357778d0-e92d-481e-817c-f9f7d7c21a23'),
        ('00e3fd11-5d54-4392-bfd5-1b22ea3e80c0'),
        ('04736ed8-4bd8-490e-935e-454c027f9b64'),
        ('2d8c0f48-f7a5-4cd2-a211-20877974efa3'),
        ('e9f73588-f3ea-4319-89ff-f7caca152f31'),
        ('13f3ef84-9057-48f2-ac6b-025e30848074'),
        ('bd0a8f34-3f8b-4a9e-baac-da81e02c7af7'),
        ('6358ca0a-1001-44a0-b9fb-9a2a5116d91d'),
        ('df4bd07b-7569-4f68-b6e9-3e73432fed34'),
        ('718be913-a84c-46b1-b8c6-2045ad813b51'),
        ('ab8d6083-75c5-49a1-84cf-485e0069bae7'),
        ('b7fc7655-a6ff-4341-aa4c-ddc14372faad'),
        ('4369b35e-7525-4e7a-a2d3-29c278320f36'),
        ('af14a8c7-0a7f-46ee-9f37-dc485662308d'),
        ('bf7a47b8-0494-4408-85d0-aea3e422e185')
    ) v(id)
),

all_data AS (
    SELECT 'BASE_PAYOUT' AS entry_type,
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)) AS event_date,
        w.AMOUNT
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE AND w.ENTRY_TYPE = 'BASE_PAYOUT'

    UNION ALL
    SELECT 'BONUS_CREDIT',
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)),
        w.AMOUNT
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE AND w.ENTRY_TYPE = 'BONUS_CREDIT'

    UNION ALL
    SELECT 'RECOVERY_RETURN',
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)),
        w.AMOUNT
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE AND w.ENTRY_TYPE = 'RECOVERY_RETURN'

    UNION ALL
    SELECT 'INTERVENTION_CREDIT',
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)),
        w.AMOUNT
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE AND w.ENTRY_TYPE = 'INTERVENTION_CREDIT'

    UNION ALL
    SELECT 'CARRY_FEE',
        TO_DATE(CONVERT_TIMEZONE('Asia/Kolkata', w.CREATED_AT)),
        w.AMOUNT
    FROM PROD_DB.CSP_PAYMENT_SETTLEMENT_SERVICE_CSP_PAYMENT_SETTLEMENT_SERVICE.WALLET_LEDGER_ENTRIES w
    WHERE w._FIVETRAN_ACTIVE = TRUE AND w.ENTRY_TYPE = 'CARRY_FEE'
      AND w.CORRELATION_ID NOT IN (SELECT id FROM carry_fee_test_ids)
),

agg AS (
    SELECT d.entry_type, p.period,
        ROUND(SUM(d.AMOUNT) / 100.0, 2) AS total_amount,
        COUNT(*) AS txn_count
    FROM all_data d
    JOIN period_def p ON d.event_date BETWEEN p.p_start AND p.p_end
    GROUP BY 1, 2
)

SELECT
    entry_type,
    MAX(CASE WHEN period='D-1' THEN total_amount END) AS "D-1",
    MAX(CASE WHEN period='D-2' THEN total_amount END) AS "D-2",
    MAX(CASE WHEN period='D-3' THEN total_amount END) AS "D-3",
    MAX(CASE WHEN period='W-1' THEN total_amount END) AS "W-1",
    MAX(CASE WHEN period='W-2' THEN total_amount END) AS "W-2",
    MAX(CASE WHEN period='W-3' THEN total_amount END) AS "W-3",
    MAX(CASE WHEN period='M-1' THEN total_amount END) AS "M-1",
    MAX(CASE WHEN period='M-2' THEN total_amount END) AS "M-2",
    MAX(CASE WHEN period='M-3' THEN total_amount END) AS "M-3"
FROM agg
GROUP BY entry_type
ORDER BY entry_type
