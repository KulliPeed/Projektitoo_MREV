#!/usr/bin/env python3
import argparse
import csv
import hashlib
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path

import psycopg


DB_HOST = "localhost"
DB_PORT = 5432
DB_NAME = "andmeprojekt"
DB_USER = "andrus"
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD") or os.environ.get("DB_PASSWORD")

DEFAULT_CSV_FILE = Path("data/raw/maksuvolglased/maksuvolglased_latest.csv")
DEFAULT_LATEST_FILE = Path("data/raw/maksuvolglased/latest.txt")
BATCH_SIZE = 1000

EXPECTED_HEADERS = [
    "Andmed on seisuga",
    "Registrikood",
    "Nimi",
    "Maksuvõlg",
    "sh vaidlustatud",
    "sh tasumisgraafikus",
    "Tasumisgraafiku lõppkuupäev",
    "Vanima tasumata nõude tasumise tähtpäev",
]

HEADER_TO_COLUMN = {
    "Andmed on seisuga": "andmed_on_seisuga",
    "Registrikood": "registrikood",
    "Nimi": "nimi",
    "Maksuvõlg": "maksuvolg",
    "sh vaidlustatud": "sh_vaidlustatud",
    "sh tasumisgraafikus": "sh_tasumisgraafikus",
    "Tasumisgraafiku lõppkuupäev": "tasumisgraafiku_loppkuupaev",
    "Vanima tasumata nõude tasumise tähtpäev": "vanima_tasumata_noude_tasumise_tahtaeg",
}

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS raw.mta_maksuvolglased_csv (
    id BIGSERIAL PRIMARY KEY,
    snapshot_date DATE NOT NULL,
    data_as_of DATE,
    source_file TEXT NOT NULL,
    file_sha256 TEXT NOT NULL,
    row_no BIGINT NOT NULL,
    loaded_at TIMESTAMP DEFAULT now(),
    andmed_on_seisuga TEXT,
    registrikood TEXT,
    nimi TEXT,
    maksuvolg TEXT,
    sh_vaidlustatud TEXT,
    sh_tasumisgraafikus TEXT,
    tasumisgraafiku_loppkuupaev TEXT,
    vanima_tasumata_noude_tasumise_tahtaeg TEXT,
    CONSTRAINT uq_mta_maksuvolglased_raw_snapshot_file_row
        UNIQUE (snapshot_date, source_file, row_no)
)
"""

CREATE_INDEX_SQL = [
    """
    CREATE INDEX IF NOT EXISTS idx_mta_maksuvolglased_raw_snapshot_date
    ON raw.mta_maksuvolglased_csv(snapshot_date)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mta_maksuvolglased_raw_registrikood
    ON raw.mta_maksuvolglased_csv(registrikood)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_mta_maksuvolglased_raw_file_sha256
    ON raw.mta_maksuvolglased_csv(file_sha256)
    """,
]

INSERT_SQL = """
INSERT INTO raw.mta_maksuvolglased_csv (
    snapshot_date,
    data_as_of,
    source_file,
    file_sha256,
    row_no,
    andmed_on_seisuga,
    registrikood,
    nimi,
    maksuvolg,
    sh_vaidlustatud,
    sh_tasumisgraafikus,
    tasumisgraafiku_loppkuupaev,
    vanima_tasumata_noude_tasumise_tahtaeg
)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (snapshot_date, source_file, row_no) DO NOTHING
"""

DATE_IN_FILENAME_RE = re.compile(r"maksuvolglased_(\d{4}-\d{2}-\d{2})_\d{4}\.csv$")


def parse_estonian_date(value: str) -> date | None:
    value = (value or "").strip()
    if not value:
        return None
    return datetime.strptime(value, "%d.%m.%Y").date()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def date_from_maksuvolglased_filename(path: Path) -> date | None:
    match = DATE_IN_FILENAME_RE.search(path.name)
    if not match:
        return None
    return date.fromisoformat(match.group(1))


def read_latest_target(latest_file: Path) -> Path | None:
    if not latest_file.exists():
        return None
    value = latest_file.read_text(encoding="utf-8").strip()
    if not value:
        return None
    return Path(value)


def infer_snapshot_date(csv_file: Path, latest_file: Path) -> date:
    from_csv_name = date_from_maksuvolglased_filename(csv_file)
    if from_csv_name is not None:
        return from_csv_name

    latest_target = read_latest_target(latest_file)
    if latest_target is not None:
        from_latest_name = date_from_maksuvolglased_filename(latest_target)
        if from_latest_name is not None:
            return from_latest_name

    return date.fromtimestamp(csv_file.stat().st_mtime)


def normalize_header(header: list[str] | None) -> list[str]:
    if header is None:
        return []
    return [(item or "").strip() for item in header]


def validate_header(header: list[str]) -> None:
    if header != EXPECTED_HEADERS:
        raise RuntimeError(
            "CSV päis ei vasta oodatud MTA maksuvõlglaste struktuurile. "
            f"Ootasin: {EXPECTED_HEADERS}; sain: {header}"
        )


def read_csv_rows(csv_file: Path, snapshot_date: date, source_file: str, sha256: str):
    rows = []
    data_as_of_values = set()

    with csv_file.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f, delimiter=";")
        header = normalize_header(reader.fieldnames)
        validate_header(header)

        for row_no, row in enumerate(reader, start=1):
            raw_data_as_of = (row.get("Andmed on seisuga") or "").strip()
            parsed_data_as_of = parse_estonian_date(raw_data_as_of)
            if parsed_data_as_of is not None:
                data_as_of_values.add(parsed_data_as_of)

            rows.append(
                (
                    snapshot_date,
                    parsed_data_as_of,
                    source_file,
                    sha256,
                    row_no,
                    raw_data_as_of,
                    (row.get("Registrikood") or "").strip(),
                    (row.get("Nimi") or "").strip(),
                    (row.get("Maksuvõlg") or "").strip(),
                    (row.get("sh vaidlustatud") or "").strip(),
                    (row.get("sh tasumisgraafikus") or "").strip(),
                    (row.get("Tasumisgraafiku lõppkuupäev") or "").strip(),
                    (row.get("Vanima tasumata nõude tasumise tähtpäev") or "").strip(),
                )
            )

    if not rows:
        raise RuntimeError(f"CSV failis ei ole andmeridu: {csv_file}")

    return rows, data_as_of_values


def connect():
    if not DB_PASSWORD:
        raise RuntimeError("Määra POSTGRES_PASSWORD või DB_PASSWORD keskkonnamuutuja.")

    return psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
    )


def ensure_table(cur) -> None:
    cur.execute(CREATE_TABLE_SQL)
    for sql in CREATE_INDEX_SQL:
        cur.execute(sql)


def count_for_file(cur, snapshot_date: date, source_file: str, sha256: str) -> int:
    cur.execute(
        """
        SELECT count(*)
        FROM raw.mta_maksuvolglased_csv
        WHERE snapshot_date = %s
          AND source_file = %s
          AND file_sha256 = %s
        """,
        (snapshot_date, source_file, sha256),
    )
    return cur.fetchone()[0]


def import_rows(cur, rows: list[tuple]) -> None:
    for start in range(0, len(rows), BATCH_SIZE):
        cur.executemany(INSERT_SQL, rows[start:start + BATCH_SIZE])


def fetch_checks(cur, snapshot_date: date, source_file: str, sha256: str) -> dict:
    cur.execute("SELECT count(*) FROM raw.mta_maksuvolglased_csv")
    total_rows = cur.fetchone()[0]

    cur.execute("SELECT count(DISTINCT snapshot_date) FROM raw.mta_maksuvolglased_csv")
    distinct_snapshot_dates = cur.fetchone()[0]

    cur.execute(
        """
        SELECT count(*), min(row_no), max(row_no),
               (count(*) = max(row_no) AND min(row_no) = 1) AS row_no_ok
        FROM raw.mta_maksuvolglased_csv
        WHERE snapshot_date = %s
          AND source_file = %s
          AND file_sha256 = %s
        """,
        (snapshot_date, source_file, sha256),
    )
    file_count, min_row_no, max_row_no, row_no_ok = cur.fetchone()

    return {
        "total_rows": total_rows,
        "distinct_snapshot_dates": distinct_snapshot_dates,
        "file_count": file_count,
        "min_row_no": min_row_no,
        "max_row_no": max_row_no,
        "row_no_ok": row_no_ok,
    }


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Laadi MTA maksuvõlglaste CSV PostgreSQL raw tabelisse."
    )
    parser.add_argument(
        "--csv-file",
        default=str(DEFAULT_CSV_FILE),
        help="MTA CSV faili tee. Vaikimisi data/raw/maksuvolglased/maksuvolglased_latest.csv.",
    )
    parser.add_argument(
        "--latest-file",
        default=str(DEFAULT_LATEST_FILE),
        help="latest.txt tee, mille järgi tuletatakse latest CSV snapshot_date.",
    )
    parser.add_argument(
        "--snapshot-date",
        help="Snapshot kuupäev YYYY-MM-DD. Kui puudub, tuletatakse failinimest või latest.txt-ist.",
    )
    return parser.parse_args(argv)


def main(argv) -> int:
    args = parse_args(argv)
    csv_file = Path(args.csv_file)
    latest_file = Path(args.latest_file)

    if not csv_file.exists():
        raise FileNotFoundError(csv_file)

    snapshot_date = (
        date.fromisoformat(args.snapshot_date)
        if args.snapshot_date
        else infer_snapshot_date(csv_file, latest_file)
    )
    source_file = str(csv_file)
    sha256 = file_sha256(csv_file)
    rows, data_as_of_values = read_csv_rows(csv_file, snapshot_date, source_file, sha256)

    print(f"CSV fail: {csv_file}")
    print(f"Snapshot date: {snapshot_date}")
    print(f"File SHA256: {sha256}")
    print(f"CSV andmeridu: {len(rows)}")
    print("Data as of väärtused: " + ", ".join(str(item) for item in sorted(data_as_of_values)))

    with connect() as conn:
        with conn.cursor() as cur:
            ensure_table(cur)
            before_count = count_for_file(cur, snapshot_date, source_file, sha256)
            import_rows(cur, rows)
            after_count = count_for_file(cur, snapshot_date, source_file, sha256)
            checks = fetch_checks(cur, snapshot_date, source_file, sha256)
        conn.commit()

    inserted_count = after_count - before_count

    print(f"Ridu samast failist enne importi: {before_count}")
    print(f"Lisatud ridu viimasest failist: {inserted_count}")
    print(f"Ridu samast failist pärast importi: {after_count}")
    print(f"Tabelis kokku ridu: {checks['total_rows']}")
    print(f"Distinct snapshot_date väärtusi: {checks['distinct_snapshot_dates']}")
    print(
        "Viimase faili row_no kontroll: "
        f"count={checks['file_count']}, "
        f"min={checks['min_row_no']}, "
        f"max={checks['max_row_no']}, "
        f"ok={checks['row_no_ok']}"
    )

    if not checks["row_no_ok"]:
        raise RuntimeError("row_no vahemik ei klapi count(*) väärtusega.")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"MTA raw import ebaõnnestus: {exc}", file=sys.stderr)
        raise SystemExit(1)
