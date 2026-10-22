/**********************************************************************
 * SP_LOAD_DAILY_TRANSACTIONS (Snowflake Scripting)
 * Converted from dml/stored_procedures/sp_load_daily_transactions.sql.
 *
 * - REPLACE PROCEDURE -> CREATE OR REPLACE PROCEDURE ... LANGUAGE SQL.
 * - OUT parameters -> returned OBJECT {P_ROWS_INSERTED, P_ROWS_REJECTED, P_RETURN_CODE}.
 * - DECLARE EXIT HANDLER FOR SQLEXCEPTION -> EXCEPTION WHEN OTHER block.
 *   Like the Teradata exit handler, it logs to ETL_LOG and returns the error
 *   code instead of re-raising. SQLCODE values are Snowflake error numbers,
 *   not Teradata codes.
 * - ACTIVITY_COUNT -> SQLROWCOUNT.
 * - DATE (TIMESTAMP(6)) + (TIME - TIME '00:00:00' HOUR TO SECOND)
 *   -> TIMESTAMP_NTZ_FROM_PARTS(date, time).
 * - CAST(CAST(date AS DATE FORMAT 'YYYYMMDD') AS INTEGER)
 *   -> YEAR(date) * 10000 + MONTH(date) * 100 + DAY(date) (no string round-trip).
 * - (FORMAT 'Z(9)9') / (FORMAT '-999999') -> TO_VARCHAR.
 * - (CURRENT_TIMESTAMP - v_start_ts) SECOND(4) -> DATEDIFF('second', ...).
 * - COLLECT STATISTICS removed.
 **********************************************************************/

CREATE OR REPLACE PROCEDURE BANKING_DW.SP_LOAD_DAILY_TRANSACTIONS(
    P_BATCH_DATE DATE,
    P_BATCH_ID   BIGINT
)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_error_count    INTEGER DEFAULT 0;
    v_rows_inserted  INTEGER DEFAULT 0;
    v_start_ts       TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0);
    v_sql_code       INTEGER DEFAULT 0;
    v_message        VARCHAR;
BEGIN
    -- Log start
    v_message := 'Started loading transactions for date: ' || TO_CHAR(P_BATCH_DATE, 'YYYY-MM-DD');
    INSERT INTO BANKING_DW.ETL_LOG (
        PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
    ) VALUES (
        'SP_LOAD_DAILY_TRANSACTIONS', :P_BATCH_ID, 'INFO', :v_message, :v_start_ts
    );

    -- Reject bad records to error table
    INSERT INTO BANKING_DW.STG_TRANSACTION_ERRORS
    SELECT stg.*, 'INVALID_ACCOUNT' AS ERROR_REASON, :P_BATCH_ID AS BATCH_ID
    FROM BANKING_DW.STG_TRANSACTIONS stg
    WHERE stg.LOAD_DATE = :P_BATCH_DATE
      AND stg.ACCOUNT_ID NOT IN (
          SELECT ACCOUNT_ID FROM BANKING_DW.DIM_ACCOUNT WHERE CURRENT_FLAG = 'Y'
      );

    v_error_count := SQLROWCOUNT;

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
    SELECT
        stg.TRANSACTION_ID,
        stg.TRANSACTION_DATE,
        stg.TRANSACTION_TIME,
        TIMESTAMP_NTZ_FROM_PARTS(stg.TRANSACTION_DATE, stg.TRANSACTION_TIME),
        a.ACCOUNT_KEY,
        c.CUSTOMER_KEY,
        a.PRODUCT_ID,
        a.BRANCH_ID,
        YEAR(stg.TRANSACTION_DATE) * 10000 + MONTH(stg.TRANSACTION_DATE) * 100 + DAY(stg.TRANSACTION_DATE),
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
        :P_BATCH_ID,
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
    WHERE stg.LOAD_DATE = :P_BATCH_DATE
      AND stg.ACCOUNT_ID IN (
          SELECT ACCOUNT_ID FROM BANKING_DW.DIM_ACCOUNT WHERE CURRENT_FLAG = 'Y'
      );

    v_rows_inserted := SQLROWCOUNT;

    -- Log completion
    v_message := 'Completed. Inserted: ' || TO_VARCHAR(v_rows_inserted) ||
                 ', Rejected: ' || TO_VARCHAR(v_error_count) ||
                 ', Duration: ' ||
                 TO_VARCHAR(DATEDIFF('second', v_start_ts, CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0)));
    INSERT INTO BANKING_DW.ETL_LOG (
        PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
    ) VALUES (
        'SP_LOAD_DAILY_TRANSACTIONS', :P_BATCH_ID, 'INFO', :v_message, CURRENT_TIMESTAMP(0)
    );

    RETURN OBJECT_CONSTRUCT('P_ROWS_INSERTED', v_rows_inserted,
                            'P_ROWS_REJECTED', v_error_count,
                            'P_RETURN_CODE', 0);

EXCEPTION
    WHEN OTHER THEN
        v_sql_code := SQLCODE;
        v_message := 'SQLCODE: ' || TO_VARCHAR(SQLCODE) || ' (' || SQLERRM || ')' ||
                     ' at ' || TO_VARCHAR(CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0));
        INSERT INTO BANKING_DW.ETL_LOG (
            PROCEDURE_NAME, BATCH_ID, LOG_LEVEL, LOG_MESSAGE, LOG_TS
        ) VALUES (
            'SP_LOAD_DAILY_TRANSACTIONS', :P_BATCH_ID, 'ERROR', :v_message, CURRENT_TIMESTAMP(0)
        );
        RETURN OBJECT_CONSTRUCT('P_ROWS_INSERTED', v_rows_inserted,
                                'P_ROWS_REJECTED', v_error_count,
                                'P_RETURN_CODE', v_sql_code);
END;
$$;
