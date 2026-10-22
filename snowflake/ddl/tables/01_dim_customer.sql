/**********************************************************************
 * DIM_CUSTOMER — Customer Dimension (Snowflake)
 * Converted from ddl/tables/01_dim_customer.sql (Teradata SET table).
 *
 * - SET table: Snowflake tables always allow duplicate rows. Uniqueness is
 *   only declared via the PRIMARY KEY below (not enforced) and must be
 *   enforced by the load/dedup logic (SP_CUSTOMER_SCD2).
 * - UNIQUE PRIMARY INDEX (CUSTOMER_KEY) -> declared PRIMARY KEY (not enforced).
 * - PARTITION BY RANGE_N(ONBOARDING_DATE ...) -> CLUSTER BY (ONBOARDING_DATE).
 * - NOT CASESPECIFIC -> COLLATE 'en-ci' (case-insensitive comparisons).
 * - COMPRESS, column FORMAT, secondary INDEXes, COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.DIM_CUSTOMER (
    CUSTOMER_ID         INTEGER          NOT NULL,
    CUSTOMER_KEY        BIGINT           NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
    FIRST_NAME          VARCHAR(50)      COLLATE 'en-ci' NOT NULL,
    LAST_NAME           VARCHAR(50)      COLLATE 'en-ci' NOT NULL,
    DATE_OF_BIRTH       DATE,
    GENDER              CHAR(1),
    MARITAL_STATUS      CHAR(1),
    EMAIL_ADDRESS       VARCHAR(100)     COLLATE 'en-ci',
    PHONE_NUMBER        VARCHAR(20),
    ADDRESS_LINE_1      VARCHAR(100)     COLLATE 'en-ci',
    ADDRESS_LINE_2      VARCHAR(100)     COLLATE 'en-ci',
    CITY                VARCHAR(50)      COLLATE 'en-ci',
    STATE_PROVINCE      VARCHAR(50)      COLLATE 'en-ci',
    POSTAL_CODE         VARCHAR(10),
    COUNTRY_CODE        CHAR(3)          COLLATE 'en-ci' DEFAULT 'NOR',
    CUSTOMER_SEGMENT    VARCHAR(20)      COLLATE 'en-ci',
    RISK_SCORE          DECIMAL(5,2),
    CREDIT_RATING       CHAR(3),
    KYC_STATUS          VARCHAR(15)      COLLATE 'en-ci' DEFAULT 'PENDING',
    ONBOARDING_DATE     DATE             NOT NULL,
    LAST_REVIEW_DATE    DATE,
    IS_ACTIVE           NUMBER(3,0)      DEFAULT 1,
    EFFECTIVE_FROM      TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    EFFECTIVE_TO        TIMESTAMP_NTZ(0) DEFAULT TIMESTAMP '9999-12-31 23:59:59',
    CURRENT_FLAG        CHAR(1)          DEFAULT 'Y',
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    ETL_UPDATE_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    CONSTRAINT PK_DIM_CUSTOMER PRIMARY KEY (CUSTOMER_KEY)
)
CLUSTER BY (ONBOARDING_DATE);

COMMENT ON TABLE BANKING_DW.DIM_CUSTOMER IS 'SCD Type 2 customer dimension with KYC and risk attributes';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.CUSTOMER_KEY IS 'Surrogate key for SCD Type 2';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.CUSTOMER_ID IS 'Natural key from source system';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.KYC_STATUS IS 'Know Your Customer verification status';
