# Protocol golden vectors

One file per message example: `<message_name>[_variant].hex` (lowercase hex, whitespace ignored, `#` comments allowed).

Both `host-mac` (Swift) and `client-android` (Kotlin) unit tests must:

1. decode every fixture and compare fields with the values documented in `docs/PROTOCOL.md`;
2. encode those values and produce the identical bytes.

This is how Swift/Kotlin drift gets caught before it reaches the device. Only the orchestrator edits fixtures.
