# How to run

Requires Python 3.11+ and a PostgreSQL 16+ server. From the project directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt

createdb healthcare_claims
export DATABASE_URL="postgresql://localhost/healthcare_claims"
python run_analysis.py --download
```

You may need to adjust `DATABASE_URL` for your PostgreSQL connection. The script downloads the CMS source files, runs the SQL checks, and saves both reports in `outputs/`.

To run the tests:

```bash
python test_checks.py
```
