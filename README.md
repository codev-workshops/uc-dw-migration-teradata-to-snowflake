# Teradata Data Warehouse — Migration Source for Snowflake

This repository contains a sample **Teradata-based data warehouse** designed as the starting point for a hands-on migration lab. The goal is to convert Teradata DDL/DML, stored procedures, and macros to Snowflake-compatible SQL, build a migration runbook, and implement validation tests.

## Repository Structure

```
├── ddl/
│   ├── tables/          # Teradata CREATE TABLE statements (SET/MULTISET, PI, PPI)
│   └── views/           # Teradata CREATE VIEW statements
├── dml/
│   ├── stored_procedures/  # Teradata stored procedures (BTEQ-style, CALL semantics)
│   ├── macros/             # Teradata macros
│   └── scripts/            # BTEQ load/extract scripts
├── data/
│   ├── seed/            # Sample CSV data for initial load
│   └── validation/      # Expected row counts and checksums for validation
├── schemas/             # ER diagrams and schema documentation
└── docs/                # Migration notes and reference material
```

## Domain: Retail Banking Analytics

The data warehouse models a **retail banking analytics** environment with:

- **Customer dimension** — demographics, segmentation, risk scores
- **Account dimension** — account types, statuses, open/close dates
- **Transaction fact** — daily transaction records with amounts, categories, channels
- **Product dimension** — banking products (loans, deposits, credit cards)
- **Branch dimension** — branch locations and regional hierarchy
- **Monthly account snapshot** — month-end balances and aggregates
- **Regulatory reporting views** — pre-built views for compliance reports

## Teradata-Specific Features Used

These features require explicit conversion when migrating to Snowflake:

| Teradata Feature | Snowflake Equivalent |
|---|---|
| `SET` / `MULTISET` tables | All Snowflake tables are multiset |
| Primary Index (PI) / Partitioned PI | Clustering keys |
| `COLLECT STATISTICS` | Automatic (no manual stats) |
| `QUALIFY ROW_NUMBER()` | `QUALIFY` (natively supported) |
| `SAMPLE` clause | `SAMPLE` / `TABLESAMPLE` |
| `CASESPECIFIC` / `NOT CASESPECIFIC` | Snowflake is case-sensitive by default |
| `FORMAT` on column definitions | `TO_CHAR` / display formatting |
| `COMPRESS` values | Automatic compression |
| Teradata `MACRO` | Snowflake stored procedure / task |
| `BTEQ` scripts | SnowSQL / Snowpipe |
| `HASHROW` / `HASHBUCKET` | `HASH()` |
| `ZEROIFNULL` / `NULLIFZERO` | `ZEROIFNULL` / `NULLIFZERO` (supported) |
| `SEL` shorthand | `SELECT` |
| `VOLATILE TABLE` | Temporary table (`CREATE TEMPORARY TABLE`) |
| `REPLACE PROCEDURE` | `CREATE OR REPLACE PROCEDURE` (JavaScript/SQL) |

## Lab Objectives

1. **Inventory** Teradata assets (tables, views, stored procedures, macros)
2. **Convert** DDL/DML for a selected subset to Snowflake
3. **Build** `MIGRATION_RUNBOOK.md` with loading approach documented
4. **Validate** with row counts, checksums, and business-level reconciliations
5. **Document** translation decisions in `SQL_TRANSLATION_NOTES.md`

## License

This is synthetic sample data created for workshop purposes. MIT License.
