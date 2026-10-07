# Healthcare Claims Reporting & Validation

This project analyzes synthetic Medicare outpatient claims published by CMS, covering 2008–2010. Python loads the files into PostgreSQL, where SQL queries produce monthly activity reports and compare financial totals with CMS’s annual beneficiary summaries.

The analysis addresses two questions:

- How do claim volumes, distinct beneficiaries, and reimbursement amounts vary by month?
- Do the annual financial totals calculated from outpatient claims match the totals in CMS’s beneficiary summaries?

## Results

The dataset contains **779,537 claims**, **85,238 distinct beneficiaries** across the full period, and **$209,292,350 in Medicare reimbursement**.

Annual claim activity and Medicare reimbursement are shown below. The [monthly report](outputs/monthly_activity.csv) includes all 36 months, along with beneficiary counts, primary payer reimbursement, and beneficiary responsibility.

| Year | Claims | Medicare reimbursement | Medicare per claim |
|---|---:|---:|---:|
| 2008 | 281,901 | $72,397,300.00 | $256.82 |
| 2009 | 322,631 | $88,139,830.00 | $273.19 |
| 2010 | 175,005 | $48,755,220.00 | $278.59 |

The Medicare totals calculated from claims matched the CMS beneficiary summaries in each year. These comparisons are included in the [annual reconciliation report](outputs/annual_reconciliation.csv):

| Year | Total from claims | CMS summary total | Difference | Beneficiaries with differences |
|---|---:|---:|---:|---:|
| 2008 | $72,397,300.00 | $72,397,300.00 | $0.00 | 0 |
| 2009 | $88,139,830.00 | $88,139,830.00 | $0.00 | 0 |
| 2010 | $48,755,220.00 | $48,755,220.00 | $0.00 | 0 |

### Observations

- **Medicare reimbursement rose faster than claim counts.** From 2008 to 2009, claim counts increased 14.4%, while Medicare reimbursement increased 21.7%. Average reimbursement per claim rose from $256.82 to $273.19.
- **A tenth of beneficiaries accounted for almost half of Medicare reimbursement..** Among beneficiaries with included outpatient claims in 2009, the 10% of beneficiaries with the highest annual Medicare reimbursement accounted for 47.5% of the total.
- **Claims per beneficiary fell.** From 2008 to 2009, the number of beneficiaries with outpatient claims increased 20.9%, while claims per beneficiary fell from 4.73 to 4.48.

## Methods and definitions

`run_analysis.py` loads the CMS files into PostgreSQL. The queries in `analysis.sql` produce the monthly report and annual financial comparisons.

Claims are grouped by their service end date (`CLM_THRU_DT`). The analysis includes segment 1 records with service dates ending in 2008–2010. Records without reporting dates are excluded. Zero and negative amounts are kept as recorded.

For the annual comparison, claims are matched to beneficiary summaries by beneficiary ID and year. Each beneficiary’s totals are checked before the differences are summarized by year.

| Monthly field | Definition |
|---|---|
| `report_month` | First day of the service end month |
| `claim_count` | Count of unique included beneficiary/claim records |
| `distinct_beneficiaries` | Distinct beneficiary IDs within the month |
| `medicare_reimbursement` | Sum of `CLM_PMT_AMT` |
| `primary_payer_reimbursement` | Sum of `NCH_PRMRY_PYR_CLM_PD_AMT` |
| `beneficiary_responsibility` | Sum of the three responsibility fields listed below |
| `medicare_per_claim` | Medicare reimbursement divided by claim count, rounded to cents; null when count is zero |

Beneficiary responsibility adds the recorded blood deductible, Part B deductible, and coinsurance amounts: `NCH_BENE_BLOOD_DDCTBL_LBLTY_AM`, `NCH_BENE_PTB_DDCTBL_AMT`, and `NCH_BENE_PTB_COINSRNC_AMT`.

The annual report compares Medicare reimbursement, primary payer reimbursement, and beneficiary responsibility with the corresponding amounts in CMS’s summaries. It shows the totals, their differences, and how many beneficiaries had a difference.

## Data and sources

The project uses outpatient claims and three annual beneficiary summary files from the [CMS Medicare Claims Sample downloads page](https://www.cms.gov/data-research/statistics-trends-and-reports/medicare-claims-synthetic-public-use-files/cms-2008-2010-data-entrepreneurs-synthetic-public-use-file-de-synpuf/de10-sample-1). The outpatient file contains 790,790 source records. This page also provides a [CMS user manual](https://www.cms.gov/Research-Statistics-Data-and-Systems/Downloadable-Public-Use-Files/SynPUFs/Downloads/SynPUF_DUG.pdf) and [codebook](https://www.cms.gov/files/document/de-10-codebook.pdf-0).

## Data checks

SQL checks identify duplicate records and invalid dates or amounts, and confirm that joining the tables does not change claim counts or financial totals. The annual amounts calculated from claims matched the CMS beneficiary summaries. `test_checks.py` uses small example datasets to check that invalid records and financial discrepancies are detected.

[How to run](SETUP.md)
