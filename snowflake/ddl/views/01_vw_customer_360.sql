/**********************************************************************
 * VW_CUSTOMER_360 — Customer 360 View (Snowflake)
 * Converted from ddl/views/01_vw_customer_360.sql.
 *
 * - REPLACE VIEW -> CREATE OR REPLACE VIEW; LOCKING ROW FOR ACCESS removed;
 *   SEL -> SELECT. ZEROIFNULL and QUALIFY are native in Snowflake.
 * - The correlated scalar subquery with QUALIFY nested inside SUM(CASE ...)
 *   is refactored: LATEST_SNAPSHOT picks the latest snapshot per ACCOUNT_KEY
 *   first, then ACCT_SUMMARY joins and aggregates. Accounts without a
 *   snapshot contribute NULL (ignored by SUM), as in the original.
 * - (FORMAT 'ZZZ,ZZZ,ZZ9.99') -> TO_CHAR(..., '999,999,990.00'):
 *   TOTAL_BALANCE and TXN_AMOUNT_LAST_90_DAYS are now VARCHAR.
 * - CURRENT_DATE - date -> DATEDIFF('day', ...).
 **********************************************************************/

CREATE OR REPLACE VIEW BANKING_DW.VW_CUSTOMER_360 AS
WITH LATEST_SNAPSHOT AS (
    SELECT
        snap.ACCOUNT_KEY,
        snap.CLOSING_BALANCE
    FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
    QUALIFY ROW_NUMBER() OVER (PARTITION BY snap.ACCOUNT_KEY
                               ORDER BY snap.SNAPSHOT_DATE DESC) = 1
),
ACCT_SUMMARY AS (
    SELECT
        a.CUSTOMER_ID,
        COUNT(*) AS TOTAL_ACCOUNTS,
        SUM(CASE WHEN a.ACCOUNT_STATUS = 'ACTIVE' THEN 1 ELSE 0 END) AS ACTIVE_ACCOUNTS,
        SUM(ls.CLOSING_BALANCE) AS TOTAL_BALANCE
    FROM BANKING_DW.DIM_ACCOUNT a
    LEFT JOIN LATEST_SNAPSHOT ls
        ON ls.ACCOUNT_KEY = a.ACCOUNT_KEY
    WHERE a.CURRENT_FLAG = 'Y'
    GROUP BY a.CUSTOMER_ID
),
TXN_SUMMARY AS (
    SELECT
        ft.CUSTOMER_KEY,
        COUNT(*) AS TXN_COUNT_90D,
        SUM(ABS(ft.TRANSACTION_AMOUNT)) AS TXN_AMOUNT_90D,
        MAX(ft.TRANSACTION_DATE) AS LAST_TXN_DATE,
        MAX(ft.CHANNEL) AS PRIMARY_CHANNEL  -- simplified; real logic would use mode
    FROM BANKING_DW.FACT_TRANSACTION ft
    WHERE ft.TRANSACTION_DATE >= DATEADD('day', -90, CURRENT_DATE())
    GROUP BY ft.CUSTOMER_KEY
)
SELECT
    c.CUSTOMER_ID,
    c.FIRST_NAME || ' ' || c.LAST_NAME AS FULL_NAME,
    c.CUSTOMER_SEGMENT,
    c.RISK_SCORE,
    c.CREDIT_RATING,
    c.KYC_STATUS,
    c.ONBOARDING_DATE,
    CAST(DATEDIFF('day', c.ONBOARDING_DATE, CURRENT_DATE()) / 365.25 AS DECIMAL(5,1)) AS TENURE_YEARS,
    ZEROIFNULL(acct_summary.TOTAL_ACCOUNTS) AS TOTAL_ACCOUNTS,
    ZEROIFNULL(acct_summary.ACTIVE_ACCOUNTS) AS ACTIVE_ACCOUNTS,
    TO_CHAR(ZEROIFNULL(acct_summary.TOTAL_BALANCE), '999,999,990.00') AS TOTAL_BALANCE,
    ZEROIFNULL(txn_summary.TXN_COUNT_90D) AS TXN_COUNT_LAST_90_DAYS,
    TO_CHAR(ZEROIFNULL(txn_summary.TXN_AMOUNT_90D), '999,999,990.00') AS TXN_AMOUNT_LAST_90_DAYS,
    txn_summary.LAST_TXN_DATE,
    txn_summary.PRIMARY_CHANNEL,
    c.CITY,
    c.COUNTRY_CODE
FROM BANKING_DW.DIM_CUSTOMER c
LEFT JOIN ACCT_SUMMARY acct_summary
    ON c.CUSTOMER_ID = acct_summary.CUSTOMER_ID
LEFT JOIN TXN_SUMMARY txn_summary
    ON c.CUSTOMER_KEY = txn_summary.CUSTOMER_KEY
WHERE c.CURRENT_FLAG = 'Y'
  AND c.IS_ACTIVE = 1;

COMMENT ON VIEW BANKING_DW.VW_CUSTOMER_360 IS 'Customer 360 view combining demographics, accounts, and recent transaction activity';
