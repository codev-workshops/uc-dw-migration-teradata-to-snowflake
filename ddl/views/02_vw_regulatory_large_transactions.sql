-- ======================================================================
-- OBJECT : BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS (view)
-- FILE   : ddl/views/02_vw_regulatory_large_transactions.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Regulatory reporting view listing transactions that exceed NOK
--     reporting thresholds or have been flagged as suspicious, enriched
--     with customer, account and branch attributes.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS
--   * Reads: BANKING_DW.FACT_TRANSACTION, BANKING_DW.DIM_ACCOUNT,
--     BANKING_DW.DIM_CUSTOMER, BANKING_DW.DIM_BRANCH
--
-- KEY BUSINESS RULES
--   * Includes rows where BASE_CURRENCY_AMOUNT >= 100000, or
--     IS_INTERNATIONAL=1 and BASE_CURRENCY_AMOUNT >= 25000, or
--     IS_FLAGGED=1.
--   * REPORTING_CATEGORY: THRESHOLD_EXCEEDED / INTL_THRESHOLD /
--     FLAGGED_SUSPICIOUS / REVIEW (evaluated in that order).
--   * Joins only current (CURRENT_FLAG='Y') account and customer
--     versions; branch join is optional (LEFT JOIN).
--   * Deduplicates to the latest ETL_BATCH_ID per TRANSACTION_ID;
--     ROW_HASH = HASHROW(TRANSACTION_ID, TRANSACTION_DATE) for
--     reconciliation.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * REPLACE VIEW; LOCKING ROW FOR ACCESS
--   * SEL shorthand for SELECT
--   * Inline (NOT CASESPECIFIC) column attribute
--   * HASHROW() hashing function
--   * QUALIFY ROW_NUMBER() OVER (...) window filtering
--   * COMMENT ON VIEW
-- ======================================================================

/**********************************************************************
 * VW_REGULATORY_LARGE_TRANSACTIONS — Regulatory Reporting View
 * Identifies transactions above reporting thresholds
 * Uses Teradata QUALIFY, HASHROW, and SAMPLE features
 **********************************************************************/

REPLACE VIEW BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS AS
LOCKING ROW FOR ACCESS
SEL
    ft.TRANSACTION_ID,
    ft.TRANSACTION_DATE,
    ft.TRANSACTION_TS,
    c.CUSTOMER_ID,
    c.FIRST_NAME (NOT CASESPECIFIC),
    c.LAST_NAME (NOT CASESPECIFIC),
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
    HASHROW(ft.TRANSACTION_ID, ft.TRANSACTION_DATE) AS ROW_HASH,
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
