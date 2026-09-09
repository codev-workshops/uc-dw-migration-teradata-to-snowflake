-- ======================================================================
-- OBJECT : BANKING_DW.DIM_BRANCH (dimension table)
-- FILE   : ddl/tables/04_dim_branch.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the branch / location dimension with Norwegian regional
--     hierarchy (city, county, region), geo-coordinates and branch type.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.DIM_BRANCH
--   * Referenced by: BANKING_DW.DIM_ACCOUNT (BRANCH_ID),
--     BANKING_DW.FACT_TRANSACTION (BRANCH_ID),
--     BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (BRANCH_ID),
--     BANKING_DW.VW_BRANCH_PERFORMANCE,
--     BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS
--
-- KEY BUSINESS RULES
--   * BRANCH_ID is the natural/primary key; BRANCH_CODE is an alternate
--     business key (Type 1 dimension, no SCD control columns).
--   * COUNTRY_CODE defaults to 'NOR'; IS_ACTIVE defaults to 1.
--   * REGION values limited to the five Norwegian regions used for
--     compression.
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
 * DIM_BRANCH — Branch / Location Dimension
 * Teradata SET table with geographic hierarchy
 **********************************************************************/

CREATE SET TABLE BANKING_DW.DIM_BRANCH, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    BRANCH_ID           INTEGER          NOT NULL,
    BRANCH_CODE         CHAR(6)          NOT NULL,
    BRANCH_NAME         VARCHAR(100)     NOT CASESPECIFIC NOT NULL,
    BRANCH_TYPE         VARCHAR(20)      NOT CASESPECIFIC
                                         COMPRESS ('FULL_SERVICE', 'DIGITAL', 'KIOSK', 'REGIONAL_HQ'),
    ADDRESS_LINE_1      VARCHAR(100)     NOT CASESPECIFIC,
    CITY                VARCHAR(50)      NOT CASESPECIFIC,
    COUNTY              VARCHAR(50)      NOT CASESPECIFIC,
    REGION              VARCHAR(50)      NOT CASESPECIFIC
                                         COMPRESS ('OSTLANDET', 'VESTLANDET', 'SORLANDET',
                                                   'TRONDELAG', 'NORD-NORGE'),
    POSTAL_CODE         VARCHAR(10),
    COUNTRY_CODE        CHAR(3)          DEFAULT 'NOR',
    LATITUDE            DECIMAL(10,7),
    LONGITUDE           DECIMAL(10,7),
    MANAGER_ID          INTEGER,
    OPENING_DATE        DATE FORMAT 'YYYY-MM-DD',
    CLOSING_DATE        DATE FORMAT 'YYYY-MM-DD',
    IS_ACTIVE           BYTEINT          DEFAULT 1 COMPRESS (0, 1),
    EMPLOYEE_COUNT      SMALLINT         COMPRESS 0,
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP(0)     DEFAULT CURRENT_TIMESTAMP(0)
)
UNIQUE PRIMARY INDEX UPI_BRANCH_ID (BRANCH_ID)
INDEX IDX_BRANCH_CODE (BRANCH_CODE)
INDEX IDX_BRANCH_REGION (REGION);

COLLECT STATISTICS COLUMN (BRANCH_ID) ON BANKING_DW.DIM_BRANCH;
COLLECT STATISTICS COLUMN (REGION) ON BANKING_DW.DIM_BRANCH;

COMMENT ON TABLE BANKING_DW.DIM_BRANCH IS 'Branch dimension with Norwegian regional hierarchy';
