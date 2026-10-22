/**********************************************************************
 * FACT_TRANSACTION — Daily Transaction Fact Table (Snowflake)
 * Converted from ddl/tables/06_fact_transaction.sql (Teradata MULTISET + PPI).
 *
 * - MULTISET -> standard table (same duplicate semantics).
 * - PRIMARY INDEX (ACCOUNT_KEY, TRANSACTION_DATE) is non-unique: no PRIMARY KEY
 *   is declared (VW_REGULATORY_LARGE_TRANSACTIONS dedups on TRANSACTION_ID,
 *   so duplicates are expected).
 * - PARTITION BY RANGE_N(TRANSACTION_DATE ... EACH INTERVAL '1' MONTH)
 *   -> CLUSTER BY (TRANSACTION_DATE). Re-validate pruning on date filters.
 * - NOT CASESPECIFIC -> COLLATE 'en-ci'; BYTEINT -> NUMBER(3,0);
 *   TIMESTAMP(n) -> TIMESTAMP_NTZ(n).
 * - COMPRESS, column FORMAT, COLLECT STATISTICS (incl. PARTITION) removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.FACT_TRANSACTION (
    TRANSACTION_ID      BIGINT           NOT NULL,
    TRANSACTION_DATE    DATE             NOT NULL,
    TRANSACTION_TIME    TIME(0),
    TRANSACTION_TS      TIMESTAMP_NTZ(6),
    ACCOUNT_KEY         BIGINT           NOT NULL,
    CUSTOMER_KEY        BIGINT           NOT NULL,
    PRODUCT_ID          INTEGER          NOT NULL,
    BRANCH_ID           INTEGER,
    DATE_KEY            INTEGER          NOT NULL,
    TRANSACTION_TYPE    VARCHAR(20)      COLLATE 'en-ci' NOT NULL,
    TRANSACTION_SUBTYPE VARCHAR(30)      COLLATE 'en-ci',
    CHANNEL             VARCHAR(20)      COLLATE 'en-ci',
    TRANSACTION_AMOUNT  DECIMAL(15,2)    NOT NULL,
    TRANSACTION_CURRENCY CHAR(3)         COLLATE 'en-ci' DEFAULT 'NOK',
    BASE_CURRENCY_AMOUNT DECIMAL(15,2),
    EXCHANGE_RATE       DECIMAL(12,6)    DEFAULT 1.000000,
    RUNNING_BALANCE     DECIMAL(15,2),
    MERCHANT_ID         VARCHAR(20),
    MERCHANT_NAME       VARCHAR(100)     COLLATE 'en-ci',
    MERCHANT_CATEGORY   VARCHAR(4),       -- MCC code
    COUNTERPARTY_ACCT   VARCHAR(20),
    REFERENCE_NUMBER    VARCHAR(30),
    DESCRIPTION_TEXT    VARCHAR(200)     COLLATE 'en-ci',
    IS_INTERNATIONAL    NUMBER(3,0)      DEFAULT 0,
    IS_FLAGGED          NUMBER(3,0)      DEFAULT 0,
    FLAG_REASON         VARCHAR(50),
    POSTING_DATE        DATE,
    VALUE_DATE          DATE,
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0)
)
CLUSTER BY (TRANSACTION_DATE);

COMMENT ON TABLE BANKING_DW.FACT_TRANSACTION IS 'Grain: one row per transaction. PPI on TRANSACTION_DATE for partition elimination.';
