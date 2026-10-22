/**********************************************************************
 * DIM_DATE — Date Dimension (Snowflake)
 * Converted from ddl/tables/05_dim_date.sql (Teradata SET table).
 *
 * - SET table: Snowflake tables always allow duplicate rows. Uniqueness is
 *   only declared via the PRIMARY KEY below (not enforced) and must be
 *   enforced by the calendar generation/load logic.
 * - UNIQUE PRIMARY INDEX (DATE_KEY) -> declared PRIMARY KEY (not enforced).
 * - No partitioning in source; ~11k rows, so no CLUSTER BY.
 * - BYTEINT -> NUMBER(3,0); column FORMAT -> plain DATE.
 * - COMPRESS, secondary INDEXes, COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.DIM_DATE (
    DATE_KEY            INTEGER          NOT NULL,   -- YYYYMMDD format
    CALENDAR_DATE       DATE             NOT NULL,
    DAY_OF_WEEK         NUMBER(3,0)      NOT NULL,   -- 1=Monday, 7=Sunday
    DAY_NAME            VARCHAR(10)      NOT NULL,
    DAY_OF_MONTH        NUMBER(3,0)      NOT NULL,
    DAY_OF_YEAR         SMALLINT         NOT NULL,
    WEEK_OF_YEAR        NUMBER(3,0)      NOT NULL,
    ISO_WEEK            NUMBER(3,0)      NOT NULL,
    MONTH_NUM           NUMBER(3,0)      NOT NULL,
    MONTH_NAME          VARCHAR(15)      NOT NULL,
    MONTH_SHORT         CHAR(3)          NOT NULL,
    QUARTER_NUM         NUMBER(3,0)      NOT NULL,
    QUARTER_NAME        CHAR(2)          NOT NULL,    -- Q1, Q2, Q3, Q4
    HALF_YEAR           NUMBER(3,0)      NOT NULL,
    CALENDAR_YEAR       SMALLINT         NOT NULL,
    FISCAL_YEAR         SMALLINT         NOT NULL,
    FISCAL_QUARTER      NUMBER(3,0)      NOT NULL,
    IS_WEEKEND          NUMBER(3,0)      NOT NULL,
    IS_NORWEGIAN_HOLIDAY NUMBER(3,0)     DEFAULT 0,
    HOLIDAY_NAME        VARCHAR(50),
    IS_BUSINESS_DAY     NUMBER(3,0)      NOT NULL,
    IS_MONTH_END        NUMBER(3,0)      NOT NULL,
    IS_QUARTER_END      NUMBER(3,0)      NOT NULL,
    IS_YEAR_END         NUMBER(3,0)      NOT NULL,
    PRIOR_DAY_DATE      DATE,
    NEXT_DAY_DATE       DATE,
    SAME_DAY_PREV_YEAR  DATE,
    CONSTRAINT PK_DIM_DATE PRIMARY KEY (DATE_KEY)
);

COMMENT ON TABLE BANKING_DW.DIM_DATE IS 'Calendar dimension with Norwegian holidays and fiscal year alignment';
