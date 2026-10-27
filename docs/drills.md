# Fault-injection drills

Unit tests prove that an alert rule fires on the series it is given; they cannot prove
that real failures produce those series. The drills break things on the running stack
and measure, with one clock, how long it takes until someone is told and until they are
told it is over:

| Measure | From | To |
|---|---|---|
| **Time to alert** | fault injected | the rule fires (its `for` period over) |
| **Time to notification** | fault injected | the notification arrives at the receiver |
| **Time to resolved** | fault removed | the "resolved" notification arrives |

`make drills ROUNDS=3` runs [`scripts/fault_drills.py`](../scripts/fault_drills.py) against
the running stack. Each round injects every fault at once, in disposable containers
labelled `drill=true` with small CPU and memory limits; apart from those, only the stack's
own Grafana is touched. As soon as a fault's notification arrives, the fault is removed.
The script reads the receiver's log ([alert-sink](../tools/alert-sink/alert_sink.py)
records when each notification arrived and when its alert started firing) and writes the
results to [`docs/drills/`](drills).

| Drill | Fault | Alert |
|---|---|---|
| service-down | `docker compose stop grafana` | TargetDown (critical, `for: 2m`) |
| crash-loop | a container that exits after 3 s, `--restart always` | ContainerRestarting (no `for`) |
| memory-pressure | a container holding ~95% of its 128 MiB limit | ContainerMemoryNearLimit (`for: 5m`) |
| error-log-burst | a Compose-labelled service logging an error every second | ContainerErrorLogBurst (Loki ruler, `for: 5m`) |
| cpu-saturation | a container spinning at its 0.1 CPU limit | ContainerCpuThrottled (`for: 15m`) |

## Results

`make drills ROUNDS=3` on 2026-10-27, 08:59 to 10:15 UTC, after both fixes below. Median
of the three rounds, minimum and maximum in brackets:

| Drill | Alert | Time to alert | Time to notification | Time to resolved | Expected from the configuration |
|---|---|---|---|---|---|
| service-down | TargetDown | 138 s (134-138) | 148 s (144-148) | 116 s (116-118) | `for 2m` + up to 30 s scrape and evaluation + 10 s `group_wait` (critical) |
| crash-loop | ContainerRestarting | 28 s (27-39) | 58 s (57-69) | 899 s (895-900) | 3 restarts counted by Docker (no `for`) + up to 30 s scrape and evaluation + 30 s `group_wait` |
| memory-pressure | ContainerMemoryNearLimit | 342 s (339-343) | 372 s (369-373) | 298 s (295-298) | `for 5m` + up to 45 s cAdvisor collection, scrape and evaluation + 30 s `group_wait` |
| error-log-burst | ContainerErrorLogBurst | 345 s (342-346) | 375 s (372-376) | 596 s (596-598) | 21 errors logged + `for 5m` + up to 1 min ruler evaluation + 30 s `group_wait` |
| cpu-saturation | ContainerCpuThrottled | 1163 s (1152-1166) | 1193 s (1182-1196) | 299 s (298-299) | ~4 min until the 5-minute usage rate passes 80% + `for 15m` + 30 s `group_wait` |

Every drill fired in every round, within the bounds its configuration sets. Within a
drill the rounds differ by at most 14 s, depending on where the fault landed in the
15-second collection, scrape and evaluation cycles.

Lab host: Debian 12 VM, 10 vCPU, 9.7 GiB RAM, Docker 27.3, the stack monitoring itself
and one Sentinel deployment. Settings that bound the timings: scrape and rule evaluation
every 15 s (Loki's ruler every minute); Alertmanager `group_wait` 10 s for critical and
30 s for warning alerts, `group_interval` 2 minutes for critical and 5 minutes for
warning. Raw data: [`drills/results-20261027-0859.json`](drills/results-20261027-0859.json).

## Where the time goes

* **The `for` duration dominates, by design.** It is what keeps a 30-second blip from
  paging anyone. Time to notification is `for` plus up to two 15-second intervals (scrape
  and evaluation; three for container metrics, which cAdvisor itself collects every 15 s)
  plus `group_wait`: 2 min 10 s to 2 min 40 s for TargetDown, measured
  2 min 24-28 s. Shorten `for` only where an outage of that length matters.
* **Rates need a full window.** `rate(...[5m])` divides by the whole five minutes, so for
  a container that has just started, CPU usage relative to its limit climbs 0.19, 0.39,
  0.59, 0.79 per minute before it crosses the 80% threshold. The CPU alert therefore
  fires about 4 minutes plus its 15-minute `for` after the fault: measured 19 min 12-26 s.
* **"Resolved" waits for the next group flush.** Alertmanager sends resolved
  notifications on the group's next `group_interval` tick: up to 2 minutes for critical,
  up to 5 for warning alerts (measured 116-118 s and 295-299 s). The 5-minute log window
  adds its own delay to the log alert, about 10 minutes in all.
  Lower `group_interval` if the all-clear must be faster; it also makes new alerts in an
  existing group wait less.
* **The crash-loop alert stays up to 15 minutes after the loop stops** (measured 895-900 s),
  because it counts restarts over 15 minutes. That is intended: a service that
  crash-looped a few minutes ago deserves a look even if it is up now.

## What the drills found

The first run exposed two problems that the unit tests could not.

**1. A real crash loop was nearly invisible.** `ContainerRestarting` counted changes of
cAdvisor's `container_start_time_seconds`. cAdvisor reports a container only while it
runs, and only every 15 seconds; Docker's restart back-off (doubling up to a minute)
keeps a crash-looping container stopped most of the time. In the drill, Docker restarted
the container 13 times in 4 minutes while cAdvisor sampled it twice, and the alert fired
only after **627 s**, when the sampling happened to catch three different start times.
The fix is a small exporter, [`tools/docker-state-exporter`](../tools/docker-state-exporter),
that reads Docker's own `RestartCount`, state and health check status through the
read-only API proxy. The rule now counts restarts as Docker does: in the three rounds
above it fired after 27-39 s and the notification arrived after **57-69 s**. The exporter
also enabled a new alert, `ContainerUnhealthy`, for failing health checks.

**2. Restarting a container looked like lost logs.** After the drill stopped and started
Grafana, `LogsDropped` went pending: Loki rejected thousands of lines as "too far
behind". When a container comes back, Alloy reads its whole Docker log again, and Loki
refuses the part older than an hour that it already holds. Nothing was lost, but the
alert could not tell. Alloy now drops lines older than an hour before sending them
(`stage.drop` with `older_than`). In the three reference rounds above, which stopped and
started Grafana three times, the filter dropped 8,288 such lines, Alloy failed to deliver
none and Loki rejected none; `LogsDropped` did not even go pending.

First run, before the fixes (round 1, notification and resolved times only):

| Drill | Time to notification | Time to resolved |
|---|---|---|
| service-down | 147 s | 116 s |
| crash-loop (cAdvisor rule) | **627 s** | 296 s |
| memory-pressure | 387 s | 298 s |
| error-log-burst | 360 s | 597 s |
| cpu-saturation | 1,181 s | 300 s |

## A real detection

While the drills were prepared, the stack raised `HostDiskSpaceLow` for the lab host's
root filesystem for real: it fired at 21:33 UTC the day before, with 14 GB (about 14%) of
97 GB free, and was routed as a warning. It stayed active through the night and the
drills, as it should, and resolved by itself at about 09:50 UTC, once space had been freed
on the host and more than 15% was free again.
