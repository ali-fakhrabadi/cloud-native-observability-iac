# Alert runbooks

Every alert links here through its `runbook_url` annotation. Each entry says what the
alert means, why it matters, how to confirm it and what usually fixes it. Queries run in
Grafana's Explore view (Prometheus or Loki datasource); commands run on the Docker host
from the repository directory.

Severities: **critical** pages someone (notified within about 10 seconds of firing,
repeated hourly); **warning** needs attention the same day (grouped for 30 seconds,
repeated every 4 hours); **none** is the Watchdog heartbeat.

## Host

### HostHighCpuUsage
*CPU above 90% for 10 minutes (warning).* Requests slow down and scheduled jobs queue.
- Who uses it: `topk(5, name:container_cpu_usage:rate5m)` and `CPU by mode` on the
  *Linux & Docker overview* dashboard (high `iowait` points at storage, not CPU).
- Fix: stop or limit the offending container (`deploy.resources.limits.cpus`), or add
  CPU. A process outside Docker shows up in `top` on the host but not in container panels.

### HostHighMemoryUsage
*Less than 10% of memory available for 10 minutes (warning).* The kernel will start
killing processes when it runs out.
- Who uses it: *Memory by container*; `sort_desc(container_memory_working_set_bytes{name!=""})`.
- Fix: set or lower memory limits for the largest containers, restart a leaking service,
  or add memory. Check for `HostOomKillDetected` at the same time.

### HostOomKillDetected
*The kernel OOM killer ended a process in the last 5 minutes (warning).* Something was
restarted or lost work.
- Confirm: `sudo dmesg -T | grep -i "killed process"`; containers killed by their own
  limit also show `ContainerRestarting` and an exit code 137 in `docker ps -a`.
- Fix: raise the memory limit of the killed service if it is legitimately larger, or fix
  the leak; then check that the host has headroom (`HostHighMemoryUsage`).

### HostDiskSpaceLow
*Less than 15% free on a filesystem for 5 minutes (warning).*
- Who uses it: `sudo du -xh --max-depth=2 <mountpoint> | sort -h | tail`; for Docker:
  `docker system df`.
- Fix: prune unused images and build cache (`docker image prune -a`,
  `docker builder prune`), check log rotation, lower Prometheus/Loki retention
  (`PROMETHEUS_RETENTION_SIZE`, `retention_period` in `config/loki/loki.yml`), or grow
  the disk.

### HostDiskSpaceCritical
*Less than 5% free for 2 minutes (critical).* Writes fail soon: databases, Prometheus
and Loki stop accepting data. Inhibits `HostDiskSpaceLow` and `HostDiskWillFillIn24Hours`
for the same filesystem.
- Act immediately with the steps of `HostDiskSpaceLow`; free space first, analyze later.

### HostDiskWillFillIn24Hours
*Linear prediction from the last 6 hours says the filesystem is full within a day, and it
is already below 40% free (warning).* Gives time to act before thresholds fire.
- Confirm the trend: `node_filesystem_avail_bytes{mountpoint="<mountpoint>"}` over 24 hours.
- Fix: find what is growing (logs, uploads, database, backups) and rotate or move it.

### HostOutOfInodes
*Less than 10% of inodes free for 10 minutes (warning).* New files cannot be created even
with free space, usually because of millions of small files.
- Find them: `sudo find <mountpoint> -xdev -type f | cut -d/ -f2-4 | sort | uniq -c | sort -n | tail`.
- Fix: delete or archive the small files (caches, sessions, mail queues).

## Containers

### ContainerRestarting
*Docker restarted a container 3 or more times in 15 minutes (warning).* A crash loop: the
service is mostly unavailable. The count is Docker's own (`RestartCount`, read by the
Docker state exporter), so containers that are down most of the time between restarts
are caught too; cAdvisor misses them.
- Why: `docker logs --tail 100 <name>`; in Grafana, the *Errors and warnings* log panel
  filtered to the container; the last exit code is `docker_container_exit_code` or
  `docker inspect -f '{{.State.ExitCode}}' <name>` (137 = killed, often out of memory).
- Fix: the cause in the logs (configuration, dependency down, memory limit).

### ContainerUnhealthy
*Docker has reported a container's health check as failing for 2 minutes (warning).*
Docker only marks a container unhealthy after the check failed several times in a row
(`retries`), so the service is very likely not serving.
- Why: `docker inspect -f '{{json .State.Health}}' <name>` shows the last check outputs;
  then the container's logs.
- Fix: the cause the check reports (dependency, port, configuration). Docker does not
  restart unhealthy containers by itself; `docker compose restart <service>` once fixed.

### ContainerStopped
*A Compose service that ran for at least 5 minutes has not been seen for a minute
(warning).* Stays active for up to 10 minutes after the container disappears, so a
deliberate `docker compose down` also shows briefly.
- Confirm: `docker ps -a --filter name=<name>`; was it stopped on purpose?
- Fix: `docker compose up -d <service>` in the owning project, then find why it stopped.

### ContainerMemoryNearLimit
*Working set above 90% of the container's memory limit for 5 minutes (warning).* The
container is OOM-killed when it reaches the limit.
- Confirm: *Memory against limit* on the overview dashboard.
- Fix: raise the limit if the usage is legitimate, otherwise investigate the leak.

### ContainerCpuThrottled
*More than 50% of CPU scheduling periods throttled while the container uses over 80% of
its CPU limit, for 15 minutes (warning).* The service is CPU-bound and slower than it
could be.
- Fix: raise `deploy.resources.limits.cpus` or reduce the work (concurrency, batch sizes).

## Services

### TargetDown
*Prometheus could not scrape a target for 2 minutes (critical).* Either the service is
down or its metrics endpoint is unreachable. While Sentinel or Node Exporter is down,
the `Sentinel*` or `Host*` alerts derived from its stale data are inhibited.
- Details: Prometheus *Status → Targets* (`http://127.0.0.1:9090/targets`) shows the
  scrape error: connection refused (down), 401 (wrong credentials or token), timeout.
- Fix: start the service; for 401, check the matching file in `./secrets`.

### SentinelHighErrorRate
*More than 5% of Sentinel responses are 5xx for 5 minutes, at more than 0.2 requests per
second (critical).* Clients see failures; ingestion requests are rejected with 503 and
must be retried. Inhibits `SentinelHighLatency`.
- Which requests: *Responses by status class* on the *Sentinel* dashboard; logs:
  `{compose_project="sentinel", level=~"error|fatal"}`, then follow one `request_id`.
- Usual causes: PostgreSQL or Redis unavailable (`docker compose ps` in the Sentinel
  project, its `/health/ready/` endpoint), statement timeouts, a bad deployment.

### SentinelHighLatency
*p95 request duration above 1 second for 10 minutes (warning).*
- Where: *Slowest views (p95)* on the Sentinel dashboard; container CPU of the web tier.
- Usual causes: CPU saturation of the web container, slow queries (check Sentinel's
  `docs/performance.md` for expected values), a large bulk ingestion.

### SentinelOutboxBacklog
*The oldest undispatched security event is older than 5 minutes (warning).* Webhook
alerts to downstream systems are delayed.
- Check the worker: `docker compose logs --tail 100 worker` in the Sentinel project;
  `sentinel_outbox_pending_messages` growing means dispatch stopped.
- Fix: restart the worker; check Redis (the Celery broker).

### SentinelWebhookDeliveriesFailing
*Webhook deliveries reached `failed` or `exhausted` in the last 30 minutes (warning).* A
receiver rejects deliveries or has been unreachable for all retries.
- Which endpoint: `GET /api/v1/webhooks/endpoints/{id}/deliveries/?status=failed` on
  Sentinel shows the error code (`http_4xx`, `timeout`, SSRF refusals).
- Fix: correct the receiver URL or its signature verification, then re-send if needed.

### SentinelIngestionRejections
*More than 20% of ingested audit events are rejected for 10 minutes (warning).* A
producer sends invalid events; they are not stored.
- Which producer: rejected events are not stored, so look at the producers: each
  receives the field errors per item in its bulk response. Start with producers that
  changed recently.
- Fix: correct the producer's payload (schema in Sentinel's OpenAPI documentation).

### SentinelErrorLogs
*More than 5 error log lines per 5 minutes in a Sentinel service for 2 minutes (warning,
Loki rule).* Catches failures that do not reach HTTP status codes, such as Celery tasks.
- Logs: `{compose_project="sentinel", level=~"error|fatal"}`; group by `logger`.

### ContainerErrorLogBurst
*More than 20 error or fatal log lines in 5 minutes from one Compose service, for 5
minutes (warning, Loki rule).*
- Logs: `{compose_project="<project>", compose_service="<service>", level=~"error|fatal"}`.
- A burst right after a restart is often startup noise; persistent bursts are not.

## Observability stack

### Watchdog
*Always firing (severity none).* Routed every 5 minutes to the `heartbeat` receiver. If
the receiver stops getting it, the alerting pipeline itself is broken. Point the
`heartbeat` receiver at an external dead man's switch service in production.

### PrometheusRuleEvaluationFailures
*A rule group failed to evaluate (critical).* Alerts in that group cannot fire.
- Details: Prometheus *Status → Rules* shows the error. Run `make test-rules` after
  changing rules; it catches most errors before deployment.

### PrometheusNotificationsFailing
*Prometheus cannot send alerts to Alertmanager for 5 minutes (critical).* This alert
itself may not arrive; the missing Watchdog will.
- Check: `make ps` (is Alertmanager running?), `make logs SERVICE=prometheus`.

### AlertmanagerNotificationsFailing
*A receiver integration has been failing for 5 minutes (critical).* Alerts are not reaching
people.
- Details: `make logs SERVICE=alertmanager`; check the URL in
  `secrets/alertmanager_webhook_url` and the receiver's availability.

### LogsDropped
*Alloy is dropping log entries or Loki is rejecting them, for 5 minutes (warning).* Logs
are incomplete.
- Causes: Loki down or overloaded, rate limits in `limits_config`, lines older than
  `reject_old_samples_max_age`. Lines dropped on purpose by filters are not counted here.

### AlloyComponentUnhealthy
*An Alloy pipeline component is unhealthy for 10 minutes (warning).*
- Details: `make logs SERVICE=alloy`; usually the Docker API proxy or Loki is
  unreachable, or a configuration change did not validate (`make validate`).
