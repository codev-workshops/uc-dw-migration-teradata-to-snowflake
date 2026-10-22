/**********************************************************************
 * CUSTOMER_TXN_HISTORY — SQL UDTF (Snowflake)
 * Reimplements the Teradata macro dml/macros/macro_customer_txn_history.sql.
 *
 * Snowflake has no macros. This single-result macro becomes a parameterized
 * view, implemented as a SQL table function (UDTF):
 *   - :param references -> UDTF arguments (no colon prefix).
 *   - Macro DEFAULTs -> argument DEFAULTs (DATE - 30 -> DATEADD('day', -30, CURRENT_DATE())).
 *   - (FORMAT ...) -> TO_CHAR(): TXN_DATE, TXN_TIME, AMOUNT, BALANCE are VARCHAR.
 *     'S ZZZ,ZZZ,ZZ9.99' -> 'S999,999,990.00'.
 *   - SAMPLE 1000 (random 1000 rows of the result) ->
 *     QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= 1000.
 *     If the business intent is "latest 1000", replace with
 *     ORDER BY TXN_DATE DESC, TXN_TIME DESC LIMIT 1000 at the call site.
 *   - ORDER BY moved to the caller (UDTF output order is not guaranteed).
 *     TXN_DATE/TXN_TIME are zero-padded strings, so they sort correctly.
 *
 * Usage (was: EXEC BANKING_DW.CUSTOMER_TXN_HISTORY(1001);):
 *   SELECT * FROM TABLE(BANKING_DW.CUSTOMER_TXN_HISTORY(1001))
 *   ORDER BY TXN_DATE DESC, TXN_TIME DESC;
 *   SELECT * FROM TABLE(BANKING_DW.CUSTOMER_TXN_HISTORY(
 *       CUST_ID => 1001, START_DATE => '2026-01-01'::DATE, TXN_TYPE => 'DEBIT'));
 **********************************************************************/

CREATE OR REPLACE FUNCTION BANKING_DW.CUSTOMER_TXN_HISTORY(
    CUST_ID    INTEGER,
    START_DATE DATE    DEFAULT DATEADD('day', -30, CURRENT_DATE()),
    END_DATE   DATE    DEFAULT CURRENT_DATE(),
    TXN_TYPE   VARCHAR DEFAULT 'ALL'
)
RETURNS TABLE (
    TXN_DATE            VARCHAR,
    TXN_TIME            VARCHAR,
    ACCOUNT_ID          VARCHAR,
    ACCOUNT_TYPE        VARCHAR,
    TRANSACTION_TYPE    VARCHAR,
    TRANSACTION_SUBTYPE VARCHAR,
    CHANNEL             VARCHAR,
    AMOUNT              VARCHAR,
    CCY                 VARCHAR,
    BALANCE             VARCHAR,
    PAYEE               VARCHAR,
    DESCRIPTION         VARCHAR,
    REF_NO              VARCHAR
)
LANGUAGE SQL
AS
$$
    SELECT
        TO_CHAR(ft.TRANSACTION_DATE, 'YYYY-MM-DD') AS TXN_DATE,
        TO_CHAR(ft.TRANSACTION_TIME, 'HH24:MI:SS') AS TXN_TIME,
        a.ACCOUNT_ID,
        a.ACCOUNT_TYPE,
        ft.TRANSACTION_TYPE,
        ft.TRANSACTION_SUBTYPE,
        ft.CHANNEL,
        TO_CHAR(ft.TRANSACTION_AMOUNT, 'S999,999,990.00') AS AMOUNT,
        ft.TRANSACTION_CURRENCY AS CCY,
        TO_CHAR(ft.RUNNING_BALANCE, 'S999,999,990.00') AS BALANCE,
        COALESCE(ft.MERCHANT_NAME, ft.COUNTERPARTY_ACCT, '--') AS PAYEE,
        ft.DESCRIPTION_TEXT AS DESCRIPTION,
        ft.REFERENCE_NUMBER AS REF_NO
    FROM BANKING_DW.FACT_TRANSACTION ft
    INNER JOIN BANKING_DW.DIM_ACCOUNT a
        ON ft.ACCOUNT_KEY = a.ACCOUNT_KEY AND a.CURRENT_FLAG = 'Y'
    INNER JOIN BANKING_DW.DIM_CUSTOMER c
        ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY AND c.CURRENT_FLAG = 'Y'
    WHERE c.CUSTOMER_ID = CUST_ID
      AND ft.TRANSACTION_DATE BETWEEN START_DATE AND END_DATE
      AND (ft.TRANSACTION_TYPE = TXN_TYPE OR TXN_TYPE = 'ALL')
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= 1000
$$;
