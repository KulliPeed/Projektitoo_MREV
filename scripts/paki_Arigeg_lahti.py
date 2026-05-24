#!/usr/bin/env python3
import argparse
import sys
import zipfile
from datetime import date
from pathlib import Path


DEFAULT_OUTPUT_ROOT = Path("data/raw/rik")
DEFAULT_FILE_NAME = "kaardile_kantud_isikud.json.zip"


def default_zip_file(snapshot_date: str, output_root: Path) -> Path:
    return output_root / snapshot_date / DEFAULT_FILE_NAME


def extract_zip(zip_file: Path, overwrite: bool = True) -> Path:
    if not zip_file.exists():
        raise FileNotFoundError(zip_file)

    extract_dir = zip_file.parent / "extracted"
    extract_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_file, "r") as z:
        bad_file = z.testzip()
        if bad_file is not None:
            raise RuntimeError(f"ZIP fail on vigane, esimene vigane fail: {bad_file}")

        for member in z.infolist():
            target = extract_dir / member.filename
            if target.exists() and not overwrite:
                print(f"Fail on juba lahti pakitud, jaan vahele: {target}")
                continue
            z.extract(member, extract_dir)

    print(f"Lahti pakitud: {extract_dir}")
    return extract_dir


def main() -> int:
    parser = argparse.ArgumentParser(description="Paki RIK kaardile kantud isikute ZIP snapshot lahti.")
    parser.add_argument("zip_file", nargs="?", help="ZIP faili tee. Kui puudub, kasutatakse tana kuupaeva vaiketeed.")
    parser.add_argument("--date", default=date.today().isoformat(), help="Snapshot kuupaev kujul YYYY-MM-DD. Kasutusel, kui zip_file puudub.")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Juurkataloog, kust vaikimisi ZIP faili otsida.")
    parser.add_argument("--no-overwrite", action="store_true", help="Ara kirjuta olemasolevaid lahtipakitud faile yle.")
    args = parser.parse_args()

    zip_file = Path(args.zip_file) if args.zip_file else default_zip_file(args.date, Path(args.output_root))

    try:
        extract_zip(zip_file, overwrite=not args.no_overwrite)
    except Exception as exc:
        print(f"Lahtipakkimine ebaonnestus: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
