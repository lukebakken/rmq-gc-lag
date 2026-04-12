# RabbitMQ Classic Queue GC Lag Reproduction

Reproduces classic queue message store GC lag caused by a publish rate spike
against a broker with long-timeout consumer queues in the same vhost.

Also demonstrates the vhost isolation mitigation: moving long-timeout consumer
queues to a dedicated vhost prevents their unacked messages from pinning segment
files in the high-throughput vhost's message store.

## How It Works

Three processes run concurrently:

- **main-workload**: 100 classic queues (`repro-queue-1` through `repro-queue-100`)
  in the `/` vhost. 100 producers + 100 consumers, 120 KB messages, consumers acking
  immediately. Variable rate: 2 msg/s per producer (200 msg/s aggregate) for
  `BASELINE_MINUTES`, then 5 msg/s per producer (500 msg/s aggregate) indefinitely.

- **webhook-publisher**: 1 producer publishing 3 msg/s to `webhook_retry_queue`.

- **webhook-consumer**: Pika consumer on `webhook_retry_queue` holding acks for a
  random 1–29.8 minute duration (up to 1000 messages in flight simultaneously).

By default all three processes use the `/` vhost. To demonstrate the mitigation,
run `webhook-publisher` and `webhook-consumer` with `VHOST=webhook` after running
`make create-vhost VHOST=webhook`.

## Prerequisites

On the perf-test host:

- Java with `/home/ec2-user/rabbitmq-perf-test/target/perf-test.jar`
- Python 3.9+ with pika: `pip3 install pika`

## Makefile Targets

```bash
# Apply HA policy to a vhost (default: /)
make ha-policy
make ha-policy VHOST=webhook

# Create a vhost, grant guest permissions, apply HA policy
make create-vhost VHOST=webhook

# Delete all queues across all vhosts
make clean

# Start the Pika webhook consumer (default vhost: /)
make webhook-consumer
make webhook-consumer VHOST=webhook

# Start the webhook_retry_queue publisher (default vhost: /)
make webhook-publisher
make webhook-publisher VHOST=webhook

# Start the 100-queue main workload (always uses / vhost)
make main-workload
make main-workload BASELINE_MINUTES=45
```

Each target runs in the foreground. Start each in a separate terminal.
Log files are written to the current directory with a UTC timestamp on the first line.

## Experiment 1: Baseline (same vhost, reproduces the incident)

```bash
make ha-policy
# terminal 1
make webhook-consumer
# terminal 2
make webhook-publisher
# terminal 3
make main-workload
```

Expected: disk free declines steadily on all nodes. Rate accelerates after the spike.

## Experiment 2: Vhost isolation (demonstrates the mitigation)

```bash
make ha-policy
make create-vhost VHOST=webhook
# terminal 1
make webhook-consumer VHOST=webhook
# terminal 2
make webhook-publisher VHOST=webhook
# terminal 3
make main-workload
```

Expected: disk free is stable throughout, even after the spike. The `/` vhost's
message store GC runs freely because `webhook_retry_queue`'s unacked messages are
isolated in the `/webhook` vhost.

## Monitoring

```bash
# Publish/ack rates and queue totals
curl -s -u guest:guest http://NODE:15672/api/overview | jq '{queue_totals, message_stats}'

# Disk free per node
curl -s http://NODE:15692/metrics | grep '^rabbitmq_disk_space_available_bytes'
```

## Files

- `Makefile` — all targets
- `webhook_consumer.py` — Pika consumer holding acks 1–29.8 min
- `FUTURE.md` — planned follow-on experiments
