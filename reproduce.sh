#!/usr/bin/env bash
# Reproduces classic queue message store GC lag under high publish rate.
#
# Runs two perf-test instances and the Pika webhook consumer:
#   - Main workload: 100 classic queues, publish + consume, 120 KB messages
#   - webhook_retry_queue publisher: 3 msg/s (Pika is the sole consumer)
#   - Pika consumer: holds acks 1-29.8 min, cap 1000 in-flight
#
# Usage: ./reproduce.sh [baseline_minutes]
#   baseline_minutes: time at 150 msg/s before spiking to 500 msg/s (default: 30)

set -o errexit
set -o nounset
set -o pipefail

declare -r uris='amqp://guest:guest@10.0.1.121:5672,amqp://guest:guest@10.0.1.74:5672,amqp://guest:guest@10.0.1.194:5672'
declare -r perf_test_jar='/home/ec2-user/rabbitmq-perf-test/target/perf-test.jar'
declare -ri baseline_minutes="${1:-30}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir

declare -r red='\033[0;31m'
declare -r green='\033[0;32m'
declare -r blue='\033[0;34m'
declare -r nc='\033[0m'

log_info() {
    echo -e "${blue}[$(date -u '+%H:%M:%S')]${nc} $1"
}

log_success() {
    echo -e "${green}[$(date -u '+%H:%M:%S')]${nc} $1"
}

log_error() {
    echo -e "${red}[$(date -u '+%H:%M:%S')]${nc} ERROR: $1" >&2
}

main() {
    log_info "Baseline phase: ${baseline_minutes} minutes at 150 msg/s"
    log_info "Spike phase: sustained 500 msg/s after baseline"

    log_info "Starting Pika webhook consumer..."
    python3 "$script_dir/webhook_consumer.py" \
        --uri 'amqp://guest:guest@10.0.1.121:5672' \
        2>&1 | tee "$script_dir/webhook_consumer.log" &
    declare -ri pika_pid=$!
    log_success "Pika consumer PID: $pika_pid"

    log_info "Starting webhook_retry_queue publisher (3 msg/s)..."
    java -jar "$perf_test_jar" \
        --uris "$uris" \
        --queue webhook_retry_queue \
        --producers 1 \
        --consumers 0 \
        --rate 3 \
        --size 122880 \
        --confirm 100 \
        --id webhook-publisher \
        2>&1 | tee "$script_dir/webhook_publisher.log" &
    declare -ri webhook_pid=$!
    log_success "webhook publisher PID: $webhook_pid"

    # Target ~75K unacked: 100 queues x QoS 500 x 6-min consumer latency
    # --variable-rate 150:N runs at 150 msg/s for N seconds, then 500:0 runs indefinitely
    log_info "Starting main 100-queue workload..."
    java -jar "$perf_test_jar" \
        --uris "$uris" \
        --queue-pattern 'repro-queue-%d' \
        --queue-pattern-from 1 \
        --queue-pattern-to 100 \
        --producers 100 \
        --consumers 100 \
        --size 122880 \
        --confirm 100 \
        --qos 500 \
        --consumer-latency 360000000 \
        --variable-rate "150:$((baseline_minutes * 60))" \
        --variable-rate '500:86400' \
        --id main-workload \
        2>&1 | tee "$script_dir/main_workload.log" &
    declare -ri main_pid=$!
    log_success "Main workload PID: $main_pid"

    echo
    log_info "Logs: main_workload.log  webhook_publisher.log  webhook_consumer.log"
    log_info "To stop: kill $main_pid $webhook_pid $pika_pid"
    echo

    wait $main_pid
    log_info "Main workload exited."
    kill $webhook_pid $pika_pid 2>/dev/null || true
}

main "$@"
