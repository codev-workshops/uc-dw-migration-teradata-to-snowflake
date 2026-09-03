# Teradata Features Used in This Data Warehouse

This document catalogs Teradata-specific SQL features used throughout the codebase, along with notes on Snowflake equivalents for migration planning.

## DDL Features

| Feature | Where Used | Migration Notes |
|---------|-----------|-----------------|
| `CREATE SET TABLE` | All dimension tables | Snowflake has no SET/MULTISET distinction. All tables allow duplicates. Enforce uniqueness via constraints if needed. |
| `CREATE MULTISET TABLE` | Fact tables | Direct mapping to standard `CREATE TABLE` |
| `NO FALLBACK` | All tables | Snowflake handles redundancy automatically. Remove. |
| `NO BEFORE/AFTER JOURNAL` | All tables | No Snowflake equivalent. Remove. |
| `CHECKSUM = DEFAULT` | All tables | No Snowflake equivalent. Remove. |
| `DEFAULT MERGEBLOCKRATIO` | All tables | No Snowflake equivalent. Remove. |
| `PRIMARY INDEX (PI)` | All tables | No direct equivalent. Use `CLUSTER BY` for frequently filtered columns. |
| `UNIQUE PRIMARY INDEX (UPI)` | Dimension tables | Use `PRIMARY KEY` constraint (not enforced but declared). |
| `PARTITION BY RANGE_N` | Fact tables, some dimensions | Use Snowflake micro-partitioning + `CLUSTER BY` on date columns. |
| `COMPRESS` | Many columns | Snowflake compresses automatically. Remove COMPRESS clauses. |
| `NOT CASESPECIFIC` | VARCHAR columns | Snowflake is case-sensitive by default. Use `COLLATE 'en-ci'` or apply `UPPER()`/`LOWER()` in queries. |
| `FORMAT` on column defs | DATE/DECIMAL columns | No column-level FORMAT in Snowflake. Use `TO_CHAR()` in queries or views. |
| `GENERATED ALWAYS AS IDENTITY` | Surrogate keys | Use `AUTOINCREMENT` or `IDENTITY` in Snowflake. |
| `COLLECT STATISTICS` | After CREATE TABLE | Not needed in Snowflake (automatic). Remove entirely. |
| `COMMENT ON TABLE/COLUMN` | All tables | Supported in Snowflake with same syntax. |

## DML Features

| Feature | Where Used | Migration Notes |
|---------|-----------|-----------------|
| `SEL` (shorthand for SELECT) | Views, procedures, macros | Replace with `SELECT` |
| `QUALIFY` | Views, procedures | Supported natively in Snowflake. |
| `ZEROIFNULL()` / `NULLIFZERO()` | Views, procedures | Supported in Snowflake. |
| `HASHROW()` | Regulatory view, validation | Use `HASH()` in Snowflake. |
| `SAMPLE` | Customer history macro | Use `SAMPLE` or `TABLESAMPLE` in Snowflake. |
| `CSUM()` (cumulative sum) | Branch performance view | Use `SUM() OVER (ORDER BY ...)` window function. |
| `MAVG()` (moving average) | Branch performance view | Use `AVG() OVER (ORDER BY ... ROWS BETWEEN N PRECEDING AND CURRENT ROW)`. |
| `LOCKING ROW FOR ACCESS` | All views | No equivalent needed. Remove. |
| `FORMAT` in SELECT | Reports, macros | Use `TO_CHAR()` for display formatting. |
| `ACTIVITY_COUNT` | Stored procedures | Use Snowflake's `SQLROWCOUNT` or result scanning. |
| `VOLATILE TABLE` | Monthly snapshot proc | Use `CREATE TEMPORARY TABLE` in Snowflake. |
| `REPLACE PROCEDURE` | All stored procedures | Use `CREATE OR REPLACE PROCEDURE` with SQL or JavaScript. |
| `REPLACE MACRO` | All macros | No macro support. Convert to stored procedures or parameterized views. |
| `MERGE INTO` | SCD2, snapshot procedures | Supported in Snowflake with same syntax. |
| `CAST(... AS DATE FORMAT ...)` | Various | Use `TO_DATE()` with format string. |
| `ADD_MONTHS()` | Snapshot procedure | Supported in Snowflake. |
| `EXTRACT()` | Various | Supported in Snowflake. |

## BTEQ Features

| Feature | Where Used | Migration Notes |
|---------|-----------|-----------------|
| `.LOGON` | All BTEQ scripts | Use SnowSQL connection or Snowpipe |
| `.IF ERRORCODE` | Error handling | Use SnowSQL `!if` or procedural error handling |
| `.IF ACTIVITYCOUNT` | Row count checks | Use `$rowcount` in SnowSQL |
| `.EXPORT DATA/REPORT FILE=` | Report extraction | Use `COPY INTO @stage` or SnowSQL `!spool` |
| `.QUIT` with return codes | Exit handling | Use SnowSQL exit codes |
| `.LABEL` / `.GOTO` | Error handlers | Use procedural logic (stored procedures) |
| `.SET WIDTH/SEPARATOR` | Formatting | SnowSQL has similar output format settings |
