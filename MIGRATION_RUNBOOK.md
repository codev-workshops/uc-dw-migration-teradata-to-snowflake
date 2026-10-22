# Teradata → Snowflake Migration Runbook — BANKING_DW

This runbook records every decision taken while converting the Teradata `BANKING_DW` warehouse in this repository to Snowflake: what changed, why, and how the result is validated. The authoritative mapping reference is [`docs/teradata_features_reference.md`](docs/teradata_features_reference.md). The original Teradata sources under `ddl/` and `dml/` are unchanged.

## 1. Deliverables

```
snowflake/
├── ddl/
│   ├── tables/   01_dim_customer.sql … 07_fact_monthly_snapshot.sql   (7, same names as ddl/tables/)
│   └── views/    01_vw_customer_360.sql … 03_vw_branch_performance.sql (3, same names as ddl/views/)
├── dml/
│   ├── stored_procedures/  sp_customer_scd2.sql, sp_load_daily_transactions.sql, sp_monthly_snapshot.sql
│   ├── macros/             macro_*.sql  → SQL table functions (UDTFs)
│   └── scripts/            daily_load.sql, extract_report.sql (SnowSQL, replace the BTEQ scripts),
│                           load_seed_data.sql (PUT + COPY INTO)
└── validation/
    ├── checksum_queries.sql            Snowflake twin of data/validation/checksum_queries.sql
    ├── fixtures_supporting_tables.sql  assumed shapes of the STG_/ETL_ tables (validation only)
    ├── run_validation.py               deploy + load + reconcile + behavioural checks
    └── requirements.txt                pinned harness dependencies
SQL_TRANSLATION_NOTES.md                construct-by-construct rewrite patterns with examples
```

## 2. Target environment and deployment order

| Item | Decision |
|---|---|
| Namespace | Teradata database `BANKING_DW` becomes a **schema** `BANKING_DW` inside a Snowflake database (e.g. `BANKING`). All objects keep two-part names (`BANKING_DW.<object>`), so set `USE DATABASE <db>` before deploying. |
| Session time zone | Columns `TIMESTAMP(0)` became `TIMESTAMP_NTZ(0)` and defaults use `CURRENT_TIMESTAMP(0)`, which Snowflake evaluates in the session time zone. Set `TIMEZONE` on the ETL user/warehouse sessions to the Teradata system time zone (the validation script uses `Europe/Oslo`) so audit columns keep the same wall-clock values. |
| `CREATE OR REPLACE` | The converted DDL uses `CREATE OR REPLACE TABLE`, which **drops existing data**. Run it only on an empty target. For re-runnable deploys, switch to `CREATE TABLE IF NOT EXISTS`. |
| Deployment order | 1) `snowflake/ddl/tables/*` (01→07) 2) supporting STG_/ETL_ tables (see §8) 3) `snowflake/ddl/views/*` 4) `snowflake/dml/macros/*` (UDTFs) 5) `snowflake/dml/stored_procedures/*` 6) load data (§7) 7) validation (§9). |
| Clustering cost | `CLUSTER BY` enables Automatic Clustering, which uses credits. It is worth it for the fact tables at production volume. For the dimensions it can be removed if pruning is already good (see decision 3). |

## 3. Feature mapping (what each Teradata construct became, and why)

### 3.1 DDL

| Teradata construct | Snowflake result | Why |
|---|---|---|
| `CREATE SET TABLE` | `CREATE OR REPLACE TABLE` + comment about duplicates | Snowflake has no SET semantics. All tables allow duplicate rows (decision 1). |
| `CREATE MULTISET TABLE` | `CREATE OR REPLACE TABLE` | Same duplicate semantics. |
| `NO FALLBACK`, `NO BEFORE/AFTER JOURNAL`, `CHECKSUM = DEFAULT`, `DEFAULT MERGEBLOCKRATIO` | removed | Storage-level options. Snowflake handles redundancy and storage itself. |
| `GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1)` | `AUTOINCREMENT START 1 INCREMENT 1` | Snowflake identity column. See §7.2 for surrogate keys during migration. |
| `COMPRESS (…)`, `COMPRESS 0`, `COMPRESS ''` | removed | Snowflake compresses columnar micro-partitions automatically. |
| `NOT CASESPECIFIC` | `COLLATE 'en-ci'` on the column | Keeps case-insensitive comparison (decision 7). |
| `DATE FORMAT 'YYYY-MM-DD'` (column) | `DATE` | Snowflake has no column-level display format. Formatting moves to queries. |
| `BYTEINT` | `NUMBER(3,0)` | Snowflake has no `BYTEINT` keyword. Note: `NUMBER(3,0)` accepts -999…999 where `BYTEINT` accepts -128…127. All BYTEINT columns here are 0/1 flags or small calendar numbers. |
| `SMALLINT`, `INTEGER`, `BIGINT`, `DECIMAL(p,s)` | unchanged | Snowflake aliases of `NUMBER`. |
| `TIME(0)` | `TIME(0)` | Same. |
| `TIMESTAMP(0)` / `TIMESTAMP(6)` | `TIMESTAMP_NTZ(0)` / `TIMESTAMP_NTZ(6)` | Explicit no-time-zone type, independent of `TIMESTAMP_TYPE_MAPPING`. |
| `DEFAULT CURRENT_TIMESTAMP(0)`, `DEFAULT TIMESTAMP '9999-12-31 23:59:59'`, other `DEFAULT`s | unchanged | Supported as written. |
| `UNIQUE PRIMARY INDEX (col)` | `CONSTRAINT PK_<table> PRIMARY KEY (col)` | Declares the key for documentation, BI tools and the optimizer. **Not enforced** (decision 2). |
| `PRIMARY INDEX (…)` (non-unique) on facts | no constraint | A NUPI does not imply uniqueness. Declaring a PK would be false. |
| Secondary `INDEX …` | removed | No secondary indexes in Snowflake. Pruning comes from micro-partition metadata and clustering. |
| `PARTITION BY RANGE_N(…)` | `CLUSTER BY (<partition date column>)` | Closest physical equivalent (decision 3). |
| `COLLECT STATISTICS …` (incl. `COLUMN (PARTITION)`) | removed | Statistics are maintained automatically. |
| `COMMENT ON TABLE/COLUMN` | unchanged | Same syntax. |

### 3.2 Views and queries

| Teradata construct | Snowflake result | Why |
|---|---|---|
| `REPLACE VIEW` | `CREATE OR REPLACE VIEW` | DDL syntax. |
| `LOCKING ROW FOR ACCESS` | removed | Snowflake readers never block writers (MVCC). |
| `SEL` | `SELECT` | Teradata shorthand. |
| `QUALIFY`, `ZEROIFNULL`, `NULLIFZERO`, `RANK() OVER`, `ADD_MONTHS`, `EXTRACT`, `MERGE INTO` | unchanged | Native in Snowflake. Note: Snowflake requires `QUALIFY` after `WHERE`/`GROUP BY`/`HAVING`. |
| `expr (FORMAT '…')` | `TO_CHAR(expr, '<mask>')` | No `FORMAT` phrase in Snowflake. The column becomes VARCHAR (decision 4). |
| `expr (TYPE)` (Teradata cast shorthand) | `CAST(expr AS TYPE)` | Shorthand not supported. |
| `col (NOT CASESPECIFIC)` | removed (the column carries `COLLATE 'en-ci'`) | Decision 7. |
| `HASHROW(…)` | `HASH(…)` | Different algorithm (decision 5). |
| `CSUM(x, o)` | `SUM(x) OVER (PARTITION BY … ORDER BY o ROWS UNBOUNDED PRECEDING)` | ANSI window function (decision 6). |
| `MAVG(x, n, o)` | `AVG(x) OVER (PARTITION BY … ORDER BY o ROWS BETWEEN n-1 PRECEDING AND CURRENT ROW)` | ANSI window function (decision 6). |
| `date - date`, `date ± n` | `DATEDIFF('day', …)`, `DATEADD('day', n, …)` | Explicit. Snowflake also accepts date arithmetic, but `DATEDIFF`/`DATEADD` make the intent and the result type explicit. |
| `CURRENT_DATE` | `CURRENT_DATE()` | Both forms work. The function form is used consistently. |
| Correlated scalar subquery with `QUALIFY` inside an aggregate | CTE with `QUALIFY` first, then join and aggregate | Snowflake supports only limited correlated scalar subqueries. The CTE form is valid and clearer. |

### 3.3 Procedural code, macros, BTEQ

| Teradata construct | Snowflake result | Why |
|---|---|---|
| `REPLACE PROCEDURE … BEGIN … END` | `CREATE OR REPLACE PROCEDURE … RETURNS OBJECT LANGUAGE SQL AS $$ DECLARE … BEGIN … END $$` | Snowflake Scripting. |
| `OUT` parameters | returned `OBJECT` (e.g. `{P_NEW_ROWS, P_CHANGED, P_RETURN_CODE}`) | One portable contract. Callers read it from the `CALL` result (or `RESULT_SCAN(LAST_QUERY_ID())`). Key names match the old OUT parameter names. |
| `DECLARE v TYPE;` / `SET v = expr;` | `DECLARE v TYPE [DEFAULT …];` / `v := expr;` | Scripting syntax. Inside SQL statements, variables are referenced as `:v`. |
| `ACTIVITY_COUNT` | `SQLROWCOUNT` | Rows affected by the last DML statement. |
| `DECLARE EXIT HANDLER FOR SQLEXCEPTION` + `SQLCODE` | `EXCEPTION WHEN OTHER THEN …` with `SQLCODE`/`SQLERRM` | Same "log and exit" behaviour. SQLCODE values are **Snowflake** error numbers, so any caller that tested specific Teradata codes must be remapped. |
| `UPDATE tgt FROM (subquery) src SET … WHERE …` | `UPDATE tgt SET … FROM (subquery) src WHERE …` | Snowflake clause order. `DISTINCT` was added to the source so each target row matches at most one source row (no non-deterministic update). |
| `CREATE VOLATILE TABLE … WITH DATA PRIMARY INDEX (…) ON COMMIT PRESERVE ROWS` | `CREATE OR REPLACE TEMPORARY TABLE … AS SELECT …` | Session-scoped. The PRIMARY INDEX clause is dropped. `OR REPLACE` makes re-runs in the same session safe. |
| `CAST(… AS DATE FORMAT 'YYYYMMDD')`, string-built dates | `YEAR()*10000 + MONTH()*100 + DAY()`, `DATE_FROM_PARTS`, `TIMESTAMP_NTZ_FROM_PARTS` | Purpose-built functions instead of string round-trips. |
| `REPLACE MACRO` (single result set) | SQL UDTF (`CREATE FUNCTION … RETURNS TABLE`) — a parameterized view | Snowflake has no macros. A UDTF is queryable like a view and takes parameters. |
| `REPLACE MACRO` (multiple result sets) | one UDTF per result set | A Snowflake procedure returns only one result set, so the three-statement AML macro becomes three UDTFs (see §6). |
| Macro `:param` and `DEFAULT` | UDTF arguments with `DEFAULT` | `DEFAULT DATE` → `DEFAULT CURRENT_DATE()`. |
| `SAMPLE n` | `QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= n` | Random n rows of the result, as `SAMPLE` returns. Snowflake `SAMPLE` applies to a table, not to a filtered result. |
| `EXEC macro(…)` | `SELECT * FROM TABLE(BANKING_DW.<udtf>(…)) ORDER BY …` | `ORDER BY` moves to the caller because UDTF output order is not guaranteed. A numeric `SORT_AMOUNT` column is returned where the macro sorted by a formatted amount. |
| BTEQ `.LOGON`, `.IF`, `.GOTO`, `.LABEL`, `.QUIT n`, `.EXPORT` | SnowSQL connection, Snowflake Scripting `EXECUTE IMMEDIATE $$ … $$` blocks with `IF`/`RAISE`, `!spool` | See §6.3. |

## 4. Semantic and behavioural decisions (read before sign-off)

1. **SET tables → standard tables (duplicate handling).** `DIM_CUSTOMER`, `DIM_PRODUCT`, `DIM_BRANCH`, `DIM_DATE` were SET tables: Teradata silently discarded exact duplicate rows on `INSERT … SELECT` (and raised an error on single-row inserts). Snowflake keeps every row. Uniqueness is now only declared via the primary key and must be guaranteed by the loaders: `SP_CUSTOMER_SCD2` dedups per `CUSTOMER_ID`, seed and bulk loads must dedup on the natural key (`QUALIFY ROW_NUMBER() OVER (PARTITION BY <key> …) = 1`, or `MERGE`), and validation query 6 in `snowflake/validation/checksum_queries.sql` detects duplicates after every load.
2. **Primary keys are declared, not enforced.** `PRIMARY KEY` on `CUSTOMER_KEY`, `ACCOUNT_KEY`, `PRODUCT_ID`, `BRANCH_ID`, `DATE_KEY` documents the UPI but Snowflake does not reject duplicates (only `NOT NULL` is enforced). Do not add `RELY` unless the dedup checks above are part of the load SLA, because `RELY` lets the optimizer eliminate joins on that assumption. `FACT_TRANSACTION` and `FACT_MONTHLY_ACCOUNT_SNAPSHOT` had non-unique PIs, so no PK is declared on them. Their grains (`TRANSACTION_ID`; `ACCOUNT_KEY` + `SNAPSHOT_MONTH_KEY`) are maintained by `VW_REGULATORY_LARGE_TRANSACTIONS` (dedup) and the snapshot `MERGE`.
3. **PPI / `RANGE_N` → `CLUSTER BY`; re-validate partition pruning.** Teradata partition elimination was guaranteed by the monthly/yearly `RANGE_N` partitions. Snowflake prunes on micro-partition min/max metadata, and `CLUSTER BY` keeps that metadata tight as data is loaded out of order. Mapping: `DIM_CUSTOMER` → `CLUSTER BY (ONBOARDING_DATE)`, `DIM_ACCOUNT` → `CLUSTER BY (OPENING_DATE)`, `FACT_TRANSACTION` → `CLUSTER BY (TRANSACTION_DATE)`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT` → `CLUSTER BY (SNAPSHOT_DATE)`. `DIM_PRODUCT`, `DIM_BRANCH`, `DIM_DATE` were not partitioned and are small, so they get only the PK. The `NO RANGE` partition (dates outside 2018–2030) has no equivalent and is no longer needed. **Action:** after the production load, check pruning for the main date-filtered workloads (`VW_BRANCH_PERFORMANCE`, `SP_MONTHLY_SNAPSHOT`, the 90-day window in `VW_CUSTOMER_360`, the regulatory extract) with the query profile ("Partitions scanned" vs "Partitions total") and with `SYSTEM$CLUSTERING_INFORMATION('BANKING_DW.FACT_TRANSACTION')`. Consider `CLUSTER BY (TRANSACTION_DATE, ACCOUNT_KEY)` if account-level lookups dominate, and drop clustering on the dimensions if Automatic Clustering credits are not justified.
4. **`FORMAT` masks turn columns into VARCHAR.** Teradata `FORMAT` only changed how a numeric/date value was displayed, and the column stayed numeric. `TO_CHAR` returns a string. Affected columns: `VW_CUSTOMER_360.TOTAL_BALANCE`, `.TXN_AMOUNT_LAST_90_DAYS`, `VW_BRANCH_PERFORMANCE.TOTAL_DEPOSITS`, `.PCT_OF_REGION_DEPOSITS`, and all formatted UDTF columns. Downstream consumers that sum, sort or compare these columns must use the numeric source (`TOTAL_VOLUME`, the snapshot table, or the UDTF `SORT_AMOUNT`) or cast back with `TO_NUMBER(col, '999,999,990.00')`. Mask translation: Teradata `Z` (zero-suppressed digit) → Snowflake `9`, Teradata `9` (always shown) → Snowflake `0`, so `ZZZ,ZZZ,ZZ9.99` → `999,999,990.00` (values below 1 render as `0.50`, as in Teradata). `S` (sign) is kept. Snowflake left-pads to the mask width; wrap in `TRIM()` if needed. Alternative if typed columns are preferred: keep the views numeric and apply `TO_CHAR` only in the extract scripts.
5. **`HASH()` ≠ `HASHROW()`.** Snowflake `HASH()` is a different 64-bit algorithm with a different value domain from Teradata `HASHROW()`. `ROW_HASH` in `VW_REGULATORY_LARGE_TRANSACTIONS` and `HASH_SUM` in the checksum queries can **never** be compared across platforms. Checksum reconciliation must be recomputed on both sides with a portable function: either the neutral fingerprints in `snowflake/validation/checksum_queries.sql` (`ID_SUM`, `LEN_SUM`, counts, min/max, amount sums), or an identical string hash (e.g. `MD5` of a normalised, `'|'`-delimited, upper-cased row string, with Teradata's MD5 UDF/`HASH_MD5` where installed). Anything persisted from `HASHROW` (e.g. old regulatory submissions) must be regenerated, not migrated.
6. **CSUM/MAVG partitioning correction (`VW_BRANCH_PERFORMANCE`).** The original `CSUM(SUM(FEES_CHARGED), SNAPSHOT_MONTH_KEY)` and `MAVG(…, 3, SNAPSHOT_MONTH_KEY)` have no partition, so a literal translation would accumulate and average across **all branches** in month order. That contradicts the column names `CUMULATIVE_FEES_YTD` and `MOVING_AVG_VOLUME_3M` in a per-branch view. (Teradata's legacy OLAP functions also treat a `GROUP BY` as a reset clause, which makes the original's intent ambiguous. This was not checked against a live Teradata system.) Decision: `CUMULATIVE_FEES_YTD = SUM(SUM(FEES_CHARGED)) OVER (PARTITION BY BRANCH_ID, CALENDAR_YEAR ORDER BY SNAPSHOT_MONTH_KEY ROWS UNBOUNDED PRECEDING)` and `MOVING_AVG_VOLUME_3M = AVG(SUM(TOTAL_DEBITS + TOTAL_CREDITS)) OVER (PARTITION BY BRANCH_ID ORDER BY SNAPSHOT_MONTH_KEY ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`. Consequences: values will **not** match the Teradata view row-for-row, so reconcile them against an independent per-branch calculation, not against the old view. `ROWS` windows count rows, not calendar months, so a branch with a missing month averages over non-adjacent months (same as MAVG). The view's 24-month filter means the first months in the window start their YTD/moving average from the filtered data.
7. **`NOT CASESPECIFIC` → `COLLATE 'en-ci'`.** Every column declared `NOT CASESPECIFIC` now carries `COLLATE 'en-ci'`, so `=`, `IN`, `GROUP BY`, `DISTINCT`, `ORDER BY` and joins on those columns stay case-insensitive (accent-sensitive, as in Teradata). The alternative, normalising with `UPPER()`/`LOWER()` in queries and loaders, was rejected because every query would have to remember it. Things to know: (a) collation applies only where a collated column is involved; comparisons between two uncollated staging columns stay case-sensitive; (b) when a collated column is compared with an uncollated one, the explicit collation wins, so `SP_CUSTOMER_SCD2` does not open a new SCD2 version for case-only changes (e.g. `oslo` → `Oslo`), which matches the Teradata behaviour; (c) Snowflake documents restrictions and performance costs for collated columns (some string functions do not support collation, and comparisons/pruning can be slower). Columns that never had `NOT CASESPECIFIC` (e.g. `PHONE_NUMBER`, `POSTAL_CODE`, codes such as `BRANCH_CODE`) were left uncollated, assuming the source system runs in ANSI mode, where the default is CASESPECIFIC. If the Teradata system runs in TERA mode (default NOT CASESPECIFIC), revisit these columns. `en-ci` sorts Norwegian letters (æ, ø, å) by English rules. Use `nb-ci` if Norwegian sort order matters for reports.

### 4.1 Additional corrections found during conversion

These are defects in the Teradata sources that would have broken or skewed results on either platform. Each is fixed in the Snowflake version and marked `CORRECTION` in the file header. Revert any of them if strict output parity with the current Teradata output is required during parallel run.

| Where | Original problem | Snowflake fix |
|---|---|---|
| `SP_CUSTOMER_SCD2`, step 2 | `QUALIFY ROW_NUMBER() OVER (PARTITION BY existing.CUSTOMER_ID …)` — `existing` is the LEFT-JOINed expired version, so the partition key is NULL for every brand-new customer and only **one new customer per batch** survives. `QUALIFY` was also written before `WHERE`. | Partition by `stg.CUSTOMER_ID`; `ORDER BY existing.EFFECTIVE_TO DESC NULLS LAST`; `QUALIFY` after `WHERE`. Verified: 2 changed + 2 new customers produce 4 inserts. |
| `SP_MONTHLY_SNAPSHOT` | `v_prev_snapshot_date = ADD_MONTHS(v_period_start, -1)` is the **first** day of the previous month, but `SNAPSHOT_DATE` is always a month end, so the join to the previous snapshot never matched and `OPENING_BALANCE` was always 0 (and `CLOSING_BALANCE` ignored history). | `v_prev_snapshot_date = v_period_start - 1 day` (previous month end). Verified: month 2 opening = month 1 closing. |
| `SP_MONTHLY_SNAPSHOT` | Selects `a.CUSTOMER_KEY` from `DIM_ACCOUNT`, which has no `CUSTOMER_KEY` column. The join to `DIM_CUSTOMER c` was otherwise unused. | `c.CUSTOMER_KEY`. |
| `DAILY_BALANCE_CHECK` macro, result 1 | `QUALIFY ROW_NUMBER() OVER (PARTITION BY ft.ACCOUNT_KEY …)` combined with `GROUP BY ACCOUNT_TYPE, CURRENCY_CODE`; `ACCOUNT_KEY` is not grouped, so the query is invalid. | Latest transaction per account in a CTE first, then aggregate. |
| `VW_CUSTOMER_360` | Correlated scalar subquery with `QUALIFY` nested inside `SUM(CASE …)`. | `LATEST_SNAPSHOT` CTE + join. Same result: accounts without snapshots contribute NULL, which `SUM` ignores. |
| `bteq_daily_load.btq` | `.IF ACTIVITYCOUNT = 0` after an aggregate query (always 1 row), so the NOSTAGING branch never fired. `.IF ERRORCODE` after `CALL SP_LOAD_DAILY_TRANSACTIONS` never fires because the procedure's exit handler swallows errors. `MAX(BATCH_ID)+1` is NULL on an empty control table. | Test the staged row count. Check `P_RETURN_CODE` from each procedure. `COALESCE(MAX(BATCH_ID), 0) + 1`. |

Observations left unchanged (business-rule questions, not translation issues): `DAYS_IN_OVERDRAFT` counts transactions with a negative running balance, not days. `OVER_LIMIT_AMOUNT = RUNNING_BALANCE - OVERDRAFT_LIMIT` (probably intended `+`). `NEGATIVE_BALANCE_ALERT` filters `RUNNING_BALANCE < 0` before picking the latest transaction, so it reports the latest *negative* transaction, not accounts whose latest balance is negative. `SP_LOAD_DAILY_TRANSACTIONS` converts non-NOK amounts with `ZEROIFNULL(rate)`, so a missing FX rate loads a zero base amount.

## 5. Per-file changes — DDL

### 5.1 `snowflake/ddl/tables/01_dim_customer.sql` (from `ddl/tables/01_dim_customer.sql`)
- `CREATE SET TABLE … NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM = DEFAULT, DEFAULT MERGEBLOCKRATIO` → `CREATE OR REPLACE TABLE BANKING_DW.DIM_CUSTOMER`; header comment on SET → duplicates (decision 1).
- `CUSTOMER_KEY … GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1)` → `AUTOINCREMENT START 1 INCREMENT 1`.
- `COLLATE 'en-ci'` on FIRST_NAME, LAST_NAME, EMAIL_ADDRESS, ADDRESS_LINE_1, ADDRESS_LINE_2, CITY, STATE_PROVINCE, COUNTRY_CODE, CUSTOMER_SEGMENT, KYC_STATUS (10 `NOT CASESPECIFIC` columns).
- `COMPRESS` removed from GENDER, MARITAL_STATUS, ADDRESS_LINE_2, CUSTOMER_SEGMENT, CREDIT_RATING, KYC_STATUS, IS_ACTIVE, CURRENT_FLAG.
- `DATE FORMAT` removed from DATE_OF_BIRTH, ONBOARDING_DATE, LAST_REVIEW_DATE. `IS_ACTIVE BYTEINT` → `NUMBER(3,0)`. `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)` (EFFECTIVE_FROM, EFFECTIVE_TO, ETL_INSERT_TS, ETL_UPDATE_TS), with defaults kept (`CURRENT_TIMESTAMP(0)`, `TIMESTAMP '9999-12-31 23:59:59'`).
- `UNIQUE PRIMARY INDEX UPI_CUSTOMER_KEY (CUSTOMER_KEY)` → `CONSTRAINT PK_DIM_CUSTOMER PRIMARY KEY (CUSTOMER_KEY)`.
- Secondary indexes NUPI_CUSTOMER_ID, IDX_CUST_SEGMENT, IDX_CUST_COUNTRY removed.
- `PARTITION BY RANGE_N(ONBOARDING_DATE … EACH INTERVAL '1' YEAR)` → `CLUSTER BY (ONBOARDING_DATE)`.
- 4 `COLLECT STATISTICS` removed. `COMMENT ON TABLE` and 3 `COMMENT ON COLUMN` kept.

### 5.2 `snowflake/ddl/tables/02_dim_account.sql`
- MULTISET header → `CREATE OR REPLACE TABLE BANKING_DW.DIM_ACCOUNT`.
- `ACCOUNT_KEY` identity → `AUTOINCREMENT START 1 INCREMENT 1`.
- `COLLATE 'en-ci'` on ACCOUNT_TYPE, ACCOUNT_SUBTYPE, CURRENCY_CODE, ACCOUNT_STATUS.
- `COMPRESS` removed (ACCOUNT_TYPE, ACCOUNT_SUBTYPE, CURRENCY_CODE, ACCOUNT_STATUS, CREDIT_LIMIT, RELATIONSHIP_MGR_ID, IS_JOINT_ACCOUNT, TAX_REPORTING_FLAG, CURRENT_FLAG).
- `DATE FORMAT` removed (OPENING_DATE, CLOSING_DATE). `BYTEINT` → `NUMBER(3,0)` (IS_JOINT_ACCOUNT, TAX_REPORTING_FLAG). `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)` with defaults kept.
- UPI `(ACCOUNT_KEY)` → `CONSTRAINT PK_DIM_ACCOUNT PRIMARY KEY (ACCOUNT_KEY)`. 4 secondary indexes removed.
- `PARTITION BY RANGE_N(OPENING_DATE … '1' YEAR)` → `CLUSTER BY (OPENING_DATE)`.
- 5 `COLLECT STATISTICS` removed. `COMMENT ON TABLE` kept.

### 5.3 `snowflake/ddl/tables/03_dim_product.sql`
- SET header → `CREATE OR REPLACE TABLE BANKING_DW.DIM_PRODUCT` + duplicates comment.
- `COLLATE 'en-ci'` on PRODUCT_NAME, PRODUCT_CATEGORY, PRODUCT_SUBCATEGORY.
- `COMPRESS` removed (PRODUCT_CATEGORY, FEE_STRUCTURE, MONTHLY_FEE `COMPRESS 0`, IS_REGULATED, IS_ACTIVE).
- `DATE FORMAT` removed (LAUNCH_DATE, DISCONTINUE_DATE). `BYTEINT` → `NUMBER(3,0)` (IS_REGULATED, IS_ACTIVE). `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)`.
- UPI `(PRODUCT_ID)` → `PRIMARY KEY (PRODUCT_ID)`. IDX_PROD_CODE, IDX_PROD_CATEGORY removed. No partition, so no `CLUSTER BY` (10-row table).
- 2 `COLLECT STATISTICS` removed. `COMMENT ON TABLE` kept.

### 5.4 `snowflake/ddl/tables/04_dim_branch.sql`
- SET header → `CREATE OR REPLACE TABLE BANKING_DW.DIM_BRANCH` + duplicates comment.
- `COLLATE 'en-ci'` on BRANCH_NAME, BRANCH_TYPE, ADDRESS_LINE_1, CITY, COUNTY, REGION.
- `COMPRESS` removed (BRANCH_TYPE, REGION, IS_ACTIVE, EMPLOYEE_COUNT `COMPRESS 0`).
- `DATE FORMAT` removed (OPENING_DATE, CLOSING_DATE). `IS_ACTIVE BYTEINT` → `NUMBER(3,0)`. `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)`.
- UPI `(BRANCH_ID)` → `PRIMARY KEY (BRANCH_ID)`. IDX_BRANCH_CODE, IDX_BRANCH_REGION removed. No `CLUSTER BY`.
- 2 `COLLECT STATISTICS` removed. `COMMENT ON TABLE` kept.

### 5.5 `snowflake/ddl/tables/05_dim_date.sql`
- SET header → `CREATE OR REPLACE TABLE BANKING_DW.DIM_DATE` + duplicates comment.
- 15 `BYTEINT` columns → `NUMBER(3,0)` (DAY_OF_WEEK … IS_YEAR_END). `SMALLINT` kept.
- `COMPRESS` removed (QUARTER_NUM, HALF_YEAR, IS_* flags, HOLIDAY_NAME `COMPRESS ''`).
- `DATE FORMAT` removed (CALENDAR_DATE, PRIOR_DAY_DATE, NEXT_DAY_DATE, SAME_DAY_PREV_YEAR).
- UPI `(DATE_KEY)` → `PRIMARY KEY (DATE_KEY)`. IDX_CALENDAR_DATE, IDX_YEAR_MONTH removed. No `CLUSTER BY` (~11k rows).
- 3 `COLLECT STATISTICS` removed. `COMMENT ON TABLE` kept. The table had no `NOT CASESPECIFIC` columns.

### 5.6 `snowflake/ddl/tables/06_fact_transaction.sql`
- MULTISET header → `CREATE OR REPLACE TABLE BANKING_DW.FACT_TRANSACTION`.
- `COLLATE 'en-ci'` on TRANSACTION_TYPE, TRANSACTION_SUBTYPE, CHANNEL, TRANSACTION_CURRENCY, MERCHANT_NAME, DESCRIPTION_TEXT.
- `COMPRESS` removed (TRANSACTION_TYPE, TRANSACTION_SUBTYPE, CHANNEL, TRANSACTION_CURRENCY, IS_INTERNATIONAL, IS_FLAGGED, FLAG_REASON).
- `DATE FORMAT` removed (TRANSACTION_DATE, POSTING_DATE, VALUE_DATE). `TIME(0)` kept. `TIMESTAMP(6)` → `TIMESTAMP_NTZ(6)` (TRANSACTION_TS). `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)`. `BYTEINT` → `NUMBER(3,0)`. `DEFAULT 'NOK'`, `DEFAULT 1.000000` kept.
- `PRIMARY INDEX PI_FACT_TXN (ACCOUNT_KEY, TRANSACTION_DATE)` (non-unique) → no PK (decision 2).
- `PARTITION BY RANGE_N(TRANSACTION_DATE BETWEEN DATE '2018-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' MONTH, NO RANGE)` → `CLUSTER BY (TRANSACTION_DATE)`.
- 7 `COLLECT STATISTICS` removed, including `COLUMN (PARTITION)`. `COMMENT ON TABLE` kept verbatim. Its text still mentions "PPI"; update the comment wording after cut-over if desired.

### 5.7 `snowflake/ddl/tables/07_fact_monthly_snapshot.sql`
- MULTISET header → `CREATE OR REPLACE TABLE BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT`.
- `COMPRESS` removed (DAYS_IN_OVERDRAFT, DAYS_DORMANT, CURRENCY_CODE). `DATE FORMAT` removed (SNAPSHOT_DATE). `TIMESTAMP(0)` → `TIMESTAMP_NTZ(0)`.
- `PRIMARY INDEX PI_MONTHLY_SNAP (ACCOUNT_KEY, SNAPSHOT_MONTH_KEY)` (non-unique) → no PK. The grain is kept by the MERGE.
- `PARTITION BY RANGE_N(SNAPSHOT_DATE … '1' MONTH, NO RANGE)` → `CLUSTER BY (SNAPSHOT_DATE)`.
- 3 `COLLECT STATISTICS` removed, including `COLUMN (PARTITION)`. `COMMENT ON TABLE` kept.

### 5.8 `snowflake/ddl/views/01_vw_customer_360.sql`
- `REPLACE VIEW` → `CREATE OR REPLACE VIEW`. `LOCKING ROW FOR ACCESS` removed. `SEL` → `SELECT`.
- The correlated scalar subquery `(SEL CLOSING_BALANCE … QUALIFY ROW_NUMBER() …)` inside `SUM(CASE WHEN CURRENT_FLAG = 'Y' …)` → CTE `LATEST_SNAPSHOT` (latest snapshot per `ACCOUNT_KEY` via `QUALIFY`) LEFT JOINed in CTE `ACCT_SUMMARY`. The `CASE WHEN CURRENT_FLAG = 'Y'` was redundant with the subquery's `WHERE a.CURRENT_FLAG = 'Y'` and was dropped. Derived tables became CTEs, and `GROUP BY 1` became an explicit column.
- `(FORMAT 'ZZZ,ZZZ,ZZ9.99')` → `TO_CHAR(…, '999,999,990.00')` on TOTAL_BALANCE and TXN_AMOUNT_LAST_90_DAYS, which are now VARCHAR (decision 4).
- `(CURRENT_DATE - ONBOARDING_DATE) / 365.25` → `DATEDIFF('day', ONBOARDING_DATE, CURRENT_DATE()) / 365.25`. `CURRENT_DATE - 90` → `DATEADD('day', -90, CURRENT_DATE())`. `ZEROIFNULL` kept. `COMMENT ON VIEW` kept.

### 5.9 `snowflake/ddl/views/02_vw_regulatory_large_transactions.sql`
- `REPLACE VIEW` → `CREATE OR REPLACE VIEW`. `LOCKING ROW FOR ACCESS` removed. `SEL` → `SELECT`.
- `c.FIRST_NAME (NOT CASESPECIFIC)`, `c.LAST_NAME (NOT CASESPECIFIC)` → plain columns (collated in `DIM_CUSTOMER`, decision 7). Wrap in `UPPER()` at the call site if an uncollated copy is ever matched.
- `HASHROW(ft.TRANSACTION_ID, ft.TRANSACTION_DATE)` → `HASH(ft.TRANSACTION_ID, ft.TRANSACTION_DATE)` (decision 5).
- `QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY ETL_BATCH_ID DESC) = 1` kept. `COMMENT ON VIEW` kept.

### 5.10 `snowflake/ddl/views/03_vw_branch_performance.sql`
- `REPLACE VIEW` → `CREATE OR REPLACE VIEW`. `LOCKING ROW FOR ACCESS` removed. `SEL` → `SELECT`.
- `CSUM(SUM(FEES_CHARGED), SNAPSHOT_MONTH_KEY)` → `SUM(SUM(FEES_CHARGED)) OVER (PARTITION BY BRANCH_ID, CALENDAR_YEAR ORDER BY SNAPSHOT_MONTH_KEY ROWS UNBOUNDED PRECEDING)`.
- `MAVG(SUM(TOTAL_DEBITS + TOTAL_CREDITS), 3, SNAPSHOT_MONTH_KEY)` → `AVG(SUM(…)) OVER (PARTITION BY BRANCH_ID ORDER BY SNAPSHOT_MONTH_KEY ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`. Partitioning added (decision 6).
- `TRIM(d.CALENDAR_YEAR (FORMAT '9999'))` → `TRIM(TO_CHAR(d.CALENDAR_YEAR, '0000'))`. `SUM(CLOSING_BALANCE) (FORMAT 'ZZZ,ZZZ,ZZZ,ZZ9.99')` → `TO_CHAR(…, '999,999,999,990.00')`. `… * 100 (FORMAT 'ZZ9.99')` → `TO_CHAR(… * 100, '990.00')`, so TOTAL_DEPOSITS and PCT_OF_REGION_DEPOSITS are now VARCHAR.
- `NULLIFZERO`, `RANK() OVER`, `SUM(SUM(…)) OVER`, `ADD_MONTHS(CURRENT_DATE(), -24)` kept. `COMMENT ON VIEW` kept.
- Decimal division: Snowflake and Teradata derive the scale of `DECIMAL / DECIMAL` differently, so the last digit of PCT_OF_REGION_DEPOSITS can differ before rounding to 2 decimals. Compare it with a ±0.01 tolerance.

## 6. Per-file changes — DML (stored procedures, macros, callers)

### 6.1 Stored procedures → Snowflake Scripting (`snowflake/dml/stored_procedures/`)

| File | Signature change | Key rewrites |
|---|---|---|
| `sp_customer_scd2.sql` | `(IN p_batch_id, OUT p_new_rows, OUT p_changed, OUT p_return_code)` → `SP_CUSTOMER_SCD2(P_BATCH_ID BIGINT) RETURNS OBJECT {P_NEW_ROWS, P_CHANGED, P_RETURN_CODE}` | Teradata `UPDATE … FROM (subquery) SET …` → Snowflake `UPDATE … SET … FROM (SELECT DISTINCT …) src WHERE …`. `ACTIVITY_COUNT` → `SQLROWCOUNT`. `QUALIFY` moved after `WHERE` and partition-key correction (§4.1). `CURRENT_DATE` → `CURRENT_DATE()`. `COLLECT STATISTICS` removed. `CUSTOMER_KEY` is generated by AUTOINCREMENT, as before. |
| `sp_load_daily_transactions.sql` | `(IN p_batch_date DATE FORMAT …, IN p_batch_id, OUT ×3)` → `SP_LOAD_DAILY_TRANSACTIONS(P_BATCH_DATE DATE, P_BATCH_ID BIGINT) RETURNS OBJECT {P_ROWS_INSERTED, P_ROWS_REJECTED, P_RETURN_CODE}` | `DECLARE EXIT HANDLER FOR SQLEXCEPTION` → `EXCEPTION WHEN OTHER THEN` (logs `SQLCODE` + `SQLERRM` to `ETL_LOG`, returns the code and does not re-raise, matching Teradata). `ACTIVITY_COUNT` → `SQLROWCOUNT`. `date (TIMESTAMP(6)) + (time - TIME '00:00:00' HOUR TO SECOND)` → `TIMESTAMP_NTZ_FROM_PARTS(date, time)`. `CAST(CAST(date AS DATE FORMAT 'YYYYMMDD') AS INTEGER)` → `YEAR(date) * 10000 + MONTH(date) * 100 + DAY(date)`. `TRIM(x (FORMAT 'Z(9)9'))` → `TO_VARCHAR(x)`. `(CURRENT_TIMESTAMP - start) SECOND(4)` → `DATEDIFF('second', …)`. `ZEROIFNULL` kept. `COLLECT STATISTICS` removed. |
| `sp_monthly_snapshot.sql` | `(IN year, IN month, IN batch, OUT p_rows_merged, OUT p_return_code)` → `SP_MONTHLY_SNAPSHOT(P_SNAPSHOT_YEAR, P_SNAPSHOT_MONTH, P_BATCH_ID) RETURNS OBJECT {P_ROWS_MERGED, P_RETURN_CODE}` | String-built `CAST(… AS DATE FORMAT 'YYYY-MM-DD')` → `DATE_FROM_PARTS`. `ADD_MONTHS(start, 1) - 1` → `DATEADD('day', -1, ADD_MONTHS(start, 1))`. `CREATE VOLATILE TABLE … WITH DATA PRIMARY INDEX (ACCOUNT_KEY) ON COMMIT PRESERVE ROWS` → `CREATE OR REPLACE TEMPORARY TABLE BANKING_DW.VT_TXN_AGGREGATES AS SELECT …`. `x (SMALLINT)` → `CAST(x AS SMALLINT)`. `(end - start + 1)` → `DATEDIFF + 1`. `MERGE INTO`, `ZEROIFNULL`, `ADD_MONTHS` kept. `DROP TABLE` → `DROP TABLE IF EXISTS`. Corrections for the previous-snapshot date and `CUSTOMER_KEY` (§4.1). |

Notes:
- Snowflake runs each DML statement in autocommit mode, as Teradata did in this BTEQ (Teradata-mode) setup. A failure halfway (e.g. after rejects were written) leaves the same partial state on both platforms. Wrap the body in `BEGIN TRANSACTION … COMMIT` if all-or-nothing is required.
- The procedures are owner's rights (the default). The ETL role that owns them needs DML on the BANKING_DW tables and `CREATE TABLE` (for the temporary table) on the schema. Use `EXECUTE AS CALLER` if the existing Teradata grants model per-user rights.

### 6.2 Macros → SQL table functions (`snowflake/dml/macros/`)

| Macro | Snowflake object(s) | Notes |
|---|---|---|
| `CUSTOMER_TXN_HISTORY(cust_id, start_date DEFAULT DATE - 30, end_date DEFAULT DATE, txn_type DEFAULT 'ALL')` | UDTF `BANKING_DW.CUSTOMER_TXN_HISTORY(CUST_ID, START_DATE DEFAULT DATEADD('day', -30, CURRENT_DATE()), END_DATE DEFAULT CURRENT_DATE(), TXN_TYPE DEFAULT 'ALL')` | Single result set → parameterized view. `SAMPLE 1000` → `QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= 1000`. If the real intent was "latest 1000", use `ORDER BY TXN_DATE DESC, TXN_TIME DESC LIMIT 1000` at the call site. `(FORMAT 'HH:MI:SS')` → `TO_CHAR(time, 'HH24:MI:SS')` (Teradata `HH` is 24-hour). `'S ZZZ,ZZZ,ZZ9.99'` → `'S999,999,990.00'`. `ORDER BY` moves to the caller. TXN_DATE/TXN_TIME are zero-padded strings, so they sort correctly. |
| `DAILY_BALANCE_CHECK(check_date)` (2 result sets) | UDTFs `DAILY_BALANCE_SUMMARY(CHECK_DATE)` and `DAILY_NEGATIVE_BALANCE_ALERT(CHECK_DATE)` | One function per result set. Summary rewritten as latest-transaction CTE, then `GROUP BY` (§4.1). `SORT_AMOUNT` (numeric) added for the alert's `ORDER BY RUNNING_BALANCE`. |
| `AML_SCREENING(screening_date DEFAULT DATE, lookback_days DEFAULT 30, amount_threshold DEFAULT 50000.00)` (3 result sets) | UDTFs `AML_STRUCTURING`, `AML_RAPID_MOVEMENT`, `AML_NEW_CUSTOMER_INTL`, each with the macro's defaults | **Option chosen: three parameterized views (UDTFs).** The multi-statement-procedure alternative was rejected because a Snowflake procedure returns only one result set, so it would need a union of three different row shapes (e.g. a `VARIANT` payload) or result tables, and callers would lose typed columns. `SORT_AMOUNT` added for each pattern's `ORDER BY`. |

Call pattern: `EXEC BANKING_DW.AML_SCREENING(CURRENT_DATE, 30, 50000.00);` → `SELECT * FROM TABLE(BANKING_DW.AML_STRUCTURING(CURRENT_DATE(), 30, 50000.00)) ORDER BY SORT_AMOUNT DESC;` (plus the other two). Named arguments with defaults also work: `TABLE(BANKING_DW.CUSTOMER_TXN_HISTORY(CUST_ID => 1001, TXN_TYPE => 'DEBIT'))`.

### 6.3 Callers (`snowflake/dml/scripts/`)

All callers of the procedures and macros are the two BTEQ scripts. Both were rewritten for SnowSQL. A scheduler wrapper invokes them with `-o exit_on_error=true -o variable_substitution=true` and `-D run_date=…`/`run_month=…` (BTEQ had literal `YYYYMMDD` placeholders in file names).

| BTEQ | `daily_load.sql` / `extract_report.sql` |
|---|---|
| `.LOGON TDPROD/etl_svc_acct` | SnowSQL named connection (`-c etl_svc`). Credentials live in the SnowSQL config or key-pair auth, not in the script. |
| `DATABASE BANKING_DW;` | `USE SCHEMA BANKING_DW;` |
| `.IF ACTIVITYCOUNT = 0 THEN .GOTO NOSTAGING` / `.QUIT 4` | `EXECUTE IMMEDIATE $$ … IF (v_staged = 0) THEN RAISE no_staging; … $$` with user exception `-20004`. |
| `.IF ERRORCODE <> 0 THEN .GOTO ERRORHANDLER` / `.QUIT 8` | Nested `BEGIN … EXCEPTION WHEN OTHER THEN` that writes the `FAILED` row to `ETL_BATCH_CONTROL` and raises `-20008`. Procedure return codes are checked via `RESULT_SCAN(LAST_QUERY_ID())`. |
| `CREATE VOLATILE TABLE VT_BATCH` | `CREATE OR REPLACE TEMPORARY TABLE BANKING_DW.VT_BATCH` (lives for the SnowSQL session). |
| `CALL SP_…(…, out1, out2, out3)` | `CALL SP_…(…)`, which returns the OBJECT. |
| `EXEC DAILY_BALANCE_CHECK(CURRENT_DATE)` | two `SELECT * FROM TABLE(…)` queries. |
| `EXEC AML_SCREENING(…)` | three `SELECT * FROM TABLE(…)` queries spooled into the same file. |
| `.EXPORT REPORT/DATA FILE=…` / `.EXPORT RESET` | `!spool <file>` / `!spool off` with `output_format=psql` (report) or `csv` (data). For large regulatory files use `COPY INTO @stage … FILE_FORMAT=(TYPE=CSV)` + `GET`. Note: BTEQ `.EXPORT DATA` wrote Teradata binary record format; the CSV output changes the file contract for downstream consumers. |
| `(CHAR(n))`, `(FORMAT …)` in extracts | dropped for CSV / `TO_CHAR(…)`. Use `RPAD()` if a fixed-width layout must be reproduced. |
| BTEQ exit codes 0/4/8 | SnowSQL exits 0 on success and non-zero on any error. The wrapper distinguishes "no data" (-20004) from failure (-20008) via the error number in the log. |

## 7. Loading approach

### 7.1 Seed and bulk data
`snowflake/dml/scripts/load_seed_data.sql`: pipe-delimited file format (`FIELD_DELIMITER='|'`, `SKIP_HEADER=1`, `EMPTY_FIELD_AS_NULL=TRUE`), internal stage, `PUT file://data/seed/*.csv`, `COPY INTO … (column list) … ON_ERROR = ABORT_STATEMENT`. For the full historical migration: unload each Teradata table with TPT Export (or `FastExport`) to delimited, compressed files, upload them to cloud storage, point an external stage at them, and `COPY INTO` table by table in the DDL order. Run the dedup checks (decision 1) before the dimensions are used.

### 7.2 Surrogate keys
`CUSTOMER_KEY` and `ACCOUNT_KEY` are referenced by both fact tables, so a historical migration must **preserve the Teradata key values**. Load them explicitly: Snowflake `AUTOINCREMENT` columns accept explicit values (unlike Teradata `GENERATED ALWAYS`). Then make sure new keys start above the migrated maximum, e.g. create the tables with `AUTOINCREMENT START <max+1>`. Snowflake identity values are unique but not guaranteed gap-free or strictly sequential, which is fine for surrogate keys.

### 7.3 Supporting tables
The procedures and scripts also use `STG_CUSTOMER`, `STG_TRANSACTIONS`, `STG_TRANSACTION_ERRORS`, `DIM_EXCHANGE_RATES`, `ETL_LOG` and `ETL_BATCH_CONTROL`, which are **not defined in this repository**. `snowflake/validation/fixtures_supporting_tables.sql` contains shapes inferred from the column lists, for validation only. Migrate the real DDL of these tables with the same rules before cut-over.

## 8. Validation approach

Validation is based on [`data/validation/expected_row_counts.csv`](data/validation/expected_row_counts.csv) and [`data/validation/checksum_queries.sql`](data/validation/checksum_queries.sql):

1. **Row counts.** After each load, compare `COUNT(*)` per table with `expected_row_counts.csv` (and, during parallel run, with the same query on Teradata). Query 1 of `snowflake/validation/checksum_queries.sql` produces the same layout.
2. **Column and aggregate checksums.** Run `data/validation/checksum_queries.sql` on Teradata and `snowflake/validation/checksum_queries.sql` on Snowflake, then diff the result sets query by query: per-month transaction counts and amount sums (query 3), monthly balance totals (query 4), and referential integrity (query 5, rewritten from `NOT IN` to `NOT EXISTS`). Compare everything except `HASH_SUM` (decision 5). Use the platform-neutral `ID_SUM`/`LEN_SUM` fingerprints or an agreed MD5-based row hash instead. `LEN_SUM` assumes the Teradata side has no trailing-space padding (`CHAR` vs `VARCHAR`); `TRIM` both sides if needed.
3. **Uniqueness.** Query 6 replaces the implicit SET/UPI guarantees: it must return 0 duplicates for every declared PK and grain.
4. **Business-level reconciliation.** Compare the views' outputs on both platforms for a fixed reference date. Expect intentional differences only in `VW_BRANCH_PERFORMANCE.CUMULATIVE_FEES_YTD`/`MOVING_AVG_VOLUME_3M` (decision 6) and in snapshot opening/closing balances (corrections in §4.1). Compare formatted VARCHAR columns after `TO_NUMBER`.
5. **Automated harness.** `snowflake/validation/run_validation.py` deploys all converted objects into a scratch database, loads the seed CSVs, generates `DIM_DATE` (2000-01-01 … 2029-12-31, with Norwegian public holidays), reconciles the row counts against `expected_row_counts.csv`, runs every checksum query, and exercises each procedure, view and UDTF against hand-computed expected results (SCD2 versioning, the error handler, snapshot opening balances, per-branch windows, dedup, AML patterns, defaults).

   ```bash
   pip install -r snowflake/validation/requirements.txt
   export SNOWFLAKE_ACCOUNT=… SNOWFLAKE_USER=… SNOWFLAKE_PASSWORD=… SNOWFLAKE_WAREHOUSE=… SNOWFLAKE_ROLE=…
   python snowflake/validation/run_validation.py --target snowflake --report validation_report.json
   python snowflake/validation/run_validation.py --target emulator   # offline, no account needed
   ```

   `--target snowflake` uses `SNOWFLAKE_DATABASE` (default `BANKING_MIGRATION_VALIDATION`) and runs `CREATE OR REPLACE`, so never point it at a database with real data. `--target emulator` runs the same checks on [fakesnow](https://github.com/tekumara/fakesnow) (Snowflake SQL on DuckDB). It strips `COLLATE`, ignores `TO_CHAR` masks and `CLUSTER BY`, and interprets the procedure and UDTF bodies statement by statement, so collation, number formatting and Snowflake Scripting syntax are confirmed only by a real-account run.

### 8.1 Validation status

| Check | Status |
|---|---|
| Snowflake-dialect parse of all converted files (sqlglot) | Passed. Snowflake Scripting blocks, `PUT` and `EXECUTE IMMEDIATE` are not parsed by sqlglot. |
| Emulator (`--target emulator`, fakesnow 0.12 / DuckDB): deploy of all 10 DDL files, 3 procedures, 6 UDTFs; seed load; row-count reconciliation DIM_CUSTOMER 15, DIM_ACCOUNT 20, DIM_PRODUCT 10, DIM_BRANCH 14, DIM_DATE 10958; all 6 checksum queries; 0 PK duplicates; 30 behavioural checks | Passed (77 checks passed, 0 failed, 3 not applicable). |
| `FACT_TRANSACTION` (50000) and `FACT_MONTHLY_ACCOUNT_SNAPSHOT` (1920) row counts | **Open.** The repo has no source extract for the facts (the CSV marks them "approximate"). Reconcile after the Teradata unload. |
| Real Snowflake compile + reconciliation (`--target snowflake`) | **Open.** No Snowflake account was available to this migration session. Run it before declaring the migration complete. |
| Teradata-side checksum run for the cross-platform diff | **Open.** Needs access to the source system. |

## 9. Cut-over checklist

- [ ] Run `run_validation.py --target snowflake` in a scratch database: all checks pass.
- [ ] Migrate DDL of STG_/ETL_/DIM_EXCHANGE_RATES tables (§7.3).
- [ ] Unload Teradata history, load with preserved surrogate keys, reset identity starts (§7.2).
- [ ] Row counts and checksums match Teradata for every table (§8, items 1–3).
- [ ] Business sign-off on decisions 4 and 6 and the §4.1 corrections (or revert them for parallel-run parity).
- [ ] Pruning re-validated on the fact tables (decision 3).
- [ ] Scheduler switched from BTEQ to the SnowSQL scripts; exit-code handling updated (§6.3).
- [ ] Downstream consumers of the VARCHAR-formatted columns and of `ROW_HASH`/CSV extracts informed (decisions 4, 5; §6.3).
