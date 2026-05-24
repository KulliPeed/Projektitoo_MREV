import argparse
import json
import os
import sys
from datetime import date
from pathlib import Path
from decimal import Decimal

import ijson
import psycopg
from psycopg.types.json import Jsonb


DB_HOST = "localhost"
DB_PORT = 5432
DB_NAME = "andmeprojekt"
DB_USER = "andrus"
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD") or os.environ.get("DB_PASSWORD")

BATCH_SIZE = 1000
VALIDATION_PROGRESS_EVERY = 50_000

def json_default(value):
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")
def json_dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, default=json_default)


def validate_file(json_file: Path, items_path: str) -> int:
    total = 0

    print("Valideerin JSON faili enne andmebaasi laadimist...", flush=True)
    with json_file.open("rb") as f:
        for total, _record in enumerate(ijson.items(f, items_path), start=1):
            if total % VALIDATION_PROGRESS_EVERY == 0:
                print(f"Valideeritud JSON kirjeid: {total}", flush=True)

    if total == 0:
        raise RuntimeError(f"JSON failis ei leitud kirjeid items_path='{items_path}'.")

    print(f"JSON terviklik. Kirjeid kokku: {total}", flush=True)
    return total


def flush_batch(cur: psycopg.Cursor, rows: list[tuple[date, str, int, Jsonb]]) -> None:
    if not rows:
        return

    cur.executemany(
        """
        INSERT INTO raw.rik_kaardile_kantud_isikud_json
            (snapshot_date, source_file, row_no, record)
        VALUES
            (%s, %s, %s, %s)
        ON CONFLICT (snapshot_date, source_file, row_no)
        DO NOTHING
        """,
        rows,
    )


def load_file(json_file: Path, snapshot_date: date, items_path: str) -> int:
    if not DB_PASSWORD:
        raise RuntimeError("Määra POSTGRES_PASSWORD või DB_PASSWORD keskkonnamuutuja.")

    total = 0
    batch = []

    with psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
    ) as conn:
        with conn.cursor() as cur:
            with json_file.open("rb") as f:
                for row_no, record in enumerate(ijson.items(f, items_path), start=1):
                    batch.append(
                        (
                            snapshot_date,
                            str(json_file),
                            row_no,
                            Jsonb(record, dumps=json_dumps),
                        )
                    )

                    if len(batch) >= BATCH_SIZE:
                        flush_batch(cur, batch)
                        conn.commit()
                        total += len(batch)
                        print(f"Laetud/proovitud kirjeid: {total}", flush=True)
                        batch.clear()

                if batch:
                    flush_batch(cur, batch)
                    conn.commit()
                    total += len(batch)
                    print(f"Laetud/proovitud kirjeid: {total}", flush=True)
                    batch.clear()

    print(f"Valmis. Kokku laetud/proovitud kirjeid: {total}", flush=True)
    return total


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

    try:
        validate_file(json_file, args.items_path)
        load_file(json_file, date.fromisoformat(args.snapshot_date), args.items_path)
    except Exception as exc:
        print(f"Laadimine ebaonnestus: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
