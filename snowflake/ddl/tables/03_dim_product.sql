/**********************************************************************
 * DIM_PRODUCT — Banking Product Dimension (Snowflake)
 * Converted from ddl/tables/03_dim_product.sql (Teradata SET table).
 *
 * - SET table: Snowflake tables always allow duplicate rows. Uniqueness is
 *   only declared via the PRIMARY KEY below (not enforced) and must be
 *   enforced by the load/dedup logic.
 * - UNIQUE PRIMARY INDEX (PRODUCT_ID) -> declared PRIMARY KEY (not enforced).
 * - No partitioning in source; small table, so no CLUSTER BY (micro-partition
 *   pruning is sufficient).
 * - NOT CASESPECIFIC -> COLLATE 'en-ci'; BYTEINT -> NUMBER(3,0).
 * - COMPRESS, column FORMAT, secondary INDEXes, COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE TABLE BANKING_DW.DIM_PRODUCT (
    PRODUCT_ID          INTEGER          NOT NULL,
    PRODUCT_CODE        VARCHAR(20)      NOT NULL,
    PRODUCT_NAME        VARCHAR(100)     COLLATE 'en-ci' NOT NULL,
    PRODUCT_CATEGORY    VARCHAR(30)      COLLATE 'en-ci' NOT NULL,
    PRODUCT_SUBCATEGORY VARCHAR(50)      COLLATE 'en-ci',
    BASE_INTEREST_RATE  DECIMAL(7,4),
    MIN_BALANCE         DECIMAL(15,2)    DEFAULT 0,
    MAX_BALANCE         DECIMAL(15,2),
    FEE_STRUCTURE       VARCHAR(20),
    MONTHLY_FEE         DECIMAL(10,2)    DEFAULT 0,
    IS_REGULATED        NUMBER(3,0)      DEFAULT 1,
    REGULATORY_CODE     VARCHAR(20),
    LAUNCH_DATE         DATE,
    DISCONTINUE_DATE    DATE,
    IS_ACTIVE           NUMBER(3,0)      DEFAULT 1,
    ETL_BATCH_ID        BIGINT,
    ETL_INSERT_TS       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
    CONSTRAINT PK_DIM_PRODUCT PRIMARY KEY (PRODUCT_ID)
);

COMMENT ON TABLE BANKING_DW.DIM_PRODUCT IS 'Banking product catalog dimension';
