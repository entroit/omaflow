#!/usr/bin/env python3
"""Profile the production cleanup path without saving dictated text.

Pass a local UTF-8 transcript file. Optional --prompt selects a candidate
system prompt. Output contains timings, safety status and an output hash;
use --show-text only when inspecting the edited wording is appropriate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("transcript", type=Path)
    parser.add_argument("--prompt", type=Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--show-text", action="store_true")
    parser.add_argument("--require", action="append", default=[],
                        help="Case-insensitive phrase the output must retain; repeatable")
    parser.add_argument("--forbid", action="append", default=[],
                        help="Case-insensitive phrase the output must remove; repeatable")
    args = parser.parse_args()
    if not 1 <= args.runs <= 20:
        parser.error("--runs must be between 1 and 20")
    binary = os.environ.get(
        "OMAFLOW_BINARY", str(Path(__file__).resolve().parents[1] / "target/release/omaflow")
    )
    payload = {"transcript": args.transcript.read_text()}
    if args.prompt:
        payload["prompt"] = args.prompt.read_text()
    times = []
    failed = False
    for index in range(args.runs):
        started = time.monotonic()
        result = subprocess.run(
            [binary, "evaluate"], input=json.dumps(payload), text=True,
            capture_output=True, check=True, timeout=660,
        )
        elapsed = round((time.monotonic() - started) * 1000)
        times.append(elapsed)
        value = json.loads(result.stdout)
        folded = value["text"].casefold()
        checks = {"required": [phrase.casefold() in folded for phrase in args.require],
                  "forbidden_removed": [phrase.casefold() not in folded for phrase in args.forbid]}
        passed = all(checks["required"] + checks["forbidden_removed"])
        failed |= not passed
        metrics = [json.loads(line.removeprefix("omaflow: inference "))
                   for line in result.stderr.splitlines()
                   if line.startswith("omaflow: inference ")]
        report = {"run": index + 1, "wall_ms": elapsed, "requests": metrics,
                  "fallback": value["fallback"],
                  "has_warning": bool(value.get("warning")),
                  "phrase_checks": checks,
                  "phrase_checks_passed": passed if args.require or args.forbid else None,
                  "output_sha256": hashlib.sha256(value["text"].encode()).hexdigest()}
        if args.show_text:
            report["text"] = value["text"]
        print(json.dumps(report, ensure_ascii=False), flush=True)
    print(json.dumps({"median_ms": statistics.median(times),
                      "note": "First run may include loading or an uncached prompt. "
                              "Hashes measure identical output, not accuracy."}))
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
