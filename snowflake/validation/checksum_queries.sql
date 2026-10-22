/**********************************************************************
 * Validation Checksum Queries — Snowflake dialect
 * Snowflake counterpart of data/validation/checksum_queries.sql.
 * Run the Teradata file on the source and this file on the target, then
 * compare result sets query by query.
 *
 * Changes vs the Teradata file:
 * - SEL -> SELECT; (FORMAT 'YYYY-MM-DD') -> TO_CHAR; (DECIMAL(18,2)) -> CAST.
 * - HASHROW(...) -> HASH(...). The two functions produce different values,
 *   so HASH_SUM (query 2) is NOT comparable across platforms. Compare the
 *   platform-neutral fingerprint columns (LEN_SUM, ID_SUM) instead, or
 *   recompute the same portable hash (e.g. MD5 of a normalised string) on
 *   both sides — see MIGRATION_RUNBOOK.md, "Validation".
 * - NOT IN (subquery) -> NOT EXISTS (same result when keys are NOT NULL,
 *   and no NULL trap if they are not).
 **********************************************************************/

-- ================================================================
-- 1. Row count validation per table
--    Compare with data/validation/expected_row_counts.csv
-- ================================================================
SELECT 'DIM_CUSTOMER' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BANKING_DW.DIM_CUSTOMER
UNION ALL SELECT 'DIM_ACCOUNT', COUNT(*) FROM BANKING_DW.DIM_ACCOUNT
UNION ALL SELECT 'DIM_PRODUCT', COUNT(*) FROM BANKING_DW.DIM_PRODUCT
UNION ALL SELECT 'DIM_BRANCH', COUNT(*) FROM BANKING_DW.DIM_BRANCH
UNION ALL SELECT 'DIM_DATE', COUNT(*) FROM BANKING_DW.DIM_DATE
UNION ALL SELECT 'FACT_TRANSACTION', COUNT(*) FROM BANKING_DW.FACT_TRANSACTION
UNION ALL SELECT 'FACT_MONTHLY_ACCOUNT_SNAPSHOT', COUNT(*) FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT
ORDER BY 1;

-- ================================================================
-- 2. Column-level checksum: DIM_CUSTOMER
-- ================================================================
SELECT
    COUNT(*) AS ROW_COUNT,
    COUNT(DISTINCT CUSTOMER_ID) AS DISTINCT_CUSTOMERS,
    SUM(HASH(CUSTOMER_ID, FIRST_NAME, LAST_NAME, CUSTOMER_SEGMENT)) AS HASH_SUM,
    SUM(CUSTOMER_ID) AS ID_SUM,
    SUM(LENGTH(FIRST_NAME) + LENGTH(LAST_NAME) + LENGTH(CUSTOMER_SEGMENT)) AS LEN_SUM,
    TO_CHAR(MIN(ONBOARDING_DATE), 'YYYY-MM-DD') AS MIN_ONBOARD_DATE,
    TO_CHAR(MAX(ONBOARDING_DATE), 'YYYY-MM-DD') AS MAX_ONBOARD_DATE,
    SUM(CASE WHEN IS_ACTIVE = 1 THEN 1 ELSE 0 END) AS ACTIVE_COUNT
FROM BANKING_DW.DIM_CUSTOMER
WHERE CURRENT_FLAG = 'Y';

-- ================================================================
-- 3. Aggregate checksum: FACT_TRANSACTION
-- ================================================================
SELECT
    EXTRACT(YEAR FROM TRANSACTION_DATE) AS TXN_YEAR,
    EXTRACT(MONTH FROM TRANSACTION_DATE) AS TXN_MONTH,
    COUNT(*) AS TXN_COUNT,
    CAST(SUM(TRANSACTION_AMOUNT) AS DECIMAL(18,2)) AS TOTAL_AMOUNT,
    CAST(SUM(BASE_CURRENCY_AMOUNT) AS DECIMAL(18,2)) AS TOTAL_BASE_AMOUNT,
    COUNT(DISTINCT ACCOUNT_KEY) AS DISTINCT_ACCOUNTS,
    COUNT(DISTINCT CUSTOMER_KEY) AS DISTINCT_CUSTOMERS,
    SUM(CASE WHEN TRANSACTION_TYPE = 'DEBIT' THEN 1 ELSE 0 END) AS DEBIT_COUNT,
    SUM(CASE WHEN TRANSACTION_TYPE = 'CREDIT' THEN 1 ELSE 0 END) AS CREDIT_COUNT,
    SUM(CASE WHEN IS_INTERNATIONAL = 1 THEN 1 ELSE 0 END) AS INTL_COUNT
FROM BANKING_DW.FACT_TRANSACTION
GROUP BY 1, 2
ORDER BY 1, 2;

-- ================================================================
-- 4. Business-level reconciliation: Monthly balances
-- ================================================================
SELECT
    snap.SNAPSHOT_MONTH_KEY,
    CAST(SUM(snap.CLOSING_BALANCE) AS DECIMAL(18,2)) AS TOTAL_DEPOSITS,
    CAST(SUM(snap.TOTAL_DEBITS) AS DECIMAL(18,2)) AS TOTAL_DEBITS,
    CAST(SUM(snap.TOTAL_CREDITS) AS DECIMAL(18,2)) AS TOTAL_CREDITS,
    CAST(SUM(snap.INTEREST_EARNED) AS DECIMAL(18,2)) AS TOTAL_INTEREST,
    CAST(SUM(snap.FEES_CHARGED) AS DECIMAL(18,2)) AS TOTAL_FEES,
    COUNT(*) AS ACCOUNT_COUNT
FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
GROUP BY 1
ORDER BY 1;

-- ================================================================
-- 5. Cross-table referential integrity checks
-- ================================================================
SELECT 'ORPHAN_TXN_ACCOUNT' AS CHECK_NAME, COUNT(*) AS ORPHAN_COUNT
FROM BANKING_DW.FACT_TRANSACTION ft
WHERE NOT EXISTS (SELECT 1 FROM BANKING_DW.DIM_ACCOUNT a WHERE a.ACCOUNT_KEY = ft.ACCOUNT_KEY)
UNION ALL
SELECT 'ORPHAN_TXN_CUSTOMER', COUNT(*)
FROM BANKING_DW.FACT_TRANSACTION ft
WHERE NOT EXISTS (SELECT 1 FROM BANKING_DW.DIM_CUSTOMER c WHERE c.CUSTOMER_KEY = ft.CUSTOMER_KEY)
UNION ALL
SELECT 'ORPHAN_SNAP_ACCOUNT', COUNT(*)
FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
WHERE NOT EXISTS (SELECT 1 FROM BANKING_DW.DIM_ACCOUNT a WHERE a.ACCOUNT_KEY = snap.ACCOUNT_KEY);

-- ================================================================
-- 6. Declared-but-not-enforced primary keys: duplicate detection
--    (replaces the implicit SET-table / UPI uniqueness of Teradata)
-- ================================================================
SELECT 'DIM_CUSTOMER.CUSTOMER_KEY' AS PK, COUNT(*) - COUNT(DISTINCT CUSTOMER_KEY) AS DUPLICATES FROM BANKING_DW.DIM_CUSTOMER
UNION ALL SELECT 'DIM_ACCOUNT.ACCOUNT_KEY', COUNT(*) - COUNT(DISTINCT ACCOUNT_KEY) FROM BANKING_DW.DIM_ACCOUNT
UNION ALL SELECT 'DIM_PRODUCT.PRODUCT_ID', COUNT(*) - COUNT(DISTINCT PRODUCT_ID) FROM BANKING_DW.DIM_PRODUCT
UNION ALL SELECT 'DIM_BRANCH.BRANCH_ID', COUNT(*) - COUNT(DISTINCT BRANCH_ID) FROM BANKING_DW.DIM_BRANCH
UNION ALL SELECT 'DIM_DATE.DATE_KEY', COUNT(*) - COUNT(DISTINCT DATE_KEY) FROM BANKING_DW.DIM_DATE
UNION ALL SELECT 'DIM_CUSTOMER.CUSTOMER_ID (current)', COUNT(*) - COUNT(DISTINCT CUSTOMER_ID) FROM BANKING_DW.DIM_CUSTOMER WHERE CURRENT_FLAG = 'Y'
UNION ALL SELECT 'FACT_MONTHLY_ACCOUNT_SNAPSHOT (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY)',
          COUNT(*) - COUNT(DISTINCT ACCOUNT_KEY, SNAPSHOT_MONTH_KEY) FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT;
