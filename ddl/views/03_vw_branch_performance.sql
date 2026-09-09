-- ======================================================================
-- OBJECT : BANKING_DW.VW_BRANCH_PERFORMANCE (view)
-- FILE   : ddl/views/03_vw_branch_performance.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Monthly branch performance dashboard view: accounts/customers
--     serviced, deposits, volume, fees, interest income, cumulative
--     fees, 3-month moving average volume and regional rankings.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.VW_BRANCH_PERFORMANCE
--   * Reads: BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT,
--     BANKING_DW.DIM_BRANCH, BANKING_DW.DIM_DATE
--
-- KEY BUSINESS RULES
--   * Only active branches (IS_ACTIVE=1) and snapshots within the
--     trailing 24 months (ADD_MONTHS(CURRENT_DATE, -24)).
--   * TOTAL_VOLUME = TOTAL_DEBITS + TOTAL_CREDITS; TOTAL_DEPOSITS =
--     SUM(CLOSING_BALANCE).
--   * CUMULATIVE_FEES_YTD is a cumulative sum ordered by
--     SNAPSHOT_MONTH_KEY; MOVING_AVG_VOLUME_3M is a 3-period moving
--     average.
--   * REGION_DEPOSIT_RANK ranks branches by deposits within
--     region/month; PCT_OF_REGION_DEPOSITS divides by region total with
--     NULLIFZERO guard.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * REPLACE VIEW; LOCKING ROW FOR ACCESS
--   * SEL shorthand for SELECT
--   * Teradata OLAP functions CSUM and MAVG
--   * NULLIFZERO; ADD_MONTHS
--   * Inline (FORMAT '9999') / (FORMAT 'ZZZ,ZZZ,ZZZ,ZZ9.99') / (FORMAT
--     'ZZ9.99') expressions
--   * COMMENT ON VIEW
-- ======================================================================

/**********************************************************************
 * VW_BRANCH_PERFORMANCE — Branch Performance Dashboard View
 * Uses OLAP functions, CSUM, MAVG, and Teradata-specific syntax
 **********************************************************************/

REPLACE VIEW BANKING_DW.VW_BRANCH_PERFORMANCE AS
LOCKING ROW FOR ACCESS
SEL
    b.BRANCH_ID,
    b.BRANCH_NAME,
    b.BRANCH_TYPE,
    b.REGION,
    b.CITY,
    snap.SNAPSHOT_MONTH_KEY,
    d.MONTH_NAME || ' ' || TRIM(d.CALENDAR_YEAR (FORMAT '9999')) AS MONTH_LABEL,
    COUNT(DISTINCT snap.ACCOUNT_KEY) AS ACCOUNTS_SERVICED,
    COUNT(DISTINCT snap.CUSTOMER_KEY) AS CUSTOMERS_SERVICED,
    SUM(snap.CLOSING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZZ,ZZ9.99') AS TOTAL_DEPOSITS,
    SUM(snap.TOTAL_DEBITS + snap.TOTAL_CREDITS) AS TOTAL_VOLUME,
    SUM(snap.FEES_CHARGED) AS TOTAL_FEES_EARNED,
    SUM(snap.INTEREST_CHARGED) AS TOTAL_INTEREST_INCOME,
    AVG(snap.CLOSING_BALANCE) AS AVG_ACCOUNT_BALANCE,
    /* Teradata CSUM — cumulative sum */
    CSUM(SUM(snap.FEES_CHARGED), snap.SNAPSHOT_MONTH_KEY) AS CUMULATIVE_FEES_YTD,
    /* Teradata MAVG — moving average (3-month window) */
    MAVG(SUM(snap.TOTAL_DEBITS + snap.TOTAL_CREDITS), 3, snap.SNAPSHOT_MONTH_KEY)
        AS MOVING_AVG_VOLUME_3M,
    /* Rank branches within region */
    RANK() OVER (PARTITION BY b.REGION, snap.SNAPSHOT_MONTH_KEY
                 ORDER BY SUM(snap.CLOSING_BALANCE) DESC) AS REGION_DEPOSIT_RANK,
    SUM(snap.CLOSING_BALANCE) /
        NULLIFZERO(SUM(SUM(snap.CLOSING_BALANCE))
                   OVER (PARTITION BY b.REGION, snap.SNAPSHOT_MONTH_KEY)) * 100
        (FORMAT 'ZZ9.99') AS PCT_OF_REGION_DEPOSITS
FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
INNER JOIN BANKING_DW.DIM_BRANCH b
    ON snap.BRANCH_ID = b.BRANCH_ID
INNER JOIN BANKING_DW.DIM_DATE d
    ON snap.SNAPSHOT_DATE = d.CALENDAR_DATE
WHERE b.IS_ACTIVE = 1
  AND snap.SNAPSHOT_DATE >= ADD_MONTHS(CURRENT_DATE, -24)
GROUP BY b.BRANCH_ID, b.BRANCH_NAME, b.BRANCH_TYPE, b.REGION, b.CITY,
         snap.SNAPSHOT_MONTH_KEY, d.MONTH_NAME, d.CALENDAR_YEAR;

COMMENT ON VIEW BANKING_DW.VW_BRANCH_PERFORMANCE IS 'Monthly branch performance with cumulative sums, moving averages, and regional rankings';
