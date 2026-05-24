#!/usr/bin/env python3
import argparse
import sys
from datetime import date
from pathlib import Path

import requests


URL = "https://avaandmed.ariregister.rik.ee/sites/default/files/avaandmed/ettevotja_rekvisiidid__kaardile_kantud_isikud.json.zip"
DEFAULT_OUTPUT_ROOT = Path("data/raw/rik")
DEFAULT_FILE_NAME = "kaardile_kantud_isikud.json.zip"
CHUNK_SIZE = 1024 * 1024


def download_snapshot(snapshot_date: str, output_root: Path, overwrite: bool = False) -> Path:
    output_dir = output_root / snapshot_date
    output_dir.mkdir(parents=True, exist_ok=True)

    output_file = output_dir / DEFAULT_FILE_NAME
    tmp_file = output_file.with_suffix(output_file.suffix + ".part")

    if output_file.exists() and output_file.stat().st_size > 0 and not overwrite:
        print(f"Fail on juba olemas, allalaadimist ei korrata: {output_file}")
        return output_file

    print(f"Laen alla RIK snapshoti kuupaevale {snapshot_date}: {URL}")
    response = requests.get(URL, stream=True, timeout=(10, 300))
    response.raise_for_status()
    expected_size = response.headers.get("content-length")
    expected_bytes = int(expected_size) if expected_size is not None else None

    bytes_written = 0
    with tmp_file.open("wb") as f:
        for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
            if chunk:
                f.write(chunk)
                bytes_written += len(chunk)

    if bytes_written == 0:
        tmp_file.unlink(missing_ok=True)
        raise RuntimeError("Allalaaditud fail oli tyhi.")
    if expected_bytes is not None and bytes_written != expected_bytes:
        tmp_file.unlink(missing_ok=True)
        raise RuntimeError(
            "Allalaaditud faili suurus ei klapi serveri Content-Length vaartusega: "
            f"ootasin {expected_bytes} baiti, sain {bytes_written} baiti."
        )

    tmp_file.replace(output_file)
    print(f"Fail salvestatud: {output_file} ({bytes_written} baiti)")
    return output_file


def main() -> int:
    parser = argparse.ArgumentParser(description="Laadi RIK kaardile kantud isikute ZIP snapshot alla.")
    parser.add_argument("--date", default=date.today().isoformat(), help="Snapshot kuupaev kujul YYYY-MM-DD. Vaikimisi tana.")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Juurkataloog, kuhu snapshot salvestada.")
    parser.add_argument("--overwrite", action="store_true", help="Laadi fail uuesti alla ka siis, kui sama paeva fail on olemas.")
    args = parser.parse_args()

    try:
        download_snapshot(args.date, Path(args.output_root), args.overwrite)
    except Exception as exc:
        print(f"Allalaadimine ebaonnestus: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
