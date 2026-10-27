# Sizing and resource footprint

Measured, not estimated: `make footprint` reads the stack's own metrics (cAdvisor,
Prometheus, Loki) and Docker's volume sizes, so the numbers below can be reproduced on any
host running the stack.

**Where:** the lab host, a Debian 12 VM with 10 vCPU, 9.7 GiB RAM and Docker 27.3, running
the stack and monitoring itself plus one [Sentinel](https://github.com/ali-fakhrabadi/sentinel-iam-audit-service)
deployment (web, worker, beat, PostgreSQL and Redis containers): 14 containers, 8 scrape
targets. **When:** the 12 hours before the fault-injection drills, 2026-10-26 20:15 to
2026-10-27 08:15 UTC.

## Memory and CPU per service

`make footprint WINDOW=12h` (memory is the working set; CPU in cores, averaged over 5 minutes):

| Service | Memory avg | Memory peak | CPU avg (cores) | CPU peak (cores) | Memory limit |
|---|---|---|---|---|---|
| grafana | 226 MiB | 299 MiB | 0.019 | 0.040 | 512 MiB |
| prometheus | 169 MiB | 212 MiB | 0.010 | 0.017 | 1 GiB |
| loki | 116 MiB | 157 MiB | 0.013 | 0.015 | 1 GiB |
| alloy | 84 MiB | 90 MiB | 0.007 | 0.009 | 384 MiB |
| alertmanager | 38 MiB | 45 MiB | 0.002 | 0.003 | 128 MiB |
| docker-socket-proxy | 30 MiB | 31 MiB | 0.002 | 0.003 | 64 MiB |
| cadvisor | 29 MiB | 33 MiB | 0.007 | 0.009 | 256 MiB |
| node-exporter | 22 MiB | 24 MiB | 0.005 | 0.006 | 64 MiB |
| alert-sink | 12 MiB | 22 MiB | 0.012 | 0.014 | 64 MiB |
| **total** | **727 MiB** | **790 MiB** | **0.077** | **0.101** | 3.5 GiB |

Peaks are per service; the total peak is the highest simultaneous sum. A recreated
container briefly has two cAdvisor series (old and new cgroup), so the report takes the
larger one per container name rather than adding them up (an earlier version of the
script did, and reported a Grafana peak above its own limit).

The [Docker state exporter](../tools/docker-state-exporter) came out of the
[drills](drills.md#what-the-drills-found), after this window, so the totals above do not
include it. In the hour after the drills (10:04 to 11:04 UTC) it used 17 MiB on average,
25 MiB at peak and 0.014 cores (64 MiB limit), and added 70 series for 18 containers. A
scrape takes 0.35 s, mostly one inspect call per container through the API proxy.

## Data volume

| Measure | Value |
|---|---|
| Active series in Prometheus | 13,092 (average) |
| Samples ingested | 781 per second |
| Log lines into Loki | 1.0 per second (280 bytes per second) |
| Prometheus data after 18.5 hours | 178 MB (about 230 MB per day) |
| Loki data after 18.5 hours | 3.6 MB |
| Grafana data | 1.7 MB |

What each source costs in series (count at 08:15 UTC): Grafana's own metrics 3,928, Loki
2,571, **one Linux host (Node Exporter) 2,189**, cAdvisor 1,187 for 14 containers (**about
85 per container**), Prometheus 1,174, Alertmanager 544, Alloy 258, **Sentinel 211**,
recording rules 17.

## What this means for a host

* **Memory:** the stack averaged 727 MiB and peaked at 790 MiB; its limits add up to
  3.5 GiB. A 4 GiB host (the Terraform default, `t3.medium`) fits the limits with room for
  the OS; 2 GiB works for the measured usage but not for every service at its limit.
* **CPU:** under 0.1 core at this scale; a 2 vCPU burstable instance idles.
* **Disk:** at about 230 MB per day, Prometheus' 15-day retention needs roughly 3.5 GB, under
  the configured 5 GB size cap (`PROMETHEUS_RETENTION_SIZE`), which bounds it for larger
  setups. The Terraform data volume defaults to 30 GiB.
* **Growth:** every further host adds about 2,200 series, every container about 85. Ten
  more hosts with 10 containers each is roughly 30,000 more series; Prometheus' memory
  grows with active series, so check `make footprint` after onboarding them.

## Provisioning time (measured in CI)

GitHub-hosted `ubuntu-24.04` runners, from an empty Docker image cache:

| Step | Duration |
|---|---|
| `make env secrets` (configuration and generated secrets) | 6 s |
| `make up`: pull every image, start, wait until all health checks pass | 48-66 s (last 5 green runs) |
| `make smoke`: 14 end-to-end checks | 4-30 s |
| `make terraform`: fmt, validate, tflint, Trivy, 37 `terraform test` runs | 56 s |
| Ansible `observability_stack` on a bare Debian 12 machine: install Docker, deploy the stack, pass the smoke test | 2 min 42 s (converge) |
| The same role applied again (must change nothing) | 46 s |
| Ansible `linux_hardening` on Debian 12 and Ubuntu 24.04 (in parallel) | 52 s (converge), 31 s (second run) |

The Ansible timings are from Molecule's test machines (privileged systemd containers on
the runner, Docker inside Docker for the stack), printed by the `ansible.posix.timer`
callback. Terraform has not been applied to AWS from this repository, so there is no
measured provisioning time for the AWS host.
