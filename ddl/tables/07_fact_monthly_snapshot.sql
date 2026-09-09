-- ======================================================================
-- OBJECT : BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (fact table)
-- FILE   : ddl/tables/07_fact_monthly_snapshot.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the periodic month-end snapshot fact table with
--     opening/closing/avg/min/max balances, debit/credit totals,
--     interest, fees, overdraft and dormancy days.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT
--   * References: BANKING_DW.DIM_ACCOUNT (ACCOUNT_KEY),
--     BANKING_DW.DIM_CUSTOMER (CUSTOMER_KEY), BANKING_DW.DIM_PRODUCT
--     (PRODUCT_ID), BANKING_DW.DIM_BRANCH (BRANCH_ID)
--   * Loaded by: BANKING_DW.SP_MONTHLY_SNAPSHOT (MERGE); read by
--     VW_CUSTOMER_360 and VW_BRANCH_PERFORMANCE
--
-- KEY BUSINESS RULES
--   * Star-schema grain: one row per account per calendar month
--     (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY); SNAPSHOT_MONTH_KEY is YYYYMM,
--     SNAPSHOT_DATE is the month-end date.
--   * Totals/counts/interest/fees default to 0; CURRENCY_CODE defaults
--     to 'NOK'; BASE_CURRENCY_CLOSING holds the NOK closing balance.
--   * Partitioned by SNAPSHOT_DATE in monthly ranges (2018-2030) with NO
--     RANGE catch-all partition.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE MULTISET TABLE
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * FORMAT 'YYYY-MM-DD'; SMALLINT with single-value COMPRESS 0;
--     COMPRESS value lists
--   * Non-unique composite PRIMARY INDEX (ACCOUNT_KEY,
--     SNAPSHOT_MONTH_KEY)
--   * PARTITION BY RANGE_N ... EACH INTERVAL '1' MONTH, NO RANGE (PPI)
--   * COLLECT STATISTICS incl. COLUMN (PARTITION); COMMENT ON TABLE
-- ======================================================================

/**********************************************************************
 * FACT_MONTHLY_ACCOUNT_SNAPSHOT — Month-End Balance Snapshot
 * Periodic snapshot fact table, one row per account per month
 **********************************************************************/

CREATE MULTISET TABLE BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    SNAPSHOT_DATE       DATE FORMAT 'YYYY-MM-DD' NOT NULL,
    SNAPSHOT_MONTH_KEY  INTEGER          NOT NULL,   -- YYYYMM format
    ACCOUNT_KEY         BIGINT           NOT NULL,
    CUSTOMER_KEY        BIGINT           NOT NULL,
    PRODUCT_ID          INTEGER          NOT NULL,
    BRANCH_ID           INTEGER,
    OPENING_BALANCE     DECIMAL(15,2)    NOT NULL,
    CLOSING_BALANCE     DECIMAL(15,2)    NOT NULL,
    AVERAGE_BALANCE     DECIMAL(15,2),
    MINIMUM_BALANCE     DECIMAL(15,2),
    MAXIMUM_BALANCE     DECIMAL(15,2),
    TOTAL_DEBITS        DECIMAL(15,2)    DEFAULT 0,
    TOTAL_CREDITS       DECIMAL(15,2)    DEFAULT 0,
    DEBIT_COUNT         INTEGER          DEFAULT 0,
    CREDIT_COUNT        INTEGER          DEFAULT 0,
    INTEREST_EARNED     DECIMAL(12,2)    DEFAULT 0,
    INTEREST_CHARGED    DECIMAL(12,2)    DEFAULT 0,
    FEES_CHARGED        DECIMAL(12,2)    DEFAULT 0,
    DAYS_IN_OVERDRAFT   SMALLINT         DEFAULT 0 COMPRESS 0,
    DAYS_DORMANT        SMALLINT         DEFAULT 0 COMPRESS 0,
    CURRENCY_CODE       CHAR(3)          DEFAULT 'NOK'
                                         COMPRESS ('NOK', 'EUR', 'USD', 'GBP', 'SEK', 'DKK'),
    BASE_CURRENCY_CLOSING DECIMAL(15,2),
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
PRIMARY INDEX PI_MONTHLY_SNAP (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY)
PARTITION BY RANGE_N(SNAPSHOT_DATE BETWEEN DATE '2018-01-01'
                                   AND     DATE '2030-12-31'
                                   EACH INTERVAL '1' MONTH,
                     NO RANGE);

COLLECT STATISTICS COLUMN (SNAPSHOT_MONTH_KEY) ON BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT;
COLLECT STATISTICS COLUMN (ACCOUNT_KEY) ON BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT;
COLLECT STATISTICS COLUMN (PARTITION) ON BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT;

COMMENT ON TABLE BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT IS 'Monthly periodic snapshot: one row per account per calendar month';
