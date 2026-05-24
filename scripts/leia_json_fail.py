from pathlib import Path


def main() -> None:
    root = Path("data")
    files = sorted(root.rglob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)

    if not files:
        print("JSON faile ei leitud data kataloogist.")
        raise SystemExit(1)

    print(files[0])


if __name__ == "__main__":
    main()
