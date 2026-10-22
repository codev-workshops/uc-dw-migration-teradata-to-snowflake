/**********************************************************************
 * VW_BRANCH_PERFORMANCE — Branch Performance Dashboard View (Snowflake)
 * Converted from ddl/views/03_vw_branch_performance.sql.
 *
 * - REPLACE VIEW -> CREATE OR REPLACE VIEW; LOCKING ROW FOR ACCESS removed;
 *   SEL -> SELECT. NULLIFZERO, RANK() OVER and ADD_MONTHS are native.
 * - CSUM(SUM(x), SNAPSHOT_MONTH_KEY) -> SUM(SUM(x)) OVER (... ROWS UNBOUNDED PRECEDING)
 * - MAVG(SUM(x), 3, SNAPSHOT_MONTH_KEY) -> AVG(SUM(x)) OVER (... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
 * - SEMANTIC DECISION: the original CSUM/MAVG have no partition, which would
 *   accumulate across all branches. The windows are now partitioned per
 *   branch (and per calendar year for the YTD sum) to match the column names
 *   CUMULATIVE_FEES_YTD and MOVING_AVG_VOLUME_3M. See MIGRATION_RUNBOOK.md.
 * - (FORMAT ...) masks -> TO_CHAR(): TOTAL_DEPOSITS and PCT_OF_REGION_DEPOSITS
 *   are now VARCHAR.
 **********************************************************************/

CREATE OR REPLACE VIEW BANKING_DW.VW_BRANCH_PERFORMANCE AS
SELECT
    b.BRANCH_ID,
    b.BRANCH_NAME,
    b.BRANCH_TYPE,
    b.REGION,
    b.CITY,
    snap.SNAPSHOT_MONTH_KEY,
    d.MONTH_NAME || ' ' || TRIM(TO_CHAR(d.CALENDAR_YEAR, '0000')) AS MONTH_LABEL,
    COUNT(DISTINCT snap.ACCOUNT_KEY) AS ACCOUNTS_SERVICED,
    COUNT(DISTINCT snap.CUSTOMER_KEY) AS CUSTOMERS_SERVICED,
    TO_CHAR(SUM(snap.CLOSING_BALANCE), '999,999,999,990.00') AS TOTAL_DEPOSITS,
    SUM(snap.TOTAL_DEBITS + snap.TOTAL_CREDITS) AS TOTAL_VOLUME,
    SUM(snap.FEES_CHARGED) AS TOTAL_FEES_EARNED,
    SUM(snap.INTEREST_CHARGED) AS TOTAL_INTEREST_INCOME,
    AVG(snap.CLOSING_BALANCE) AS AVG_ACCOUNT_BALANCE,
    /* Was Teradata CSUM — cumulative sum, per branch, reset each calendar year */
    SUM(SUM(snap.FEES_CHARGED)) OVER (
        PARTITION BY b.BRANCH_ID, d.CALENDAR_YEAR
        ORDER BY snap.SNAPSHOT_MONTH_KEY
        ROWS UNBOUNDED PRECEDING) AS CUMULATIVE_FEES_YTD,
    /* Was Teradata MAVG — 3-month moving average, per branch */
    AVG(SUM(snap.TOTAL_DEBITS + snap.TOTAL_CREDITS)) OVER (
        PARTITION BY b.BRANCH_ID
        ORDER BY snap.SNAPSHOT_MONTH_KEY
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS MOVING_AVG_VOLUME_3M,
    /* Rank branches within region */
    RANK() OVER (PARTITION BY b.REGION, snap.SNAPSHOT_MONTH_KEY
                 ORDER BY SUM(snap.CLOSING_BALANCE) DESC) AS REGION_DEPOSIT_RANK,
    TO_CHAR(
        SUM(snap.CLOSING_BALANCE) /
            NULLIFZERO(SUM(SUM(snap.CLOSING_BALANCE))
                       OVER (PARTITION BY b.REGION, snap.SNAPSHOT_MONTH_KEY)) * 100,
        '990.00') AS PCT_OF_REGION_DEPOSITS
FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
INNER JOIN BANKING_DW.DIM_BRANCH b
    ON snap.BRANCH_ID = b.BRANCH_ID
INNER JOIN BANKING_DW.DIM_DATE d
    ON snap.SNAPSHOT_DATE = d.CALENDAR_DATE
WHERE b.IS_ACTIVE = 1
  AND snap.SNAPSHOT_DATE >= ADD_MONTHS(CURRENT_DATE(), -24)
GROUP BY b.BRANCH_ID, b.BRANCH_NAME, b.BRANCH_TYPE, b.REGION, b.CITY,
         snap.SNAPSHOT_MONTH_KEY, d.MONTH_NAME, d.CALENDAR_YEAR;

COMMENT ON VIEW BANKING_DW.VW_BRANCH_PERFORMANCE IS 'Monthly branch performance with cumulative sums, moving averages, and regional rankings';
