/**********************************************************************
 * DIM_ACCOUNT — Account Dimension (Snowflake)
 * Converted from ddl/tables/02_dim_account.sql (Teradata MULTISET table).
 *
 * - MULTISET -> standard table (same duplicate semantics).
 * - UNIQUE PRIMARY INDEX (ACCOUNT_KEY) -> declared PRIMARY KEY (not enforced).
 * - PARTITION BY RANGE_N(OPENING_DATE ...) -> CLUSTER BY (OPENING_DATE).
 * - NOT CASESPECIFIC -> COLLATE 'en-ci'.
 * - COMPRESS, column FORMAT, secondary INDEXes, COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.DIM_ACCOUNT (
    ACCOUNT_KEY         BIGINT           NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
    ACCOUNT_ID          VARCHAR(20)      NOT NULL,
    CUSTOMER_ID         INTEGER          NOT NULL,
    ACCOUNT_TYPE        VARCHAR(20)      COLLATE 'en-ci' NOT NULL,
    ACCOUNT_SUBTYPE     VARCHAR(30)      COLLATE 'en-ci',
    CURRENCY_CODE       CHAR(3)          COLLATE 'en-ci' DEFAULT 'NOK',
    OPENING_DATE        DATE             NOT NULL,
    CLOSING_DATE        DATE,
    ACCOUNT_STATUS      VARCHAR(15)      COLLATE 'en-ci' DEFAULT 'ACTIVE',
    INTEREST_RATE       DECIMAL(7,4),
    CREDIT_LIMIT        DECIMAL(15,2),
    OVERDRAFT_LIMIT     DECIMAL(15,2)    DEFAULT 0,
    BRANCH_ID           INTEGER,
    RELATIONSHIP_MGR_ID INTEGER,
    PRODUCT_ID          INTEGER          NOT NULL,
    IS_JOINT_ACCOUNT    NUMBER(3,0)      DEFAULT 0,
    TAX_REPORTING_FLAG  NUMBER(3,0)      DEFAULT 1,
    EFFECTIVE_FROM      TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    EFFECTIVE_TO        TIMESTAMP_NTZ(0) DEFAULT TIMESTAMP '9999-12-31 23:59:59',
    CURRENT_FLAG        CHAR(1)          DEFAULT 'Y',
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    ETL_UPDATE_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    CONSTRAINT PK_DIM_ACCOUNT PRIMARY KEY (ACCOUNT_KEY)
)
CLUSTER BY (OPENING_DATE);

COMMENT ON TABLE BANKING_DW.DIM_ACCOUNT IS 'Account dimension with SCD Type 2 tracking for status and rate changes';
