# Architecture and data handling

## Offline-first boundary

The mobile SOS form validates and saves directly through `EmergencyRepository` to the app's SQLite file. It never calls FastAPI. An unavailable server therefore cannot prevent creation or retrieval of records. `sync_status` starts as `pending`; the schema supports later server ID assignment. A sync worker/client is not implemented yet.

The server has its own database and persistence repository. `client_id` is a stable local idempotency key with a uniqueness constraint. A repeated POST returns the already persisted row rather than adding another. Deployments needing stronger conflict behavior should reject a reused key whose payload differs.

## Mobile schema and migrations

Schema version 1 contains `emergency_cases` and `message_queue`. Database creation is centralized in `AppDatabase`, with an upgrade callback reserved for additive migrations. A future schema change must increment `schemaVersion` and add a forward migration; avoid destructive table replacement so pending records survive upgrades.

`message_id` is the queue primary key. A future BLE receive path should insert inside a transaction using a uniqueness-conflict result to discard repeats before forwarding. Message payloads should use a compact versioned envelope such as `emergency.v1`; apply a documented maximum hop count and expiry check before relay, and prune expired records in a bounded maintenance task. These policies are not yet enforced by an actual BLE transport.

## Privacy and triage

Only injury/bleeding/consciousness/trapped indicators, a free-text emergency description, optional coordinates, timestamps, status, and sync/message metadata are modeled. Do not add names, phone numbers, or precise location unless a clear operational need and user-facing explanation exist. Local database encryption and retention controls are future hardening work.

The mobile baseline flags reported unconsciousness, severe bleeding, or trapped status for urgent human review. Unknown values do not trigger a negative inference. This is a transparent assistance suggestion, not a diagnosis and not a trained model. No ML training or medical performance claims are part of this milestone.

## BLE and platform limits

Interfaces and persistent message IDs prepare for a later BLE module; no radio scanning, connection, exchange, or store-and-forward is implemented. Android and iOS impose background execution, permissions, radio, and vendor-specific constraints. Background mesh reliability must be researched and validated on real devices before it is promised.

## Synchronization lifecycle (planned)

1. Save locally and retain `pending` state.
2. A future sync worker selects pending records and POSTs `client_id = local_id`.
3. On success, save the server ID and mark synced in a local transaction.
4. On failure, preserve the local record and pending state, apply bounded backoff, and retry.
5. Never delete a local emergency merely because a request failed.
