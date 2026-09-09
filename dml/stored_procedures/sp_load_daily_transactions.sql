-- ======================================================================
-- OBJECT : BANKING_DW.SP_LOAD_DAILY_TRANSACTIONS (stored procedure)
-- FILE   : dml/stored_procedures/sp_load_daily_transactions.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Loads one batch date of staged transactions into the transaction
--     fact table, rejecting rows for unknown accounts, converting
--     amounts to NOK and logging progress/errors.
--
-- INPUT / OUTPUT TABLES
--   * Reads: BANKING_DW.STG_TRANSACTIONS, BANKING_DW.DIM_ACCOUNT,
--     BANKING_DW.DIM_CUSTOMER, BANKING_DW.DIM_EXCHANGE_RATES
--   * Writes: BANKING_DW.FACT_TRANSACTION (insert),
--     BANKING_DW.STG_TRANSACTION_ERRORS (insert rejects),
--     BANKING_DW.ETL_LOG (insert start/complete/error rows)
--   * Parameters: IN p_batch_date, IN p_batch_id; OUT p_rows_inserted,
--     p_rows_rejected, p_return_code
--
-- KEY BUSINESS RULES
--   * Rejects staged transactions (LOAD_DATE = p_batch_date) whose
--     ACCOUNT_ID has no current (CURRENT_FLAG='Y') match in DIM_ACCOUNT
--     into STG_TRANSACTION_ERRORS with ERROR_REASON='INVALID_ACCOUNT'.
--   * Valid rows are joined to the current DIM_ACCOUNT and DIM_CUSTOMER
--     versions to resolve ACCOUNT_KEY, CUSTOMER_KEY, PRODUCT_ID and
--     BRANCH_ID.
--   * Non-NOK amounts are converted to NOK base currency via
--     DIM_EXCHANGE_RATES (FROM_CURRENCY -> 'NOK' on TRANSACTION_DATE); a
--     missing rate yields ZEROIFNULL -> 0 amount/rate.
--   * IS_INTERNATIONAL = 1 when CURRENCY_CODE <> 'NOK', else 0.
--   * DATE_KEY derived as INTEGER YYYYMMDD; TRANSACTION_TS built from
--     date + time.
--   * Row counts captured via ACTIVITY_COUNT; INFO rows written to
--     ETL_LOG at start and completion (with duration), ERROR row with
--     SQLCODE on exception.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * REPLACE PROCEDURE with IN/OUT parameters; DATE FORMAT 'YYYY-MM-DD'
--     parameter type
--   * DECLARE EXIT HANDLER FOR SQLEXCEPTION; SQLCODE
--   * ACTIVITY_COUNT
--   * SEL shorthand for SELECT
--   * ZEROIFNULL
--   * Inline FORMAT expressions (FORMAT '-999999', FORMAT 'Z(9)9', DATE
--     FORMAT 'YYYYMMDD')
--   * Teradata type casts: (TIMESTAMP(6)), INTERVAL HOUR TO SECOND
--     arithmetic, SECOND(4)
--   * COLLECT STATISTICS inside procedure
-- ======================================================================

/**********************************************************************
 * SP_LOAD_DAILY_TRANSACTIONS
 * Loads daily transaction data from staging to fact table
 * Uses Teradata-specific MERGE, ACTIVITY_COUNT, and error handling
 **********************************************************************/

REPLACE PROCEDURE BANKING_DW.SP_LOAD_DAILY_TRANSACTIONS(
    IN p_batch_date DATE FORMAT 'YYYY-MM-DD',
    IN p_batch_id   BIGINT,
    OUT p_rows_inserted INTEGER,
    OUT p_rows_rejected INTEGER,
    OUT p_return_code INTEGER
)
BEGIN
    DECLARE v_activity_count INTEGER;
    DECLARE v_error_count INTEGER DEFAULT 0;
    DECLARE v_start_ts TIMESTAMP(0);
    DECLARE v_sql_code INTEGER;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET p_return_code = SQLCODE;
        INSERT INTO BANKING_DW.ETL_LOG (
            PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
        ) VALUES (
            'SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'ERROR',
            'SQLCODE: ' || TRIM(p_return_code (FORMAT '-999999')) ||
            ' at ' || CAST(CURRENT_TIMESTAMP(0) AS VARCHAR(26)),
            CURRENT_TIMESTAMP(0)
        );
    END;

    SET v_start_ts = CURRENT_TIMESTAMP(0);
    SET p_rows_inserted = 0;
    SET p_rows_rejected = 0;
    SET p_return_code = 0;

    -- Log start
    INSERT INTO BANKING_DW.ETL_LOG (
        PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
    ) VALUES (
        'SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'INFO',
        'Started loading transactions for date: ' || CAST(p_batch_date AS VARCHAR(10)),
        v_start_ts
    );

    -- Reject bad records to error table
    INSERT INTO BANKING_DW.STG_TRANSACTION_ERRORS
    SEL stg.*, 'INVALID_ACCOUNT' AS ERROR_REASON, p_batch_id AS BATCH_ID
    FROM BANKING_DW.STG_TRANSACTIONS stg
    WHERE stg.LOAD_DATE = p_batch_date
      AND stg.ACCOUNT_ID NOT IN (
          SEL ACCOUNT_ID FROM BANKING_DW.DIM_ACCOUNT WHERE CURRENT_FLAG = 'Y'
      );

    SET v_error_count = ACTIVITY_COUNT;

    -- Insert valid transactions
    INSERT INTO BANKING_DW.FACT_TRANSACTION (
        TRANSACTION_ID, TRANSACTION_DATE, TRANSACTION_TIME, TRANSACTION_TS,
        ACCOUNT_KEY, CUSTOMER_KEY, PRODUCT_ID, BRANCH_ID, DATE_KEY,
        TRANSACTION_TYPE, TRANSACTION_SUBTYPE, CHANNEL,
        TRANSACTION_AMOUNT, TRANSACTION_CURRENCY, BASE_CURRENCY_AMOUNT,
        EXCHANGE_RATE, MERCHANT_ID, MERCHANT_NAME, MERCHANT_CATEGORY,
        COUNTERPARTY_ACCT, REFERENCE_NUMBER, DESCRIPTION_TEXT,
        IS_INTERNATIONAL, POSTING_DATE, VALUE_DATE,
        ETL_BATCH_ID, ETL_INSERT_TS
    )
    SEL
        stg.TRANSACTION_ID,
        stg.TRANSACTION_DATE,
        stg.TRANSACTION_TIME,
        stg.TRANSACTION_DATE (TIMESTAMP(6)) + (stg.TRANSACTION_TIME - TIME '00:00:00' HOUR TO SECOND),
        a.ACCOUNT_KEY,
        c.CUSTOMER_KEY,
        a.PRODUCT_ID,
        a.BRANCH_ID,
        CAST(CAST(stg.TRANSACTION_DATE AS DATE FORMAT 'YYYYMMDD') AS INTEGER),
        stg.TRANSACTION_TYPE,
        stg.TRANSACTION_SUBTYPE,
        stg.CHANNEL,
        stg.TRANSACTION_AMOUNT,
        stg.CURRENCY_CODE,
        CASE WHEN stg.CURRENCY_CODE <> 'NOK'
             THEN stg.TRANSACTION_AMOUNT * ZEROIFNULL(fx.EXCHANGE_RATE)
             ELSE stg.TRANSACTION_AMOUNT
        END,
        ZEROIFNULL(fx.EXCHANGE_RATE),
        stg.MERCHANT_ID,
        stg.MERCHANT_NAME,
        stg.MERCHANT_CATEGORY,
        stg.COUNTERPARTY_ACCT,
        stg.REFERENCE_NUMBER,
        stg.DESCRIPTION_TEXT,
        CASE WHEN stg.CURRENCY_CODE <> 'NOK' THEN 1 ELSE 0 END,
        stg.POSTING_DATE,
        stg.VALUE_DATE,
        p_batch_id,
        CURRENT_TIMESTAMP(0)
    FROM BANKING_DW.STG_TRANSACTIONS stg
    INNER JOIN BANKING_DW.DIM_ACCOUNT a
        ON stg.ACCOUNT_ID = a.ACCOUNT_ID
       AND a.CURRENT_FLAG = 'Y'
    INNER JOIN BANKING_DW.DIM_CUSTOMER c
        ON a.CUSTOMER_ID = c.CUSTOMER_ID
       AND c.CURRENT_FLAG = 'Y'
    LEFT JOIN BANKING_DW.DIM_EXCHANGE_RATES fx
        ON stg.CURRENCY_CODE = fx.FROM_CURRENCY
       AND fx.TO_CURRENCY = 'NOK'
       AND stg.TRANSACTION_DATE = fx.RATE_DATE
    WHERE stg.LOAD_DATE = p_batch_date
      AND stg.ACCOUNT_ID IN (
          SEL ACCOUNT_ID FROM BANKING_DW.DIM_ACCOUNT WHERE CURRENT_FLAG = 'Y'
      );

    SET p_rows_inserted = ACTIVITY_COUNT;
    SET p_rows_rejected = v_error_count;

    -- Collect stats on the new partition
    COLLECT STATISTICS COLUMN (TRANSACTION_DATE) ON BANKING_DW.FACT_TRANSACTION;

    -- Log completion
    INSERT INTO BANKING_DW.ETL_LOG (
        PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
    ) VALUES (
        'SP_LOAD_DAILY_TRANSACTIONS', p_batch_id, 'INFO',
        'Completed. Inserted: ' || TRIM(p_rows_inserted (FORMAT 'Z(9)9')) ||
        ', Rejected: ' || TRIM(p_rows_rejected (FORMAT 'Z(9)9')) ||
        ', Duration: ' || CAST(
            (CURRENT_TIMESTAMP(0) - v_start_ts) SECOND(4) AS VARCHAR(15)),
        CURRENT_TIMESTAMP(0)
    );

END;
