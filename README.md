# Resilience AI

Offline-first emergency communication foundation for flash floods and other disasters. Local SOS creation and storage are independent of network access and the FastAPI service.

## Architecture

- `mobile/`: Flutter Android-first app, SQLite database and repository, SOS/history/detail views, transparent rules-based triage suggestion.
- `backend/`: optional FastAPI synchronization service backed by SQLAlchemy and SQLite.
- `data/raw/` and `scripts/`: explicitly synthetic example records and Pandas validation/normalization.
- `docs/architecture.md`: data boundaries, message handling, privacy and planned work.

No GPS permission is requested; coordinates are nullable. The app stores only emergency fields and local synchronization/message metadata. The sample data is synthetic and is not medical evidence.

## Requirements

Flutter stable with Dart 3.3+, Android SDK for device builds, and Python 3.10+ for the backend. Install Python packages in an isolated virtual environment:

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Start backend

From the repository root after installation:

```powershell
python -m uvicorn backend.app.main:app --reload
```

The service is at `http://127.0.0.1:8000`; interactive API docs are at `/docs`. Set `RESILIENCE_DATABASE_URL` to override the default server database path. POST requests require a stable client-generated `client_id`; repeated IDs return the existing row, allowing safe create retries.

## Mobile setup and run

```powershell
cd mobile
flutter create --platforms=android .
flutter pub get
flutter test
flutter run
```

SOS records are written directly to SQLite before leaving the form. No server call or internet check participates in local capture. On a real Android device, create an SOS, force-stop and reopen the app to confirm it appears in history. Then enable airplane mode (and ensure Wi-Fi/Bluetooth are disabled by the device), create another SOS, force-stop/reopen, and verify both remain. This validates local persistence only; it does not test synchronization or Bluetooth relay.

## Dataset preprocessing

From the repository root:

```powershell
python scripts/preprocess_data.py
```

Exit status 0 means no validation issues; status 1 means the processed output was written but row-level validation issues were reported; status 2 means a fatal input/schema/read error. Coordinates remain blank when unavailable and invalid records are reported, never converted into guessed values.

## Tests

```powershell
python -m pytest backend/tests scripts/test_preprocess_data.py
cd mobile
flutter test
```

Backend tests use an isolated in-memory SQLite database. Mobile tests use an in-memory SQLite implementation and do not call the API.

## Milestone checklist

### Implemented and tested

- [x] Backend CRUD API, validation, idempotent create key, and isolated SQLite tests.
- [x] Synthetic CSV and Pandas preprocessing pipeline with tests.

### Implemented but not fully tested

- [x] Flutter local SQLite schema, CRUD/message deduplication foundations, SOS/history/detail UI, and mobile tests authored. Flutter test/build/device runs were unavailable here.
- [x] Documented transparent triage rules, privacy boundaries, and BLE/AI limits.

### Planned / not implemented

- [ ] Actual sync client/retry workflow and end-to-end server sync.
- [ ] BLE discovery, transfer, relay, expiry enforcement, and real-device tests.
- [ ] On-device ML model and validation.

See [docs/milestone-4.md](docs/milestone-4.md) for verified environment status and limitations.
