#!/usr/bin/env python3
"""Cost of a shell command as the plugin spawns it (/bin/sh -c CMD).

Reports mean wall time and CPU (user+sys of all reaped descendants) over N
runs, plus the exact number of processes it creates (execve count under
strace -f).

Usage: bench/cost.py N 'command' ['command' ...]
"""
import os
import resource
import subprocess
import sys
import tempfile
import time


def measure(cmd: str, n: int) -> tuple[float, float, int]:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    for _ in range(n):
        subprocess.run(["/bin/sh", "-c", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wall = (time.perf_counter() - t0) / n * 1000
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)) / n * 1000
    with tempfile.NamedTemporaryFile("r", suffix=".strace") as f:
        subprocess.run(
            ["strace", "-f", "-qq", "-e", "trace=execve", "-o", f.name, "/bin/sh", "-c", cmd],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        execs = sum(1 for line in open(f.name) if "execve(" in line and "= 0" in line)
    return wall, cpu, execs


def main() -> None:
    n = int(sys.argv[1])
    for cmd in sys.argv[2:]:
        wall, cpu, execs = measure(cmd, n)
        print(f"{wall:8.1f} ms wall {cpu:8.2f} ms cpu {execs:3d} procs  {cmd[:90]}")


if __name__ == "__main__":
    os.environ.setdefault("LC_ALL", "C")
    main()
