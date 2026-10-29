import pandas as pd
import pytest
from scripts.preprocess_data import preprocess


def test_preprocess_keeps_unknown_location_blank_and_deduplicates(tmp_path):
    source = tmp_path / "input.csv"
    output = tmp_path / "out.csv"
    row = ["SYN-x", " MAJOR ", "unknown", "unknown", "false", "Help", "", "", "2026-01-01T00:00:00Z", "SYNTHETIC"]
    pd.DataFrame([row, row], columns=["sample_case_id", "injury_type", "bleeding_status", "consciousness_status", "trapped", "emergency_description", "latitude", "longitude", "timestamp", "record_type"]).to_csv(source, index=False)
    frame, issues = preprocess(source, output)
    assert len(frame) == 1
    assert pd.isna(frame.loc[0, "latitude"])
    assert frame.loc[0, "injury_type"] == "major"
    assert any("exact duplicate" in issue for issue in issues)


def test_missing_column_is_fatal(tmp_path):
    source = tmp_path / "bad.csv"
    source.write_text("sample_case_id\nSYN-x\n", encoding="utf-8")
    with pytest.raises(ValueError, match="Missing required columns"):
        preprocess(source, tmp_path / "out.csv")
