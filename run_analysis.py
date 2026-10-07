"""Recreate the two CMS outpatient reporting CSVs with Python and PostgreSQL."""
import argparse
import csv
import hashlib
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.request
import zipfile

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parent
CMS_DOWNLOADS = 'https://www.cms.gov/research-statistics-data-and-systems/downloadable-public-use-files/synpufs/downloads/'
SOURCES = (
    ('outpatient.zip', 'DE1_0_2008_to_2010_Outpatient_Claims_Sample_1.csv',
     CMS_DOWNLOADS+'de1_0_2008_to_2010_outpatient_claims_sample_1.zip',
     '7c94a94c8c676511d0bbea2dae3e6511980bdb8e44003285a0619a7ef38f9495', None),
    ('beneficiary_2008.zip', 'DE1_0_2008_Beneficiary_Summary_File_Sample_1.csv',
     CMS_DOWNLOADS+'de1_0_2008_beneficiary_summary_file_sample_1.zip',
     '2b0c9cbfb07a6eb46d5f96472c0891275a390b686c3fa34daae8d3e53d70b18b', 2008),
    ('beneficiary_2009.zip', 'DE1_0_2009_Beneficiary_Summary_File_Sample_1.csv',
     CMS_DOWNLOADS+'de1_0_2009_beneficiary_summary_file_sample_1.zip',
     'dff1853368d8279cd60efabd067ad518decd5f200475134e0b4d0408880bb379', 2009),
    ('beneficiary_2010_page_link.zip', 'DE1_0_2010_Beneficiary_Summary_File_Sample_1.csv',
     'https://www.cms.gov/research-statistics-data-and-systems/statistics-trends-and-reports/synpufs/downloads/de1_0_2010_beneficiary_summary_file_sample_20.zip',
     'b28b8ac7ecc2ba2fb3138dbba74dd41a183a34d0322c0492f7a87a8e7dc1fdff', 2010),
)
CLAIM_FIELDS = ('DESYNPUF_ID','CLM_ID','SEGMENT','PRVDR_NUM','CLM_FROM_DT','CLM_THRU_DT',
    'CLM_PMT_AMT','NCH_PRMRY_PYR_CLM_PD_AMT','NCH_BENE_BLOOD_DDCTBL_LBLTY_AM',
    'NCH_BENE_PTB_DDCTBL_AMT','NCH_BENE_PTB_COINSRNC_AMT')
BENE_FIELDS = ('DESYNPUF_ID','MEDREIMB_OP','PPPYMT_OP','BENRES_OP')
REPORTS = ('monthly_activity','annual_reconciliation')
SCHEMA = 'healthcare_claims'


class ValidationError(ValueError):
    pass


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def get_archive(data_dir, source, download=False):
    name,member,url,expected,year = source
    path = data_dir/name
    # Also accept archives saved under their official download names.
    if not path.exists() and (data_dir/url.rsplit('/',1)[-1]).exists():
        path = data_dir/url.rsplit('/',1)[-1]
    if not path.exists():
        if not download:
            raise FileNotFoundError(f'Missing {name}. Supply --data-dir or use --download.')
        data_dir.mkdir(parents=True,exist_ok=True)
        print(f'Downloading {name}',flush=True)
        part = path.with_suffix('.zip.part')
        try:
            with urllib.request.urlopen(url,timeout=90) as response,part.open('wb') as out:
                shutil.copyfileobj(response,out)
            if digest(part)!=expected:
                raise ValidationError(f'Source changed: {name}; review it before analysis.')
            part.replace(path)
        finally:
            part.unlink(missing_ok=True)
    if digest(path)!=expected:
        raise ValidationError(f'Unexpected source hash: {path.name}; expected the inspected Sample 1 archive.')
    return path


def prepare_database(con,schema=SCHEMA):
    """Keep project objects in their own schema; tests use a temporary schema."""
    if con.info.server_version < 160000:
        raise ValidationError('PostgreSQL 16 or newer is required.')
    con.execute(sql.SQL('CREATE SCHEMA IF NOT EXISTS {}').format(sql.Identifier(schema)))
    con.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(schema)))
    con.execute('DROP TABLE IF EXISTS outpatient_raw,beneficiaries_raw')
    for table,fields in [('outpatient_raw',CLAIM_FIELDS),('beneficiaries_raw',BENE_FIELDS)]:
        definitions = [sql.SQL('{} TEXT').format(sql.Identifier(name.lower())) for name in fields]
        if table=='beneficiaries_raw':
            definitions.append(sql.SQL('report_year INTEGER'))
        con.execute(sql.SQL('CREATE TABLE {} ({})').format(
            sql.Identifier(table),sql.SQL(',').join(definitions)))


def load_sources(con,data_dir,download=False):
    # Stream the inspected archives directly into PostgreSQL; raw files stay unchanged.
    for source in SOURCES:
        archive = get_archive(data_dir,source,download)
        _,member,_,_,year = source
        fields = CLAIM_FIELDS if year is None else BENE_FIELDS
        table = 'outpatient_raw' if year is None else 'beneficiaries_raw'
        columns = [sql.Identifier(name.lower()) for name in fields]
        if year is not None:
            columns.append(sql.Identifier('report_year'))
        query = sql.SQL('COPY {} ({}) FROM STDIN').format(
            sql.Identifier(table),sql.SQL(',').join(columns))
        print(f'Loading {archive.name}',flush=True)
        with zipfile.ZipFile(archive) as z:
            if member not in z.namelist():
                raise ValidationError(f'Wrong archive member in {archive.name}: expected {member}')
            with z.open(member) as raw,io.TextIOWrapper(raw,encoding='utf-8-sig',newline='') as f:
                reader = csv.reader(f)
                header = next(reader)
                missing = set(fields)-set(header)
                if missing:
                    raise ValidationError(f'Missing fields in {member}: {sorted(missing)}')
                positions = [header.index(name) for name in fields]
                with con.cursor() as cur,cur.copy(query) as copy:
                    for record in reader:
                        if len(record)!=len(header):
                            raise ValidationError(f'Unexpected field count in {member}, line {reader.line_num}.')
                        values = [record[i] if record[i]!='' else None for i in positions]
                        if year is not None:
                            values.append(year)
                        copy.write_row(values)


def run_sql(con):
    con.execute((ROOT/'analysis.sql').read_text(encoding='utf-8'))


def validate(con):
    checks = con.execute('SELECT check_name,failures FROM validation_checks ORDER BY check_name').fetchall()
    bad = [(name,n) for name,n in checks if n is None or n!=0]
    if bad:
        raise ValidationError('Failed checks: '+', '.join(f'{name} ({n})' for name,n in bad))
    return checks


def write_reports(con,output_dir):
    validate(con)
    output_dir.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output_dir,prefix='.reports-') as scratch:
        for name in REPORTS:
            order = 'report_month' if name=='monthly_activity' else 'report_year,measure'
            result = con.execute(f'SELECT * FROM {name} ORDER BY {order}')
            with (Path(scratch)/(name+'.csv')).open('w',newline='',encoding='utf-8') as f:
                writer = csv.writer(f,lineterminator='\n')
                writer.writerow([d[0] for d in result.description])
                writer.writerows(result.fetchall())
        for name in REPORTS:
            (Path(scratch)/(name+'.csv')).replace(output_dir/(name+'.csv'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir',type=Path,default=ROOT/'data/raw',help='Directory containing the four source ZIPs')
    parser.add_argument('--download',action='store_true',help='Download missing official archives (about 44 MB total)')
    parser.add_argument('--database-url',default=os.environ.get('DATABASE_URL'),
        help='PostgreSQL connection string; defaults to the DATABASE_URL environment variable')
    args = parser.parse_args()
    if not args.database_url:
        parser.error('Set DATABASE_URL or supply --database-url for your project database.')
    try:
        with psycopg.connect(args.database_url,connect_timeout=10) as con:
            prepare_database(con)
            load_sources(con,args.data_dir.resolve(),args.download)
            run_sql(con)
            checks = validate(con)
            con.commit()
            write_reports(con,ROOT/'outputs')
            claims,people,paid = con.execute('SELECT count(*),count(DISTINCT beneficiary_id),sum(medicare_paid) FROM included_claims').fetchone()
            excluded = con.execute('SELECT count(*) FROM excluded_records').fetchone()[0]
            print(f'Checks passed: {len(checks)}. Included claims: {claims:,}; distinct beneficiaries: {people:,}; Medicare reimbursement: ${paid:,.2f}.')
            print(f'Date rule: excluded {excluded:,} undated segment-2 records; details remain in {SCHEMA}.excluded_records.')
            print('Wrote outputs/monthly_activity.csv (36 rows) and outputs/annual_reconciliation.csv (9 rows).')
    except (OSError,ValueError,psycopg.Error,zipfile.BadZipFile) as exc:
        print(f'Analysis stopped: {exc}',file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':
    raise SystemExit(main())
