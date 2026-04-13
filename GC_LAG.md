# Classic Queue Message Store GC Lag

## Summary

Under sustained publish load with a long-timeout consumer queue in the same vhost, the classic queue shared message store fails to reclaim segment files fast enough. Disk usage grows continuously until the consumer acks its messages or the broker is restarted. This behavior is a regression relative to RabbitMQ 3.13.7 — it is present in both the Amazon MQ 20251225 build and current `main`.

## Observed Behavior

### Amazon MQ for RabbitMQ (3.13.7, awsbuild_20251225)

Production broker `b-c24a60f7-ce4a-4ca4-b1c6-d113bc60c936` (3-node m5.4xlarge cluster):

- Disk declined 24–57 GB per node during business hours (13:00–20:00 UTC) on April 8–10, 2026
- Recovered overnight as publish rate dropped and GC caught up
- No disk alarm fired because peak rate (~300–500 msg/s) was lower than the March 23 incident (~840 msg/s)
- Customer workaround: purge `webhook_retry_queue`

Reproduction on 3-node m5.4xlarge test cluster (awsbuild_20251225, same vhost):

- Disk declined ~3 GB/node in ~7 minutes at 200 msg/s baseline
- Accelerated after spike to 500 msg/s

### Vanilla RabbitMQ 3.13.7 (upstream)

Reproduction on 3-node m5.4xlarge test cluster (same workload, same vhost):

- Disk **stable** throughout baseline and spike phases
- No GC lag observed

### RabbitMQ `main` (single instance, m7g.large)

Reproduction on single-instance m7g.large (2026-04-13):

- Disk declining at baseline rate (200 msg/s) **before the spike**:

| Time (UTC) | Disk free |
|---|---|
| 14:40:29 | 184.18 GB |
| 14:41:00 | 184.07 GB |
| 14:41:30 | 183.62 GB |
| 14:42:00 | 183.51 GB |
| 14:42:31 | 183.38 GB |
| 14:43:01 | 182.96 GB |

~1.4 GB decline in 2.5 minutes at 200 msg/s. The spike had not yet started (30-minute baseline phase).

This is **worse** than the Amazon MQ 20251225 build, which was stable during the baseline phase.

## Workload

Three concurrent processes:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`), 100 producers + 100 consumers, 120 KB messages, consumers acking immediately. Variable rate: 2 msg/s/producer (200 msg/s aggregate) for 30 minutes, then 5 msg/s/producer (500 msg/s aggregate).
- **webhook-publisher**: 1 producer, 3 msg/s to `webhook_retry_queue`.
- **webhook-consumer**: Pika consumer on `webhook_retry_queue` holding acks for 1–29.8 minutes (up to 1000 messages in flight).

Policy on `/` vhost: `queue-version: 2`. On the cluster reproduction: also `ha-mode: all`, `ha-sync-mode: automatic`.

Reproduction scripts: https://github.com/lukebakken/rmq-gc-lag

## Root Cause (Working Theory)

The `webhook_retry_queue` consumer holds acks for up to 30 minutes. The unacked messages remain referenced in the shared message store index with `ref_count > 0`, pinning the segment files that contain them. The message store GC cannot delete or compact those files while any message they contain is still referenced.

The high-throughput queues (`repro-queue-*`) write new messages to the same shared message store. As they publish and consume, their messages are written to new segment files. But because the `webhook_retry_queue` messages pin older files, the store accumulates files faster than GC can reclaim them.

The mechanism is confirmed by the vhost isolation mitigation: moving `webhook_retry_queue` to a separate vhost gives it a separate message store instance. Its unacked messages no longer pin files in the `/` vhost's store, and GC runs freely — disk was stable at 185.6 GB throughout a 40-minute run at 200–500 msg/s.

## Code Changes Between 3.13.7 and awsbuild_20251225

The `BACKPORT.md` in the 20251225 build lists commits applied to `rabbit_msg_store.erl` after `v3.13.7`. Key changes:

- `e033d97f37 CQ: Defer shared store GC when removes were observed` — introduces `current_file_removes`: defers index deletion for messages removed from the current write file until roll-over
- `df9f9604e2 CQ: Rewrite the message store file scanning code` — rewrites the file scanning/compaction algorithm
- `2955c4e8e2 CQ: Get messages list from file when doing compaction` — changes how compaction determines which messages to move
- Removal of pluggable index module (`rabbit_msg_store_ets_index`) — index is now always ETS
- Removal of `file_handle_cache_stats` module

The specific commit that introduced the regression has not been isolated. The `current_file_removes` deferral is the most behaviorally significant change, but the compaction algorithm rewrite may also be a factor.

## Mitigation (Confirmed)

Move `webhook_retry_queue` (and any other queue with long consumer timeouts) to a dedicated vhost. This is a configuration-only change requiring no code modification or instance upgrade.

Vhost isolation experiment results (awsbuild_20251225, 3-node cluster):
- Same vhost: disk declined ~3 GB/node in ~7 minutes at 200 msg/s
- Separate vhost: disk stable at 185.6 GB throughout 40-minute run at 200–500 msg/s

## Next Steps

- Let the `main` reproduction run through the spike phase to quantify the decline rate
- File a GitHub issue against `rabbitmq/rabbitmq-server` with reproduction steps pointing to https://github.com/lukebakken/rmq-gc-lag
- Tag @lhoguin (https://github.com/lhoguin) — sole author of the classic queue message store
