# Android BLE SOS device test

## Current validation boundary

Automated tests use a local SQLite database and protocol unit tests; they do not exercise Android radios. The current transport elects one central from a short device identity in manufacturer data. That central sends queued messages with RX writes, while its peer sends its queue with TX notifications. Both directions require the same protocol build on both phones. The current source has not been verified with a post-change physical SOS transfer.

## Two-phone test

1. Build the debug app and update both phones in place using the commands below. Do not uninstall or clear app data. If `adb install -r` reports a signature mismatch, stop and use the matching signing key; do not uninstall the existing app.
2. Launch on both phones. Grant the Android **Nearby devices** permissions requested by the app. Keep Bluetooth enabled.
3. Turn Wi-Fi and mobile data off on both phones.
4. On Phone B tap **Find nearby SOS devices** and leave the screen open. Repeat on Phone A.
5. On Phone A create and save an SOS with a description and, if available, GPS coordinates. Local saving does not wait for BLE.
6. In Emergency history, check the row's delivery state and tap **Send SOS** (or **Retry send** after a failure). Keep both phones foregrounded and nearby while the action waits for the receiver's persistence acknowledgement. A connected state or queued message is not a delivery confirmation.
7. Confirm the record appears in Phone B's local history. The receive path commits the emergency and queue row in one SQLite transaction before sending the BLE acknowledgement; Phone A changes to **Delivered** only after receiving it.
8. Repeat in the reverse direction with a fresh SOS. Use **Refresh** or pull down to reload a phone's local history from SQLite.
9. Stop discovery on Phone A and B. On Phone B start discovery while Phone C is nearby to check store-and-forward.
10. Repeat with the same SOS in range twice, move a phone out of range during transfer, send an expired record, and exercise the configured eight-hop limit.
11. Delete a locally created test record and confirm the dialog. This deletes only the local row and queue entry; it cannot cancel copies already delivered to other phones. Received SOS rows do not offer this delete action.
12. Deny Nearby devices or switch Bluetooth off and verify Phone A can still create and save SOS records.

## Commands

From the project root, with Android SDK tools installed and USB debugging enabled:

```powershell
cd mobile
flutter pub get
flutter build apk --debug
flutter devices
adb -s <PHONE_A_DEVICE_ID> install -r build\app\outputs\flutter-apk\app-debug.apk
adb -s <PHONE_B_DEVICE_ID> install -r build\app\outputs\flutter-apk\app-debug.apk
```

Use `adb install -r` for an in-place update; if signatures do not match, stop without uninstalling or clearing app data. Launch `resilience_ai` on both phones and tap **Find nearby SOS devices**. Keep both screens awake and foregrounded. Confirm each shows the other nearby, create a fresh SOS on Phone A, and check Phone B's history. Repeat from Phone B to Phone A. Use new SOS records for this test; existing rows remain untouched.

For transfer diagnostics, capture Flutter logs while reproducing:

```powershell
adb -s <PHONE_A_DEVICE_ID> logcat -s flutter GattServerCallback GattConnectionManager
adb -s <PHONE_B_DEVICE_ID> logcat -s flutter GattServerCallback GattConnectionManager
```

Look for `peer.election` and confirm exactly one phone logs `role=central`. For each message, the sender should log `gatt.write` or `gatt.notify`, the receiver should log `message.persisted`, and the sender should log `transfer.acknowledged`. A `transfer.peer_complete` marks the end of the two-way session. `peer.identity.missing` means the other phone is running a build without the identity advertisement needed for deterministic election.

BLE operation requires Android BLE peripheral (advertising/GATT server) and central (scan/connect/GATT client) support. Some phone models restrict concurrent scanning and advertising, and background operation is intentionally stopped when the app is paused. Keep both apps in the foreground during this test. Radio behavior and interoperability still require physical-device validation.
