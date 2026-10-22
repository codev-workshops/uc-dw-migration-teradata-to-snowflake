/*********************************************************************
 * Monthly Extract Script (SnowSQL) — replaces dml/scripts/bteq_extract_report.btq
 *
 * Run:
 *   snowsql -c etl_svc -f snowflake/dml/scripts/extract_report.sql \
 *     -o exit_on_error=true -o variable_substitution=true \
 *     -o friendly=false -o header=true -o timing=false \
 *     -D run_month=$(date +%Y%m) -D run_date=$(date +%Y%m%d)
 *
 * BTEQ -> Snowflake mapping:
 *   .EXPORT DATA/REPORT FILE= -> !spool with output_format csv / psql.
 *       For large regulatory files prefer COPY INTO @stage + GET.
 *   (CHAR(n)) fixed-width casts -> dropped for CSV; RPAD() if fixed width is needed.
 *   (FORMAT ...) -> TO_CHAR().
 *   .IF ACTIVITYCOUNT = 0 THEN .GOTO NODATA -> Snowflake Scripting check that
 *       raises -20004 (BTEQ .QUIT 4).
 *   EXEC AML_SCREENING(...) (3 result sets) -> three UDTF queries.
 *   VW_BRANCH_PERFORMANCE.TOTAL_DEPOSITS and PCT_OF_REGION_DEPOSITS are already
 *   VARCHAR (formatted in the view), so they are selected as-is.
 *********************************************************************/

USE SCHEMA BANKING_DW;

/* Export 1: Large Transaction Report (CSV for regulatory submission) */
!set output_format=csv
!spool /etl/exports/large_txn_report_&{run_month}.csv

SELECT
    TRANSACTION_ID,
    TO_CHAR(TRANSACTION_DATE, 'YYYY-MM-DD') AS TRANSACTION_DATE,
    CUSTOMER_ID,
    FIRST_NAME,
    LAST_NAME,
    KYC_STATUS,
    ACCOUNT_ID,
    ACCOUNT_TYPE,
    TRANSACTION_TYPE,
    TO_CHAR(TRANSACTION_AMOUNT, 'S999,999,990.00') AS TRANSACTION_AMOUNT,
    TRANSACTION_CURRENCY,
    TO_CHAR(BASE_CURRENCY_AMOUNT, 'S999,999,990.00') AS BASE_CURRENCY_AMOUNT,
    IS_INTERNATIONAL,
    REPORTING_CATEGORY,
    MERCHANT_NAME,
    REFERENCE_NUMBER
FROM BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS
WHERE TRANSACTION_DATE BETWEEN ADD_MONTHS(CURRENT_DATE(), -1) AND CURRENT_DATE()
ORDER BY 2, 1;

!spool off

EXECUTE IMMEDIATE $$
DECLARE
    v_rows   INTEGER;
    no_data  EXCEPTION (-20004, 'WARNING: No large transactions found for the reporting period.');
BEGIN
    SELECT COUNT(*) INTO :v_rows
    FROM BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS
    WHERE TRANSACTION_DATE BETWEEN ADD_MONTHS(CURRENT_DATE(), -1) AND CURRENT_DATE();
    IF (v_rows = 0) THEN
        RAISE no_data;
    END IF;
    RETURN v_rows;
END;
$$;

/* Export 2: Branch Performance Summary (formatted report) */
!set output_format=psql
!spool /etl/exports/branch_performance_&{run_month}.rpt

SELECT
    BRANCH_NAME AS "Branch",
    REGION AS "Region",
    MONTH_LABEL AS "Month",
    TO_CHAR(ACCOUNTS_SERVICED, '9999990') AS "Accounts",
    TOTAL_DEPOSITS AS "Total Deposits (NOK)",
    TO_CHAR(TOTAL_FEES_EARNED, '999,999,990.00') AS "Fees Earned",
    TO_CHAR(REGION_DEPOSIT_RANK, '90') AS "Rank",
    PCT_OF_REGION_DEPOSITS AS "% Region"
FROM BANKING_DW.VW_BRANCH_PERFORMANCE
WHERE SNAPSHOT_MONTH_KEY = (YEAR(ADD_MONTHS(CURRENT_DATE(), -1)) * 100)
                          + MONTH(ADD_MONTHS(CURRENT_DATE(), -1))
ORDER BY REGION, REGION_DEPOSIT_RANK;

!spool off

/* Export 3: AML Screening Results (was EXEC BANKING_DW.AML_SCREENING(CURRENT_DATE, 30, 50000.00)) */
!set output_format=csv
!spool /etl/exports/aml_screening_&{run_date}.csv

SELECT * FROM TABLE(BANKING_DW.AML_STRUCTURING(CURRENT_DATE(), 30, 50000.00))
ORDER BY SORT_AMOUNT DESC;

SELECT * FROM TABLE(BANKING_DW.AML_RAPID_MOVEMENT(CURRENT_DATE(), 30, 50000.00))
ORDER BY SORT_AMOUNT DESC;

SELECT * FROM TABLE(BANKING_DW.AML_NEW_CUSTOMER_INTL(CURRENT_DATE(), 30, 50000.00))
ORDER BY SORT_AMOUNT DESC;

!spool off

SELECT 'Monthly reports exported successfully at ' ||
       TO_CHAR(CURRENT_TIMESTAMP(0), 'YYYY-MM-DD HH24:MI:SS');

!exit
