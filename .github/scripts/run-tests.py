#!/usr/bin/env python3
"""Runs `swift test` for one package and reports the result for CI.

Run with `python3 -I`. Exit status 0 means every test passed, or that the only
failures were tests in .github/ci/known-flaky.txt which then passed when run
again alone. Anything else fails:

- a failing test that is not on the list is never rerun;
- a run that ends without a failure list (a crash, a hang guard, a leftover
  child process reported by ProcessAudit) counts as a real failure;
- a listed test that also fails alone is a real failure.

Skipped tests (no KVM, no GPU, no simulator runtime, no local corpus) are
counted and listed with their reasons, so a skip is always visible.

Usage: run-tests.py --package ycode [--scratch-path DIR] [--log DIR] [-- args for swift test]
"""
import argparse
import glob
import os
import platform
import queue
import re
import signal
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FLAKY_LIST = os.path.join(REPO, ".github", "ci", "known-flaky.txt")


def host_platforms():
    """The platform names a known-flaky line can use on this machine."""
    if sys.platform == "darwin":
        return {"*", "macos"}
    return {"*", "linux", "linux-" + platform.machine()}


def load_flaky(path=FLAKY_LIST):
    """Returns the tests listed for this machine."""
    names = set()
    with open(path, encoding="utf-8") as listing:
        for line in listing:
            parts = line.split("#", 1)[0].split()
            if len(parts) == 2 and parts[0] in host_platforms():
                names.add(parts[1])
    return names


def is_flaky(test_id, flaky):
    """test_id is Module.Suite.test (no parentheses). A list entry matches a
    trailing run of its dotted parts, or a whole suite."""
    parts = test_id.split(".")
    for entry in flaky:
        wanted = entry.split(".")
        for start in range(len(parts)):
            if parts[start:start + len(wanted)] == wanted:
                return True
    return False


def read_xunit(paths):
    """Returns (failed, skipped): failed maps test id to its rerun filter, skipped holds (test, reason)."""
    failed, skipped = {}, []
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            continue  # A run that died while writing: no list, so it counts as a crash.
        for case in root.iter("testcase"):
            suite, name = case.get("classname", ""), case.get("name", "")
            test_id = (suite + "." + name).split("(")[0]
            if case.find("failure") is not None or case.find("error") is not None:
                failed[test_id] = re.escape(suite + "/" + name)
            skip = case.find("skipped")
            if skip is not None:
                reason = (skip.text or skip.get("message") or "").strip()
                skipped.append((test_id, reason or f"opt-in test with no stated reason: {test_id}"))
    return failed, skipped


def xctest_failures(log_text):
    """XCTest failures from the console log (its xUnit file exists only with --parallel)."""
    failed = {}
    for match in re.finditer(r"Test Case '-?\[?([^' \]]+)[ .]([^' \]]+)\]?' failed", log_text):
        suite, name = match.group(1), match.group(2)
        failed[suite + "." + name] = re.escape(suite + "/" + name)
    return failed


def summary(lines):
    """Prints lines and appends them to the job summary when there is one."""
    print("\n".join(lines))
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n\n")


def descendants(root):
    """The process ids below root, from `ps` (parents before children)."""
    listing = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 2:
            children.setdefault(int(fields[1]), []).append(int(fields[0]))
    found, queue = [], [root]
    while queue:
        for child in children.get(queue.pop(0), []):
            found.append(child)
            queue.append(child)
    return found


def report_hang(root, log):
    """Writes what each process of a silent run is doing: its command line and,
    on macOS, a few seconds of `sample` (all threads' stacks)."""
    def emit(text):
        data = text.encode("utf-8", "replace")
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        log.write(data)
    for pid in [root] + descendants(root):
        command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        emit(f"\n=== hang guard: process {pid}: {command}\n")
        if sys.platform == "darwin":
            sampled = subprocess.run(["sample", str(pid), "3", "-mayDie"], capture_output=True, text=True, timeout=60)
            emit(sampled.stdout + sampled.stderr)


def run(command, cwd, log_path, silence_limit=0):
    """Runs a command, streaming its output to the console and a log. Returns (status, text, hung).

    With silence_limit (seconds), a run that prints nothing for that long is
    taken as hung: its processes' stacks go to the log, then it is stopped."""
    print("+ " + " ".join(command), flush=True)
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    lines = queue.Queue()

    def read():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)  # End of output.

    threading.Thread(target=read, daemon=True).start()
    chunks, hung = [], False
    with open(log_path, "wb") as log:
        while True:
            try:
                line = lines.get(timeout=silence_limit or None)
            except queue.Empty:
                hung = True
                message = f"\n::error title=Hang guard::no output for {silence_limit // 60} minutes; stopping the run\n"
                sys.stdout.write(message)
                sys.stdout.flush()
                log.write(message.encode())
                report_hang(process.pid, log)
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(process.pid, sig)
                    except ProcessLookupError:
                        break
                    try:
                        process.wait(timeout=15)
                        break
                    except subprocess.TimeoutExpired:
                        pass
                break
            if line is None:
                break
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            log.write(line)
            chunks.append(line)
    return process.wait(), b"".join(chunks).decode("utf-8", "replace"), hung


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, help="package directory, relative to the repository root")
    parser.add_argument("--scratch-path", help="SwiftPM scratch path")
    parser.add_argument("--log", default=None, help="directory for logs and xUnit files")
    parser.add_argument("--swift", default="swift", help="the swift command")
    parser.add_argument("--silence-limit", type=int, default=20,
                        help="minutes without output after which the run counts as hung (0: no limit)")
    parser.add_argument("extra", nargs="*", help="more arguments for swift test")
    options = parser.parse_args()

    package = os.path.join(REPO, options.package)
    log_dir = os.path.abspath(options.log or os.path.join(package, ".build-ci-logs"))
    os.makedirs(log_dir, exist_ok=True)
    label = options.package.replace("/", "-")
    xunit = os.path.join(log_dir, label + ".xml")
    for stale in glob.glob(os.path.join(log_dir, label + "*.xml")):
        os.remove(stale)

    scratch = ["--scratch-path", os.path.abspath(options.scratch_path)] if options.scratch_path else []
    base = [options.swift, "test"] + scratch
    status, text, hung = run(base + ["--xunit-output", xunit] + options.extra, package,
                             os.path.join(log_dir, label + ".log"), options.silence_limit * 60)

    reports = sorted(glob.glob(os.path.join(log_dir, label + "*.xml")))
    failed, skipped = read_xunit(reports)
    failed.update(xctest_failures(text))

    title = f"### `{options.package}` on {sys.platform} {platform.machine()}"
    skip_lines = []
    if skipped:
        reasons = {}
        for _test, reason in skipped:
            reasons[reason] = reasons.get(reason, 0) + 1
        skip_lines = [f"Skipped {len(skipped)} tests:"]
        skip_lines += [f"- {count} × {reason}" for reason, count in sorted(reasons.items())]

    if hung:
        summary([title, f"**Failed:** no output for {options.silence_limit} minutes, so the run was stopped. "
                        "The log ends with each test process's stacks."] + skip_lines)
        return 1
    if status == 0:
        summary([title, "All tests passed."] + skip_lines)
        return 0
    if not failed:
        summary([title, f"**Failed:** `swift test` exited with {status} and reported no failing test "
                        "(a crash or a process-audit failure). See the log."] + skip_lines)
        return 1

    flaky = load_flaky()
    real = sorted(test for test in failed if not is_flaky(test, flaky))
    if real:
        summary([title, f"**Failed:** {len(real)} tests. They were not rerun."]
                + [f"- `{test}`" for test in real] + skip_lines)
        return 1

    # Only listed tests failed: each one must pass on its own.
    results = []
    still_failing = []
    for test, pattern in sorted(failed.items()):
        rerun_log = os.path.join(log_dir, label + "-rerun-" + re.sub(r"[^A-Za-z0-9.]", "_", test) + ".log")
        rerun_status, _, _ = run(base + ["--skip-build", "--filter", pattern], package, rerun_log,
                                 options.silence_limit * 60)
        results.append(f"- `{test}`: {'passed alone' if rerun_status == 0 else 'also failed alone'}")
        if rerun_status != 0:
            still_failing.append(test)
        else:
            print(f"::warning title=Known flaky test::{test} failed in the full run and passed alone")
    if still_failing:
        summary([title, f"**Failed:** {len(still_failing)} known-flaky tests also failed alone."] + results + skip_lines)
        return 1
    summary([title, "Passed, apart from known-flaky tests that failed in the full run and passed alone:"]
            + results + skip_lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
