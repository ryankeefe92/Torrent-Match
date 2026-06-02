#!/usr/bin/env python3

import csv
import gzip
import sqlite3
import sys
import urllib.request
from pathlib import Path
from typing import Dict, Optional


DATASET_URLS = {
    "basics": "https://datasets.imdbws.com/title.basics.tsv.gz",
    "ratings": "https://datasets.imdbws.com/title.ratings.tsv.gz",
}
MOVIE_TYPES = {"movie"}
MIN_RUNTIME_MINUTES = 45


def normalize(text: str) -> str:
    import re
    import unicodedata

    folded = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    folded = folded.lower().replace("&", " and ")
    return " ".join(re.sub(r"[^a-z0-9]+", " ", folded).split())


def load_ratings(dataset_path: Path) -> Dict[str, int]:
    ratings = {}
    with gzip.open(dataset_path, "rt", encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source, delimiter="\t")
        for row in reader:
            try:
                ratings[row["tconst"]] = int(row["numVotes"])
            except ValueError:
                continue
    return ratings


def should_keep(runtime_minutes: Optional[int], votes: int) -> bool:
    if runtime_minutes is None:
        return votes >= 25
    if runtime_minutes >= MIN_RUNTIME_MINUTES:
        return True
    return votes >= 5000


def english_bias_score(title: str) -> int:
    return sum(1 for character in title if "a" <= character.lower() <= "z")


def build_catalog(basics_path: Path, ratings_path: Path, output_path: Path) -> int:
    ratings = load_ratings(ratings_path)
    connection = sqlite3.connect(output_path)

    try:
        cursor = connection.cursor()
        cursor.execute("DROP TABLE IF EXISTS movies")
        cursor.execute(
            """
            CREATE TABLE movies (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                year INTEGER NOT NULL,
                normalized_title TEXT NOT NULL,
                canonical_title TEXT NOT NULL,
                provider_query TEXT NOT NULL,
                num_votes INTEGER NOT NULL,
                runtime_minutes INTEGER,
                english_bias INTEGER NOT NULL
            )
            """
        )

        best_by_key = {}

        with gzip.open(basics_path, "rt", encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source, delimiter="\t")

            for row in reader:
                if row["titleType"] not in MOVIE_TYPES:
                    continue
                if row["isAdult"] != "0":
                    continue

                title = row["primaryTitle"].strip()
                year_text = row["startYear"].strip()
                if not title or year_text == r"\N":
                    continue

                normalized_title = normalize(title)
                if not normalized_title:
                    continue

                original_title = row["originalTitle"].strip()
                canonical_title = normalize(original_title) if original_title else normalized_title

                try:
                    year = int(year_text)
                except ValueError:
                    continue

                runtime_text = row["runtimeMinutes"].strip()
                runtime_minutes = None if runtime_text == r"\N" else int(runtime_text)
                votes = ratings.get(row["tconst"], 0)

                if not should_keep(runtime_minutes, votes):
                    continue

                provider_query = "{} {}".format(title.replace("\t", " ").replace("\n", " "), year)
                dedupe_key = (normalized_title, year)
                candidate = (
                    row["tconst"],
                    title.replace("\t", " ").replace("\n", " "),
                    year,
                    normalized_title,
                    canonical_title,
                    provider_query,
                    votes,
                    runtime_minutes,
                    english_bias_score(title),
                )

                existing = best_by_key.get(dedupe_key)
                if existing is None:
                    best_by_key[dedupe_key] = candidate
                    continue

                if candidate[6] > existing[6]:
                    best_by_key[dedupe_key] = candidate
                    continue

                if candidate[6] == existing[6] and candidate[8] > existing[8]:
                    best_by_key[dedupe_key] = candidate

        cursor.executemany(
            """
            INSERT INTO movies (
                id, title, year, normalized_title, canonical_title,
                provider_query, num_votes, runtime_minutes, english_bias
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            best_by_key.values(),
        )

        cursor.execute("CREATE INDEX idx_movies_normalized_title ON movies(normalized_title)")
        cursor.execute("CREATE INDEX idx_movies_canonical_title ON movies(canonical_title)")
        cursor.execute("CREATE INDEX idx_movies_votes ON movies(num_votes DESC)")
        connection.commit()
        return len(best_by_key)
    finally:
        connection.close()


def download(url: str, destination: Path) -> None:
    print("Downloading {}".format(url))
    urllib.request.urlretrieve(url, destination)


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    output_path = repo_root / "TorrentMatcherCore" / "Sources" / "TorrentMatcherCore" / "Resources" / "MovieCatalog.sqlite"
    basics_path = output_path.with_name("title.basics.tsv.gz")
    ratings_path = output_path.with_name("title.ratings.tsv.gz")

    output_path.parent.mkdir(parents=True, exist_ok=True)

    download(DATASET_URLS["basics"], basics_path)
    download(DATASET_URLS["ratings"], ratings_path)

    try:
        count = build_catalog(basics_path, ratings_path, output_path)
    finally:
        if basics_path.exists():
            basics_path.unlink()
        if ratings_path.exists():
            ratings_path.unlink()

    print("Wrote {} entries to {}".format(count, output_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
