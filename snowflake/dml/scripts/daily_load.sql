/*********************************************************************
 * Daily Load Script (SnowSQL) — replaces dml/scripts/bteq_daily_load.btq
 *
 * Run:
 *   snowsql -c etl_svc -f snowflake/dml/scripts/daily_load.sql \
 *     -o exit_on_error=true -o variable_substitution=true \
 *     -D run_date=$(date +%Y%m%d)
 *
 * BTEQ -> Snowflake mapping:
 *   .LOGON              -> SnowSQL named connection (-c etl_svc)
 *   DATABASE BANKING_DW -> USE SCHEMA BANKING_DW (inside the target database)
 *   .IF / .GOTO / .LABEL -> Snowflake Scripting block with IF + EXCEPTION
 *   .QUIT 4 (no staging) / .QUIT 8 (error) -> raised user exceptions
 *       -20004 / -20008; with exit_on_error=true SnowSQL exits non-zero
 *       and the scheduler distinguishes the cases by the error number.
 *   CALL ... OUT params -> CALL returns an OBJECT; read via RESULT_SCAN
 *   EXEC DAILY_BALANCE_CHECK -> two UDTF queries
 *   .EXPORT REPORT FILE= -> !spool
 *
 * Behavioural corrections (see MIGRATION_RUNBOOK.md, "Callers"):
 *   - The BTEQ staging check tested ACTIVITYCOUNT of an aggregate query,
 *     which always returns one row, so NOSTAGING never fired. The block
 *     below tests the staged row count instead.
 *   - SP_LOAD_DAILY_TRANSACTIONS swallows errors in its exit handler, so
 *     .IF ERRORCODE never saw them. The block checks P_RETURN_CODE.
 *   - MAX(BATCH_ID) + 1 is wrapped in COALESCE(..., 0) for an empty
 *     ETL_BATCH_CONTROL.
 *********************************************************************/

!set output_format=psql
USE SCHEMA BANKING_DW;

/* Step 1: Validate staging data (informational output, as in BTEQ) */
SELECT 'STAGING_CHECK' AS STEP_NAME,
       COUNT(*) AS ROW_COUNT,
       TO_CHAR(MIN(LOAD_DATE), 'YYYY-MM-DD') AS MIN_DATE,
       TO_CHAR(MAX(LOAD_DATE), 'YYYY-MM-DD') AS MAX_DATE,
       COUNT(DISTINCT ACCOUNT_ID) AS DISTINCT_ACCOUNTS
FROM BANKING_DW.STG_TRANSACTIONS
WHERE LOAD_DATE = CURRENT_DATE();

/* Steps 1-4 with control flow */
EXECUTE IMMEDIATE $$
DECLARE
    v_staged      INTEGER;
    v_batch_id    BIGINT;
    v_result      OBJECT;
    no_staging    EXCEPTION (-20004, 'WARNING: No staging data found for today');
    etl_failed    EXCEPTION (-20008, 'ERROR: ETL pipeline failed');
BEGIN
    SELECT COUNT(*) INTO :v_staged
    FROM BANKING_DW.STG_TRANSACTIONS
    WHERE LOAD_DATE = CURRENT_DATE();

    IF (v_staged = 0) THEN
        RAISE no_staging;
    END IF;

    /* Step 2: Generate new batch ID (session-scoped, like the VOLATILE table) */
    CREATE OR REPLACE TEMPORARY TABLE BANKING_DW.VT_BATCH AS
    SELECT COALESCE(MAX(BATCH_ID), 0) + 1 AS BATCH_ID,
           CURRENT_DATE() AS BATCH_DATE,
           CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0) AS BATCH_START_TS
    FROM BANKING_DW.ETL_BATCH_CONTROL;

    SELECT BATCH_ID INTO :v_batch_id FROM BANKING_DW.VT_BATCH;

    BEGIN
        /* Step 3: SCD2 customer dimension update */
        CALL BANKING_DW.SP_CUSTOMER_SCD2(:v_batch_id);
        SELECT $1 INTO :v_result FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        IF (v_result:P_RETURN_CODE::INTEGER <> 0) THEN
            RAISE etl_failed;
        END IF;

        /* Step 4: Load daily transactions */
        CALL BANKING_DW.SP_LOAD_DAILY_TRANSACTIONS(CURRENT_DATE(), :v_batch_id);
        SELECT $1 INTO :v_result FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        IF (v_result:P_RETURN_CODE::INTEGER <> 0) THEN
            RAISE etl_failed;
        END IF;
    EXCEPTION
        WHEN OTHER THEN
            /* ERRORHANDLER label */
            INSERT INTO BANKING_DW.ETL_BATCH_CONTROL (
                BATCH_ID, BATCH_DATE, BATCH_STATUS, START_TS, END_TS
            )
            SELECT BATCH_ID, BATCH_DATE, 'FAILED', BATCH_START_TS, CURRENT_TIMESTAMP(0)
            FROM BANKING_DW.VT_BATCH;
            RAISE etl_failed;
    END;

    RETURN 'Batch ' || TO_VARCHAR(v_batch_id) || ' loaded';
END;
$$;

/* Step 5: Run balance reconciliation (was EXEC BANKING_DW.DAILY_BALANCE_CHECK) */
SELECT * FROM TABLE(BANKING_DW.DAILY_BALANCE_SUMMARY(CURRENT_DATE()))
ORDER BY ACCOUNT_TYPE, CURRENCY_CODE;

SELECT * FROM TABLE(BANKING_DW.DAILY_NEGATIVE_BALANCE_ALERT(CURRENT_DATE()))
ORDER BY SORT_AMOUNT ASC;

/* Step 6: Export reconciliation report */
!spool /etl/reports/daily_recon_&{run_date}.txt

SELECT
    'DAILY_RECONCILIATION' AS REPORT_TYPE,
    TO_CHAR(CURRENT_DATE(), 'YYYY-MM-DD') AS REPORT_DATE,
    (SELECT BATCH_ID FROM BANKING_DW.VT_BATCH) AS BATCH_ID,
    (SELECT COUNT(*) FROM BANKING_DW.STG_TRANSACTIONS
     WHERE LOAD_DATE = CURRENT_DATE()) AS STAGED_ROWS,
    (SELECT COUNT(*) FROM BANKING_DW.FACT_TRANSACTION
     WHERE ETL_BATCH_ID = (SELECT BATCH_ID FROM BANKING_DW.VT_BATCH)) AS LOADED_ROWS,
    (SELECT COUNT(*) FROM BANKING_DW.STG_TRANSACTION_ERRORS
     WHERE BATCH_ID = (SELECT BATCH_ID FROM BANKING_DW.VT_BATCH)) AS ERROR_ROWS;

!spool off

/* Step 7: Record batch completion */
INSERT INTO BANKING_DW.ETL_BATCH_CONTROL (
    BATCH_ID, BATCH_DATE, BATCH_STATUS, START_TS, END_TS
)
SELECT BATCH_ID, BATCH_DATE, 'COMPLETED', BATCH_START_TS, CURRENT_TIMESTAMP(0)
FROM BANKING_DW.VT_BATCH;

DROP TABLE IF EXISTS BANKING_DW.VT_BATCH;

!exit
