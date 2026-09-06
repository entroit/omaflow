"""Shared production cleanup evaluation, with bounded requests and explicit results."""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OMAFLOW_BINARY", ROOT / "target/release/omaflow"))


def configuration():
    result = subprocess.run([str(BINARY), "effective-config"], capture_output=True,
                            text=True, check=True, timeout=5)
    return json.loads(result.stdout)["cleanup"]


def evaluate(config, model, transcript, clipboard="", window=""):
    started = time.monotonic()
    body = {"transcript": transcript, "prompt": config["system_prompt"],
            "model": model, "clipboard": clipboard, "vocabulary": config["custom_vocabulary"]}
    if window:
        body["window"] = {"class": "evaluation", "title": window}
    result = subprocess.run([str(BINARY), "evaluate"], input=json.dumps(body),
                            capture_output=True, text=True, check=True, timeout=125)
    value = json.loads(result.stdout)
    if os.environ.get("OMAFLOW_EVAL_JSONL"):
        with open(os.environ["OMAFLOW_EVAL_JSONL"], "a") as output:
            output.write(json.dumps({**body, **value, "elapsed_ms": round((time.monotonic()-started)*1000)}) + "\n")
    return value, round((time.monotonic() - started) * 1000)


def request(config, model, transcript, clipboard="", window=""):
    value, elapsed = evaluate(config, model, transcript, clipboard, window)
    return value["text"], elapsed
