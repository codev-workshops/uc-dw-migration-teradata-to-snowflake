/**********************************************************************
 * SP_CUSTOMER_SCD2
 * Applies SCD Type 2 changes to the customer dimension
 * Uses Teradata MERGE with complex WHEN logic
 **********************************************************************/

REPLACE PROCEDURE BANKING_DW.SP_CUSTOMER_SCD2(
    IN p_batch_id    BIGINT,
    OUT p_new_rows   INTEGER,
    OUT p_changed    INTEGER,
    OUT p_return_code INTEGER
)
BEGIN
    DECLARE v_current_ts TIMESTAMP(0);

    SET v_current_ts = CURRENT_TIMESTAMP(0);
    SET p_return_code = 0;
    SET p_new_rows = 0;
    SET p_changed = 0;

    -- Step 1: Expire changed records
    UPDATE BANKING_DW.DIM_CUSTOMER tgt
    FROM (
        SEL stg.CUSTOMER_ID
        FROM BANKING_DW.STG_CUSTOMER stg
        INNER JOIN BANKING_DW.DIM_CUSTOMER dim
            ON stg.CUSTOMER_ID = dim.CUSTOMER_ID
           AND dim.CURRENT_FLAG = 'Y'
        WHERE (
            stg.CUSTOMER_SEGMENT <> dim.CUSTOMER_SEGMENT
            OR stg.RISK_SCORE <> dim.RISK_SCORE
            OR stg.CREDIT_RATING <> dim.CREDIT_RATING
            OR stg.KYC_STATUS <> dim.KYC_STATUS
            OR stg.ADDRESS_LINE_1 <> dim.ADDRESS_LINE_1
            OR stg.CITY <> dim.CITY
            OR stg.STATE_PROVINCE <> dim.STATE_PROVINCE
            OR stg.POSTAL_CODE <> dim.POSTAL_CODE
            OR COALESCE(stg.PHONE_NUMBER, '') <> COALESCE(dim.PHONE_NUMBER, '')
            OR COALESCE(stg.EMAIL_ADDRESS, '') <> COALESCE(dim.EMAIL_ADDRESS, '')
            OR stg.MARITAL_STATUS <> dim.MARITAL_STATUS
        )
    ) src
    SET CURRENT_FLAG = 'N',
        EFFECTIVE_TO = v_current_ts,
        ETL_UPDATE_TS = v_current_ts,
        ETL_BATCH_ID = p_batch_id
    WHERE tgt.CUSTOMER_ID = src.CUSTOMER_ID
      AND tgt.CURRENT_FLAG = 'Y';

    SET p_changed = ACTIVITY_COUNT;

    -- Step 2: Insert new versions of changed records + brand new customers
    INSERT INTO BANKING_DW.DIM_CUSTOMER (
        CUSTOMER_ID, FIRST_NAME, LAST_NAME, DATE_OF_BIRTH, GENDER,
        MARITAL_STATUS, EMAIL_ADDRESS, PHONE_NUMBER,
        ADDRESS_LINE_1, ADDRESS_LINE_2, CITY, STATE_PROVINCE,
        POSTAL_CODE, COUNTRY_CODE, CUSTOMER_SEGMENT, RISK_SCORE,
        CREDIT_RATING, KYC_STATUS, ONBOARDING_DATE, LAST_REVIEW_DATE,
        IS_ACTIVE, EFFECTIVE_FROM, EFFECTIVE_TO, CURRENT_FLAG,
        ETL_BATCH_ID, ETL_INSERT_TS, ETL_UPDATE_TS
    )
    SEL
        stg.CUSTOMER_ID,
        stg.FIRST_NAME,
        stg.LAST_NAME,
        stg.DATE_OF_BIRTH,
        stg.GENDER,
        stg.MARITAL_STATUS,
        stg.EMAIL_ADDRESS,
        stg.PHONE_NUMBER,
        stg.ADDRESS_LINE_1,
        stg.ADDRESS_LINE_2,
        stg.CITY,
        stg.STATE_PROVINCE,
        stg.POSTAL_CODE,
        COALESCE(stg.COUNTRY_CODE, 'NOR'),
        stg.CUSTOMER_SEGMENT,
        stg.RISK_SCORE,
        stg.CREDIT_RATING,
        stg.KYC_STATUS,
        COALESCE(existing.ONBOARDING_DATE, CURRENT_DATE),
        CURRENT_DATE,
        1,
        v_current_ts,
        TIMESTAMP '9999-12-31 23:59:59',
        'Y',
        p_batch_id,
        v_current_ts,
        v_current_ts
    FROM BANKING_DW.STG_CUSTOMER stg
    LEFT JOIN BANKING_DW.DIM_CUSTOMER existing
        ON stg.CUSTOMER_ID = existing.CUSTOMER_ID
       AND existing.CURRENT_FLAG = 'N'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY existing.CUSTOMER_ID
                               ORDER BY existing.EFFECTIVE_TO DESC) = 1
    WHERE stg.CUSTOMER_ID NOT IN (
        SEL CUSTOMER_ID FROM BANKING_DW.DIM_CUSTOMER WHERE CURRENT_FLAG = 'Y'
    );

    SET p_new_rows = ACTIVITY_COUNT;

    -- Collect stats
    COLLECT STATISTICS COLUMN (CUSTOMER_ID) ON BANKING_DW.DIM_CUSTOMER;
    COLLECT STATISTICS COLUMN (CURRENT_FLAG) ON BANKING_DW.DIM_CUSTOMER;

END;
