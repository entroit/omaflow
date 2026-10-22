#!/usr/bin/env python3
"""Exercise the built HTTP clients with synthetic data and loopback servers only."""
from concurrent.futures import ThreadPoolExecutor
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
import tomllib
import wave

from private_storage_test import daemon, wait_until

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"
TEXT = "Send the report."
KEY = "review-secret\\credential"
OPENAI = {"choices": [{"message": {"content": TEXT}, "finish_reason": "stop"}]}
OLLAMA = {"message": {"content": TEXT}, "done": True, "done_reason": "stop"}
TEST_ENV = {key: value for key, value in os.environ.items()
            if key.lower() not in {"http_proxy", "https_proxy", "all_proxy", "no_proxy",
                                   "ftp_proxy", "curl_ca_bundle", "ssl_cert_file",
                                   "ssl_cert_dir", "sslkeylogfile"}
            and not key.startswith("OMAFLOW_")}


@contextmanager
def server(responses):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.do_POST()

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            spec = responses[min(len(requests), len(responses) - 1)]
            requests.append({"time": time.monotonic(), "body": raw,
                             "headers": self.headers, "path": self.path, "method": self.command})
            time.sleep(spec.get("delay", 0))
            body = spec.get("body", OPENAI)
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            try:
                self.send_response(spec.get("status", 200))
                self.send_header("Content-Length", str(len(data) + spec.get("missing", 0)))
                self.send_header("Connection", "close")
                if "retry_after" in spec:
                    self.send_header("Retry-After", spec["retry_after"])
                if "location" in spec:
                    self.send_header("Location", spec["location"])
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
    env = dict(TEST_ENV, HOME=str(base), OMAFLOW_CONFIG=str(config),
               XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(base / "config"),
               XDG_CACHE_HOME=str(base / "cache"), XDG_STATE_HOME=str(base / "state"),
               XDG_DATA_HOME=str(base / "data"), CURL_HOME=str(base), PATH="/usr/bin")

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

    with server([{}]) as (proxy, intercepted), server([{}]) as (origin, requests):
        configure(origin, key=KEY)
        result = run(extra_env={"http_proxy": proxy, "https_proxy": proxy,
                                "ALL_PROXY": proxy, "all_proxy": proxy,
                                "NO_PROXY": "", "no_proxy": ""})
        assert result.returncode == 0 and result.stdout == TEXT, result.stderr
        assert len(requests) == 1 and KEY.encode() not in requests[0]["body"]
        assert not intercepted, intercepted
    print("PASS ambient proxies cannot receive local private model requests")

    with server([{}]) as (target, redirected):
        with server([{"status": 307, "location": f"{target}/v1/chat/completions"}]) as (origin, requests):
            configure(origin, key=KEY)
            (base / ".curlrc").write_text(f'location\nurl = "{target}/v1/chat/completions"\n')
            result = run("test-cleanup", "")
            assert result.returncode != 0 and not json.loads(result.stdout)["ok"], result.stderr
            assert len(requests) == 1 and not redirected
    (base / ".curlrc").write_text("retry = 5\nretry-all-errors\nretry-delay = 1\n")
    print("PASS redirects and personal curl defaults cannot add private-data destinations")

    for endpoint in [
        "https://fixture:URL_SECRET@example.invalid/v1/chat/completions",
        "https://example.invalid/private?api_key=URL_SECRET/v1/chat/completions",
        "https://example.invalid/#URL_SECRET/v1/chat/completions",
        "http://gpu.lan/v1/chat/completions",
        "http://127.1/v1/chat/completions",
        "http://127.0.0.1%2eexample.invalid/v1/chat/completions",
    ]:
        config.write_text('[cleanup]\nengine="openai"\nendpoint=' + json.dumps(endpoint) + '\n')
        result = run("effective-config", "")
        assert result.returncode != 0, endpoint
        assert "URL_SECRET" not in result.stdout + result.stderr
    print("PASS URL credentials and unauthenticated remote HTTP fail before state publication or network I/O")

    with server([{}]) as (origin, requests), server([{}]) as (other, other_requests):
        configure(origin, key=KEY)
        for fields, expected_key in [
            ({"cleanup_endpoint": f"{other}/v1/chat/completions"}, None),
            ({"cleanup_endpoint": f"{origin}/alternate/v1/chat/completions",
              "cleanup_model": "another-model"}, KEY),
            ({"cleanup_endpoint": f"{other}/v1/chat/completions",
              "cleanup_api_key": 'replacement\\key"quoted'}, 'replacement\\key"quoted'),
            ({"cleanup_api_key": ""}, None),
        ]:
            result = subprocess.run([str(BINARY), "test-cleanup", "-"],
                                    input=json.dumps(fields), text=True, capture_output=True,
                                    env=env, timeout=5)
            assert result.returncode == 0, result.stdout + result.stderr
            received = (other_requests if fields.get("cleanup_endpoint", "").startswith(other)
                        else requests)[-1]
            assert received["headers"].get("Authorization") == (
                f"Bearer {expected_key}" if expected_key else None), received
        assert tomllib.loads(config.read_text())["cleanup"]["api_key"] == KEY
    print("PASS unsaved model tests keep keys within one origin and honor explicit replacement or removal")

    with server([{}]) as (target, injected):
        configure("https://127.0.0.1:1", key=KEY)
        for fields in [
            {"cleanup_api_key": f"synthetic\nurl = {target}/injected\n#"},
            {"cleanup_api_key": "synthetic\rX-Injected: yes"},
            {"cleanup_api_key": "x" * 4097},
            {"cleanup_endpoint": f"{target}/v1/chat/completions",
             "cleanup_model": "synthetic\nprivate-model"},
        ]:
            result = subprocess.run([str(BINARY), "test-cleanup", "-"],
                                    input=json.dumps(fields), text=True, capture_output=True,
                                    env=env, timeout=5)
            report = json.loads(result.stdout)
            assert result.returncode != 0 and report["kind"] == "configuration", report
            assert "synthetic" not in result.stdout + result.stderr
        assert not injected, injected
    print("PASS unsaved keys cannot inject curl options and invalid fields cause no model request")

    for engine, reply in [("openai", OPENAI), ("ollama", OLLAMA)]:
        for first in [{"status": 503, "body": {"error": "busy"}},
                      {"status": 200, "body": b'{"partial":', "missing": 100}]:
            with server([first, {"body": reply}]) as (origin, requests):
                configure(origin, engine, key=KEY)
                result = run()
                assert result.returncode == 0, result.stderr
                assert result.stdout == TEXT, result.stdout
                assert len(requests) == 2, requests
                assert requests[0]["body"] == requests[1]["body"]
                assert all(request["headers"]["Authorization"] == f"Bearer {KEY}"
                           for request in requests)
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

    reflected = "PRIVATE_CONTEXT_REFLECTED_AS_FINISH_REASON"
    for engine in ["openai", "ollama"]:
        reply = ({"choices": [{"message": {"content": TEXT}, "finish_reason": reflected}]}
                 if engine == "openai" else
                 {"message": {"content": TEXT}, "done": True, "done_reason": reflected})
        with server([{"body": reply}]) as (origin, requests):
            configure(origin, engine)
            result = run("evaluate", json.dumps({"transcript": TEXT}))
            report = json.loads(result.stdout)
            assert report["fallback"] and report["text"] == TEXT, report
            assert reflected not in result.stdout + result.stderr
            assert len(requests) == 1
    print("PASS model completion metadata cannot echo private context into errors or logs")

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
                    assert KEY.encode() not in Path(f"/proc/{child}/environ").read_bytes()
                credentials = [descriptor for child in children
                               for descriptor in Path(f"/proc/{child}/fd").iterdir()
                               if descriptor.readlink().as_posix().startswith("/memfd:omaflow-curl-auth ")]
                assert len(credentials) == 1
                assert credentials[0].stat().st_mode & 0o777 == 0o600
                assert credentials[0].stat().st_nlink == 0
                assert not list(runtime.glob("omaflow-curl-*.conf"))
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

    with server([{"delay": .1}]) as (origin, requests):
        configure(origin)
        keys = [f"{KEY}-{index}" for index in range(4)]

        def check_key(key):
            fields = {"cleanup_engine": "openai", "cleanup_model": "review-model",
                      "cleanup_endpoint": f"{origin}/v1/chat/completions", "cleanup_api_key": key}
            result = subprocess.run([str(BINARY), "test-cleanup", "-"],
                                    input=json.dumps(fields), text=True, capture_output=True,
                                    env=env, timeout=5)
            assert result.returncode == 0 and json.loads(result.stdout)["ok"], result.stderr
            assert key not in result.stdout + result.stderr

        with ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(check_key, keys))
        assert sorted(request["headers"]["Authorization"] for request in requests) == [
            f"Bearer {key}" for key in keys]
        assert not list(runtime.glob("omaflow-curl-*.conf"))
    print("PASS simultaneous model tests keep distinct credentials isolated")

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
        assert result.returncode == 0 and json.loads(result.stdout)["ok"]
        assert len(requests) == 1 and requests[0]["headers"]["Authorization"] == f"Bearer {KEY}"
        assert KEY not in result.stdout + result.stderr
        assert not (base / "missing-runtime").exists()
    print("PASS credentials need no runtime directory and create no filesystem configuration")

    reply = OPENAI | {"text": TEXT}
    with server([{"body": reply}]) as (origin, requests), server([{"body": reply}]) as (other, other_requests):
        def plant_credentials(home, _runtime, _state):
            (home / "bin/curl").unlink()
            (home / "config.toml").write_text(
                '[behavior]\nmodels_configured=true\nkeep_models_loaded=false\n'
                '[backend]\nengine="openai"\nmodel="review-model"\n'
                f'endpoint="{origin}/v1/audio/transcriptions"\n'
                f'health_endpoint="{other}/health-other"\napi_key={json.dumps(KEY)}\n'
                '[cleanup]\nenabled=true\nengine="openai"\nmodel="review-model"\n'
                f'endpoint="{origin}/v1/chat/completions"\napi_key={json.dumps(KEY)}\n'
                f'[journal]\nfolder="{home / "Journal"}"\n'
                f'[todos]\nfolder="{home / "To-dos"}"\n'
            )

        with daemon(plant_credentials) as (home, daemon_runtime, _state, snapshot, send):
            saved_path = home / "config.toml"
            isolated = dict(TEST_ENV, HOME=str(home), XDG_RUNTIME_DIR=str(daemon_runtime),
                            XDG_STATE_HOME=str(home / "state"), OMAFLOW_CONFIG=str(saved_path),
                            XDG_CONFIG_HOME=str(home / "config"),
                            XDG_CACHE_HOME=str(home / "cache"), XDG_DATA_HOME=str(home / "data"),
                            CURL_HOME=str(home), PATH=f"{home / 'bin'}:/usr/bin")

            def saved():
                return tomllib.loads(saved_path.read_text())

            def change(fields, predicate):
                send("configure:" + json.dumps({"key": "models", "value": fields}))
                wait_until(lambda: predicate(saved()))

            wait_until(lambda: any(r["path"] == "/health-other" for r in other_requests))
            assert all(r["headers"].get("Authorization") is None for r in other_requests)
            change({"speech_health_endpoint": f"{origin}/health-same"},
                   lambda value: value["backend"]["health_endpoint"] == f"{origin}/health-same")
            wait_until(lambda: any(r["path"] == "/health-same" for r in requests), timeout=8)
            assert all(r["headers"].get("Authorization") == f"Bearer {KEY}"
                       for r in requests if r["path"] == "/health-same")

            recording = home / "synthetic.wav"
            with wave.open(str(recording), "wb") as wav:
                wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                wav.writeframes(b"\x01\x40" * 1600)

            for role, section, path in [("cleanup", "cleanup", "/v1/chat/completions"),
                                        ("speech", "backend", "/v1/audio/transcriptions")]:
                for destination, explicit, expected in [
                    (f"{origin}/alternate{path}", None, KEY),
                    (f"{other}{path}", None, ""),
                    (f"{origin}{path}", "replacement-key", "replacement-key"),
                    (f"{origin}{path}", "", ""),
                ]:
                    fields = {f"{role}_endpoint": destination, f"{role}_model": "changed-model"}
                    if explicit is not None:
                        fields[f"{role}_api_key"] = explicit
                    change(fields, lambda value: value[section]["endpoint"] == destination
                           and value[section]["api_key"] == expected)
                    command = [str(BINARY), "cleanup"] if role == "cleanup" else [
                        str(BINARY), "transcribe-file", str(recording)]
                    result = subprocess.run(command, input=TEXT, text=True, capture_output=True,
                                            env=isolated, timeout=8)
                    assert result.returncode == 0 and result.stdout.strip() == TEXT, result.stderr
                    received = [r for r in (other_requests if destination.startswith(other) else requests)
                                if r["method"] == "POST"][-1]
                    assert received["headers"].get("Authorization") == (
                        f"Bearer {expected}" if expected else None), received
            for broken in [
                '[cleanup]\napi_key = PRIVATE_CONFIG_SECRET\n',
                '[behavior]\npaste_mode = "PRIVATE_CONFIG_SECRET"\n',
            ]:
                saved_path.write_text(broken)
                for command in ["reload-config", "configure:" + json.dumps({
                    "key": "models", "value": {"cleanup_model": "changed-again"}})]:
                    serial = snapshot()["feedback_serial"]
                    send(command)
                    wait_until(lambda: snapshot()["feedback_serial"] > serial)
                    state = snapshot()
                    assert state["feedback_error"], state
                    assert "PRIVATE_CONFIG_SECRET" not in json.dumps(state)
                    assert "PRIVATE_CONFIG_SECRET" not in (home / "daemon.log").read_text()
                    assert saved_path.read_text() == broken
        print("PASS daemon saves and audio/text requests bind retained keys to one origin; health follows the same rule")
        print("PASS daemon reload and save errors do not publish malformed config secrets")

        # No daemon runs while selecting built-in endpoints, so these assertions
        # cannot contact installed model services on their fixed ports.
        for kind, model, section in [("speech", "nvidia/parakeet-tdt-0.6b-v3", "backend"),
                                     ("cleanup", "gemma4:e4b", "cleanup")]:
            configure(origin, key=KEY)
            config.write_text(config.read_text() +
                              f'\n[backend]\nengine="openai"\nendpoint="{origin}/transcribe"\n'
                              f'api_key={json.dumps(KEY)}\n')
            result = subprocess.run([str(BINARY), "model-select", kind, model],
                                    env=env, text=True, capture_output=True, timeout=5)
            assert result.returncode == 0, result.stderr
            assert tomllib.loads(config.read_text())[section]["api_key"] == ""
        print("PASS switching to built-in speech or cleanup clears the previous provider key")

    for broken in [
        '[cleanup]\napi_key = PRIVATE_CONFIG_SECRET\n',
        '[behavior]\npaste_mode = "PRIVATE_CONFIG_SECRET"\n',
    ]:
        config.write_text(broken)
        for command in [["effective-config"], ["test-cleanup"],
                        ["model-select", "cleanup", "gemma4:e4b"]]:
            result = subprocess.run([str(BINARY), *command], env=env, text=True,
                                    capture_output=True, timeout=5)
            assert result.returncode != 0, command
            assert "PRIVATE_CONFIG_SECRET" not in result.stdout + result.stderr
        assert config.read_text() == broken
    print("PASS malformed config load, connection test and save errors omit private values")
