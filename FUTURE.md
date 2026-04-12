# Future Work

## Completed

### Isolate `webhook_retry_queue` in a separate virtual host

Demonstrated on 2026-04-11. With `webhook_retry_queue` in `/webhook`, disk free was
stable at 185.6 GB throughout a 40-minute baseline + spike run (~100 MB total decline
vs ~3 GB/7 min in the same-vhost configuration). See Experiment 2 in README.md.

## Planned

### Quantify the GC reclaim rate threshold

Determine the aggregate publish rate at which the classic queue message store GC can
no longer keep pace on an m5.4xlarge broker with `ha-mode: all`. Run the same-vhost
workload at increasing publish rates (100, 200, 300, 400, 500 msg/s) and measure the
disk decline rate at each level to find the crossover point.

### Repeat with quorum queues

Run the same workload with quorum queues instead of classic mirrored queues to compare
disk growth behavior under equivalent throughput and unacked counts.
