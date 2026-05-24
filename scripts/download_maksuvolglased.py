#!/usr/bin/env python3
from __future__ import print_function

import argparse
import shutil
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup


PAGE_URL = "https://www.emta.ee/eraklient/amet-uudised-ja-kontakt/uudised-pressiinfo-statistika/statistika-ja-avaandmed#maksuvolglaste-nimekiri"
DEFAULT_OUTPUT_DIR = "data/raw/maksuvolglased"
MIN_CSV_BYTES = 1000
TIMEOUT_SECONDS = 60

HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; maksuvolglased-downloader/1.0)"
}


def normalize_text(text):
    return " ".join(text.replace("\xa0", " ").lower().split())


def is_preferred_href(href):
    parsed = urlparse(href)
    if not parsed.netloc:
        return True
    return parsed.netloc.lower() == "ncfailid.emta.ee"


def find_csv_url(html, page_url):
    soup = BeautifulSoup(html, "html.parser")
    candidates = []

    for link in soup.find_all("a"):
        href = link.get("href")
        if not href:
            continue

        text = normalize_text(link.get_text(" ", strip=True))
        if "maksuvõlglaste nimekiri" not in text or "csv" not in text:
            continue

        full_url = urljoin(page_url, href)
        candidates.append((is_preferred_href(full_url), full_url))

    if not candidates:
        raise RuntimeError("Ei leidnud MTA lehelt linki 'Maksuvõlglaste nimekiri | csv'.")

    candidates.sort(reverse=True)
    return candidates[0][1]


def fetch_page(session, page_url):
    try:
        response = session.get(page_url, headers=HEADERS, allow_redirects=True, timeout=TIMEOUT_SECONDS)
    except requests.RequestException as exc:
        raise RuntimeError("MTA lehe avamine ebaõnnestus: {0}".format(exc))

    if response.status_code != 200:
        raise RuntimeError("MTA lehe avamine ebaõnnestus: HTTP {0} {1}".format(response.status_code, page_url))

    return response.text


def download_csv(session, csv_url):
    try:
        response = session.get(csv_url, headers=HEADERS, allow_redirects=True, timeout=TIMEOUT_SECONDS)
    except requests.RequestException as exc:
        raise RuntimeError("CSV faili allalaadimine ebaõnnestus URL-ilt {0}: {1}".format(csv_url, exc))

    if response.status_code != 200:
        raise RuntimeError("CSV faili allalaadimine ebaõnnestus: HTTP {0} {1}".format(response.status_code, csv_url))

    content = response.content
    first_line = validate_csv_response(response, content)
    return content, first_line


def validate_csv_response(response, content):
    content_type = response.headers.get("Content-Type", "")
    if "html" in content_type.lower():
        raise RuntimeError("Allalaaditud vastuse Content-Type viitab HTML-ile: {0}".format(content_type))

    if not content:
        raise RuntimeError("Allalaaditud fail on tühi.")

    start = content[:200].lower()
    if b"<html" in start or b"<!doctype html" in start:
        raise RuntimeError("Allalaaditud fail näib olevat HTML, mitte CSV.")

    if len(content) < MIN_CSV_BYTES:
        raise RuntimeError("Allalaaditud fail on kahtlaselt väike: {0} baiti.".format(len(content)))

    first_line = content.splitlines()[0].decode("utf-8-sig", errors="replace")
    if ";" not in first_line and "," not in first_line:
        raise RuntimeError("Allalaaditud faili esimene rida ei näi olevat CSV: {0}".format(first_line))

    return first_line


def save_file(content, output_dir, keep_latest_copy):
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y-%m-%d_%H%M")
    csv_path = output_path / "maksuvolglased_{0}.csv".format(timestamp)
    temp_path = output_path / "{0}.part".format(csv_path.name)

    temp_path.write_bytes(content)
    temp_path.replace(csv_path)

    latest_txt = output_path / "latest.txt"
    latest_txt.write_text(str(csv_path) + "\n", encoding="utf-8")

    latest_copy = None
    if keep_latest_copy:
        latest_copy = output_path / "maksuvolglased_latest.csv"
        shutil.copyfile(str(csv_path), str(latest_copy))

    return csv_path, latest_txt, latest_copy


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Laeb MTA avaandmetest alla maksuvõlglaste CSV faili.")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Kaust, kuhu CSV salvestada.")
    parser.add_argument("--keep-latest-copy", action="store_true", help="Tee lisaks maksuvolglased_latest.csv koopia.")
    parser.add_argument("--page-url", default=PAGE_URL, help="MTA avaandmete lehe URL.")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    session = requests.Session()

    print("Avan MTA avaandmete lehe: {0}".format(args.page_url))
    html = fetch_page(session, args.page_url)

    csv_url = find_csv_url(html, args.page_url)
    print("Leidsin CSV URL-i: {0}".format(csv_url))

    content, first_line = download_csv(session, csv_url)

    csv_path, latest_txt, latest_copy = save_file(content, args.output_dir, args.keep_latest_copy)

    print("Salvestasin faili: {0}".format(csv_path))
    print("Alla laaditud baite: {0}".format(len(content)))
    print("CSV kontroll: fail ei ole tühi ega HTML.")
    print("CSV esimene rida: {0}".format(first_line))
    print("Uuendasin latest.txt: {0}".format(latest_txt))
    if latest_copy is not None:
        print("Uuendasin latest koopiat: {0}".format(latest_copy))

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:
        print("Allalaadimine ebaõnnestus: {0}".format(exc), file=sys.stderr)
        sys.exit(1)
