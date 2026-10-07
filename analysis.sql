-- preparation (PostgreSQL 16+)
-- The runner loads source strings using COPY and selects the healthcare_claims schema.
-- Rebuild only the named project objects; failed runs roll back the transaction.
DROP VIEW IF EXISTS beneficiary_comparison,included_claims,excluded_records;
DROP TABLE IF EXISTS validation_checks,annual_reconciliation,monthly_activity,beneficiaries,claims;

CREATE TABLE claims AS
WITH date_text AS (
    SELECT *,
        substring(CLM_FROM_DT,1,4)||'-'||substring(CLM_FROM_DT,5,2)||'-'||substring(CLM_FROM_DT,7,2) AS from_iso,
        substring(CLM_THRU_DT,1,4)||'-'||substring(CLM_THRU_DT,5,2)||'-'||substring(CLM_THRU_DT,7,2) AS thru_iso
    FROM outpatient_raw
), parsed AS (
    SELECT *,
        CASE WHEN CLM_FROM_DT ~ '^[0-9]{8}$' AND pg_input_is_valid(from_iso,'date')
            THEN CAST(from_iso AS DATE) END AS from_date,
        CASE WHEN CLM_THRU_DT ~ '^[0-9]{8}$' AND pg_input_is_valid(thru_iso,'date')
            THEN CAST(thru_iso AS DATE) END AS thru_date
    FROM date_text
)
SELECT DESYNPUF_ID AS beneficiary_id, CLM_ID AS claim_id,
    SEGMENT AS segment, PRVDR_NUM AS provider_id,
    CLM_FROM_DT AS from_raw, CLM_THRU_DT AS thru_raw,
    from_date,thru_date,CAST(EXTRACT(YEAR FROM thru_date) AS INTEGER) AS report_year,
    CASE WHEN CLM_PMT_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(CLM_PMT_AMT,'numeric(18,2)')
        THEN CAST(CLM_PMT_AMT AS NUMERIC(18,2)) END AS medicare_paid,
    CASE WHEN NCH_PRMRY_PYR_CLM_PD_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(NCH_PRMRY_PYR_CLM_PD_AMT,'numeric(18,2)')
        THEN CAST(NCH_PRMRY_PYR_CLM_PD_AMT AS NUMERIC(18,2)) END AS primary_paid,
    CASE WHEN NCH_BENE_BLOOD_DDCTBL_LBLTY_AM ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM,'numeric(18,2)')
        THEN CAST(NCH_BENE_BLOOD_DDCTBL_LBLTY_AM AS NUMERIC(18,2)) END
      + CASE WHEN NCH_BENE_PTB_DDCTBL_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(NCH_BENE_PTB_DDCTBL_AMT,'numeric(18,2)')
        THEN CAST(NCH_BENE_PTB_DDCTBL_AMT AS NUMERIC(18,2)) END
      + CASE WHEN NCH_BENE_PTB_COINSRNC_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(NCH_BENE_PTB_COINSRNC_AMT,'numeric(18,2)')
        THEN CAST(NCH_BENE_PTB_COINSRNC_AMT AS NUMERIC(18,2)) END AS responsibility
FROM parsed;

CREATE TABLE beneficiaries AS
SELECT DESYNPUF_ID AS beneficiary_id, report_year,
    CASE WHEN MEDREIMB_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(MEDREIMB_OP,'numeric(18,2)')
        THEN CAST(MEDREIMB_OP AS NUMERIC(18,2)) END AS medicare_control,
    CASE WHEN PPPYMT_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(PPPYMT_OP,'numeric(18,2)')
        THEN CAST(PPPYMT_OP AS NUMERIC(18,2)) END AS primary_control,
    CASE WHEN BENRES_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'
        AND pg_input_is_valid(BENRES_OP,'numeric(18,2)')
        THEN CAST(BENRES_OP AS NUMERIC(18,2)) END AS responsibility_control
FROM beneficiaries_raw;

ANALYZE claims;
ANALYZE beneficiaries;

CREATE VIEW included_claims AS
SELECT *,CAST(date_trunc('month',thru_date) AS DATE) AS report_month
FROM claims WHERE segment='1' AND from_date IS NOT NULL
    AND thru_date IS NOT NULL AND from_date<=thru_date
    AND report_year BETWEEN 2008 AND 2010;

CREATE VIEW excluded_records AS
SELECT *,'Missing reporting dates' AS exclusion_reason
FROM claims WHERE segment='2' AND from_raw IS NULL AND thru_raw IS NULL;

-- monthly_report
CREATE TABLE monthly_activity AS
WITH months AS (
    SELECT CAST(report_month AS DATE) AS report_month
    FROM generate_series(TIMESTAMP '2008-01-01', TIMESTAMP '2010-12-01',
        INTERVAL '1 month') AS t(report_month)
), activity AS (
    SELECT report_month, count(*) AS claim_count,
        count(DISTINCT beneficiary_id) AS distinct_beneficiaries,
        sum(medicare_paid) AS medicare_reimbursement,
        sum(primary_paid) AS primary_payer_reimbursement,
        sum(responsibility) AS beneficiary_responsibility,
        CAST(round(sum(medicare_paid)/count(*),2) AS NUMERIC(18,2)) AS medicare_per_claim
    FROM included_claims GROUP BY report_month
)
SELECT m.report_month, coalesce(a.claim_count,0) AS claim_count,
    coalesce(a.distinct_beneficiaries,0) AS distinct_beneficiaries,
    coalesce(a.medicare_reimbursement,CAST(0 AS NUMERIC(18,2))) AS medicare_reimbursement,
    coalesce(a.primary_payer_reimbursement,CAST(0 AS NUMERIC(18,2))) AS primary_payer_reimbursement,
    coalesce(a.beneficiary_responsibility,CAST(0 AS NUMERIC(18,2))) AS beneficiary_responsibility,
    a.medicare_per_claim
FROM months m LEFT JOIN activity a USING(report_month)
ORDER BY m.report_month;

-- annual_report
-- Compare at beneficiary/year level before summarizing, so errors cannot offset.
CREATE VIEW beneficiary_comparison AS
WITH calculated AS (
    SELECT beneficiary_id,report_year,
        sum(medicare_paid) AS medicare,
        sum(primary_paid) AS primary_payer,
        sum(responsibility) AS responsibility
    FROM included_claims GROUP BY beneficiary_id,report_year
)
SELECT b.beneficiary_id,b.report_year,
    coalesce(c.medicare,CAST(0 AS NUMERIC(18,2))) AS calculated_medicare,
    b.medicare_control AS supplied_medicare,
    coalesce(c.primary_payer,CAST(0 AS NUMERIC(18,2))) AS calculated_primary,
    b.primary_control AS supplied_primary,
    coalesce(c.responsibility,CAST(0 AS NUMERIC(18,2))) AS calculated_responsibility,
    b.responsibility_control AS supplied_responsibility
FROM beneficiaries b LEFT JOIN calculated c USING(beneficiary_id,report_year);

CREATE TABLE annual_reconciliation AS
WITH measures AS (
    SELECT report_year,'medicare_reimbursement' AS measure,
        calculated_medicare AS calculated,supplied_medicare AS supplied
    FROM beneficiary_comparison
    UNION ALL
    SELECT report_year,'primary_payer_reimbursement',calculated_primary,supplied_primary
    FROM beneficiary_comparison
    UNION ALL
    SELECT report_year,'beneficiary_responsibility',calculated_responsibility,supplied_responsibility
    FROM beneficiary_comparison
)
SELECT report_year,measure,sum(calculated) AS calculated_total,
    sum(supplied) AS supplied_total,sum(calculated-supplied) AS difference,
    count(*) FILTER(WHERE calculated IS DISTINCT FROM supplied) AS beneficiary_mismatch_count
FROM measures GROUP BY report_year,measure ORDER BY report_year,measure;

-- validation
CREATE TABLE validation_checks AS
SELECT 'required_keys' AS check_name,
    (SELECT count(*) FROM claims WHERE beneficiary_id IS NULL OR claim_id IS NULL OR segment IS NULL)
    + (SELECT count(*) FROM beneficiaries WHERE beneficiary_id IS NULL OR report_year IS NULL) AS failures
UNION ALL
SELECT 'source_key_uniqueness',count(*) FROM (
    SELECT beneficiary_id,claim_id,segment FROM claims GROUP BY beneficiary_id,claim_id,segment HAVING count(*)>1) AS duplicate_keys
UNION ALL
SELECT 'beneficiary_year_uniqueness',count(*) FROM (
    SELECT beneficiary_id,report_year FROM beneficiaries GROUP BY beneficiary_id,report_year HAVING count(*)>1) AS duplicate_keys
UNION ALL
SELECT 'included_claim_uniqueness',count(*) FROM (
    SELECT beneficiary_id,claim_id FROM included_claims GROUP BY beneficiary_id,claim_id HAVING count(*)>1) AS duplicate_keys
UNION ALL
SELECT 'dates_and_segments',count(*) FROM claims WHERE
    segment IS NULL OR segment NOT IN ('1','2')
    OR (segment='2' AND (from_raw IS NOT NULL OR thru_raw IS NOT NULL))
    OR (segment='1' AND (from_date IS NULL OR thru_date IS NULL
        OR from_date>thru_date OR report_year NOT BETWEEN 2008 AND 2010
        OR NOT coalesce((from_raw ~ '^[0-9]{8}$'),false)
        OR NOT coalesce((thru_raw ~ '^[0-9]{8}$'),false)))
UNION ALL
-- Check lexical precision too: NUMERIC casting must not silently round source money.
SELECT 'amount_parsing',
    (SELECT count(*) FROM outpatient_raw WHERE
        NOT coalesce((CLM_PMT_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((NCH_PRMRY_PYR_CLM_PD_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((NCH_BENE_BLOOD_DDCTBL_LBLTY_AM ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((NCH_BENE_PTB_DDCTBL_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((NCH_BENE_PTB_COINSRNC_AMT ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false))
    + (SELECT count(*) FROM claims WHERE medicare_paid IS NULL OR primary_paid IS NULL OR responsibility IS NULL)
    + (SELECT count(*) FROM beneficiaries_raw WHERE
        NOT coalesce((MEDREIMB_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((PPPYMT_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false)
        OR NOT coalesce((BENRES_OP ~ '^-?[0-9]+([.][0-9]{1,2})?$'),false))
    + (SELECT count(*) FROM beneficiaries WHERE medicare_control IS NULL OR primary_control IS NULL OR responsibility_control IS NULL)
UNION ALL
SELECT 'beneficiary_year_match',count(*) FROM included_claims c
    LEFT JOIN beneficiaries b USING(beneficiary_id,report_year)
    WHERE b.beneficiary_id IS NULL;

INSERT INTO validation_checks
WITH before_join AS (
    SELECT count(*) AS records,sum(medicare_paid) AS medicare,
        sum(primary_paid) AS primary_payer,sum(responsibility) AS responsibility
    FROM included_claims
), after_join AS (
    SELECT count(*) AS records,sum(c.medicare_paid) AS medicare,
        sum(c.primary_paid) AS primary_payer,sum(c.responsibility) AS responsibility
    FROM included_claims c LEFT JOIN beneficiaries b USING(beneficiary_id,report_year)
)
SELECT 'join_preserves_totals',CASE WHEN
    a.records IS NOT DISTINCT FROM b.records AND a.medicare IS NOT DISTINCT FROM b.medicare
    AND a.primary_payer IS NOT DISTINCT FROM b.primary_payer
    AND a.responsibility IS NOT DISTINCT FROM b.responsibility THEN 0 ELSE 1 END
FROM before_join a CROSS JOIN after_join b;

INSERT INTO validation_checks
WITH totals AS (
    SELECT 'raw' AS subset,count(*) AS records,coalesce(sum(medicare_paid),0) AS medicare,
        coalesce(sum(primary_paid),0) AS primary_payer,coalesce(sum(responsibility),0) AS responsibility FROM claims
    UNION ALL
    SELECT 'included',count(*),coalesce(sum(medicare_paid),0),coalesce(sum(primary_paid),0),coalesce(sum(responsibility),0) FROM included_claims
    UNION ALL
    SELECT 'excluded',count(*),coalesce(sum(medicare_paid),0),coalesce(sum(primary_paid),0),coalesce(sum(responsibility),0) FROM excluded_records
)
SELECT 'source_partition',CASE WHEN r.records=i.records+e.records
    AND r.medicare=i.medicare+e.medicare AND r.primary_payer=i.primary_payer+e.primary_payer
    AND r.responsibility=i.responsibility+e.responsibility THEN 0 ELSE 1 END
FROM totals r,totals i,totals e WHERE r.subset='raw' AND i.subset='included' AND e.subset='excluded';

INSERT INTO validation_checks
SELECT 'monthly_totals',CASE WHEN
    (SELECT count(*) FROM monthly_activity)=36
    AND (SELECT count(DISTINCT report_month) FROM monthly_activity)=36
    AND (SELECT sum(claim_count) FROM monthly_activity)=(SELECT count(*) FROM included_claims)
    AND (SELECT sum(medicare_reimbursement) FROM monthly_activity) IS NOT DISTINCT FROM (SELECT sum(medicare_paid) FROM included_claims)
    AND (SELECT sum(primary_payer_reimbursement) FROM monthly_activity) IS NOT DISTINCT FROM (SELECT sum(primary_paid) FROM included_claims)
    AND (SELECT sum(beneficiary_responsibility) FROM monthly_activity) IS NOT DISTINCT FROM (SELECT sum(responsibility) FROM included_claims)
    THEN 0 ELSE 1 END;

INSERT INTO validation_checks
SELECT 'annual_reconciliation',
    count(*) FILTER(WHERE difference IS DISTINCT FROM 0 OR beneficiary_mismatch_count<>0)
    + CASE WHEN count(*)=9 THEN 0 ELSE 1 END
FROM annual_reconciliation;
