/**********************************************************************
 * DIM_BRANCH — Branch / Location Dimension (Snowflake)
 * Converted from ddl/tables/04_dim_branch.sql (Teradata SET table).
 *
 * - SET table: Snowflake tables always allow duplicate rows. Uniqueness is
 *   only declared via the PRIMARY KEY below (not enforced) and must be
 *   enforced by the load/dedup logic.
 * - UNIQUE PRIMARY INDEX (BRANCH_ID) -> declared PRIMARY KEY (not enforced).
 * - No partitioning in source; small table, so no CLUSTER BY.
 * - NOT CASESPECIFIC -> COLLATE 'en-ci'; BYTEINT -> NUMBER(3,0).
 * - COMPRESS, column FORMAT, secondary INDEXes, COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.DIM_BRANCH (
    BRANCH_ID           INTEGER          NOT NULL,
    BRANCH_CODE         CHAR(6)          NOT NULL,
    BRANCH_NAME         VARCHAR(100)     COLLATE 'en-ci' NOT NULL,
    BRANCH_TYPE         VARCHAR(20)      COLLATE 'en-ci',
    ADDRESS_LINE_1      VARCHAR(100)     COLLATE 'en-ci',
    CITY                VARCHAR(50)      COLLATE 'en-ci',
    COUNTY              VARCHAR(50)      COLLATE 'en-ci',
    REGION              VARCHAR(50)      COLLATE 'en-ci',
    POSTAL_CODE         VARCHAR(10),
    COUNTRY_CODE        CHAR(3)          DEFAULT 'NOR',
    LATITUDE            DECIMAL(10,7),
    LONGITUDE           DECIMAL(10,7),
    MANAGER_ID          INTEGER,
    OPENING_DATE        DATE,
    CLOSING_DATE        DATE,
    IS_ACTIVE           NUMBER(3,0)      DEFAULT 1,
    EMPLOYEE_COUNT      SMALLINT,
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    CONSTRAINT PK_DIM_BRANCH PRIMARY KEY (BRANCH_ID)
);

COMMENT ON TABLE BANKING_DW.DIM_BRANCH IS 'Branch dimension with Norwegian regional hierarchy';
