/**********************************************************************
 * FACT_MONTHLY_ACCOUNT_SNAPSHOT — Month-End Balance Snapshot (Snowflake)
 * Converted from ddl/tables/07_fact_monthly_snapshot.sql (Teradata MULTISET + PPI).
 *
 * - MULTISET -> standard table (same duplicate semantics).
 * - PRIMARY INDEX (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY) is non-unique: no PRIMARY
 *   KEY is declared. The grain (one row per account per month) is maintained
 *   by the MERGE in SP_MONTHLY_SNAPSHOT.
 * - PARTITION BY RANGE_N(SNAPSHOT_DATE ... EACH INTERVAL '1' MONTH)
 *   -> CLUSTER BY (SNAPSHOT_DATE). Re-validate pruning on date filters.
 * - COMPRESS, column FORMAT, COLLECT STATISTICS (incl. PARTITION) removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (
    SNAPSHOT_DATE       DATE             NOT NULL,
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
    DAYS_IN_OVERDRAFT   SMALLINT         DEFAULT 0,
    DAYS_DORMANT        SMALLINT         DEFAULT 0,
    CURRENCY_CODE       CHAR(3)          DEFAULT 'NOK',
    BASE_CURRENCY_CLOSING DECIMAL(15,2),
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0)
)
CLUSTER BY (SNAPSHOT_DATE);

COMMENT ON TABLE BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT IS 'Monthly periodic snapshot: one row per account per calendar month';
