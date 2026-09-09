-- ======================================================================
-- OBJECT : BANKING_DW.DIM_PRODUCT (dimension table)
-- FILE   : ddl/tables/03_dim_product.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the banking product catalog dimension (deposits, lending,
--     cards, investment, insurance, payments) with rates, balance limits
--     and fee structure.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.DIM_PRODUCT
--   * Referenced by: BANKING_DW.DIM_ACCOUNT (PRODUCT_ID),
--     BANKING_DW.FACT_TRANSACTION (PRODUCT_ID),
--     BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (PRODUCT_ID)
--
-- KEY BUSINESS RULES
--   * PRODUCT_ID is the natural/primary key (no surrogate, not SCD Type
--     2 - Type 1 overwrite dimension).
--   * IS_REGULATED and IS_ACTIVE default to 1; MIN_BALANCE and
--     MONTHLY_FEE default to 0.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE SET TABLE
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * NOT CASESPECIFIC; FORMAT 'YYYY-MM-DD'; COMPRESS value lists /
--     COMPRESS 0
--   * UNIQUE PRIMARY INDEX plus secondary INDEX definitions
--   * COLLECT STATISTICS; COMMENT ON TABLE
-- ======================================================================

/**********************************************************************
 * DIM_PRODUCT — Banking Product Dimension
 * Teradata SET table with single-column primary index
 **********************************************************************/

CREATE SET TABLE BANKING_DW.DIM_PRODUCT, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    PRODUCT_ID          INTEGER          NOT NULL,
    PRODUCT_CODE        VARCHAR(20)      NOT NULL,
    PRODUCT_NAME        VARCHAR(100)     NOT CASESPECIFIC NOT NULL,
    PRODUCT_CATEGORY    VARCHAR(30)      NOT CASESPECIFIC NOT NULL
                                         COMPRESS ('DEPOSITS', 'LENDING', 'CARDS', 'INVESTMENT',
                                                   'INSURANCE', 'PAYMENTS'),
    PRODUCT_SUBCATEGORY VARCHAR(50)      NOT CASESPECIFIC,
    BASE_INTEREST_RATE  DECIMAL(7,4),
    MIN_BALANCE         DECIMAL(15,2)    DEFAULT 0,
    MAX_BALANCE         DECIMAL(15,2),
    FEE_STRUCTURE       VARCHAR(20)      COMPRESS ('FIXED', 'TIERED', 'NONE', 'PERCENTAGE'),
    MONTHLY_FEE         DECIMAL(10,2)    DEFAULT 0 COMPRESS 0,
    IS_REGULATED        BYTEINT          DEFAULT 1 COMPRESS (0, 1),
    REGULATORY_CODE     VARCHAR(20),
    LAUNCH_DATE         DATE FORMAT 'YYYY-MM-DD',
    DISCONTINUE_DATE    DATE FORMAT 'YYYY-MM-DD',
    IS_ACTIVE           BYTEINT          DEFAULT 1 COMPRESS (0, 1),
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
UNIQUE PRIMARY INDEX UPI_PRODUCT_ID (PRODUCT_ID)
INDEX IDX_PROD_CODE (PRODUCT_CODE)
INDEX IDX_PROD_CATEGORY (PRODUCT_CATEGORY);

COLLECT STATISTICS COLUMN (PRODUCT_ID) ON BANKING_DW.DIM_PRODUCT;
COLLECT STATISTICS COLUMN (PRODUCT_CATEGORY) ON BANKING_DW.DIM_PRODUCT;

COMMENT ON TABLE BANKING_DW.DIM_PRODUCT IS 'Banking product catalog dimension';
