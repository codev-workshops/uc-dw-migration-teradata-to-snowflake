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
