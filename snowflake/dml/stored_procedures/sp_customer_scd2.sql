/**********************************************************************
 * SP_CUSTOMER_SCD2 (Snowflake Scripting)
 * Converted from dml/stored_procedures/sp_customer_scd2.sql.
 *
 * - REPLACE PROCEDURE -> CREATE OR REPLACE PROCEDURE ... LANGUAGE SQL.
 * - OUT parameters (p_new_rows, p_changed, p_return_code) -> returned OBJECT
 *   {P_NEW_ROWS, P_CHANGED, P_RETURN_CODE}. Callers read it from the CALL result.
 * - Teradata UPDATE tgt FROM (subquery) src SET ... -> Snowflake
 *   UPDATE tgt SET ... FROM (subquery) src WHERE ... (DISTINCT added so each
 *   target row matches at most one source row).
 * - ACTIVITY_COUNT -> SQLROWCOUNT.
 * - QUALIFY moved after WHERE (Snowflake clause order).
 * - CORRECTION: QUALIFY now partitions by stg.CUSTOMER_ID. The original
 *   partitioned by existing.CUSTOMER_ID, which is NULL for every brand-new
 *   customer, so only one new customer per batch would have been inserted.
 * - COLLECT STATISTICS removed (automatic in Snowflake).
 **********************************************************************/

CREATE OR REPLACE PROCEDURE BANKING_DW.SP_CUSTOMER_SCD2(P_BATCH_ID BIGINT)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_current_ts  TIMESTAMP_NTZ(0) DEFAULT CURRENT_TIMESTAMP(0)::TIMESTAMP_NTZ(0);
    v_new_rows    INTEGER DEFAULT 0;
    v_changed     INTEGER DEFAULT 0;
BEGIN
    -- Step 1: Expire changed records
    UPDATE BANKING_DW.DIM_CUSTOMER tgt
    SET CURRENT_FLAG  = 'N',
        EFFECTIVE_TO  = :v_current_ts,
        ETL_UPDATE_TS = :v_current_ts,
        ETL_BATCH_ID  = :P_BATCH_ID
    FROM (
        SELECT DISTINCT stg.CUSTOMER_ID
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
    WHERE tgt.CUSTOMER_ID = src.CUSTOMER_ID
      AND tgt.CURRENT_FLAG = 'Y';

    v_changed := SQLROWCOUNT;

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
    SELECT
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
        COALESCE(existing.ONBOARDING_DATE, CURRENT_DATE()),
        CURRENT_DATE(),
        1,
        :v_current_ts,
        TIMESTAMP '9999-12-31 23:59:59',
        'Y',
        :P_BATCH_ID,
        :v_current_ts,
        :v_current_ts
    FROM BANKING_DW.STG_CUSTOMER stg
    LEFT JOIN BANKING_DW.DIM_CUSTOMER existing
        ON stg.CUSTOMER_ID = existing.CUSTOMER_ID
       AND existing.CURRENT_FLAG = 'N'
    WHERE stg.CUSTOMER_ID NOT IN (
        SELECT CUSTOMER_ID FROM BANKING_DW.DIM_CUSTOMER WHERE CURRENT_FLAG = 'Y'
    )
    QUALIFY ROW_NUMBER() OVER (PARTITION BY stg.CUSTOMER_ID
                               ORDER BY existing.EFFECTIVE_TO DESC NULLS LAST) = 1;

    v_new_rows := SQLROWCOUNT;

    RETURN OBJECT_CONSTRUCT('P_NEW_ROWS', v_new_rows,
                            'P_CHANGED', v_changed,
                            'P_RETURN_CODE', 0);
END;
$$;
