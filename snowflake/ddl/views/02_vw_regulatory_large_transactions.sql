/**********************************************************************
 * VW_REGULATORY_LARGE_TRANSACTIONS — Regulatory Reporting View (Snowflake)
 * Converted from ddl/views/02_vw_regulatory_large_transactions.sql.
 *
 * - REPLACE VIEW -> CREATE OR REPLACE VIEW; LOCKING ROW FOR ACCESS removed;
 *   SEL -> SELECT.
 * - FIRST_NAME/LAST_NAME (NOT CASESPECIFIC) removed: the columns are
 *   COLLATE 'en-ci' in DIM_CUSTOMER, so comparisons stay case-insensitive.
 * - HASHROW(...) -> HASH(...). Values differ from Teradata; any checksum
 *   reconciliation on ROW_HASH must be recomputed on both platforms.
 * - QUALIFY ROW_NUMBER() kept (native in Snowflake).
 **********************************************************************/

CREATE OR REPLACE VIEW BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS AS
SELECT
    ft.TRANSACTION_ID,
    ft.TRANSACTION_DATE,
    ft.TRANSACTION_TS,
    c.CUSTOMER_ID,
    c.FIRST_NAME,
    c.LAST_NAME,
    c.KYC_STATUS,
    a.ACCOUNT_ID,
    a.ACCOUNT_TYPE,
    ft.TRANSACTION_TYPE,
    ft.TRANSACTION_SUBTYPE,
    ft.TRANSACTION_AMOUNT,
    ft.TRANSACTION_CURRENCY,
    ft.BASE_CURRENCY_AMOUNT,
    ft.MERCHANT_NAME,
    ft.COUNTERPARTY_ACCT,
    ft.IS_INTERNATIONAL,
    ft.REFERENCE_NUMBER,
    ft.DESCRIPTION_TEXT,
    b.BRANCH_NAME,
    b.REGION,
    CASE
        WHEN ft.BASE_CURRENCY_AMOUNT >= 100000 THEN 'THRESHOLD_EXCEEDED'
        WHEN ft.IS_INTERNATIONAL = 1
             AND ft.BASE_CURRENCY_AMOUNT >= 25000 THEN 'INTL_THRESHOLD'
        WHEN ft.IS_FLAGGED = 1 THEN 'FLAGGED_SUSPICIOUS'
        ELSE 'REVIEW'
    END AS REPORTING_CATEGORY,
    HASH(ft.TRANSACTION_ID, ft.TRANSACTION_DATE) AS ROW_HASH,
    ft.ETL_BATCH_ID
FROM BANKING_DW.FACT_TRANSACTION ft
INNER JOIN BANKING_DW.DIM_ACCOUNT a
    ON ft.ACCOUNT_KEY = a.ACCOUNT_KEY
   AND a.CURRENT_FLAG = 'Y'
INNER JOIN BANKING_DW.DIM_CUSTOMER c
    ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY
   AND c.CURRENT_FLAG = 'Y'
LEFT JOIN BANKING_DW.DIM_BRANCH b
    ON ft.BRANCH_ID = b.BRANCH_ID
WHERE (ft.BASE_CURRENCY_AMOUNT >= 100000
       OR (ft.IS_INTERNATIONAL = 1 AND ft.BASE_CURRENCY_AMOUNT >= 25000)
       OR ft.IS_FLAGGED = 1)
QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.TRANSACTION_ID
                           ORDER BY ft.ETL_BATCH_ID DESC) = 1;

COMMENT ON VIEW BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS IS 'Regulatory reporting: transactions exceeding NOK thresholds or flagged as suspicious';
