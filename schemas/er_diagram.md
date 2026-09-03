# Banking Data Warehouse — Entity Relationship Diagram

```
                    +-------------------+
                    |    DIM_DATE       |
                    +-------------------+
                    | DATE_KEY (PK)     |
                    | CALENDAR_DATE     |
                    | DAY_OF_WEEK       |
                    | MONTH_NUM         |
                    | QUARTER_NUM       |
                    | CALENDAR_YEAR     |
                    | IS_BUSINESS_DAY   |
                    | IS_NORWEGIAN_     |
                    |   HOLIDAY         |
                    +-------------------+
                            |
                            | DATE_KEY
                            |
+-------------------+     +-------------------------+     +-------------------+
|  DIM_CUSTOMER     |     |   FACT_TRANSACTION      |     |  DIM_BRANCH       |
+-------------------+     +-------------------------+     +-------------------+
| CUSTOMER_KEY (PK) |<----| CUSTOMER_KEY (FK)       |---->| BRANCH_ID (PK)    |
| CUSTOMER_ID (NK)  |     | ACCOUNT_KEY (FK)        |     | BRANCH_CODE       |
| FIRST_NAME        |     | TRANSACTION_ID (PK)     |     | BRANCH_NAME       |
| LAST_NAME         |     | TRANSACTION_DATE        |     | BRANCH_TYPE       |
| CUSTOMER_SEGMENT  |     | TRANSACTION_TYPE        |     | CITY              |
| RISK_SCORE        |     | TRANSACTION_AMOUNT      |     | REGION            |
| CREDIT_RATING     |     | CHANNEL                 |     | COUNTRY_CODE      |
| KYC_STATUS        |     | DATE_KEY (FK)            |     +-------------------+
| ONBOARDING_DATE   |     | BRANCH_ID (FK)          |
| CURRENT_FLAG      |     | PRODUCT_ID (FK)         |
+-------------------+     +-------------------------+
        |                           |
        |                           |
        |     +---------------------------+     +-------------------+
        |     | FACT_MONTHLY_ACCOUNT_     |     |  DIM_PRODUCT      |
        |     |        SNAPSHOT           |     +-------------------+
        |     +---------------------------+     | PRODUCT_ID (PK)   |
        +---->| CUSTOMER_KEY (FK)         |---->| PRODUCT_CODE      |
              | ACCOUNT_KEY (FK)          |     | PRODUCT_NAME      |
              | SNAPSHOT_DATE             |     | PRODUCT_CATEGORY  |
              | SNAPSHOT_MONTH_KEY        |     | BASE_INTEREST_RATE|
              | OPENING_BALANCE           |     | FEE_STRUCTURE     |
              | CLOSING_BALANCE           |     +-------------------+
              | TOTAL_DEBITS              |
              | TOTAL_CREDITS             |
              +---------------------------+
                        |
                        |
              +-------------------+
              |  DIM_ACCOUNT      |
              +-------------------+
              | ACCOUNT_KEY (PK)  |
              | ACCOUNT_ID (NK)   |
              | CUSTOMER_ID (FK)  |
              | ACCOUNT_TYPE      |
              | CURRENCY_CODE     |
              | ACCOUNT_STATUS    |
              | INTEREST_RATE     |
              | BRANCH_ID (FK)    |
              | PRODUCT_ID (FK)   |
              | CURRENT_FLAG      |
              +-------------------+
```

## Schema Type
**Star Schema** with two fact tables:
- `FACT_TRANSACTION` — transaction grain (one row per banking transaction)
- `FACT_MONTHLY_ACCOUNT_SNAPSHOT` — periodic snapshot grain (one row per account per month)

## Dimensions
| Dimension | Type | Grain |
|-----------|------|-------|
| DIM_CUSTOMER | SCD Type 2 | One row per customer version |
| DIM_ACCOUNT | SCD Type 2 | One row per account version |
| DIM_PRODUCT | SCD Type 1 | One row per product |
| DIM_BRANCH | SCD Type 1 | One row per branch |
| DIM_DATE | Static | One row per calendar day |

## Teradata-Specific Design Choices
- **Primary Indexes (PI)**: Chosen for even data distribution across AMPs
- **Partitioned Primary Indexes (PPI)**: Used on fact tables for partition elimination on date ranges
- **COMPRESS**: Applied to low-cardinality columns to save storage
- **COLLECT STATISTICS**: Explicit statistics collection for query optimizer
- **SET vs MULTISET**: Dimension tables use SET (no duplicates); fact tables use MULTISET (allow duplicates for performance)
