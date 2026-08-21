#!/usr/bin/env python3
"""Publish per-thread CPU usage for radiod as a CSV the UberSDR admin panel reads.

Samples /proc/<pid>/task/<tid>/stat twice over SAMPLE_SECONDS and writes
"name,cpu_pct,cpu_num" rows, header included, replaced atomically.

Consumed by readThreadStats() in ka9q_ubersdr/radiod_channels_api.go, which
attributes CPU to a channel by finding the channel's decimal SSRC as a
whitespace-delimited token in the thread name.  radiod names demodulator threads
"<demod> <ssrc>", and Linux caps thread names at 15 characters -- so UberSDR
allocates short SSRCs to keep them inside that budget.  If every row here is
named "radiod", that budget has been exceeded and the attribution is lost.

Pure /proc reads, no forks per cycle.
"""

import os
import re
import time

STATS_FILE = "/var/run/restart-trigger/radiod-thread-stats.csv"
# Temp file lives beside the target: os.replace() is only atomic within one
# filesystem, so it cannot be staged somewhere like /dev/shm.
TMP_FILE = "/var/run/restart-trigger/radiod-thread-stats.tmp"

SAMPLE_SECONDS = 2

try:
    HZ = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
except (ValueError, OSError):
    HZ = 100

# Greedy match strips the "PID (name) " prefix correctly even when the thread
# name itself contains ")".
STAT_RE = re.compile(r"^\d+ \(.*\) ")

# Field offsets after the prefix is stripped: see proc(5).
UTIME_FIELD = 11
STIME_FIELD = 12
PROCESSOR_FIELD = 36


def find_radiod_pid():
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"/proc/{entry.name}/comm") as f:
                if f.read().strip() == "radiod":
                    return entry.name
        except OSError:
            pass
    return None


def read_thread_stats(pid):
    """Return {tid: (utime, stime, cpu_num, name)} for every thread of pid."""
    stats = {}
    task_dir = f"/proc/{pid}/task"
    try:
        tids = os.listdir(task_dir)
    except OSError:
        return stats
    for tid in tids:
        try:
            with open(f"{task_dir}/{tid}/stat") as f:
                raw = f.read()
            fields = STAT_RE.sub("", raw).split()
            try:
                with open(f"{task_dir}/{tid}/comm") as f:
                    name = f.read().strip()
            except OSError:
                name = "?"
            stats[tid] = (
                int(fields[UTIME_FIELD]),
                int(fields[STIME_FIELD]),
                fields[PROCESSOR_FIELD],
                name,
            )
        except (OSError, IndexError, ValueError):
            pass
    return stats


def main():
    while True:
        pid = find_radiod_pid()
        if pid is None or not os.path.isdir(f"/proc/{pid}/task"):
            time.sleep(1)
            continue

        first = read_thread_stats(pid)
        started = time.monotonic()
        time.sleep(SAMPLE_SECONDS)
        second = read_thread_stats(pid)

        elapsed_ticks = max(1.0, (time.monotonic() - started) * HZ)

        lines = ["name,cpu_pct,cpu_num"]
        for tid, (utime, stime, cpu_num, name) in second.items():
            if tid not in first:
                continue  # thread appeared mid-sample; no baseline to diff
            prev_utime, prev_stime, _, _ = first[tid]
            pct = (utime - prev_utime + stime - prev_stime) * 100.0 / elapsed_ticks
            lines.append(f"{name},{pct:.1f},{cpu_num}")

        with open(TMP_FILE, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(TMP_FILE, STATS_FILE)


if __name__ == "__main__":
    main()
