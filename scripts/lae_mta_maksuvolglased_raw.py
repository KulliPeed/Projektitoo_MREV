#!/usr/bin/env python3
import argparse
import csv
import hashlib
import json
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
DATASET_NAME = "mta_maksuvolglased_csv"

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

CREATE_SCHEMA_SQL = [
    "CREATE SCHEMA IF NOT EXISTS raw",
    "CREATE SCHEMA IF NOT EXISTS admin",
]

CREATE_AUDIT_TABLE_SQL = [
    """
    CREATE TABLE IF NOT EXISTS admin.raw_import_audit (
        id BIGSERIAL PRIMARY KEY,
        dataset_name TEXT NOT NULL,
        logical_snapshot_date DATE NOT NULL,
        source_file TEXT NOT NULL,
        action TEXT NOT NULL,
        expected_rows BIGINT NOT NULL,
        existing_rows_before BIGINT NOT NULL,
        inserted_rows BIGINT NOT NULL DEFAULT 0,
        raw_rows_after BIGINT,
        content_signature TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'SUCCESS',
        message TEXT,
        started_at TIMESTAMP DEFAULT now(),
        finished_at TIMESTAMP DEFAULT now()
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_raw_import_audit_dataset_snapshot_started
    ON admin.raw_import_audit(dataset_name, logical_snapshot_date, started_at DESC)
    """,
]

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS raw.mta_maksuvolglased_csv (
    id BIGSERIAL PRIMARY KEY,
    snapshot_date DATE NOT NULL,
    data_as_of DATE,
    source_file TEXT NOT NULL,
    file_sha256 TEXT NOT NULL,
    row_no BIGINT NOT NULL,
    loaded_at TIMESTAMP DEFAULT now(),
    row_hash TEXT,
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
    "ALTER TABLE raw.mta_maksuvolglased_csv ADD COLUMN IF NOT EXISTS row_hash TEXT",
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
    """
    CREATE UNIQUE INDEX IF NOT EXISTS ux_mta_maksuvolglased_raw_data_as_of_row_hash
    ON raw.mta_maksuvolglased_csv(data_as_of, row_hash)
    WHERE data_as_of IS NOT NULL AND row_hash IS NOT NULL
    """,
]

INSERT_SQL = """
INSERT INTO raw.mta_maksuvolglased_csv (
    snapshot_date,
    data_as_of,
    source_file,
    file_sha256,
    row_no,
    row_hash,
    andmed_on_seisuga,
    registrikood,
    nimi,
    maksuvolg,
    sh_vaidlustatud,
    sh_tasumisgraafikus,
    tasumisgraafiku_loppkuupaev,
    vanima_tasumata_noude_tasumise_tahtaeg
)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT DO NOTHING
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


def snapshot_signature(row_hashes: list[str]) -> str:
    payload = "\n".join(sorted(row_hashes))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def row_hash_for_mta(data_as_of: date, values: dict[str, str]) -> str:
    payload = {"data_as_of": data_as_of.isoformat(), **values}
    canonical = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


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


def resolve_import_file(csv_file: Path, latest_file: Path) -> Path:
    latest_target = read_latest_target(latest_file)
    if (
        latest_target is not None
        and latest_target.exists()
        and csv_file.name == DEFAULT_CSV_FILE.name
    ):
        return latest_target
    return csv_file


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
    row_hashes = []
    data_as_of_values = set()
    missing_data_as_of_count = 0

    with csv_file.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f, delimiter=";")
        header = normalize_header(reader.fieldnames)
        validate_header(header)

        for row_no, row in enumerate(reader, start=1):
            raw_data_as_of = (row.get("Andmed on seisuga") or "").strip()
            parsed_data_as_of = parse_estonian_date(raw_data_as_of)
            if parsed_data_as_of is None:
                missing_data_as_of_count += 1
            else:
                data_as_of_values.add(parsed_data_as_of)

            values = {
                "andmed_on_seisuga": raw_data_as_of,
                "registrikood": (row.get("Registrikood") or "").strip(),
                "nimi": (row.get("Nimi") or "").strip(),
                "maksuvolg": (row.get("Maksuvõlg") or "").strip(),
                "sh_vaidlustatud": (row.get("sh vaidlustatud") or "").strip(),
                "sh_tasumisgraafikus": (row.get("sh tasumisgraafikus") or "").strip(),
                "tasumisgraafiku_loppkuupaev": (
                    row.get("Tasumisgraafiku lõppkuupäev") or ""
                ).strip(),
                "vanima_tasumata_noude_tasumise_tahtaeg": (
                    row.get("Vanima tasumata nõude tasumise tähtpäev") or ""
                ).strip(),
            }

            if parsed_data_as_of is None:
                row_hash = None
            else:
                row_hash = row_hash_for_mta(parsed_data_as_of, values)
                row_hashes.append(row_hash)

            rows.append(
                (
                    snapshot_date,
                    parsed_data_as_of,
                    source_file,
                    sha256,
                    row_no,
                    row_hash,
                    values["andmed_on_seisuga"],
                    values["registrikood"],
                    values["nimi"],
                    values["maksuvolg"],
                    values["sh_vaidlustatud"],
                    values["sh_tasumisgraafikus"],
                    values["tasumisgraafiku_loppkuupaev"],
                    values["vanima_tasumata_noude_tasumise_tahtaeg"],
                )
            )

    if not rows:
        raise RuntimeError(f"CSV failis ei ole andmeridu: {csv_file}")
    if missing_data_as_of_count:
        raise RuntimeError(
            "MTA CSV sisaldab ridu ilma 'Andmed on seisuga' väärtuseta: "
            f"{missing_data_as_of_count}"
        )
    if len(data_as_of_values) != 1:
        raise RuntimeError(
            "MTA CSV peab sisaldama täpselt ühte logical data_as_of väärtust; "
            f"sain: {sorted(data_as_of_values)}"
        )
    if len(row_hashes) != len(set(row_hashes)):
        raise RuntimeError("MTA CSV sisaldab sama data_as_of sees duplikaatseid row_hash väärtusi.")

    return rows, next(iter(data_as_of_values)), row_hashes


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
    for sql in CREATE_SCHEMA_SQL:
        cur.execute(sql)
    for sql in CREATE_AUDIT_TABLE_SQL:
        cur.execute(sql)
    cur.execute(CREATE_TABLE_SQL)
    for sql in CREATE_INDEX_SQL:
        cur.execute(sql)


def advisory_lock_snapshot(cur, logical_snapshot_date: date) -> None:
    cur.execute(
        "SELECT pg_advisory_xact_lock(hashtext(%s)::bigint)",
        (f"{DATASET_NAME}:{logical_snapshot_date.isoformat()}",),
    )


def snapshot_state(cur, data_as_of: date) -> dict:
    cur.execute(
        """
        SELECT row_hash
        FROM raw.mta_maksuvolglased_csv
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    values = [row[0] for row in cur.fetchall()]
    hashes = [value for value in values if value]
    signature = snapshot_signature(hashes) if len(values) == len(hashes) and hashes else None
    return {"count": len(values), "hash_count": len(hashes), "signature": signature}


def delete_snapshot(cur, data_as_of: date) -> int:
    cur.execute(
        "DELETE FROM raw.mta_maksuvolglased_csv WHERE data_as_of = %s",
        (data_as_of,),
    )
    return cur.rowcount


def import_rows(cur, rows: list[tuple]) -> None:
    for start in range(0, len(rows), BATCH_SIZE):
        cur.executemany(INSERT_SQL, rows[start:start + BATCH_SIZE])


def log_import(
    cur,
    logical_snapshot_date: date,
    source_file: str,
    action: str,
    expected_rows: int,
    existing_rows_before: int,
    inserted_rows: int,
    raw_rows_after: int,
    content_signature: str,
    message: str | None = None,
) -> None:
    cur.execute(
        """
        INSERT INTO admin.raw_import_audit (
            dataset_name,
            logical_snapshot_date,
            source_file,
            action,
            expected_rows,
            existing_rows_before,
            inserted_rows,
            raw_rows_after,
            content_signature,
            status,
            message
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'SUCCESS', %s)
        """,
        (
            DATASET_NAME,
            logical_snapshot_date,
            source_file,
            action,
            expected_rows,
            existing_rows_before,
            inserted_rows,
            raw_rows_after,
            content_signature,
            message,
        ),
    )


def fetch_checks(cur, data_as_of: date) -> dict:
    cur.execute("SELECT count(*) FROM raw.mta_maksuvolglased_csv")
    total_rows = cur.fetchone()[0]

    cur.execute("SELECT count(DISTINCT data_as_of) FROM raw.mta_maksuvolglased_csv")
    distinct_data_as_of = cur.fetchone()[0]

    cur.execute(
        """
        SELECT count(*), min(row_no), max(row_no),
               (count(*) = max(row_no) AND min(row_no) = 1) AS row_no_ok,
               (count(row_hash) = count(*) AND count(DISTINCT row_hash) = count(*)) AS row_hash_ok
        FROM raw.mta_maksuvolglased_csv
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    snapshot_count, min_row_no, max_row_no, row_no_ok, row_hash_ok = cur.fetchone()

    return {
        "total_rows": total_rows,
        "distinct_data_as_of": distinct_data_as_of,
        "snapshot_count": snapshot_count,
        "min_row_no": min_row_no,
        "max_row_no": max_row_no,
        "row_no_ok": row_no_ok,
        "row_hash_ok": row_hash_ok,
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
    latest_file = Path(args.latest_file)
    csv_file = resolve_import_file(Path(args.csv_file), latest_file)

    if not csv_file.exists():
        raise FileNotFoundError(csv_file)

    snapshot_date = (
        date.fromisoformat(args.snapshot_date)
        if args.snapshot_date
        else infer_snapshot_date(csv_file, latest_file)
    )
    source_file = csv_file.name
    sha256 = file_sha256(csv_file)
    rows, data_as_of, row_hashes = read_csv_rows(csv_file, snapshot_date, source_file, sha256)
    expected_rows = len(rows)
    expected_signature = snapshot_signature(row_hashes)

    print(f"CSV fail: {csv_file}")
    print(f"Source file metadata: {source_file}")
    print(f"Snapshot date: {snapshot_date}")
    print(f"Logical data_as_of: {data_as_of}")
    print(f"File SHA256: {sha256}")
    print(f"CSV andmeridu: {expected_rows}")
    print(f"Expected signature: {expected_signature}")

    with connect() as conn:
        with conn.cursor() as cur:
            ensure_table(cur)
            advisory_lock_snapshot(cur, data_as_of)
            before_state = snapshot_state(cur, data_as_of)

            if (
                before_state["count"] == expected_rows
                and before_state["signature"] == expected_signature
            ):
                action = "SKIP_ALREADY_COMPLETE"
                inserted_count = 0
                after_state = before_state
                message = "RAW snapshot on juba sama rea-arvu ja sisu allkirjaga olemas."
            else:
                action = (
                    "INSERT"
                    if before_state["count"] == 0
                    else "REPLACE_PARTIAL_OR_CHANGED"
                )
                deleted_count = delete_snapshot(cur, data_as_of) if before_state["count"] else 0
                import_rows(cur, rows)
                after_state = snapshot_state(cur, data_as_of)
                inserted_count = after_state["count"]
                message = f"Kustutatud ridu enne taaslaadimist: {deleted_count}."

                if (
                    after_state["count"] != expected_rows
                    or after_state["signature"] != expected_signature
                ):
                    raise RuntimeError(
                        "MTA RAW snapshot ei vasta pärast importi oodatud seisule: "
                        f"expected_rows={expected_rows}, actual_rows={after_state['count']}, "
                        f"expected_signature={expected_signature}, "
                        f"actual_signature={after_state['signature']}"
                    )

            checks = fetch_checks(cur, data_as_of)
            log_import(
                cur=cur,
                logical_snapshot_date=data_as_of,
                source_file=source_file,
                action=action,
                expected_rows=expected_rows,
                existing_rows_before=before_state["count"],
                inserted_rows=inserted_count,
                raw_rows_after=after_state["count"],
                content_signature=expected_signature,
                message=message,
            )
        conn.commit()

    print(f"Import action: {action}")
    print(f"RAW snapshot ridu enne importi: {before_state['count']}")
    print(f"RAW snapshot row_hash ridu enne importi: {before_state['hash_count']}")
    print(f"Lisatud/laetud ridu: {inserted_count}")
    print(f"RAW snapshot ridu pärast importi: {after_state['count']}")
    print(f"Tabelis kokku ridu: {checks['total_rows']}")
    print(f"Distinct data_as_of väärtusi: {checks['distinct_data_as_of']}")
    print(
        "Logical snapshot row_no kontroll: "
        f"count={checks['snapshot_count']}, "
        f"min={checks['min_row_no']}, "
        f"max={checks['max_row_no']}, "
        f"ok={checks['row_no_ok']}"
    )
    print(f"Logical snapshot row_hash kontroll ok={checks['row_hash_ok']}")

    if not checks["row_no_ok"]:
        raise RuntimeError("row_no vahemik ei klapi count(*) väärtusega.")
    if not checks["row_hash_ok"]:
        raise RuntimeError("row_hash kontroll ei klapi logical snapshot'i sees.")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f"MTA raw import ebaõnnestus: {exc}", file=sys.stderr)
        raise SystemExit(1)
