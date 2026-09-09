-- ======================================================================
-- OBJECT : BANKING_DW.DIM_CUSTOMER (dimension table)
-- FILE   : ddl/tables/01_dim_customer.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the SCD Type 2 customer dimension holding demographics,
--     address, segmentation, risk score, credit rating and KYC status.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.DIM_CUSTOMER
--   * Referenced by: BANKING_DW.FACT_TRANSACTION (CUSTOMER_KEY),
--     BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (CUSTOMER_KEY),
--     BANKING_DW.DIM_ACCOUNT (CUSTOMER_ID natural key)
--   * Loaded by: BANKING_DW.SP_CUSTOMER_SCD2 from
--     BANKING_DW.STG_CUSTOMER
--
-- KEY BUSINESS RULES
--   * CUSTOMER_KEY is the identity surrogate key (one per customer
--     version); CUSTOMER_ID is the natural key from the source system.
--   * SCD Type 2 control columns: EFFECTIVE_FROM, EFFECTIVE_TO (default
--     '9999-12-31 23:59:59'), CURRENT_FLAG (default 'Y'). Only
--     CURRENT_FLAG='Y' rows are the active version.
--   * COUNTRY_CODE defaults to 'NOR'; KYC_STATUS defaults to 'PENDING';
--     IS_ACTIVE defaults to 1.
--   * Partitioned by ONBOARDING_DATE in yearly ranges (2000-2030).
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE SET TABLE (duplicate rows rejected)
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1) on
--     CUSTOMER_KEY
--   * NOT CASESPECIFIC on VARCHAR/CHAR columns
--   * FORMAT 'YYYY-MM-DD' on DATE columns
--   * COMPRESS value lists (multi-value compression)
--   * UNIQUE PRIMARY INDEX plus secondary INDEX definitions
--   * PARTITION BY RANGE_N (partitioned primary index, PPI)
--   * COLLECT STATISTICS; COMMENT ON TABLE / COLUMN
-- ======================================================================

/**********************************************************************
 * DIM_CUSTOMER — Customer Dimension
 * Teradata SET table with primary index on CUSTOMER_ID
 * Includes COMPRESS, FORMAT, and CASESPECIFIC features
 **********************************************************************/

CREATE SET TABLE BANKING_DW.DIM_CUSTOMER, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    CUSTOMER_ID         INTEGER          NOT NULL,
    CUSTOMER_KEY        BIGINT           NOT NULL GENERATED ALWAYS AS IDENTITY
                                         (START WITH 1 INCREMENT BY 1),
    FIRST_NAME          VARCHAR(50)      NOT CASESPECIFIC NOT NULL,
    LAST_NAME           VARCHAR(50)      NOT CASESPECIFIC NOT NULL,
    DATE_OF_BIRTH       DATE FORMAT 'YYYY-MM-DD',
    GENDER              CHAR(1)          COMPRESS ('M', 'F', 'O'),
    MARITAL_STATUS      CHAR(1)          COMPRESS ('S', 'M', 'D', 'W'),
    EMAIL_ADDRESS       VARCHAR(100)     NOT CASESPECIFIC,
    PHONE_NUMBER        VARCHAR(20),
    ADDRESS_LINE_1      VARCHAR(100)     NOT CASESPECIFIC,
    ADDRESS_LINE_2      VARCHAR(100)     NOT CASESPECIFIC COMPRESS '',
    CITY                VARCHAR(50)      NOT CASESPECIFIC,
    STATE_PROVINCE      VARCHAR(50)      NOT CASESPECIFIC,
    POSTAL_CODE         VARCHAR(10),
    COUNTRY_CODE        CHAR(3)          NOT CASESPECIFIC DEFAULT 'NOR',
    CUSTOMER_SEGMENT    VARCHAR(20)      NOT CASESPECIFIC
                                         COMPRESS ('RETAIL', 'PREMIUM', 'PRIVATE', 'CORPORATE'),
    RISK_SCORE          DECIMAL(5,2),
    CREDIT_RATING       CHAR(3)          COMPRESS ('AAA', 'AA', 'A', 'BBB', 'BB', 'B', 'CCC'),
    KYC_STATUS          VARCHAR(15)      NOT CASESPECIFIC DEFAULT 'PENDING'
                                         COMPRESS ('VERIFIED', 'PENDING', 'REVIEW', 'EXPIRED'),
    ONBOARDING_DATE     DATE FORMAT 'YYYY-MM-DD' NOT NULL,
    LAST_REVIEW_DATE    DATE FORMAT 'YYYY-MM-DD',
    IS_ACTIVE           BYTEINT          DEFAULT 1 COMPRESS (0, 1),
    EFFECTIVE_FROM      TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0),
    EFFECTIVE_TO        TIMESTAMP(0)     DEFAULT TIMESTAMP '9999-12-31 23:59:59',
    CURRENT_FLAG        CHAR(1)          DEFAULT 'Y' COMPRESS ('Y', 'N'),
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0),
    ETL_UPDATE_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
UNIQUE PRIMARY INDEX UPI_CUSTOMER_KEY (CUSTOMER_KEY)
INDEX NUPI_CUSTOMER_ID (CUSTOMER_ID)
INDEX IDX_CUST_SEGMENT (CUSTOMER_SEGMENT)
INDEX IDX_CUST_COUNTRY (COUNTRY_CODE)
PARTITION BY RANGE_N(ONBOARDING_DATE BETWEEN DATE '2000-01-01'
                                     AND     DATE '2030-12-31'
                                     EACH INTERVAL '1' YEAR);

COLLECT STATISTICS COLUMN (CUSTOMER_ID) ON BANKING_DW.DIM_CUSTOMER;
COLLECT STATISTICS COLUMN (CUSTOMER_SEGMENT) ON BANKING_DW.DIM_CUSTOMER;
COLLECT STATISTICS COLUMN (COUNTRY_CODE) ON BANKING_DW.DIM_CUSTOMER;
COLLECT STATISTICS COLUMN (IS_ACTIVE) ON BANKING_DW.DIM_CUSTOMER;

COMMENT ON TABLE BANKING_DW.DIM_CUSTOMER IS 'SCD Type 2 customer dimension with KYC and risk attributes';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.CUSTOMER_KEY IS 'Surrogate key for SCD Type 2';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.CUSTOMER_ID IS 'Natural key from source system';
COMMENT ON COLUMN BANKING_DW.DIM_CUSTOMER.KYC_STATUS IS 'Know Your Customer verification status';
