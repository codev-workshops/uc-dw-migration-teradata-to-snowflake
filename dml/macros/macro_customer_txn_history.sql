-- ======================================================================
-- OBJECT : BANKING_DW.CUSTOMER_TXN_HISTORY (macro)
-- FILE   : dml/macros/macro_customer_txn_history.sql
-- ----------------------------------------------------------------------
-- PURPOSE
--   * Customer statement macro returning transaction history for one
--     customer over a date range, optionally filtered by transaction
--     type.
--
-- INPUT / OUTPUT TABLES
--   * Reads: BANKING_DW.FACT_TRANSACTION, BANKING_DW.DIM_ACCOUNT,
--     BANKING_DW.DIM_CUSTOMER
--   * Writes: none (read-only, returns a result set)
--   * Parameters: cust_id, start_date (default DATE - 30), end_date
--     (default DATE), txn_type (default 'ALL')
--
-- KEY BUSINESS RULES
--   * Filters to CUSTOMER_ID = cust_id via current (CURRENT_FLAG='Y')
--     customer and account versions.
--   * TRANSACTION_DATE between start_date and end_date inclusive.
--   * txn_type = 'ALL' applies no type filter; any other value matches
--     TRANSACTION_TYPE exactly.
--   * PAYEE = MERCHANT_NAME, else COUNTERPARTY_ACCT, else '--'; ordered
--     newest first and limited to a 1000-row SAMPLE.
--
-- TERADATA-SPECIFIC FEATURES USED
--   * REPLACE MACRO with typed parameters, DEFAULT values and :param
--     references
--   * SEL shorthand for SELECT
--   * SAMPLE 1000 row sampling clause
--   * DATE FORMAT 'YYYY-MM-DD' parameter type; inline (FORMAT
--     'HH:MI:SS') / (FORMAT 'S ZZZ,ZZZ,ZZ9.99') expressions
-- ======================================================================

/**********************************************************************
 * MACRO_CUSTOMER_TXN_HISTORY
 * Retrieves transaction history for a specific customer
 * Demonstrates Teradata macro with multiple parameters
 **********************************************************************/

REPLACE MACRO BANKING_DW.CUSTOMER_TXN_HISTORY (
    cust_id INTEGER,
    start_date DATE FORMAT 'YYYY-MM-DD' DEFAULT DATE - 30,
    end_date DATE FORMAT 'YYYY-MM-DD' DEFAULT DATE,
    txn_type VARCHAR(20) DEFAULT 'ALL'
) AS (
    SEL
        ft.TRANSACTION_DATE (FORMAT 'YYYY-MM-DD') AS TXN_DATE,
        ft.TRANSACTION_TIME (FORMAT 'HH:MI:SS') AS TXN_TIME,
        a.ACCOUNT_ID,
        a.ACCOUNT_TYPE,
        ft.TRANSACTION_TYPE,
        ft.TRANSACTION_SUBTYPE,
        ft.CHANNEL,
        ft.TRANSACTION_AMOUNT (FORMAT 'S ZZZ,ZZZ,ZZ9.99') AS AMOUNT,
        ft.TRANSACTION_CURRENCY AS CCY,
        ft.RUNNING_BALANCE (FORMAT 'S ZZZ,ZZZ,ZZ9.99') AS BALANCE,
        COALESCE(ft.MERCHANT_NAME, ft.COUNTERPARTY_ACCT, '--') AS PAYEE,
        ft.DESCRIPTION_TEXT AS DESCRIPTION,
        ft.REFERENCE_NUMBER AS REF_NO
    FROM BANKING_DW.FACT_TRANSACTION ft
    INNER JOIN BANKING_DW.DIM_ACCOUNT a
        ON ft.ACCOUNT_KEY = a.ACCOUNT_KEY AND a.CURRENT_FLAG = 'Y'
    INNER JOIN BANKING_DW.DIM_CUSTOMER c
        ON ft.CUSTOMER_KEY = c.CUSTOMER_KEY AND c.CURRENT_FLAG = 'Y'
    WHERE c.CUSTOMER_ID = :cust_id
      AND ft.TRANSACTION_DATE BETWEEN :start_date AND :end_date
      AND (ft.TRANSACTION_TYPE = :txn_type OR :txn_type = 'ALL')
    ORDER BY ft.TRANSACTION_DATE DESC, ft.TRANSACTION_TIME DESC
    SAMPLE 1000;
);
