-- ======================================================================
-- OBJECT : BANKING_DW.DIM_DATE (dimension table)
-- FILE   : ddl/tables/05_dim_date.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Defines the pre-populated calendar dimension with ISO week, fiscal
--     year, Norwegian holiday and business-day flags, and prior/next-day
--     navigation columns.
--
-- INPUT / OUTPUT TABLES
--   * Creates: BANKING_DW.DIM_DATE
--   * Referenced by: BANKING_DW.FACT_TRANSACTION (DATE_KEY),
--     BANKING_DW.VW_BRANCH_PERFORMANCE (joined on CALENDAR_DATE =
--     SNAPSHOT_DATE)
--
-- KEY BUSINESS RULES
--   * DATE_KEY is an INTEGER smart key in YYYYMMDD format; CALENDAR_DATE
--     is the equivalent DATE.
--   * DAY_OF_WEEK uses 1=Monday ... 7=Sunday; QUARTER_NAME is Q1-Q4.
--   * IS_BUSINESS_DAY, IS_WEEKEND, IS_MONTH_END, IS_QUARTER_END,
--     IS_YEAR_END are mandatory BYTEINT flags; IS_NORWEGIAN_HOLIDAY
--     defaults to 0.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * CREATE SET TABLE
--   * NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM =
--     DEFAULT, DEFAULT MERGEBLOCKRATIO table options
--   * FORMAT 'YYYY-MM-DD' on DATE columns; BYTEINT data type
--   * COMPRESS value lists / COMPRESS ''
--   * UNIQUE PRIMARY INDEX plus secondary (composite) INDEX definitions
--   * COLLECT STATISTICS; COMMENT ON TABLE
-- ======================================================================

/**********************************************************************
 * DIM_DATE — Date Dimension
 * Pre-populated calendar table with Norwegian business day flags
 **********************************************************************/

CREATE SET TABLE BANKING_DW.DIM_DATE, NO FALLBACK,
     NO BEFORE JOURNAL,
     NO AFTER JOURNAL,
     CHECKSUM = DEFAULT,
     DEFAULT MERGEBLOCKRATIO
(
    DATE_KEY            INTEGER          NOT NULL,   -- YYYYMMDD format
    CALENDAR_DATE       DATE FORMAT 'YYYY-MM-DD' NOT NULL,
    DAY_OF_WEEK         BYTEINT          NOT NULL,   -- 1=Monday, 7=Sunday
    DAY_NAME            VARCHAR(10)      NOT NULL,
    DAY_OF_MONTH        BYTEINT          NOT NULL,
    DAY_OF_YEAR         SMALLINT         NOT NULL,
    WEEK_OF_YEAR        BYTEINT          NOT NULL,
    ISO_WEEK            BYTEINT          NOT NULL,
    MONTH_NUM           BYTEINT          NOT NULL,
    MONTH_NAME          VARCHAR(15)      NOT NULL,
    MONTH_SHORT         CHAR(3)          NOT NULL,
    QUARTER_NUM         BYTEINT          NOT NULL COMPRESS (1, 2, 3, 4),
    QUARTER_NAME        CHAR(2)          NOT NULL,    -- Q1, Q2, Q3, Q4
    HALF_YEAR           BYTEINT          NOT NULL COMPRESS (1, 2),
    CALENDAR_YEAR       SMALLINT         NOT NULL,
    FISCAL_YEAR         SMALLINT         NOT NULL,
    FISCAL_QUARTER      BYTEINT          NOT NULL,
    IS_WEEKEND          BYTEINT          NOT NULL COMPRESS (0, 1),
    IS_NORWEGIAN_HOLIDAY BYTEINT         DEFAULT 0 COMPRESS (0, 1),
    HOLIDAY_NAME        VARCHAR(50)      COMPRESS '',
    IS_BUSINESS_DAY     BYTEINT          NOT NULL COMPRESS (0, 1),
    IS_MONTH_END        BYTEINT          NOT NULL COMPRESS (0, 1),
    IS_QUARTER_END      BYTEINT          NOT NULL COMPRESS (0, 1),
    IS_YEAR_END         BYTEINT          NOT NULL COMPRESS (0, 1),
    PRIOR_DAY_DATE      DATE FORMAT 'YYYY-MM-DD',
    NEXT_DAY_DATE       DATE FORMAT 'YYYY-MM-DD',
    SAME_DAY_PREV_YEAR  DATE FORMAT 'YYYY-MM-DD'
)
UNIQUE PRIMARY INDEX UPI_DATE_KEY (DATE_KEY)
INDEX IDX_CALENDAR_DATE (CALENDAR_DATE)
INDEX IDX_YEAR_MONTH (CALENDAR_YEAR, MONTH_NUM);

COLLECT STATISTICS COLUMN (DATE_KEY) ON BANKING_DW.DIM_DATE;
COLLECT STATISTICS COLUMN (CALENDAR_YEAR) ON BANKING_DW.DIM_DATE;
COLLECT STATISTICS COLUMN (IS_BUSINESS_DAY) ON BANKING_DW.DIM_DATE;

COMMENT ON TABLE BANKING_DW.DIM_DATE IS 'Calendar dimension with Norwegian holidays and fiscal year alignment';
