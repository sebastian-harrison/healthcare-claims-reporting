"""Small examples checking the same SQL and export guard used by the runner."""
import csv
from decimal import Decimal
import os
from pathlib import Path
import tempfile
import unittest
import uuid

import psycopg

from run_analysis import ValidationError,prepare_database,run_sql,validate,write_reports


def populate_example(con):
    with con.cursor() as cur:
        cur.executemany('INSERT INTO outpatient_raw VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)',[
            ('A','C1','1','P1','20071230','20081231','100.00','5.00','0.00','1.00','2.00'),
            ('B','C2','1','P2','20081201','20081201','40.00','0.00','0.00','0.00','2.00'),
            ('A','C3','1','P1','20081231','20090101','-10.00','0.00','0.00','0.00','0.00'),
            ('B','C4','1','P2','20101231','20101231','0.00','0.00','0.00','0.00','0.00'),
            ('A','C1','2','P3',None,None,'20.00','0.00','0.00','0.00','0.00'),
        ])
        cur.executemany('INSERT INTO beneficiaries_raw VALUES (%s,%s,%s,%s,%s)',[
            ('A','100.00','5.00','3.00',2008),('B','40.00','0.00','2.00',2008),
            ('A','-10.00','0.00','0.00',2009),('B','0.00','0.00','0.00',2009),
            ('A','0.00','0.00','0.00',2010),('B','0.00','0.00','0.00',2010),
        ])


class ReportingChecks(unittest.TestCase):
    def setUp(self):
        self.con = psycopg.connect(os.environ['DATABASE_URL'])
        # Each fixture has its own schema, rolled back along with the test data.
        self.addCleanup(self.con.close)
        self.addCleanup(self.con.rollback)
        prepare_database(self.con,'claims_test_'+uuid.uuid4().hex)
        populate_example(self.con)

    def test_baseline_boundaries_signed_amounts_and_counts(self):
        run_sql(self.con)
        self.assertEqual(len(validate(self.con)),11)
        rows = self.con.execute("SELECT CAST(report_month AS TEXT),claim_count,medicare_reimbursement FROM monthly_activity WHERE claim_count>0 ORDER BY report_month").fetchall()
        self.assertEqual(rows,[('2008-12-01',2,Decimal('140.00')),
            ('2009-01-01',1,Decimal('-10.00')),('2010-12-01',1,Decimal('0.00'))])
        self.assertEqual(self.con.execute('SELECT count(*) FROM excluded_records').fetchone()[0],1)
        self.assertEqual(self.con.execute('SELECT count(DISTINCT beneficiary_id) FROM included_claims').fetchone()[0],2)
        self.assertEqual(self.con.execute('SELECT sum(distinct_beneficiaries) FROM monthly_activity').fetchone()[0],4)
        with tempfile.TemporaryDirectory() as folder:
            write_reports(self.con,Path(folder))
            with (Path(folder)/'monthly_activity.csv').open(newline='') as f:
                empty_month = next(csv.DictReader(f))
            self.assertEqual(empty_month['claim_count'],'0')
            self.assertEqual(empty_month['medicare_reimbursement'],'0.00')
            self.assertEqual(empty_month['primary_payer_reimbursement'],'0.00')
            self.assertEqual(empty_month['beneficiary_responsibility'],'0.00')
            self.assertEqual(empty_month['medicare_per_claim'],'')

    def test_duplicate_beneficiary_key_blocks_export(self):
        self.con.execute("INSERT INTO beneficiaries_raw SELECT * FROM beneficiaries_raw WHERE DESYNPUF_ID='A' AND report_year=2008")
        run_sql(self.con)
        with tempfile.TemporaryDirectory() as folder:
            existing = Path(folder)/'monthly_activity.csv'
            existing.write_text('previous successful report\n')
            with self.assertRaisesRegex(ValidationError,'beneficiary_year_uniqueness'):
                write_reports(self.con,Path(folder))
            self.assertEqual(existing.read_text(),'previous successful report\n')
            self.assertFalse((Path(folder)/'annual_reconciliation.csv').exists())

    def test_offsetting_amount_changes_are_detected(self):
        # The year total stays at $140; beneficiary-level comparisons must still fail.
        self.con.execute("UPDATE outpatient_raw SET CLM_PMT_AMT='101.00' WHERE CLM_ID='C1' AND SEGMENT='1'")
        self.con.execute("UPDATE outpatient_raw SET CLM_PMT_AMT='39.00' WHERE CLM_ID='C2'")
        run_sql(self.con)
        difference,mismatches = self.con.execute("SELECT difference,beneficiary_mismatch_count FROM annual_reconciliation WHERE report_year=2008 AND measure='medicare_reimbursement'").fetchone()
        self.assertEqual(difference,Decimal('0.00'))
        self.assertEqual(mismatches,2)
        with self.assertRaisesRegex(ValidationError,'annual_reconciliation'):
            validate(self.con)

    def test_invalid_calendar_date_and_extra_money_precision(self):
        self.con.execute("UPDATE outpatient_raw SET CLM_THRU_DT='20080230',CLM_PMT_AMT='100.001' WHERE CLM_ID='C1' AND SEGMENT='1'")
        run_sql(self.con)
        self.assertEqual(self.con.execute("SELECT thru_date,medicare_paid FROM claims WHERE claim_id='C1' AND segment='1'").fetchone(),(None,None))
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValidationError,'amount_parsing'):
                write_reports(self.con,Path(folder))
            self.assertEqual(list(Path(folder).iterdir()),[])


if __name__=='__main__':
    if not os.environ.get('DATABASE_URL'):
        raise SystemExit('Set DATABASE_URL for your PostgreSQL project database before running tests.')
    unittest.main(verbosity=2)
