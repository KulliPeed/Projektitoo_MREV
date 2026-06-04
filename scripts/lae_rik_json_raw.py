#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
from datetime import date
from decimal import Decimal
from pathlib import Path

import ijson
import psycopg
from psycopg.types.json import Jsonb


DB_HOST = "localhost"
DB_PORT = 5432
DB_NAME = "andmeprojekt"
DB_USER = "andrus"
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD") or os.environ.get("DB_PASSWORD")

BATCH_SIZE = 1000
PROGRESS_EVERY = 50_000
DATASET_NAME = "rik_kaardile_kantud_isikud_json"

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
CREATE TABLE IF NOT EXISTS raw.rik_kaardile_kantud_isikud_json (
    id BIGSERIAL PRIMARY KEY,
    snapshot_date DATE NOT NULL,
    source_file TEXT NOT NULL,
    row_no BIGINT NOT NULL,
    record JSONB NOT NULL,
    loaded_at TIMESTAMP DEFAULT now(),
    row_hash TEXT,
    CONSTRAINT uq_rik_raw_snapshot_file_row UNIQUE (snapshot_date, source_file, row_no)
)
"""

CREATE_INDEX_SQL = [
    "ALTER TABLE raw.rik_kaardile_kantud_isikud_json ADD COLUMN IF NOT EXISTS row_hash TEXT",
    """
    CREATE INDEX IF NOT EXISTS idx_rik_raw_snapshot_date
    ON raw.rik_kaardile_kantud_isikud_json(snapshot_date)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_rik_raw_record_gin
    ON raw.rik_kaardile_kantud_isikud_json
    USING GIN(record)
    """,
    """
    CREATE UNIQUE INDEX IF NOT EXISTS ux_rik_raw_snapshot_date_row_hash
    ON raw.rik_kaardile_kantud_isikud_json(snapshot_date, row_hash)
    WHERE row_hash IS NOT NULL
    """,
]


def json_default(value):
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def json_dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, default=json_default)


def canonical_json(value) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=json_default,
    )


def row_hash_for_rik(snapshot_date: date, record) -> str:
    payload = snapshot_date.isoformat() + "\n" + canonical_json(record)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def snapshot_signature(row_hashes: list[str]) -> str:
    payload = "\n".join(sorted(row_hashes))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def read_expected_snapshot(json_file: Path, snapshot_date: date, items_path: str) -> tuple[int, str]:
    row_hashes = []
    seen_hashes = set()
    total = 0

    print("Valideerin JSON faili ja arvutan snapshot'i allkirja...", flush=True)
    with json_file.open("rb") as f:
        for total, record in enumerate(ijson.items(f, items_path), start=1):
            row_hash = row_hash_for_rik(snapshot_date, record)
            if row_hash in seen_hashes:
                raise RuntimeError(
                    "RIK JSON sisaldab sama snapshot_date sees duplikaatset row_hash väärtust "
                    f"real {total}."
                )
            seen_hashes.add(row_hash)
            row_hashes.append(row_hash)

            if total % PROGRESS_EVERY == 0:
                print(f"Valideeritud JSON kirjeid: {total}", flush=True)

    if total == 0:
        raise RuntimeError(f"JSON failis ei leitud kirjeid items_path='{items_path}'.")

    signature = snapshot_signature(row_hashes)
    print(f"JSON terviklik. Kirjeid kokku: {total}", flush=True)
    print(f"Expected signature: {signature}", flush=True)
    return total, signature


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


def advisory_lock_snapshot(cur, snapshot_date: date) -> None:
    cur.execute(
        "SELECT pg_advisory_xact_lock(hashtext(%s)::bigint)",
        (f"{DATASET_NAME}:{snapshot_date.isoformat()}",),
    )


def snapshot_state(cur, snapshot_date: date) -> dict:
    cur.execute(
        """
        SELECT row_hash
        FROM raw.rik_kaardile_kantud_isikud_json
        WHERE snapshot_date = %s
        """,
        (snapshot_date,),
    )
    values = [row[0] for row in cur.fetchall()]
    hashes = [value for value in values if value]
    signature = snapshot_signature(hashes) if len(values) == len(hashes) and hashes else None
    return {"count": len(values), "hash_count": len(hashes), "signature": signature}


def delete_snapshot(cur, snapshot_date: date) -> int:
    cur.execute(
        "DELETE FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = %s",
        (snapshot_date,),
    )
    return cur.rowcount


def flush_batch(cur: psycopg.Cursor, rows: list[tuple[date, str, int, Jsonb, str]]) -> None:
    if not rows:
        return

    cur.executemany(
        """
        INSERT INTO raw.rik_kaardile_kantud_isikud_json
            (snapshot_date, source_file, row_no, record, row_hash)
        VALUES
            (%s, %s, %s, %s, %s)
        ON CONFLICT DO NOTHING
        """,
        rows,
    )


def load_file(cur, json_file: Path, snapshot_date: date, items_path: str, source_file: str) -> int:
    total = 0
    batch = []

    with json_file.open("rb") as f:
        for row_no, record in enumerate(ijson.items(f, items_path), start=1):
            batch.append(
                (
                    snapshot_date,
                    source_file,
                    row_no,
                    Jsonb(record, dumps=json_dumps),
                    row_hash_for_rik(snapshot_date, record),
                )
            )

            if len(batch) >= BATCH_SIZE:
                flush_batch(cur, batch)
                total += len(batch)
                if total % PROGRESS_EVERY == 0:
                    print(f"Laetud/proovitud kirjeid: {total}", flush=True)
                batch.clear()

        if batch:
            flush_batch(cur, batch)
            total += len(batch)
            print(f"Laetud/proovitud kirjeid: {total}", flush=True)
            batch.clear()

    print(f"Valmis. Kokku laetud/proovitud kirjeid: {total}", flush=True)
    return total


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


def fetch_checks(cur, snapshot_date: date) -> dict:
    cur.execute("SELECT count(*) FROM raw.rik_kaardile_kantud_isikud_json")
    total_rows = cur.fetchone()[0]

    cur.execute("SELECT count(DISTINCT snapshot_date) FROM raw.rik_kaardile_kantud_isikud_json")
    distinct_snapshot_dates = cur.fetchone()[0]

    cur.execute(
        """
        SELECT count(*), min(row_no), max(row_no),
               (count(*) = max(row_no) AND min(row_no) = 1) AS row_no_ok,
               (count(row_hash) = count(*) AND count(DISTINCT row_hash) = count(*)) AS row_hash_ok
        FROM raw.rik_kaardile_kantud_isikud_json
        WHERE snapshot_date = %s
        """,
        (snapshot_date,),
    )
    snapshot_count, min_row_no, max_row_no, row_no_ok, row_hash_ok = cur.fetchone()

    return {
        "total_rows": total_rows,
        "distinct_snapshot_dates": distinct_snapshot_dates,
        "snapshot_count": snapshot_count,
        "min_row_no": min_row_no,
        "max_row_no": max_row_no,
        "row_no_ok": row_no_ok,
        "row_hash_ok": row_hash_ok,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Laadi RIK kaardile kantud isikute JSON PostgreSQL raw tabelisse."
    )
    parser.add_argument("json_file", help="JSON faili tee")
    parser.add_argument("snapshot_date", help="Snapshot kuupäev kujul YYYY-MM-DD")
    parser.add_argument(
        "--items-path",
        default="item",
        help="ijson items path. Top-level listi korral kasuta vaikeväärtust 'item'.",
    )
    args = parser.parse_args()

    json_file = Path(args.json_file)
    if not json_file.exists():
        raise FileNotFoundError(json_file)

    snapshot_date = date.fromisoformat(args.snapshot_date)
    source_file = json_file.name

    try:
        expected_rows, expected_signature = read_expected_snapshot(
            json_file,
            snapshot_date,
            args.items_path,
        )

        print(f"JSON fail: {json_file}", flush=True)
        print(f"Source file metadata: {source_file}", flush=True)
        print(f"Snapshot date: {snapshot_date}", flush=True)
        print(f"JSON kirjeid: {expected_rows}", flush=True)

        with connect() as conn:
            with conn.cursor() as cur:
                ensure_table(cur)
                advisory_lock_snapshot(cur, snapshot_date)
                before_state = snapshot_state(cur, snapshot_date)

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
                    deleted_count = delete_snapshot(cur, snapshot_date) if before_state["count"] else 0
                    attempted_count = load_file(
                        cur,
                        json_file,
                        snapshot_date,
                        args.items_path,
                        source_file,
                    )
                    after_state = snapshot_state(cur, snapshot_date)
                    inserted_count = after_state["count"]
                    message = (
                        f"Kustutatud ridu enne taaslaadimist: {deleted_count}; "
                        f"laadimiseks proovitud ridu: {attempted_count}."
                    )

                    if (
                        after_state["count"] != expected_rows
                        or after_state["signature"] != expected_signature
                    ):
                        raise RuntimeError(
                            "RIK RAW snapshot ei vasta pärast importi oodatud seisule: "
                            f"expected_rows={expected_rows}, actual_rows={after_state['count']}, "
                            f"expected_signature={expected_signature}, "
                            f"actual_signature={after_state['signature']}"
                        )

                checks = fetch_checks(cur, snapshot_date)
                log_import(
                    cur=cur,
                    logical_snapshot_date=snapshot_date,
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

    except Exception as exc:
        print(f"Laadimine ebaonnestus: {exc}", file=sys.stderr)
        return 1

    print(f"Import action: {action}", flush=True)
    print(f"RAW snapshot ridu enne importi: {before_state['count']}", flush=True)
    print(f"RAW snapshot row_hash ridu enne importi: {before_state['hash_count']}", flush=True)
    print(f"Lisatud/laetud ridu: {inserted_count}", flush=True)
    print(f"RAW snapshot ridu pärast importi: {after_state['count']}", flush=True)
    print(f"Tabelis kokku ridu: {checks['total_rows']}", flush=True)
    print(f"Distinct snapshot_date väärtusi: {checks['distinct_snapshot_dates']}", flush=True)
    print(
        "Logical snapshot row_no kontroll: "
        f"count={checks['snapshot_count']}, "
        f"min={checks['min_row_no']}, "
        f"max={checks['max_row_no']}, "
        f"ok={checks['row_no_ok']}",
        flush=True,
    )
    print(f"Logical snapshot row_hash kontroll ok={checks['row_hash_ok']}", flush=True)

    if not checks["row_no_ok"]:
        print("row_no vahemik ei klapi count(*) väärtusega.", file=sys.stderr)
        return 1
    if not checks["row_hash_ok"]:
        print("row_hash kontroll ei klapi logical snapshot'i sees.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
