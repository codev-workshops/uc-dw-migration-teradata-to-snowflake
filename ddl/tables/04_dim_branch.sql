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
