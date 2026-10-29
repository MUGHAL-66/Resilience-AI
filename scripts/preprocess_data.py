"""Validate and normalize the explicitly synthetic emergency CSV."""
from __future__ import annotations
import argparse
import sys
from pathlib import Path
import pandas as pd

REQUIRED = {"sample_case_id", "injury_type", "bleeding_status", "consciousness_status", "trapped", "emergency_description", "latitude", "longitude", "timestamp", "record_type"}
CATEGORIES = {
    "injury_type": {"none", "minor", "major", "unknown"},
    "bleeding_status": {"none", "minor", "severe", "unknown"},
    "consciousness_status": {"conscious", "unconscious", "unknown"},
    "trapped": {"true", "false"},
}


def preprocess(source: Path, destination: Path) -> tuple[pd.DataFrame, list[str]]:
    frame = pd.read_csv(source, dtype=str, keep_default_na=False)
    missing = REQUIRED - set(frame.columns)
    if missing:
        raise ValueError(f"Missing required columns: {', '.join(sorted(missing))}")
    frame = frame[list(sorted(REQUIRED))].copy()
    issues: list[str] = []
    for col, allowed in CATEGORIES.items():
        frame[col] = frame[col].str.strip().str.lower()
        bad = ~frame[col].isin(allowed)
        for row in frame.index[bad]:
            issues.append(f"row {row + 2}: invalid {col}={frame.at[row, col]!r}")
    for col, low, high in (("latitude", -90, 90), ("longitude", -180, 180)):
        parsed = pd.to_numeric(frame[col].replace("", pd.NA), errors="coerce")
        bad = frame[col].ne("") & (parsed.isna() | ~parsed.between(low, high))
        for row in frame.index[bad]:
            issues.append(f"row {row + 2}: invalid {col}={frame.at[row, col]!r}")
        frame[col] = parsed
    half_location = frame["latitude"].isna() ^ frame["longitude"].isna()
    for row in frame.index[half_location]:
        issues.append(f"row {row + 2}: latitude and longitude must both be present or absent")
    bad_timestamp = pd.to_datetime(frame["timestamp"], errors="coerce", utc=True).isna()
    for row in frame.index[bad_timestamp]:
        issues.append(f"row {row + 2}: invalid timestamp={frame.at[row, 'timestamp']!r}")
    if not frame["record_type"].str.strip().str.lower().eq("synthetic").all():
        issues.append("record_type must be synthetic for every row")
    frame["record_type"] = frame["record_type"].str.strip().str.lower()
    duplicates = frame.duplicated(keep="first")
    duplicate_count = int(duplicates.sum())
    frame = frame.loc[~duplicates].copy()
    destination.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(destination, index=False)
    if duplicate_count:
        issues.append(f"removed {duplicate_count} exact duplicate row(s)")
    return frame, issues


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("data/raw/synthetic_flash_flood_emergencies.csv"))
    parser.add_argument("--output", type=Path, default=Path("data/processed/synthetic_flash_flood_emergencies.csv"))
    args = parser.parse_args(argv)
    try:
        frame, issues = preprocess(args.input, args.output)
    except (OSError, pd.errors.ParserError, ValueError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    for issue in issues:
        print(f"VALIDATION: {issue}")
    print(f"Processed {len(frame)} synthetic records to {args.output}")
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
