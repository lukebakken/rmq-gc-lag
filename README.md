# GC Lag Reproduction

Reproduces the classic queue message store GC lag incident.

## What This Does

Simulates the customer's workload in two phases:

1. **Baseline phase** (default 30 minutes): 100 classic queues at ~150 msg/s aggregate,
   120 KB messages, consumers holding acks for ~6 minutes (QoS 500) to maintain ~75K
   unacked messages. A separate publisher sends 3 msg/s to `webhook_retry_queue`.
   A Pika consumer holds those acks for 1-29.8 minutes (up to 1000 in flight).

2. **Spike phase**: publish rate increases to ~500 msg/s. `ClassicQueuesStorageUsed`
   should begin growing steadily as GC falls behind.

## Prerequisites

On the perf-test host:
- Java (for perf-test)
- Python 3.9+ with pika: `pip3 install pika`
- `/home/ec2-user/rabbitmq-perf-test/target/perf-test.jar`

The broker must have `ha-mode: all, ha-sync-mode: automatic` applied to all queues
(set manually via policy before running).

## Usage

```bash
# Default: 30-minute baseline then spike
./reproduce.sh

# Custom baseline duration
./reproduce.sh 45
```

## Monitoring

Watch `ClassicQueuesStorageUsed` in CloudWatch. During the baseline phase it should
be stable. After the spike it should grow continuously.

Also watch `MessageUnacknowledgedCount` — it should be ~75K during baseline and grow
after the spike as the higher publish rate fills the 6-minute hold window faster.

## Files

- `reproduce.sh` — main orchestration script
- `webhook_consumer.py` — Pika consumer for `webhook_retry_queue`
- `main_workload.log` — perf-test output for 100-queue workload (created at runtime)
- `webhook_publisher.log` — perf-test output for webhook publisher (created at runtime)
- `webhook_consumer.log` — Pika consumer log (created at runtime)
