# SQL Translation Notes — Teradata → Snowflake

Construct-level rewrite patterns used in `snowflake/`. The decisions behind them, and the per-file change lists, are in [`MIGRATION_RUNBOOK.md`](MIGRATION_RUNBOOK.md).

## Tables

```sql
-- Teradata
CREATE SET TABLE BANKING_DW.DIM_PRODUCT, NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL,
     CHECKSUM = DEFAULT, DEFAULT MERGEBLOCKRATIO
( PRODUCT_NAME VARCHAR(100) NOT CASESPECIFIC NOT NULL,
  IS_ACTIVE    BYTEINT DEFAULT 1 COMPRESS (0, 1),
  LAUNCH_DATE  DATE FORMAT 'YYYY-MM-DD',
  ETL_INSERT_TS TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0) )
UNIQUE PRIMARY INDEX UPI_PRODUCT_ID (PRODUCT_ID)
INDEX IDX_PROD_CODE (PRODUCT_CODE);
COLLECT STATISTICS COLUMN (PRODUCT_ID) ON BANKING_DW.DIM_PRODUCT;

-- Snowflake
CREATE OR REPLACE TABLE BANKING_DW.DIM_PRODUCT (
  PRODUCT_NAME  VARCHAR(100) COLLATE 'en-ci' NOT NULL,
  IS_ACTIVE     NUMBER(3,0) DEFAULT 1,
  LAUNCH_DATE   DATE,
  ETL_INSERT_TS TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0),
  CONSTRAINT PK_DIM_PRODUCT PRIMARY KEY (PRODUCT_ID)      -- declared, not enforced
);
```

| Teradata | Snowflake |
|---|---|
| `GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1)` | `AUTOINCREMENT START 1 INCREMENT 1` |
| `PRIMARY INDEX (a, d) PARTITION BY RANGE_N(d BETWEEN … EACH INTERVAL '1' MONTH, NO RANGE)` | `CLUSTER BY (d)` |
| `TIMESTAMP(n)` | `TIMESTAMP_NTZ(n)` |
| `BYTEINT` | `NUMBER(3,0)` |

## Queries

| Teradata | Snowflake | Example |
|---|---|---|
| `SEL` | `SELECT` | |
| `REPLACE VIEW v AS LOCKING ROW FOR ACCESS SEL …` | `CREATE OR REPLACE VIEW v AS SELECT …` | |
| `x (FORMAT 'ZZZ,ZZZ,ZZ9.99')` | `TO_CHAR(x, '999,999,990.00')` | Teradata `Z` → `9`, Teradata `9` → `0`. Result is VARCHAR. |
| `x (FORMAT 'S ZZZ,ZZZ,ZZ9.99')` | `TO_CHAR(x, 'S999,999,990.00')` | |
| `d (FORMAT 'YYYY-MM-DD')` | `TO_CHAR(d, 'YYYY-MM-DD')` | |
| `t (FORMAT 'HH:MI:SS')` | `TO_CHAR(t, 'HH24:MI:SS')` | Teradata `HH` = 24-hour, Snowflake `HH24`. |
| `x (SMALLINT)`, `x (DECIMAL(18,2))` | `CAST(x AS SMALLINT)`, `CAST(x AS DECIMAL(18,2))` | |
| `col (NOT CASESPECIFIC)` | `col` (collated column) or `UPPER(col)` | |
| `HASHROW(a, b)` | `HASH(a, b)` | Values differ across platforms. |
| `CSUM(SUM(x), o)` | `SUM(SUM(x)) OVER (PARTITION BY p ORDER BY o ROWS UNBOUNDED PRECEDING)` | |
| `MAVG(SUM(x), 3, o)` | `AVG(SUM(x)) OVER (PARTITION BY p ORDER BY o ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)` | |
| `CURRENT_DATE - 90`, `d1 - d2` | `DATEADD('day', -90, CURRENT_DATE())`, `DATEDIFF('day', d2, d1)` | |
| `ADD_MONTHS(d, 1) - 1` | `DATEADD('day', -1, ADD_MONTHS(d, 1))` | |
| `CAST(TRIM(y (FORMAT '9999')) \|\| '-' \|\| TRIM(m (FORMAT '99')) \|\| '-01' AS DATE FORMAT 'YYYY-MM-DD')` | `DATE_FROM_PARTS(y, m, 1)` | |
| `d (TIMESTAMP(6)) + (t - TIME '00:00:00' HOUR TO SECOND)` | `TIMESTAMP_NTZ_FROM_PARTS(d, t)` | |
| `CAST(CAST(d AS DATE FORMAT 'YYYYMMDD') AS INTEGER)` | `YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d)` | |
| `(ts2 - ts1) SECOND(4)` | `DATEDIFF('second', ts1, ts2)` | |
| `… QUALIFY … WHERE …` | `… WHERE … QUALIFY …` | Snowflake enforces clause order. |
| `x NOT IN (SEL k …)` | unchanged, or `NOT EXISTS (…)` | `NOT IN` returns no rows if the subquery yields a NULL. |

### Correlated scalar subquery with QUALIFY inside an aggregate

```sql
-- Teradata (VW_CUSTOMER_360)
SUM(CASE WHEN CURRENT_FLAG = 'Y' THEN
      (SEL CLOSING_BALANCE FROM FACT_MONTHLY_ACCOUNT_SNAPSHOT snap
        WHERE snap.ACCOUNT_KEY = a.ACCOUNT_KEY
        QUALIFY ROW_NUMBER() OVER (PARTITION BY snap.ACCOUNT_KEY ORDER BY snap.SNAPSHOT_DATE DESC) = 1)
    ELSE 0 END)

-- Snowflake
WITH LATEST_SNAPSHOT AS (
  SELECT ACCOUNT_KEY, CLOSING_BALANCE FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_KEY ORDER BY SNAPSHOT_DATE DESC) = 1)
… SUM(ls.CLOSING_BALANCE) … FROM DIM_ACCOUNT a LEFT JOIN LATEST_SNAPSHOT ls ON ls.ACCOUNT_KEY = a.ACCOUNT_KEY
```

## Stored procedures (Snowflake Scripting)

```sql
-- Teradata
REPLACE PROCEDURE BANKING_DW.P(IN p_id BIGINT, OUT p_rows INTEGER)
BEGIN
  DECLARE v_ts TIMESTAMP(0);
  SET v_ts = CURRENT_TIMESTAMP(0);
  UPDATE T tgt FROM (SEL ID FROM S) src SET X = v_ts WHERE tgt.ID = src.ID;
  SET p_rows = ACTIVITY_COUNT;
END;

-- Snowflake
CREATE OR REPLACE PROCEDURE BANKING_DW.P(P_ID BIGINT)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
  v_ts TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0);
BEGIN
  UPDATE T tgt SET X = :v_ts FROM (SELECT DISTINCT ID FROM S) src WHERE tgt.ID = src.ID;
  RETURN OBJECT_CONSTRUCT('P_ROWS', SQLROWCOUNT);
END;
$$;
```

| Teradata | Snowflake |
|---|---|
| `OUT` parameters | `RETURNS OBJECT` with the same key names. Caller: `CALL P(1);` then `SELECT $1:P_ROWS FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))`. |
| Variable in SQL: `v_ts` | `:v_ts` (in expressions/assignments: `v_ts`) |
| `SET v = expr;` | `v := expr;` |
| `ACTIVITY_COUNT` | `SQLROWCOUNT` |
| `DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN … SQLCODE … END;` | `EXCEPTION WHEN OTHER THEN … SQLCODE / SQLERRM / SQLSTATE …` (at the end of the block) |
| `CREATE VOLATILE TABLE vt AS (SEL …) WITH DATA PRIMARY INDEX (k) ON COMMIT PRESERVE ROWS;` | `CREATE OR REPLACE TEMPORARY TABLE vt AS SELECT …;` |
| `COLLECT STATISTICS …` | remove |

## Macros

```sql
-- Teradata
REPLACE MACRO BANKING_DW.M (d DATE DEFAULT DATE, n INTEGER DEFAULT 30) AS (
  SEL … WHERE TRANSACTION_DATE BETWEEN :d - :n AND :d ORDER BY …; );
EXEC BANKING_DW.M(CURRENT_DATE, 30);

-- Snowflake: parameterized view (SQL UDTF)
CREATE OR REPLACE FUNCTION BANKING_DW.M(D DATE DEFAULT CURRENT_DATE(), N INTEGER DEFAULT 30)
RETURNS TABLE (…)
LANGUAGE SQL
AS $$ SELECT … WHERE TRANSACTION_DATE BETWEEN DATEADD('day', -N, D) AND D $$;
SELECT * FROM TABLE(BANKING_DW.M(CURRENT_DATE(), 30)) ORDER BY …;
SELECT * FROM TABLE(BANKING_DW.M(N => 7));          -- named argument, D defaults
```

- One UDTF per result set when a macro has several `SEL` statements.
- `ORDER BY` belongs to the caller. Return a numeric sort column when the macro sorted on a value that is now formatted.
- `SAMPLE n` on a result → `QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= n`. `SAMPLE`/`TABLESAMPLE` in Snowflake samples a table, not a filtered result.

## BTEQ → SnowSQL

| BTEQ | SnowSQL / Snowflake Scripting |
|---|---|
| `.LOGON tdpid/user,pwd;` | `snowsql -c <connection>` |
| `DATABASE X;` | `USE SCHEMA X;` |
| `.SET SEPARATOR '\|'`, `.SET WIDTH` | `!set output_format=csv\|psql` (SnowSQL options) |
| `.EXPORT REPORT FILE=f;` … `.EXPORT RESET;` | `!spool f` … `!spool off` (or `COPY INTO @stage` + `GET` for data files) |
| `.IF ACTIVITYCOUNT = 0 THEN .GOTO L;` / `.IF ERRORCODE <> 0 …` / `.LABEL` / `.QUIT n` | `EXECUTE IMMEDIATE $$ DECLARE e EXCEPTION (-20004, '…'); BEGIN … IF (…) THEN RAISE e; END IF; … EXCEPTION WHEN OTHER THEN … END; $$;` with `-o exit_on_error=true` |
| File-name placeholders (`…_YYYYMMDD.txt`) | `&{run_date}` with `-o variable_substitution=true -D run_date=$(date +%Y%m%d)` |
