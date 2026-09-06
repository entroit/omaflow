#!/usr/bin/env python3
"""Production safety gate on 180 real spoken-to-written pairs.

Fail on any changed ordered numeric sequence, or loss of more than one distinct
content word. The word score tolerates one inflection/spelling difference and
is reported separately; it is not an exact semantic-accuracy measurement.
The original spoken numeric sequence is also accepted unchanged.
Raw fallbacks are safe preservation, counted explicitly, not successful edits.
"""
import collections
import json
from pathlib import Path
import re
import sys
from cleanup_common import configuration, evaluate
from itn_score import ordered_digits, SMALL, TENS, SCALES, ORDINALS

cfg = configuration()
if len(sys.argv) > 1 and sys.argv[1] != "-":
    cfg["system_prompt"] = Path(sys.argv[1]).read_text()
cases = json.loads((Path(__file__).parent / "data/itn_sample.json").read_text())
CLASSES = ["CARDINAL", "DATE", "DECIMAL", "FRACTION", "MEASURE", "MONEY", "ORDINAL", "TELEPHONE", "TIME"]
assert collections.Counter(case["class"] for case in cases) == {name: 20 for name in CLASSES}, "itn_sample.json must hold 20 rows per class"
number_words = set(SMALL) | set(TENS) | set(SCALES) | set(ORDINALS)
number_words |= {word + "s" for word in ORDINALS}
number_words |= {"point", "percent", "sil", "oh", "quarter", "quarters", "half", "halves"}

def words(text):
    return set(re.findall(r"[a-z]{3,}", text.lower())) - number_words

stats = collections.defaultdict(lambda: [0,0,0,0,0])
bad = []
for case in cases:
    result, _ = evaluate(cfg, cfg["model"], case["spoken"])
    output = result["text"]
    fallback = result["fallback"]
    changed = not fallback and ordered_digits(output) not in {ordered_digits(case["written"]), ordered_digits(case["spoken"])}
    dropped = len(words(case["spoken"]) - words(output))
    score = stats[case["class"]]
    score[0] += 1
    score[1] += not changed
    score[2] += dropped == 0
    score[3] += not changed and dropped == 0
    score[4] += fallback
    if changed or dropped > 1:
        bad.append((case, output, changed, dropped))
print(f"{'class':10} {'n':>3} {'number-safe':>12} {'no-dropped':>11} {'both':>6} {'raw fallback':>13}")
total = [0]*5
for category, score in sorted(stats.items()):
    print(f"{category:10} {score[0]:3} {score[1]/score[0]:11.0%} {score[2]/score[0]:10.0%} {score[3]/score[0]:5.0%} {score[4]:13}")
    total = [a+b for a,b in zip(total, score)]
print(f"{'TOTAL':10} {total[0]:3} {total[1]/total[0]:11.0%} {total[2]/total[0]:10.0%} {total[3]/total[0]:5.0%} {total[4]:13}")
print(f"\n{len(bad)} problem cases:")
for case, output, changed, dropped in bad[:12]:
    print(f"\n[{case['class']}] numeric-change={changed} dropped={dropped}\n S: {case['spoken']}\n W: {case['written']}\n O: {output}")
if bad:
    raise SystemExit(1)
