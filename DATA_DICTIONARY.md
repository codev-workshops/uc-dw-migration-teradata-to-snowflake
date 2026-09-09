# BANKING_DW Data Dictionary

## Overview

- All objects live in the **`BANKING_DW`** schema (Teradata database).
- The model is a **star schema**: two fact tables (`FACT_TRANSACTION`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT`) surrounded by five dimensions (`DIM_CUSTOMER`, `DIM_ACCOUNT`, `DIM_PRODUCT`, `DIM_BRANCH`, `DIM_DATE`).
- **NOK (Norwegian krone) is the base currency.** `TRANSACTION_CURRENCY` / `CURRENCY_CODE` default to `'NOK'`; `BASE_CURRENCY_AMOUNT` and `BASE_CURRENCY_CLOSING` hold NOK-converted values.
- `DIM_CUSTOMER` and `DIM_ACCOUNT` are **SCD Type 2** dimensions with identity surrogate keys and `EFFECTIVE_FROM` / `EFFECTIVE_TO` / `CURRENT_FLAG` control columns. `DIM_PRODUCT`, `DIM_BRANCH` and `DIM_DATE` are Type 1 dimensions keyed by their natural key.
- All tables are created with `NO FALLBACK, NO BEFORE JOURNAL, NO AFTER JOURNAL, CHECKSUM = DEFAULT, DEFAULT MERGEBLOCKRATIO`.
- Source DDL: `ddl/tables/01_dim_customer.sql` … `07_fact_monthly_snapshot.sql`. Views are documented in `ddl/views/`; ETL logic in `dml/`.

### Column legend

| Abbreviation | Meaning |
|---|---|
| **SK** | Surrogate key (`GENERATED ALWAYS AS IDENTITY`) |
| **NK** | Natural / business key from the source system |
| **PK** | Primary key of a Type 1 dimension (also its `UNIQUE PRIMARY INDEX`) |
| **FK→X** | Foreign-key-style reference to table X (not enforced in Teradata) |
| **SCD** | SCD Type 2 control column |
| **DD** | Degenerate dimension / fact identifier |
| **NCS** | `NOT CASESPECIFIC` |
| Compression column | Value(s) listed in the `COMPRESS` clause; blank = none |

### Foreign-key cross-reference

| Column | Appears in | References |
|---|---|---|
| `CUSTOMER_KEY` | `FACT_TRANSACTION`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT` | `BANKING_DW.DIM_CUSTOMER.CUSTOMER_KEY` (SK, current version at load time) |
| `CUSTOMER_ID` | `DIM_ACCOUNT` | `BANKING_DW.DIM_CUSTOMER.CUSTOMER_ID` (NK; join with `CURRENT_FLAG='Y'`) |
| `ACCOUNT_KEY` | `FACT_TRANSACTION`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT` | `BANKING_DW.DIM_ACCOUNT.ACCOUNT_KEY` (SK) |
| `PRODUCT_ID` | `DIM_ACCOUNT`, `FACT_TRANSACTION`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT` | `BANKING_DW.DIM_PRODUCT.PRODUCT_ID` (PK) |
| `BRANCH_ID` | `DIM_ACCOUNT`, `FACT_TRANSACTION`, `FACT_MONTHLY_ACCOUNT_SNAPSHOT` | `BANKING_DW.DIM_BRANCH.BRANCH_ID` (PK) |
| `DATE_KEY` | `FACT_TRANSACTION` | `BANKING_DW.DIM_DATE.DATE_KEY` (PK, `YYYYMMDD` integer) |
| `SNAPSHOT_DATE` | `FACT_MONTHLY_ACCOUNT_SNAPSHOT` | `BANKING_DW.DIM_DATE.CALENDAR_DATE` (used by `VW_BRANCH_PERFORMANCE`) |

---

## BANKING_DW.DIM_CUSTOMER

- **Purpose:** SCD Type 2 customer dimension with demographics, address, segmentation, risk and KYC attributes.
- **Table type:** `SET` (duplicate rows rejected).
- **Grain:** one row per customer *version*; exactly one row per `CUSTOMER_ID` has `CURRENT_FLAG='Y'`.
- **Loaded by:** `SP_CUSTOMER_SCD2` from `BANKING_DW.STG_CUSTOMER`.

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `CUSTOMER_ID` | `INTEGER` | NOT NULL | NK | | Natural key from source system; shared across SCD versions |
| `CUSTOMER_KEY` | `BIGINT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1)` | NOT NULL | SK (UPI) | | Surrogate key for SCD Type 2; referenced by fact tables |
| `FIRST_NAME` | `VARCHAR(50)` NCS | NOT NULL | | | Given name |
| `LAST_NAME` | `VARCHAR(50)` NCS | NOT NULL | | | Family name |
| `DATE_OF_BIRTH` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Date of birth |
| `GENDER` | `CHAR(1)` | NULL | | `'M','F','O'` | Gender code |
| `MARITAL_STATUS` | `CHAR(1)` | NULL | | `'S','M','D','W'` | Single / Married / Divorced / Widowed; SCD-tracked |
| `EMAIL_ADDRESS` | `VARCHAR(100)` NCS | NULL | | | E-mail; SCD-tracked |
| `PHONE_NUMBER` | `VARCHAR(20)` | NULL | | | Phone; SCD-tracked |
| `ADDRESS_LINE_1` | `VARCHAR(100)` NCS | NULL | | | Street address; SCD-tracked |
| `ADDRESS_LINE_2` | `VARCHAR(100)` NCS | NULL | | `''` | Additional address line |
| `CITY` | `VARCHAR(50)` NCS | NULL | | | City; SCD-tracked |
| `STATE_PROVINCE` | `VARCHAR(50)` NCS | NULL | | | State / province (fylke); SCD-tracked |
| `POSTAL_CODE` | `VARCHAR(10)` | NULL | | | Postal code; SCD-tracked |
| `COUNTRY_CODE` | `CHAR(3)` NCS `DEFAULT 'NOR'` | NULL | | | ISO-3 country code, defaults to Norway |
| `CUSTOMER_SEGMENT` | `VARCHAR(20)` NCS | NULL | | `'RETAIL','PREMIUM','PRIVATE','CORPORATE'` | Commercial segment; SCD-tracked |
| `RISK_SCORE` | `DECIMAL(5,2)` | NULL | | | Internal risk score; SCD-tracked |
| `CREDIT_RATING` | `CHAR(3)` | NULL | | `'AAA','AA','A','BBB','BB','B','CCC'` | Credit rating grade; SCD-tracked |
| `KYC_STATUS` | `VARCHAR(15)` NCS `DEFAULT 'PENDING'` | NULL | | `'VERIFIED','PENDING','REVIEW','EXPIRED'` | Know Your Customer verification status; SCD-tracked |
| `ONBOARDING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NOT NULL | Partition column | | Date customer was onboarded; carried across versions |
| `LAST_REVIEW_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Last KYC / periodic review date |
| `IS_ACTIVE` | `BYTEINT DEFAULT 1` | NULL | | `0, 1` | 1 = active customer |
| `EFFECTIVE_FROM` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | SCD | | Version start timestamp |
| `EFFECTIVE_TO` | `TIMESTAMP(0) DEFAULT TIMESTAMP '9999-12-31 23:59:59'` | NULL | SCD | | Version end timestamp; high-date for current row |
| `CURRENT_FLAG` | `CHAR(1) DEFAULT 'Y'` | NULL | SCD | `'Y','N'` | `'Y'` = current version |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch that inserted/updated the row |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert timestamp |
| `ETL_UPDATE_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row last-update timestamp |

**Indexes and partitioning**

| Type | Name | Columns |
|---|---|---|
| Unique Primary Index | `UPI_CUSTOMER_KEY` | `CUSTOMER_KEY` |
| Secondary Index | `NUPI_CUSTOMER_ID` | `CUSTOMER_ID` |
| Secondary Index | `IDX_CUST_SEGMENT` | `CUSTOMER_SEGMENT` |
| Secondary Index | `IDX_CUST_COUNTRY` | `COUNTRY_CODE` |
| Partition | `RANGE_N(ONBOARDING_DATE BETWEEN DATE '2000-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' YEAR)` | |

**SCD Type 2 control columns:** `EFFECTIVE_FROM`, `EFFECTIVE_TO`, `CURRENT_FLAG`. Statistics collected on `CUSTOMER_ID`, `CUSTOMER_SEGMENT`, `COUNTRY_CODE`, `IS_ACTIVE`.

---

## BANKING_DW.DIM_ACCOUNT

- **Purpose:** SCD Type 2 account dimension tracking account type, currency, status, limits and rate changes.
- **Table type:** `MULTISET`.
- **Grain:** one row per account *version*; one `CURRENT_FLAG='Y'` row per `ACCOUNT_ID`.
- **References:** `DIM_CUSTOMER` (`CUSTOMER_ID`), `DIM_PRODUCT` (`PRODUCT_ID`), `DIM_BRANCH` (`BRANCH_ID`).

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `ACCOUNT_KEY` | `BIGINT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1)` | NOT NULL | SK (UPI) | | Surrogate key; referenced by fact tables |
| `ACCOUNT_ID` | `VARCHAR(20)` | NOT NULL | NK | | Account number from source system |
| `CUSTOMER_ID` | `INTEGER` | NOT NULL | FK→`DIM_CUSTOMER` (NK) | | Owning customer |
| `ACCOUNT_TYPE` | `VARCHAR(20)` NCS | NOT NULL | | `'CHECKING','SAVINGS','LOAN','CREDIT_CARD','MORTGAGE','DEPOSIT','INVESTMENT'` | Account product type |
| `ACCOUNT_SUBTYPE` | `VARCHAR(30)` NCS | NULL | | `'PERSONAL','BUSINESS','JOINT','TRUST'` | Ownership subtype |
| `CURRENCY_CODE` | `CHAR(3)` NCS `DEFAULT 'NOK'` | NULL | | `'NOK','EUR','USD','GBP','SEK','DKK'` | Account currency |
| `OPENING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NOT NULL | Partition column | | Account opening date |
| `CLOSING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Account closing date |
| `ACCOUNT_STATUS` | `VARCHAR(15)` NCS `DEFAULT 'ACTIVE'` | NULL | | `'ACTIVE','DORMANT','CLOSED','FROZEN','SUSPENDED'` | Lifecycle status; SCD-tracked |
| `INTEREST_RATE` | `DECIMAL(7,4)` | NULL | | | Current interest rate; SCD-tracked |
| `CREDIT_LIMIT` | `DECIMAL(15,2)` | NULL | | `0` | Credit limit (cards / lines) |
| `OVERDRAFT_LIMIT` | `DECIMAL(15,2) DEFAULT 0` | NULL | | | Authorised overdraft |
| `BRANCH_ID` | `INTEGER` | NULL | FK→`DIM_BRANCH` | | Servicing branch |
| `RELATIONSHIP_MGR_ID` | `INTEGER` | NULL | | `0` | Relationship manager identifier |
| `PRODUCT_ID` | `INTEGER` | NOT NULL | FK→`DIM_PRODUCT` | | Product the account is based on |
| `IS_JOINT_ACCOUNT` | `BYTEINT DEFAULT 0` | NULL | | `0, 1` | 1 = joint account |
| `TAX_REPORTING_FLAG` | `BYTEINT DEFAULT 1` | NULL | | `0, 1` | 1 = subject to tax reporting |
| `EFFECTIVE_FROM` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | SCD | | Version start timestamp |
| `EFFECTIVE_TO` | `TIMESTAMP(0) DEFAULT TIMESTAMP '9999-12-31 23:59:59'` | NULL | SCD | | Version end timestamp |
| `CURRENT_FLAG` | `CHAR(1) DEFAULT 'Y'` | NULL | SCD | `'Y','N'` | `'Y'` = current version |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch identifier |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert timestamp |
| `ETL_UPDATE_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row last-update timestamp |

**Indexes and partitioning**

| Type | Name | Columns |
|---|---|---|
| Unique Primary Index | `UPI_ACCOUNT_KEY` | `ACCOUNT_KEY` |
| Secondary Index | `NUPI_ACCOUNT_ID` | `ACCOUNT_ID` |
| Secondary Index | `IDX_ACCT_CUSTOMER` | `CUSTOMER_ID` |
| Secondary Index | `IDX_ACCT_TYPE` | `ACCOUNT_TYPE` |
| Secondary Index | `IDX_ACCT_BRANCH` | `BRANCH_ID` |
| Partition | `RANGE_N(OPENING_DATE BETWEEN DATE '2000-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' YEAR)` | |

**SCD Type 2 control columns:** `EFFECTIVE_FROM`, `EFFECTIVE_TO`, `CURRENT_FLAG`. Statistics collected on `ACCOUNT_ID`, `CUSTOMER_ID`, `ACCOUNT_TYPE`, `ACCOUNT_STATUS`, `BRANCH_ID`.

---

## BANKING_DW.DIM_PRODUCT

- **Purpose:** Banking product catalog (deposits, lending, cards, investment, insurance, payments).
- **Table type:** `SET`. Type 1 dimension (no SCD columns).
- **Grain:** one row per product.

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `PRODUCT_ID` | `INTEGER` | NOT NULL | PK (UPI) | | Product identifier |
| `PRODUCT_CODE` | `VARCHAR(20)` | NOT NULL | Alternate key | | Business product code |
| `PRODUCT_NAME` | `VARCHAR(100)` NCS | NOT NULL | | | Product display name |
| `PRODUCT_CATEGORY` | `VARCHAR(30)` NCS | NOT NULL | | `'DEPOSITS','LENDING','CARDS','INVESTMENT','INSURANCE','PAYMENTS'` | Top-level category |
| `PRODUCT_SUBCATEGORY` | `VARCHAR(50)` NCS | NULL | | | Sub-category |
| `BASE_INTEREST_RATE` | `DECIMAL(7,4)` | NULL | | | Base rate for the product |
| `MIN_BALANCE` | `DECIMAL(15,2) DEFAULT 0` | NULL | | | Minimum balance requirement |
| `MAX_BALANCE` | `DECIMAL(15,2)` | NULL | | | Maximum balance allowed |
| `FEE_STRUCTURE` | `VARCHAR(20)` | NULL | | `'FIXED','TIERED','NONE','PERCENTAGE'` | Fee model |
| `MONTHLY_FEE` | `DECIMAL(10,2) DEFAULT 0` | NULL | | `0` | Monthly fee amount |
| `IS_REGULATED` | `BYTEINT DEFAULT 1` | NULL | | `0, 1` | 1 = regulated product |
| `REGULATORY_CODE` | `VARCHAR(20)` | NULL | | | Regulatory classification code |
| `LAUNCH_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Product launch date |
| `DISCONTINUE_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Product discontinuation date |
| `IS_ACTIVE` | `BYTEINT DEFAULT 1` | NULL | | `0, 1` | 1 = currently offered |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch identifier |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert timestamp |

**Indexes**

| Type | Name | Columns |
|---|---|---|
| Unique Primary Index | `UPI_PRODUCT_ID` | `PRODUCT_ID` |
| Secondary Index | `IDX_PROD_CODE` | `PRODUCT_CODE` |
| Secondary Index | `IDX_PROD_CATEGORY` | `PRODUCT_CATEGORY` |

Statistics collected on `PRODUCT_ID`, `PRODUCT_CATEGORY`.

---

## BANKING_DW.DIM_BRANCH

- **Purpose:** Branch / location dimension with Norwegian regional hierarchy (city → county → region).
- **Table type:** `SET`. Type 1 dimension (no SCD columns).
- **Grain:** one row per branch.

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `BRANCH_ID` | `INTEGER` | NOT NULL | PK (UPI) | | Branch identifier |
| `BRANCH_CODE` | `CHAR(6)` | NOT NULL | Alternate key | | Business branch code |
| `BRANCH_NAME` | `VARCHAR(100)` NCS | NOT NULL | | | Branch name |
| `BRANCH_TYPE` | `VARCHAR(20)` NCS | NULL | | `'FULL_SERVICE','DIGITAL','KIOSK','REGIONAL_HQ'` | Branch format |
| `ADDRESS_LINE_1` | `VARCHAR(100)` NCS | NULL | | | Street address |
| `CITY` | `VARCHAR(50)` NCS | NULL | | | City |
| `COUNTY` | `VARCHAR(50)` NCS | NULL | | | County (fylke) |
| `REGION` | `VARCHAR(50)` NCS | NULL | | `'OSTLANDET','VESTLANDET','SORLANDET','TRONDELAG','NORD-NORGE'` | Norwegian region |
| `POSTAL_CODE` | `VARCHAR(10)` | NULL | | | Postal code |
| `COUNTRY_CODE` | `CHAR(3) DEFAULT 'NOR'` | NULL | | | ISO-3 country code |
| `LATITUDE` | `DECIMAL(10,7)` | NULL | | | Geo latitude |
| `LONGITUDE` | `DECIMAL(10,7)` | NULL | | | Geo longitude |
| `MANAGER_ID` | `INTEGER` | NULL | | | Branch manager identifier |
| `OPENING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Branch opening date |
| `CLOSING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Branch closing date |
| `IS_ACTIVE` | `BYTEINT DEFAULT 1` | NULL | | `0, 1` | 1 = open branch |
| `EMPLOYEE_COUNT` | `SMALLINT` | NULL | | `0` | Headcount |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch identifier |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert timestamp |

**Indexes**

| Type | Name | Columns |
|---|---|---|
| Unique Primary Index | `UPI_BRANCH_ID` | `BRANCH_ID` |
| Secondary Index | `IDX_BRANCH_CODE` | `BRANCH_CODE` |
| Secondary Index | `IDX_BRANCH_REGION` | `REGION` |

Statistics collected on `BRANCH_ID`, `REGION`.

---

## BANKING_DW.DIM_DATE

- **Purpose:** Pre-populated calendar dimension with Norwegian holidays, business-day flags and fiscal-year alignment.
- **Table type:** `SET`. Type 1 dimension.
- **Grain:** one row per calendar day.

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `DATE_KEY` | `INTEGER` | NOT NULL | PK (UPI) | | Smart key in `YYYYMMDD` format |
| `CALENDAR_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NOT NULL | Alternate key | | Calendar date |
| `DAY_OF_WEEK` | `BYTEINT` | NOT NULL | | | 1 = Monday … 7 = Sunday |
| `DAY_NAME` | `VARCHAR(10)` | NOT NULL | | | Day name |
| `DAY_OF_MONTH` | `BYTEINT` | NOT NULL | | | Day number within month |
| `DAY_OF_YEAR` | `SMALLINT` | NOT NULL | | | Day number within year |
| `WEEK_OF_YEAR` | `BYTEINT` | NOT NULL | | | Week number |
| `ISO_WEEK` | `BYTEINT` | NOT NULL | | | ISO-8601 week number |
| `MONTH_NUM` | `BYTEINT` | NOT NULL | | | Month number 1–12 |
| `MONTH_NAME` | `VARCHAR(15)` | NOT NULL | | | Month name |
| `MONTH_SHORT` | `CHAR(3)` | NOT NULL | | | Month abbreviation |
| `QUARTER_NUM` | `BYTEINT` | NOT NULL | | `1, 2, 3, 4` | Calendar quarter |
| `QUARTER_NAME` | `CHAR(2)` | NOT NULL | | | `Q1`–`Q4` |
| `HALF_YEAR` | `BYTEINT` | NOT NULL | | `1, 2` | Half-year |
| `CALENDAR_YEAR` | `SMALLINT` | NOT NULL | | | Calendar year |
| `FISCAL_YEAR` | `SMALLINT` | NOT NULL | | | Fiscal year |
| `FISCAL_QUARTER` | `BYTEINT` | NOT NULL | | | Fiscal quarter |
| `IS_WEEKEND` | `BYTEINT` | NOT NULL | | `0, 1` | 1 = Saturday/Sunday |
| `IS_NORWEGIAN_HOLIDAY` | `BYTEINT DEFAULT 0` | NULL | | `0, 1` | 1 = Norwegian public holiday |
| `HOLIDAY_NAME` | `VARCHAR(50)` | NULL | | `''` | Holiday name |
| `IS_BUSINESS_DAY` | `BYTEINT` | NOT NULL | | `0, 1` | 1 = banking business day |
| `IS_MONTH_END` | `BYTEINT` | NOT NULL | | `0, 1` | 1 = last day of month |
| `IS_QUARTER_END` | `BYTEINT` | NOT NULL | | `0, 1` | 1 = last day of quarter |
| `IS_YEAR_END` | `BYTEINT` | NOT NULL | | `0, 1` | 1 = last day of year |
| `PRIOR_DAY_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Previous calendar date |
| `NEXT_DAY_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Next calendar date |
| `SAME_DAY_PREV_YEAR` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Same date one year earlier |

**Indexes**

| Type | Name | Columns |
|---|---|---|
| Unique Primary Index | `UPI_DATE_KEY` | `DATE_KEY` |
| Secondary Index | `IDX_CALENDAR_DATE` | `CALENDAR_DATE` |
| Secondary Index | `IDX_YEAR_MONTH` | `CALENDAR_YEAR, MONTH_NUM` |

Statistics collected on `DATE_KEY`, `CALENDAR_YEAR`, `IS_BUSINESS_DAY`.

---

## BANKING_DW.FACT_TRANSACTION

- **Purpose:** Daily transaction fact — the largest table in the warehouse.
- **Table type:** `MULTISET` with Partitioned Primary Index (PPI) on `TRANSACTION_DATE`.
- **Grain:** one row per transaction (`TRANSACTION_ID`).
- **Loaded by:** `SP_LOAD_DAILY_TRANSACTIONS` from `BANKING_DW.STG_TRANSACTIONS`.

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `TRANSACTION_ID` | `BIGINT` | NOT NULL | DD (transaction identifier) | | Unique transaction identifier from source |
| `TRANSACTION_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NOT NULL | PI column / partition column | | Transaction date |
| `TRANSACTION_TIME` | `TIME(0)` | NULL | | | Transaction time |
| `TRANSACTION_TS` | `TIMESTAMP(6)` | NULL | | | Full timestamp (date + time) |
| `ACCOUNT_KEY` | `BIGINT` | NOT NULL | FK→`DIM_ACCOUNT` (SK), PI column | | Account surrogate key |
| `CUSTOMER_KEY` | `BIGINT` | NOT NULL | FK→`DIM_CUSTOMER` (SK) | | Customer surrogate key |
| `PRODUCT_ID` | `INTEGER` | NOT NULL | FK→`DIM_PRODUCT` | | Product identifier (from account) |
| `BRANCH_ID` | `INTEGER` | NULL | FK→`DIM_BRANCH` | | Branch identifier (from account) |
| `DATE_KEY` | `INTEGER` | NOT NULL | FK→`DIM_DATE` | | `YYYYMMDD` date key |
| `TRANSACTION_TYPE` | `VARCHAR(20)` NCS | NOT NULL | | `'DEBIT','CREDIT','TRANSFER','FEE','INTEREST','REVERSAL','ADJUSTMENT'` | Transaction class |
| `TRANSACTION_SUBTYPE` | `VARCHAR(30)` NCS | NULL | | `'ATM_WITHDRAWAL','POS_PURCHASE','ONLINE_TRANSFER','DIRECT_DEBIT','SALARY','STANDING_ORDER','CARD_PAYMENT','MOBILE_PAYMENT','VIPPS'` | Transaction subtype |
| `CHANNEL` | `VARCHAR(20)` NCS | NULL | | `'BRANCH','ATM','ONLINE','MOBILE','POS','API'` | Originating channel |
| `TRANSACTION_AMOUNT` | `DECIMAL(15,2)` | NOT NULL | Measure | | Amount in transaction currency |
| `TRANSACTION_CURRENCY` | `CHAR(3)` NCS `DEFAULT 'NOK'` | NULL | | `'NOK','EUR','USD','GBP','SEK','DKK'` | Transaction currency |
| `BASE_CURRENCY_AMOUNT` | `DECIMAL(15,2)` | NULL | Measure | | Amount converted to NOK |
| `EXCHANGE_RATE` | `DECIMAL(12,6) DEFAULT 1.000000` | NULL | | | Rate applied to reach NOK |
| `RUNNING_BALANCE` | `DECIMAL(15,2)` | NULL | Measure | | Account balance after this transaction |
| `MERCHANT_ID` | `VARCHAR(20)` | NULL | | | Merchant identifier |
| `MERCHANT_NAME` | `VARCHAR(100)` NCS | NULL | | | Merchant name |
| `MERCHANT_CATEGORY` | `VARCHAR(4)` | NULL | | | Merchant category code (MCC) |
| `COUNTERPARTY_ACCT` | `VARCHAR(20)` | NULL | | | Counterparty account number |
| `REFERENCE_NUMBER` | `VARCHAR(30)` | NULL | | | Payment reference |
| `DESCRIPTION_TEXT` | `VARCHAR(200)` NCS | NULL | | | Free-text description |
| `IS_INTERNATIONAL` | `BYTEINT DEFAULT 0` | NULL | | `0, 1` | 1 when currency ≠ NOK |
| `IS_FLAGGED` | `BYTEINT DEFAULT 0` | NULL | | `0, 1` | 1 = flagged as suspicious |
| `FLAG_REASON` | `VARCHAR(50)` | NULL | | `''` | Reason for flag |
| `POSTING_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Ledger posting date |
| `VALUE_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NULL | | | Value (settlement) date |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch identifier |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert timestamp |

**Indexes and partitioning**

| Type | Name | Columns |
|---|---|---|
| Primary Index (non-unique) | `PI_FACT_TXN` | `ACCOUNT_KEY, TRANSACTION_DATE` |
| Partition | `RANGE_N(TRANSACTION_DATE BETWEEN DATE '2018-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' MONTH, NO RANGE)` | |

Statistics collected on `TRANSACTION_ID`, `TRANSACTION_DATE`, `ACCOUNT_KEY`, `CUSTOMER_KEY`, `TRANSACTION_TYPE`, `CHANNEL`, `PARTITION`.

---

## BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT

- **Purpose:** Periodic snapshot fact with month-end balances and monthly aggregates per account.
- **Table type:** `MULTISET` with PPI on `SNAPSHOT_DATE`.
- **Grain:** one row per account per calendar month (`ACCOUNT_KEY`, `SNAPSHOT_MONTH_KEY`).
- **Loaded by:** `SP_MONTHLY_SNAPSHOT` (MERGE from `FACT_TRANSACTION` aggregates).

| Column | Data type | Nullable | Key role | Compression | Description |
|---|---|---|---|---|---|
| `SNAPSHOT_DATE` | `DATE FORMAT 'YYYY-MM-DD'` | NOT NULL | Partition column; joins `DIM_DATE.CALENDAR_DATE` | | Month-end date of the snapshot |
| `SNAPSHOT_MONTH_KEY` | `INTEGER` | NOT NULL | PI column | | Month key in `YYYYMM` format |
| `ACCOUNT_KEY` | `BIGINT` | NOT NULL | FK→`DIM_ACCOUNT` (SK), PI column | | Account surrogate key |
| `CUSTOMER_KEY` | `BIGINT` | NOT NULL | FK→`DIM_CUSTOMER` (SK) | | Customer surrogate key |
| `PRODUCT_ID` | `INTEGER` | NOT NULL | FK→`DIM_PRODUCT` | | Product identifier |
| `BRANCH_ID` | `INTEGER` | NULL | FK→`DIM_BRANCH` | | Branch identifier |
| `OPENING_BALANCE` | `DECIMAL(15,2)` | NOT NULL | Measure | | Prior month closing balance |
| `CLOSING_BALANCE` | `DECIMAL(15,2)` | NOT NULL | Measure | | Opening + credits − debits |
| `AVERAGE_BALANCE` | `DECIMAL(15,2)` | NULL | Measure | | Average running balance in month |
| `MINIMUM_BALANCE` | `DECIMAL(15,2)` | NULL | Measure | | Minimum running balance |
| `MAXIMUM_BALANCE` | `DECIMAL(15,2)` | NULL | Measure | | Maximum running balance |
| `TOTAL_DEBITS` | `DECIMAL(15,2) DEFAULT 0` | NULL | Measure | | Sum of DEBIT + FEE amounts |
| `TOTAL_CREDITS` | `DECIMAL(15,2) DEFAULT 0` | NULL | Measure | | Sum of CREDIT + INTEREST amounts |
| `DEBIT_COUNT` | `INTEGER DEFAULT 0` | NULL | Measure | | Number of debit/fee transactions |
| `CREDIT_COUNT` | `INTEGER DEFAULT 0` | NULL | Measure | | Number of credit/interest transactions |
| `INTEREST_EARNED` | `DECIMAL(12,2) DEFAULT 0` | NULL | Measure | | Positive INTEREST amounts |
| `INTEREST_CHARGED` | `DECIMAL(12,2) DEFAULT 0` | NULL | Measure | | Negative INTEREST amounts (absolute) |
| `FEES_CHARGED` | `DECIMAL(12,2) DEFAULT 0` | NULL | Measure | | FEE amounts (absolute) |
| `DAYS_IN_OVERDRAFT` | `SMALLINT DEFAULT 0` | NULL | Measure | `0` | Count of negative running-balance days |
| `DAYS_DORMANT` | `SMALLINT DEFAULT 0` | NULL | Measure | `0` | Days in period with no activity |
| `CURRENCY_CODE` | `CHAR(3) DEFAULT 'NOK'` | NULL | | `'NOK','EUR','USD','GBP','SEK','DKK'` | Account currency |
| `BASE_CURRENCY_CLOSING` | `DECIMAL(15,2)` | NULL | Measure | | Closing balance converted to NOK |
| `ETL_BATCH_ID` | `BIGINT` | NULL | | | Batch identifier |
| `ETL_INSERT_TS` | `TIMESTAMP(0) DEFAULT CURRENT_TIMESTAMP(0)` | NULL | | | Row insert/refresh timestamp |

**Indexes and partitioning**

| Type | Name | Columns |
|---|---|---|
| Primary Index (non-unique) | `PI_MONTHLY_SNAP` | `ACCOUNT_KEY, SNAPSHOT_MONTH_KEY` |
| Partition | `RANGE_N(SNAPSHOT_DATE BETWEEN DATE '2018-01-01' AND DATE '2030-12-31' EACH INTERVAL '1' MONTH, NO RANGE)` | |

Statistics collected on `SNAPSHOT_MONTH_KEY`, `ACCOUNT_KEY`, `PARTITION`.

---

## Staging and support tables referenced by DML (no DDL in this repo)

| Table | Used by | Role |
|---|---|---|
| `BANKING_DW.STG_TRANSACTIONS` | `SP_LOAD_DAILY_TRANSACTIONS` | Daily staged transactions (`LOAD_DATE`, `ACCOUNT_ID`, `CURRENCY_CODE`, …) |
| `BANKING_DW.STG_TRANSACTION_ERRORS` | `SP_LOAD_DAILY_TRANSACTIONS` | Rejected staging rows plus `ERROR_REASON`, `BATCH_ID` |
| `BANKING_DW.STG_CUSTOMER` | `SP_CUSTOMER_SCD2` | Staged customer snapshot for SCD2 processing |
| `BANKING_DW.DIM_EXCHANGE_RATES` | `SP_LOAD_DAILY_TRANSACTIONS` | `FROM_CURRENCY`, `TO_CURRENCY`, `RATE_DATE`, `EXCHANGE_RATE` lookup for NOK conversion |
| `BANKING_DW.ETL_LOG` | `SP_LOAD_DAILY_TRANSACTIONS` | `PROCEDURE_NAME`, `BATCH_ID`, `LOG_LEVEL`, `LOG_MESSAGE`, `LOG_TS` audit log |
