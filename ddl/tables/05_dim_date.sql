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
