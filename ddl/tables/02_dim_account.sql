-- ======================================================================
-- OBJECT : BANKING_DW.DIM_ACCOUNT (dimension table)
-- FILE   : ddl/tables/02_dim_account.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the SCD Type 2 account dimension: account type/subtype,
--     currency, status, limits, rates and owning
--     customer/branch/product.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.DIM_ACCOUNT
--   * References: BANKING_DW.DIM_CUSTOMER (CUSTOMER_ID),
--     BANKING_DW.DIM_PRODUCT (PRODUCT_ID), BANKING_DW.DIM_BRANCH
--     (BRANCH_ID)
--   * Referenced by: BANKING_DW.FACT_TRANSACTION (ACCOUNT_KEY),
--     BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (ACCOUNT_KEY)
--   * Used as lookup by: SP_LOAD_DAILY_TRANSACTIONS, SP_MONTHLY_SNAPSHOT
--     and all macros/views
--
-- KEY BUSINESS RULES
--   * ACCOUNT_KEY is the identity surrogate key; ACCOUNT_ID is the
--     natural key.
--   * SCD Type 2 control columns: EFFECTIVE_FROM, EFFECTIVE_TO (default
--     '9999-12-31 23:59:59'), CURRENT_FLAG (default 'Y'); tracks status
--     and rate changes.
--   * CURRENCY_CODE defaults to 'NOK' (base currency); ACCOUNT_STATUS
--     defaults to 'ACTIVE'; OVERDRAFT_LIMIT defaults to 0;
--     TAX_REPORTING_FLAG defaults to 1.
--   * Partitioned by OPENING_DATE in yearly ranges (2000-2030).
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE MULTISET TABLE (duplicates allowed)
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * GENERATED ALWAYS AS IDENTITY on ACCOUNT_KEY
--   * NOT CASESPECIFIC; FORMAT 'YYYY-MM-DD'; COMPRESS value lists /
--     single-value COMPRESS 0
--   * UNIQUE PRIMARY INDEX plus secondary INDEX definitions
--   * PARTITION BY RANGE_N (PPI)
--   * COLLECT STATISTICS; COMMENT ON TABLE
-- ======================================================================

/**********************************************************************
 * DIM_ACCOUNT — Account Dimension
 * Teradata MULTISET table with composite primary index
 **********************************************************************/

CREATE MULTISET TABLE BANKING_DW.DIM_ACCOUNT, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    ACCOUNT_KEY         BIGINT           NOT NULL GENERATED ALWAYS AS IDENTITY
                                         (START WITH 1 INCREMENT BY 1),
    ACCOUNT_ID          VARCHAR(20)      NOT NULL,
    CUSTOMER_ID         INTEGER          NOT NULL,
    ACCOUNT_TYPE        VARCHAR(20)      NOT CASESPECIFIC NOT NULL
                                         COMPRESS ('CHECKING', 'SAVINGS', 'LOAN', 'CREDIT_CARD',
                                                   'MORTGAGE', 'DEPOSIT', 'INVESTMENT'),
    ACCOUNT_SUBTYPE     VARCHAR(30)      NOT CASESPECIFIC
                                         COMPRESS ('PERSONAL', 'BUSINESS', 'JOINT', 'TRUST'),
    CURRENCY_CODE       CHAR(3)          NOT CASESPECIFIC DEFAULT 'NOK'
                                         COMPRESS ('NOK', 'EUR', 'USD', 'GBP', 'SEK', 'DKK'),
    OPENING_DATE        DATE FORMAT 'YYYY-MM-DD' NOT NULL,
    CLOSING_DATE        DATE FORMAT 'YYYY-MM-DD',
    ACCOUNT_STATUS      VARCHAR(15)      NOT CASESPECIFIC DEFAULT 'ACTIVE'
                                         COMPRESS ('ACTIVE', 'DORMANT', 'CLOSED', 'FROZEN', 'SUSPENDED'),
    INTEREST_RATE       DECIMAL(7,4),
    CREDIT_LIMIT        DECIMAL(15,2)    COMPRESS 0,
    OVERDRAFT_LIMIT     DECIMAL(15,2)    DEFAULT 0,
    BRANCH_ID           INTEGER,
    RELATIONSHIP_MGR_ID INTEGER          COMPRESS 0,
    PRODUCT_ID          INTEGER          NOT NULL,
    IS_JOINT_ACCOUNT    BYTEINT          DEFAULT 0 COMPRESS (0, 1),
    TAX_REPORTING_FLAG  BYTEINT          DEFAULT 1 COMPRESS (0, 1),
    EFFECTIVE_FROM      TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0),
    EFFECTIVE_TO        TIMESTAMP(0)     DEFAULT TIMESTAMP '9999-12-31 23:59:59',
    CURRENT_FLAG        CHAR(1)          DEFAULT 'Y' COMPRESS ('Y', 'N'),
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0),
    ETL_UPDATE_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
UNIQUE PRIMARY INDEX UPI_ACCOUNT_KEY (ACCOUNT_KEY)
INDEX NUPI_ACCOUNT_ID (ACCOUNT_ID)
INDEX IDX_ACCT_CUSTOMER (CUSTOMER_ID)
INDEX IDX_ACCT_TYPE (ACCOUNT_TYPE)
INDEX IDX_ACCT_BRANCH (BRANCH_ID)
PARTITION BY RANGE_N(OPENING_DATE BETWEEN DATE '2000-01-01'
                                  AND     DATE '2030-12-31'
                                  EACH INTERVAL '1' YEAR);

COLLECT STATISTICS COLUMN (ACCOUNT_ID) ON BANKING_DW.DIM_ACCOUNT;
COLLECT STATISTICS COLUMN (CUSTOMER_ID) ON BANKING_DW.DIM_ACCOUNT;
COLLECT STATISTICS COLUMN (ACCOUNT_TYPE) ON BANKING_DW.DIM_ACCOUNT;
COLLECT STATISTICS COLUMN (ACCOUNT_STATUS) ON BANKING_DW.DIM_ACCOUNT;
COLLECT STATISTICS COLUMN (BRANCH_ID) ON BANKING_DW.DIM_ACCOUNT;

COMMENT ON TABLE BANKING_DW.DIM_ACCOUNT IS 'Account dimension with SCD Type 2 tracking for status and rate changes';
