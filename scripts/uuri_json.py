import argparse
import json
from pathlib import Path
from typing import Any

import ijson


PREVIEW_CHARS = 2000
FULL_LOAD_LIMIT_BYTES = 50 * 1024 * 1024


def format_size(size_bytes: int) -> str:
    units = ("B", "KB", "MB", "GB")
    size = float(size_bytes)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size_bytes} B"


def preview_file(path: Path) -> str:
    with path.open("r", encoding="utf-8", errors="replace") as f:
        return f.read(PREVIEW_CHARS)


def describe_value(value: Any) -> None:
    if isinstance(value, list):
        print("Top-level struktuur: list")
        print(f"Listi kirjete arv: {len(value)}")
        if value:
            print(f"Esimese kirje tüüp: {type(value[0]).__name__}")
            if isinstance(value[0], dict):
                print("Esimese kirje võtmed:")
                for key in value[0].keys():
                    print(f"  - {key}")
    elif isinstance(value, dict):
        print("Top-level struktuur: object")
        print("Top-level võtmed:")
        for key, item in value.items():
            suffix = f" ({type(item).__name__})"
            if isinstance(item, list):
                suffix += f", kirjeid: {len(item)}"
            print(f"  - {key}{suffix}")
    else:
        print(f"Top-level struktuur: muu ({type(value).__name__})")


def describe_streaming(path: Path) -> None:
    with path.open("rb") as f:
        parser = ijson.parse(f)
        try:
            prefix, event, value = next(parser)
        except StopIteration:
            print("Fail on tühi.")
            return

        if (prefix, event) == ("", "start_array"):
            print("Top-level struktuur: list")
            with path.open("rb") as items_file:
                try:
                    first_item = next(ijson.items(items_file, "item"))
                except StopIteration:
                    print("List on tühi.")
                    return
            print(f"Esimese kirje tüüp: {type(first_item).__name__}")
            if isinstance(first_item, dict):
                print("Esimese kirje võtmed:")
                for key in first_item.keys():
                    print(f"  - {key}")
            return

        if (prefix, event) == ("", "start_map"):
            print("Top-level struktuur: object")
            keys = []
            for prefix, event, value in parser:
                if prefix == "" and event == "map_key":
                    keys.append(value)
                    if len(keys) >= 50:
                        break
            print("Top-level võtmed:")
            for key in keys:
                print(f"  - {key}")
            if len(keys) >= 50:
                print("  ...")
            return

        print(f"Top-level struktuur: muu (ijson event: {event}, value: {value!r})")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Uuri RIK JSON faili suurust ja top-level struktuuri."
    )
    parser.add_argument("json_file", help="JSON faili tee")
    args = parser.parse_args()

    json_file = Path(args.json_file)
    if not json_file.exists():
        raise FileNotFoundError(json_file)

    size = json_file.stat().st_size
    print(f"Fail: {json_file}")
    print(f"Suurus: {format_size(size)} ({size} bytes)")
    print()
    print(f"Faili alguse esimesed {PREVIEW_CHARS} märki:")
    print(preview_file(json_file))
    print()

    if size <= FULL_LOAD_LIMIT_BYTES:
        with json_file.open("r", encoding="utf-8") as f:
            describe_value(json.load(f))
    else:
        describe_streaming(json_file)


if __name__ == "__main__":
    main()
