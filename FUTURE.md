# Future Work

## Isolate `webhook_retry_queue` in a separate virtual host

**Goal:** Demonstrate that moving `webhook_retry_queue` to its own virtual host
prevents its unacked messages from pinning segment files in the `/` vhost's
message store, allowing the `/` store to GC normally under a publish rate spike.

**Required changes:**

- Add a `create-vhost` Makefile target to create the `/webhook` vhost via the
  HTTP API
- Add a separate HA policy target scoped to `/webhook`
- Update `webhook-publisher` and `webhook-consumer` targets to use the `/webhook`
  vhost URI
- Run both scenarios back-to-back and compare disk free trajectory across nodes
