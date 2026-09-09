-- ======================================================================
-- OBJECT : BANKING_DW.FACT_TRANSACTION (fact table)
-- FILE   : ddl/tables/06_fact_transaction.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the daily transaction fact table - the largest table in
--     the warehouse - holding one row per posted transaction with
--     amounts, currency conversion, channel and merchant details.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.FACT_TRANSACTION
--   * References: BANKING_DW.DIM_ACCOUNT (ACCOUNT_KEY),
--     BANKING_DW.DIM_CUSTOMER (CUSTOMER_KEY), BANKING_DW.DIM_PRODUCT
--     (PRODUCT_ID), BANKING_DW.DIM_BRANCH (BRANCH_ID),
--     BANKING_DW.DIM_DATE (DATE_KEY)
--   * Loaded by: BANKING_DW.SP_LOAD_DAILY_TRANSACTIONS; read by
--     SP_MONTHLY_SNAPSHOT, all macros and views
--
-- KEY BUSINESS RULES
--   * Star-schema grain: one row per transaction (TRANSACTION_ID);
--     surrogate FKs to account and customer, natural-key FKs to product,
--     branch and date.
--   * TRANSACTION_CURRENCY defaults to 'NOK'; BASE_CURRENCY_AMOUNT holds
--     the NOK-converted amount and EXCHANGE_RATE defaults to 1.000000.
--   * IS_INTERNATIONAL and IS_FLAGGED default to 0; FLAG_REASON stores
--     the suspicious-activity reason.
--   * Partitioned by TRANSACTION_DATE in monthly ranges (2018-2030) with
--     NO RANGE catch-all partition for partition elimination.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE MULTISET TABLE
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * NOT CASESPECIFIC; FORMAT 'YYYY-MM-DD'; TIME(0)/TIMESTAMP(6);
--     BYTEINT
--   * COMPRESS value lists / COMPRESS ''
--   * Non-unique composite PRIMARY INDEX (ACCOUNT_KEY, TRANSACTION_DATE)
--   * PARTITION BY RANGE_N ... EACH INTERVAL '1' MONTH, NO RANGE (PPI)
--   * COLLECT STATISTICS incl. COLUMN (PARTITION); COMMENT ON TABLE
-- ======================================================================

/**********************************************************************
 * FACT_TRANSACTION — Daily Transaction Fact Table
 * Teradata MULTISET table with Partitioned Primary Index (PPI)
 * This is the largest table in the warehouse — uses PPI on TRANSACTION_DATE
 **********************************************************************/

CREATE MULTISET TABLE BANKING_DW.FACT_TRANSACTION, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    TRANSACTION_ID      BIGINT           NOT NULL,
    TRANSACTION_DATE    DATE FORMAT 'YYYY-MM-DD' NOT NULL,
    TRANSACTION_TIME    TIME(0),
    TRANSACTION_TS      TIMESTAMP(6),
    ACCOUNT_KEY         BIGINT           NOT NULL,
    CUSTOMER_KEY        BIGINT           NOT NULL,
    PRODUCT_ID          INTEGER          NOT NULL,
    BRANCH_ID           INTEGER,
    DATE_KEY            INTEGER          NOT NULL,
    TRANSACTION_TYPE    VARCHAR(20)      NOT CASESPECIFIC NOT NULL
                                         COMPRESS ('DEBIT', 'CREDIT', 'TRANSFER', 'FEE',
                                                   'INTEREST', 'REVERSAL', 'ADJUSTMENT'),
    TRANSACTION_SUBTYPE VARCHAR(30)      NOT CASESPECIFIC
                                         COMPRESS ('ATM_WITHDRAWAL', 'POS_PURCHASE', 'ONLINE_TRANSFER',
                                                   'DIRECT_DEBIT', 'SALARY', 'STANDING_ORDER',
                                                   'CARD_PAYMENT', 'MOBILE_PAYMENT', 'VIPPS'),
    CHANNEL             VARCHAR(20)      NOT CASESPECIFIC
                                         COMPRESS ('BRANCH', 'ATM', 'ONLINE', 'MOBILE', 'POS', 'API'),
    TRANSACTION_AMOUNT  DECIMAL(15,2)    NOT NULL,
    TRANSACTION_CURRENCY CHAR(3)         NOT CASESPECIFIC DEFAULT 'NOK'
                                         COMPRESS ('NOK', 'EUR', 'USD', 'GBP', 'SEK', 'DKK'),
    BASE_CURRENCY_AMOUNT DECIMAL(15,2),
    EXCHANGE_RATE       DECIMAL(12,6)    DEFAULT 1.000000,
    RUNNING_BALANCE     DECIMAL(15,2),
    MERCHANT_ID         VARCHAR(20),
    MERCHANT_NAME       VARCHAR(100)     NOT CASESPECIFIC,
    MERCHANT_CATEGORY   VARCHAR(4),       -- MCC code
    COUNTERPARTY_ACCT   VARCHAR(20),
    REFERENCE_NUMBER    VARCHAR(30),
    DESCRIPTION_TEXT    VARCHAR(200)     NOT CASESPECIFIC,
    IS_INTERNATIONAL    BYTEINT          DEFAULT 0 COMPRESS (0, 1),
    IS_FLAGGED          BYTEINT          DEFAULT 0 COMPRESS (0, 1),
    FLAG_REASON         VARCHAR(50)      COMPRESS '',
    POSTING_DATE        DATE FORMAT 'YYYY-MM-DD',
    VALUE_DATE          DATE FORMAT 'YYYY-MM-DD',
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
PRIMARY INDEX PI_FACT_TXN (ACCOUNT_KEY, TRANSACTION_DATE)
PARTITION BY RANGE_N(TRANSACTION_DATE BETWEEN DATE '2018-01-01'
                                      AND     DATE '2030-12-31'
                                      EACH INTERVAL '1' MONTH,
                     NO RANGE);

COLLECT STATISTICS COLUMN (TRANSACTION_ID) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (TRANSACTION_DATE) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (ACCOUNT_KEY) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (CUSTOMER_KEY) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (TRANSACTION_TYPE) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (CHANNEL) ON BANKING_DW.FACT_TRANSACTION;
COLLECT STATISTICS COLUMN (PARTITION) ON BANKING_DW.FACT_TRANSACTION;

COMMENT ON TABLE BANKING_DW.FACT_TRANSACTION IS 'Grain: one row per transaction. PPI on TRANSACTION_DATE for partition elimination.';
