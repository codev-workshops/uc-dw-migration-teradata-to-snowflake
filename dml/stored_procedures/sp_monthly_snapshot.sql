-- ======================================================================
-- OBJECT : BANKING_DW.SP_MONTHLY_SNAPSHOT (stored procedure)
-- FILE   : dml/stored_procedures/sp_monthly_snapshot.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Builds the month-end account snapshot for a given year/month by
--     aggregating transactions into a volatile table and merging results
--     into the snapshot fact.
--
-- INPUT / OUTPUT TABLES
--   * Reads: BANKING_DW.FACT_TRANSACTION, BANKING_DW.DIM_ACCOUNT,
--     BANKING_DW.DIM_CUSTOMER, BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT
--     (prior month row)
--   * Writes: BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT (MERGE
--     insert/update); session-scoped VT_TXN_AGGREGATES volatile table
--     (created and dropped)
--   * Parameters: IN p_snapshot_year, p_snapshot_month, p_batch_id; OUT
--     p_rows_merged, p_return_code
--
-- KEY BUSINESS RULES
--   * Period = first to last day of the month; SNAPSHOT_DATE = month-
--     end; SNAPSHOT_MONTH_KEY = year*100 + month; prior snapshot looked
--     up one month back.
--   * TOTAL_DEBITS / DEBIT_COUNT from DEBIT and FEE types (absolute
--     amounts); TOTAL_CREDITS / CREDIT_COUNT from CREDIT and INTEREST
--     types.
--   * INTEREST_EARNED = positive INTEREST amounts; INTEREST_CHARGED =
--     negative INTEREST amounts; FEES_CHARGED = FEE amounts.
--   * DAYS_IN_OVERDRAFT = count of transactions with negative
--     RUNNING_BALANCE; MIN/MAX/AVG balance from RUNNING_BALANCE.
--   * OPENING_BALANCE = prior month CLOSING_BALANCE (0 if none);
--     CLOSING_BALANCE = opening + credits - debits.
--   * Only current (CURRENT_FLAG='Y') accounts with ACCOUNT_STATUS in
--     ('ACTIVE','DORMANT'); accounts with no activity get DAYS_DORMANT =
--     days in period.
--   * Existing (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY) rows are updated,
--     otherwise inserted; p_rows_merged from ACTIVITY_COUNT.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * REPLACE PROCEDURE with IN/OUT parameters
--   * CREATE VOLATILE TABLE ... WITH DATA PRIMARY INDEX ON COMMIT
--     PRESERVE ROWS
--   * MERGE INTO ... WHEN MATCHED / WHEN NOT MATCHED
--   * SEL shorthand for SELECT
--   * ZEROIFNULL; ADD_MONTHS; date arithmetic
--   * Inline FORMAT expressions (FORMAT '9999', FORMAT '99') and
--     Teradata inline casts (SMALLINT)
--   * ACTIVITY_COUNT
--   * COLLECT STATISTICS inside procedure
-- ======================================================================

/**********************************************************************
 * SP_MONTHLY_SNAPSHOT
 * Calculates month-end account snapshots from transaction data
 * Uses Teradata OLAP functions, volatile tables, and MERGE
 **********************************************************************/

REPLACE PROCEDURE BANKING_DW.SP_MONTHLY_SNAPSHOT(
    IN p_snapshot_year   INTEGER,
    IN p_snapshot_month  INTEGER,
    IN p_batch_id        BIGINT,
    OUT p_rows_merged    INTEGER,
    OUT p_return_code    INTEGER
)
BEGIN
    DECLARE v_snapshot_date DATE;
    DECLARE v_period_start DATE;
    DECLARE v_period_end DATE;
    DECLARE v_prev_snapshot_date DATE;
    DECLARE v_snapshot_month_key INTEGER;

    SET p_return_code = 0;
    SET p_rows_merged = 0;

    -- Calculate period boundaries
    SET v_period_start = CAST(
        TRIM(p_snapshot_year (FORMAT '9999')) || '-' ||
        TRIM(p_snapshot_month (FORMAT '99')) || '-01' AS DATE FORMAT 'YYYY-MM-DD');
    SET v_period_end = ADD_MONTHS(v_period_start, 1) - 1;
    SET v_snapshot_date = v_period_end;
    SET v_snapshot_month_key = (p_snapshot_year * 100) + p_snapshot_month;
    SET v_prev_snapshot_date = ADD_MONTHS(v_period_start, -1);

    -- Create volatile table for aggregated transaction data
    CREATE VOLATILE TABLE VT_TXN_AGGREGATES AS (
        SEL
            ft.ACCOUNT_KEY,
            SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('DEBIT', 'FEE')
                     THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS TOTAL_DEBITS,
            SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('CREDIT', 'INTEREST')
                     THEN ft.TRANSACTION_AMOUNT ELSE 0 END) AS TOTAL_CREDITS,
            SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('DEBIT', 'FEE') THEN 1 ELSE 0 END) AS DEBIT_COUNT,
            SUM(CASE WHEN ft.TRANSACTION_TYPE IN ('CREDIT', 'INTEREST') THEN 1 ELSE 0 END) AS CREDIT_COUNT,
            SUM(CASE WHEN ft.TRANSACTION_TYPE = 'INTEREST' AND ft.TRANSACTION_AMOUNT > 0
                     THEN ft.TRANSACTION_AMOUNT ELSE 0 END) AS INTEREST_EARNED,
            SUM(CASE WHEN ft.TRANSACTION_TYPE = 'INTEREST' AND ft.TRANSACTION_AMOUNT < 0
                     THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS INTEREST_CHARGED,
            SUM(CASE WHEN ft.TRANSACTION_TYPE = 'FEE'
                     THEN ABS(ft.TRANSACTION_AMOUNT) ELSE 0 END) AS FEES_CHARGED,
            MIN(ft.RUNNING_BALANCE) AS MIN_BALANCE,
            MAX(ft.RUNNING_BALANCE) AS MAX_BALANCE,
            AVG(ft.RUNNING_BALANCE) AS AVG_BALANCE,
            SUM(CASE WHEN ft.RUNNING_BALANCE < 0 THEN 1 ELSE 0 END) AS OVERDRAFT_DAYS
        FROM BANKING_DW.FACT_TRANSACTION ft
        WHERE ft.TRANSACTION_DATE BETWEEN v_period_start AND v_period_end
        GROUP BY ft.ACCOUNT_KEY
    ) WITH DATA
    PRIMARY INDEX (ACCOUNT_KEY)
    ON COMMIT PRESERVE ROWS;

    -- Merge into snapshot table
    MERGE INTO BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT tgt
    USING (
        SEL
            v_snapshot_date AS SNAPSHOT_DATE,
            v_snapshot_month_key AS SNAPSHOT_MONTH_KEY,
            a.ACCOUNT_KEY,
            a.CUSTOMER_KEY,
            a.PRODUCT_ID,
            a.BRANCH_ID,
            ZEROIFNULL(prev.CLOSING_BALANCE) AS OPENING_BALANCE,
            ZEROIFNULL(prev.CLOSING_BALANCE)
                + ZEROIFNULL(agg.TOTAL_CREDITS)
                - ZEROIFNULL(agg.TOTAL_DEBITS) AS CLOSING_BALANCE,
            ZEROIFNULL(agg.AVG_BALANCE) AS AVERAGE_BALANCE,
            ZEROIFNULL(agg.MIN_BALANCE) AS MINIMUM_BALANCE,
            ZEROIFNULL(agg.MAX_BALANCE) AS MAXIMUM_BALANCE,
            ZEROIFNULL(agg.TOTAL_DEBITS) AS TOTAL_DEBITS,
            ZEROIFNULL(agg.TOTAL_CREDITS) AS TOTAL_CREDITS,
            ZEROIFNULL(agg.DEBIT_COUNT) AS DEBIT_COUNT,
            ZEROIFNULL(agg.CREDIT_COUNT) AS CREDIT_COUNT,
            ZEROIFNULL(agg.INTEREST_EARNED) AS INTEREST_EARNED,
            ZEROIFNULL(agg.INTEREST_CHARGED) AS INTEREST_CHARGED,
            ZEROIFNULL(agg.FEES_CHARGED) AS FEES_CHARGED,
            ZEROIFNULL(agg.OVERDRAFT_DAYS) (SMALLINT) AS DAYS_IN_OVERDRAFT,
            CASE WHEN agg.ACCOUNT_KEY IS NULL
                 THEN (v_period_end - v_period_start + 1) (SMALLINT)
                 ELSE 0 (SMALLINT)
            END AS DAYS_DORMANT,
            a.CURRENCY_CODE,
            p_batch_id AS ETL_BATCH_ID
        FROM BANKING_DW.DIM_ACCOUNT a
        LEFT JOIN BANKING_DW.DIM_CUSTOMER c
            ON a.CUSTOMER_ID = c.CUSTOMER_ID
           AND c.CURRENT_FLAG = 'Y'
        LEFT JOIN VT_TXN_AGGREGATES agg
            ON a.ACCOUNT_KEY = agg.ACCOUNT_KEY
        LEFT JOIN BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT prev
            ON a.ACCOUNT_KEY = prev.ACCOUNT_KEY
           AND prev.SNAPSHOT_DATE = v_prev_snapshot_date
        WHERE a.CURRENT_FLAG = 'Y'
          AND a.ACCOUNT_STATUS IN ('ACTIVE', 'DORMANT')
    ) src
    ON tgt.ACCOUNT_KEY = src.ACCOUNT_KEY
       AND tgt.SNAPSHOT_MONTH_KEY = src.SNAPSHOT_MONTH_KEY
    WHEN MATCHED THEN UPDATE SET
        OPENING_BALANCE = src.OPENING_BALANCE,
        CLOSING_BALANCE = src.CLOSING_BALANCE,
        AVERAGE_BALANCE = src.AVERAGE_BALANCE,
        MINIMUM_BALANCE = src.MINIMUM_BALANCE,
        MAXIMUM_BALANCE = src.MAXIMUM_BALANCE,
        TOTAL_DEBITS = src.TOTAL_DEBITS,
        TOTAL_CREDITS = src.TOTAL_CREDITS,
        DEBIT_COUNT = src.DEBIT_COUNT,
        CREDIT_COUNT = src.CREDIT_COUNT,
        INTEREST_EARNED = src.INTEREST_EARNED,
        INTEREST_CHARGED = src.INTEREST_CHARGED,
        FEES_CHARGED = src.FEES_CHARGED,
        DAYS_IN_OVERDRAFT = src.DAYS_IN_OVERDRAFT,
        DAYS_DORMANT = src.DAYS_DORMANT,
        ETL_BATCH_ID = src.ETL_BATCH_ID,
        ETL_INSERT_TS = CURRENT_TIMESTAMP(0)
    WHEN NOT MATCHED THEN INSERT (
        SNAPSHOT_DATE, SNAPSHOT_MONTH_KEY, ACCOUNT_KEY, CUSTOMER_KEY,
        PRODUCT_ID, BRANCH_ID, OPENING_BALANCE, CLOSING_BALANCE,
        AVERAGE_BALANCE, MINIMUM_BALANCE, MAXIMUM_BALANCE,
        TOTAL_DEBITS, TOTAL_CREDITS, DEBIT_COUNT, CREDIT_COUNT,
        INTEREST_EARNED, INTEREST_CHARGED, FEES_CHARGED,
        DAYS_IN_OVERDRAFT, DAYS_DORMANT, CURRENCY_CODE,
        ETL_BATCH_ID, ETL_INSERT_TS
    ) VALUES (
        src.SNAPSHOT_DATE, src.SNAPSHOT_MONTH_KEY, src.ACCOUNT_KEY, src.CUSTOMER_KEY,
        src.PRODUCT_ID, src.BRANCH_ID, src.OPENING_BALANCE, src.CLOSING_BALANCE,
        src.AVERAGE_BALANCE, src.MINIMUM_BALANCE, src.MAXIMUM_BALANCE,
        src.TOTAL_DEBITS, src.TOTAL_CREDITS, src.DEBIT_COUNT, src.CREDIT_COUNT,
        src.INTEREST_EARNED, src.INTEREST_CHARGED, src.FEES_CHARGED,
        src.DAYS_IN_OVERDRAFT, src.DAYS_DORMANT, src.CURRENCY_CODE,
        src.ETL_BATCH_ID, CURRENT_TIMESTAMP(0)
    );

    SET p_rows_merged = ACTIVITY_COUNT;

    -- Clean up volatile table
    DROP TABLE VT_TXN_AGGREGATES;

    -- Collect stats
    COLLECT STATISTICS COLUMN (SNAPSHOT_MONTH_KEY) ON BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT;

END;
