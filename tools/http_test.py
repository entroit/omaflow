#!/usr/bin/env python3
"""Exercise the built HTTP clients with synthetic data and loopback servers only."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"
TEXT = "Send the report."
KEY = "review-secret\\credential"
OPENAI = {"choices": [{"message": {"content": TEXT}, "finish_reason": "stop"}]}
OLLAMA = {"message": {"content": TEXT}, "done": True, "done_reason": "stop"}


@contextmanager
def server(responses):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            spec = responses[min(len(requests), len(responses) - 1)]
            requests.append({"time": time.monotonic(), "body": raw,
                             "headers": self.headers, "path": self.path})
            time.sleep(spec.get("delay", 0))
            body = spec.get("body", OPENAI)
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            try:
                self.send_response(spec.get("status", 200))
                self.send_header("Content-Length", str(len(data) + spec.get("missing", 0)))
                self.send_header("Connection", "close")
                if "retry_after" in spec:
                    self.send_header("Retry-After", spec["retry_after"])
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=lambda: http.serve_forever(poll_interval=.02), daemon=True)
    worker.start()
    try:
        yield f"http://127.0.0.1:{http.server_port}", requests
    finally:
        http.shutdown()
        http.server_close()
        worker.join(timeout=1)


with tempfile.TemporaryDirectory(prefix="omaflow-http-test-") as directory:
    base = Path(directory)
    runtime = base / "runtime"
    runtime.mkdir(mode=0o700)
    config = base / "config.toml"
    # The application must not inherit retries or redirects from curl defaults.
    (base / ".curlrc").write_text("retry = 5\nretry-all-errors\nretry-delay = 1\n")
    env = dict(os.environ, OMAFLOW_CONFIG=str(config), XDG_RUNTIME_DIR=str(runtime),
               CURL_HOME=str(base))

    def configure(origin, engine="openai", timeout=3, key=""):
        path = "/v1/chat/completions" if engine == "openai" else "/api/chat"
        config.write_text(
            f'[cleanup]\nenabled=true\nengine="{engine}"\n'
            f'endpoint="{origin}{path}"\nmodel="review-model"\n'
            f'timeout_seconds={timeout}\n'
            f'api_key={json.dumps(key)}\n'
            'system_prompt="PRIVATE_CUSTOM_PROMPT"\n'
            'custom_vocabulary=["PRIVATE_VOCABULARY"]\n'
        )

    def run(command="cleanup", input_text=TEXT, extra_env=None):
        return subprocess.run([str(BINARY), command], input=input_text, text=True,
                              capture_output=True, env=env | (extra_env or {}), timeout=12)

    for engine, reply in [("openai", OPENAI), ("ollama", OLLAMA)]:
        for first in [{"status": 503, "body": {"error": "busy"}},
                      {"status": 200, "body": b'{"partial":', "missing": 100}]:
            with server([first, {"body": reply}]) as (origin, requests):
                configure(origin, engine)
                result = run()
                assert result.returncode == 0, result.stderr
                assert result.stdout == TEXT, result.stdout
                assert len(requests) == 2, requests
                assert requests[0]["body"] == requests[1]["body"]
        print(f"PASS {engine}: retries 503 and interrupted 200 with identical isolated bodies")

    for status in [400, 401, 403, 404]:
        with server([{"status": status}]) as (origin, requests):
            configure(origin)
            result = run("evaluate", json.dumps({"transcript": TEXT}))
            report = json.loads(result.stdout)
            assert report["fallback"] and report["text"] == TEXT
            assert len(requests) == 1, requests
    print("PASS permanent errors are not retried and preserve the raw transcript")

    source = "The budget is fifty thousand, I mean sixty thousand euros"
    cleaned = "The budget is sixty thousand euros."
    for engine in ["openai", "ollama"]:
        reply = ({"choices": [{"message": {"content": cleaned},
                               "finish_reason": "stop"}]} if engine == "openai"
                 else {"message": {"content": cleaned}, "done": True, "done_reason": "stop"})
        with server([{"body": reply}]) as (origin, requests):
            configure(origin, engine)
            result = run("evaluate", json.dumps({"transcript": source}))
            report = json.loads(result.stdout)
            assert not report["fallback"] and report["text"] == cleaned, report
            assert report["candidate"] == cleaned
            assert len(requests) == 1
    print("PASS both cleanup protocols accept contextual corrections from the model")

    incomplete = [
        ("openai", {"choices": [{"message": {"content": "Send"},
                                 "finish_reason": "content_filter"}]}),
        ("openai", {"choices": [{"message": {"content": "Send"}}]}),
        ("ollama", {"message": {"content": "Send"}, "done": False}),
        ("ollama", {"message": {"content": "Send"}, "done_reason": "stop"}),
    ]
    for engine, reply in incomplete:
        with server([{"body": reply}]) as (origin, requests):
            configure(origin, engine)
            result = run("evaluate", json.dumps({"transcript": TEXT}))
            report = json.loads(result.stdout)
            assert report["fallback"] and report["text"] == TEXT, report
            assert len(requests) == 1
    print("PASS incomplete cleanup completion preserves the raw transcript")

    with server([{"status": 503}]) as (origin, requests):
        configure(origin)
        result = run()
        assert result.returncode != 0
        assert len(requests) == 3, requests
    print("PASS retries stop after three attempts, ignoring personal curl retry settings")

    date = format_datetime(datetime.now(timezone.utc) + timedelta(seconds=60), usegmt=True)
    for delay in ["60", date, "999999999999999999999999999"]:
        with server([{"status": 429, "retry_after": delay}, {}]) as (origin, requests):
            configure(origin, timeout=1)
            started = time.monotonic()
            result = run()
            assert result.returncode != 0
            assert len(requests) == 1, requests
            assert time.monotonic() - started < 2
    with server([{"status": 429, "retry_after": "1"}, {}]) as (origin, requests):
        configure(origin)
        result = run()
        assert result.returncode == 0, result.stderr
        assert requests[1]["time"] - requests[0]["time"] >= 1
    print("PASS Retry-After seconds, dates and extreme delays respect the overall deadline")

    with server([{"delay": 5.2}]) as (origin, requests):
        configure(origin, timeout=6)
        result = run()
        assert result.returncode == 0, result.stderr
        assert result.stdout == TEXT and len(requests) == 1
    print("PASS a healthy slow request keeps its full timeout without duplicate inference")

    for engine, reply in [("openai", OPENAI), ("ollama", OLLAMA)]:
        with server([{"body": reply, "delay": .3}]) as (origin, requests):
            configure(origin, engine, key=KEY)
            process = subprocess.Popen([str(BINARY), "test-cleanup"], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 2
                children = []
                while time.monotonic() < deadline:
                    children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
                    if requests and children:
                        break
                    time.sleep(.005)
                assert children, "curl child was not observed"
                for child in children:
                    assert KEY.encode() not in Path(f"/proc/{child}/cmdline").read_bytes()
                credentials = list(runtime.glob("omaflow-curl-*.conf"))
                assert len(credentials) == 1
                assert credentials[0].stat().st_mode & 0o777 == 0o600
                stdout, stderr = process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            report = json.loads(stdout)
            assert process.returncode == 0 and report["kind"] == "ready", (stdout, stderr)
            assert len(requests) == 1
            assert requests[0]["headers"]["Authorization"] == f"Bearer {KEY}"
            sent = json.loads(requests[0]["body"])
            assert sent["model"] == "review-model"
            assert sent["messages"] == [{"role": "system", "content": "Reply with OK."},
                                        {"role": "user", "content": "Reply with OK."}]
            assert "PRIVATE_" not in requests[0]["body"].decode()
            assert KEY not in stdout + stderr
            assert not list(runtime.glob("omaflow-curl-*.conf"))
    print("PASS saved-model tests authenticate both protocols without exposing credentials or private context")

    cases = [
        ({"status": 401, "body": {"error": KEY}}, "authentication"),
        ({"status": 403}, "authentication"),
        ({"status": 404, "body": {"error": {"code": "model_not_found"}}}, "model"),
        ({"status": 404}, "configuration"),
        ({"status": 400}, "configuration"),
        ({"status": 429}, "rate_limit"),
        ({"status": 503}, "server"),
        ({"status": 405}, "connection"),
        ({"body": {"choices": []}}, "response"),
        ({"body": b'{"choices":', "missing": 100}, "connection"),
    ]
    for spec, kind in cases:
        with server([spec]) as (origin, requests):
            configure(origin, key=KEY)
            result = run("test-cleanup", "")
            report = json.loads(result.stdout)
            assert result.returncode != 0 and not report["ok"], result.stdout
            assert report["kind"] == kind, report
            assert len(requests) == 1, requests
            assert KEY not in result.stdout + result.stderr
    print("PASS explicit model tests distinguish auth/model/rate-limit/response failures and never retry")

    with server([{"status": 404, "body": {"error": "model 'missing' not found"}}]) as (origin, requests):
        configure(origin, engine="ollama")
        result = run("test-cleanup", "")
        assert json.loads(result.stdout)["kind"] == "model" and len(requests) == 1
    print("PASS Ollama missing-model responses are identified without echoing server text")

    with server([{}]) as (origin, requests):
        configure(origin, key=KEY)
        result = run("test-cleanup", "", {"XDG_RUNTIME_DIR": str(base / "missing-runtime")})
        assert result.returncode != 0 and not requests
        assert KEY not in result.stdout + result.stderr
    print("PASS credential-storage failure sends no request and does not expose the key")
