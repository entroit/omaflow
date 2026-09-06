#!/usr/bin/env python3
"""Judge a live-segment rule against a checked transcript.

    tools/segment_compare.py RECORDING.wav REFERENCE.txt

Runs `omaflow segment-file` (the real segmenter and meter, with the installed
config) so the file is transcribed whole and in segments, then reports the
word error rate of each against the human-checked reference, the words on
either side of every cut, peak speech-server VRAM and wall time.

Recordings must be 16 kHz mono 16-bit WAV. Keep personal recordings under
tools/data/local/, which is ignored by git. Set OMAFLOW_BINARY to test a
build other than the installed one.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path


def words(text):
    return re.findall(r"[\w']+", text.lower())


def wer(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    if not r:
        return 0.0, 0, 0, 0
    d = list(range(len(h) + 1))
    ops = [[(0, 0, 0)] * (len(h) + 1) for _ in range(len(r) + 1)]
    for j in range(len(h) + 1):
        ops[0][j] = (0, j, 0)
    for i in range(1, len(r) + 1):
        prev, d = d, [i] + [0] * len(h)
        ops[i][0] = (0, 0, i)
        for j in range(1, len(h) + 1):
            sub = prev[j - 1] + (r[i - 1] != h[j - 1])
            ins, dele = d[j - 1] + 1, prev[j] + 1
            d[j] = min(sub, ins, dele)
            if d[j] == sub:
                s, x, y = ops[i - 1][j - 1]
                ops[i][j] = (s + (r[i - 1] != h[j - 1]), x, y)
            elif d[j] == ins:
                s, x, y = ops[i][j - 1]
                ops[i][j] = (s, x + 1, y)
            else:
                s, x, y = ops[i - 1][j]
                ops[i][j] = (s, x, y + 1)
    s, x, y = ops[len(r)][len(h)]
    return d[len(h)] / len(r), s, x, y


def peak_vram(stop):
    peak = [0]

    def poll():
        while not stop.is_set():
            out = subprocess.run(
                ["nvidia-smi", "--query-compute-apps=process_name,used_memory",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True,
            ).stdout
            for line in out.splitlines():
                if "nemo-speech" in line:
                    peak[0] = max(peak[0], int(line.split(",")[1]))
            time.sleep(0.2)

    thread = threading.Thread(target=poll, daemon=True)
    thread.start()
    return peak, thread


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    wav, reference = Path(sys.argv[1]), Path(sys.argv[2]).read_text()
    binary = os.environ.get("OMAFLOW_BINARY", "omaflow")
    stop = threading.Event()
    peak, thread = peak_vram(stop)
    started = time.monotonic()
    run = subprocess.run([binary, "segment-file", str(wav)], capture_output=True, text=True)
    elapsed = time.monotonic() - started
    stop.set()
    thread.join()
    if run.returncode != 0:
        sys.exit(run.stderr.strip() or "segment-file failed")
    report = json.loads(run.stdout)
    segments = report["segments"]
    joined = " ".join(s["text"] for s in segments if s["text"])

    print(f"{wav.name}: {report['seconds']:.1f} s, "
          f"rule {report['live_segment_seconds']} s / 700 ms + {report['live_segment_tiers']}")
    for label, text in (("whole", report["whole"]), ("segmented", joined)):
        rate, sub, ins, dele = wer(reference, text)
        print(f"  {label:9} WER {rate:6.1%}  sub {sub} ins {ins} del {dele}  words {len(words(text))}")
    print(f"  segments  {len(segments)}  "
          f"longest {max(s['end'] - s['start'] for s in segments):.1f} s  "
          f"peak speech VRAM {peak[0]} MiB  wall {elapsed:.1f} s")
    for before, after in zip(segments, segments[1:]):
        left = " ".join(words(before["text"])[-3:])
        right = " ".join(words(after["text"])[:3])
        print(f"  cut at {before['end']:6.1f} s: ...{left} | {right}...")
    whole_words, joined_words = words(report["whole"]), words(joined)
    if whole_words != joined_words:
        missing = [w for w in whole_words if w not in joined_words]
        extra = [w for w in joined_words if w not in whole_words]
        print(f"  differs from whole: missing {missing[:8]} extra {extra[:8]}")


if __name__ == "__main__":
    main()
