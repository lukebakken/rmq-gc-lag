URIS := amqp://guest:guest@10.0.1.121:5672,amqp://guest:guest@10.0.1.74:5672,amqp://guest:guest@10.0.1.194:5672
PERF_TEST_JAR := /home/ec2-user/rabbitmq-perf-test/target/perf-test.jar
JAVA_OPTS := -Xmx1500m
BASELINE_MINUTES := 30

.PHONY: webhook-consumer webhook-publisher main-workload

webhook-consumer:
	python3 webhook_consumer.py \
		--uri amqp://guest:guest@10.0.1.121:5672 \
		2>&1 | tee webhook_consumer.log

webhook-publisher:
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris $(URIS) \
		--queue webhook_retry_queue \
		--producers 1 \
		--consumers 0 \
		--rate 3 \
		--size 122880 \
		--confirm 100 \
		--id webhook-publisher \
		2>&1 | tee webhook_publisher.log

main-workload:
	java $(JAVA_OPTS) -jar $(PERF_TEST_JAR) \
		--uris $(URIS) \
		--queue-pattern 'repro-queue-%d' \
		--queue-pattern-from 1 \
		--queue-pattern-to 100 \
		--producers 100 \
		--consumers 100 \
		--size 122880 \
		--confirm 100 \
		--qos 500 \
		--consumer-latency 360000000 \
		--variable-rate "150:$$(($(BASELINE_MINUTES) * 60))" \
		--variable-rate '500:86400' \
		--id main-workload \
		2>&1 | tee main_workload.log
