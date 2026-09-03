/**********************************************************************
 * MACRO_DAILY_BALANCE_CHECK
 * Teradata macro for daily balance reconciliation
 * Macros are a Teradata-specific feature with no direct Snowflake equivalent
 **********************************************************************/

REPLACE MACRO BANKING_DW.DAILY_BALANCE_CHECK (
    check_date DATE FORMAT 'YYYY-MM-DD'
) AS (
    -- Summary of all account balances as of the check date
    SEL
        'BALANCE_SUMMARY' AS CHECK_TYPE,
        a.ACCOUNT_TYPE,
        a.CURRENCY_CODE,
        COUNT(*) AS ACCOUNT_COUNT,
        SUM(ft.RUNNING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZZ,ZZ9.99') AS TOTAL_BALANCE,
        AVG(ft.RUNNING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZ9.99') AS AVG_BALANCE,
        MIN(ft.RUNNING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZ9.99') AS MIN_BALANCE,
        MAX(ft.RUNNING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZ9.99') AS MAX_BALANCE
    FROM BANKING_DW.DIM_ACCOUNT a
    INNER JOIN BANKING_DW.FACT_TRANSACTION ft
        ON a.ACCOUNT_KEY = ft.ACCOUNT_KEY
    WHERE a.CURRENT_FLAG = 'Y'
      AND a.ACCOUNT_STATUS = 'ACTIVE'
      AND ft.TRANSACTION_DATE = :check_date
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.ACCOUNT_KEY
                               ORDER BY ft.TRANSACTION_TS DESC) = 1
    GROUP BY a.ACCOUNT_TYPE, a.CURRENCY_CODE
    ORDER BY a.ACCOUNT_TYPE, a.CURRENCY_CODE;

    -- Accounts with negative balances (excluding credit products)
    SEL
        'NEGATIVE_BALANCE_ALERT' AS CHECK_TYPE,
        a.ACCOUNT_ID,
        c.FIRST_NAME || ' ' || c.LAST_NAME AS CUSTOMER_NAME,
        a.ACCOUNT_TYPE,
        ft.RUNNING_BALANCE (FORMAT 'S ZZZ,ZZZ,ZZ9.99') AS CURRENT_BALANCE,
        a.OVERDRAFT_LIMIT (FORMAT 'ZZZ,ZZZ,ZZ9.99') AS OVERDRAFT_LIMIT,
        ft.RUNNING_BALANCE - a.OVERDRAFT_LIMIT (FORMAT 'S ZZZ,ZZZ,ZZ9.99') AS OVER_LIMIT_AMOUNT
    FROM BANKING_DW.DIM_ACCOUNT a
    INNER JOIN BANKING_DW.DIM_CUSTOMER c
        ON a.CUSTOMER_ID = c.CUSTOMER_ID AND c.CURRENT_FLAG = 'Y'
    INNER JOIN BANKING_DW.FACT_TRANSACTION ft
        ON a.ACCOUNT_KEY = ft.ACCOUNT_KEY
    WHERE a.CURRENT_FLAG = 'Y'
      AND a.ACCOUNT_TYPE NOT IN ('CREDIT_CARD', 'LOAN')
      AND ft.TRANSACTION_DATE = :check_date
      AND ft.RUNNING_BALANCE < 0
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.ACCOUNT_KEY
                               ORDER BY ft.TRANSACTION_TS DESC) = 1
    ORDER BY ft.RUNNING_BALANCE ASC;
);
