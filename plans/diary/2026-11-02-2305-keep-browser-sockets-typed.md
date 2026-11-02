# Keep browser sockets typed

Browser WebSocket now stores its native connection, unread text, waiting
readers, opening resume and subscription listener with their real types.
Its queues use the shared Chain module. Native operations are generated from
the reviewed catalogue, including narrow constructor SecurityError mapping.
URL resolution and token checks reuse HTTP's typed native operations.

Native validation passed and all 19 browser WebSocket program runs passed,
including dev/release lifetime, cancellation, equality, failures and binary
message behavior. Behavioral goldens stayed unchanged. HostFree stays off
until the remaining families are migrated.
