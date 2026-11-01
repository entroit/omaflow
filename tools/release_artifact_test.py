#!/usr/bin/env python3
"""Exercise release acquisition with isolated external-command fixtures.

Downloads come from a fixture curl. Signatures are real: a test key signs the
statement, and the verifier checks it with the system OpenSSL, through a
wrapper that only records the call.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMMIT = "a" * 40
VERSION = "0.22.0"
sys.path.insert(0, str(ROOT / "scripts"))
import release_artifact  # noqa: E402


def openssl(*args):
    subprocess.run(["/usr/bin/openssl", *args], check=True, capture_output=True, timeout=15)


with tempfile.TemporaryDirectory(prefix="omaflow-artifact-test-") as temporary:
    base = Path(temporary)
    configuration = base / "configuration.json"
    log = base / "commands.jsonl"
    sentinel = base / "executed"
    asset = base / "asset"
    original = ("#!/usr/bin/python3\nfrom pathlib import Path\n"
                f"Path({str(sentinel)!r}).write_text('executed')\n").encode()
    digest = hashlib.sha256(original).hexdigest()
    signature = base / "signature"
    helper = base / "release_artifact.py"
    curl = base / "curl"
    checker = base / "openssl"
    key, other_key, public = base / "key.pem", base / "other.pem", base / "public.pem"
    openssl("genpkey", "-algorithm", "ed25519", "-out", str(key))
    openssl("genpkey", "-algorithm", "ed25519", "-out", str(other_key))
    openssl("pkey", "-in", str(key), "-pubout", "-out", str(public))

    def sign(destination, commit=COMMIT, version=VERSION, signer=key):
        statement = base / "statement"
        statement.write_bytes(release_artifact.statement(commit, version, len(original), digest))
        openssl("pkeyutl", "-sign", "-rawin", "-inkey", str(signer),
                "-in", str(statement), "-out", str(destination))

    curl.write_text(f'''#!/usr/bin/python3
import json
from pathlib import Path
import sys
configuration = json.loads(Path({str(configuration)!r}).read_text())
args = sys.argv[1:]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps({{"tool": "curl", "args": args}}) + "\\n")
assert args[0] == "--disable"
assert args[args.index("--proto") + 1] == "=https"
assert args[args.index("--proto-redir") + 1] == "=https"
assert args[args.index("--max-redirs") + 1] == "3"
destination = Path(args[args.index("--output") + 1])
kind = "signature" if args[-1].endswith(".sig") else "executable"
if configuration.get("curl_fail") == kind:
    destination.write_bytes(b"partial")
    sys.exit(7)
source = configuration["signature" if kind == "signature" else "binary"]
destination.write_bytes(Path(source).read_bytes())
''')
    checker.write_text(f'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps({{"tool": "openssl", "args": args, "env": dict(os.environ)}}) + "\\n")
os.execv("/usr/bin/openssl", ["/usr/bin/openssl", *args])
''')
    curl.chmod(0o700)
    checker.chmod(0o700)
    source = (ROOT / "scripts/release_artifact.py").read_text()
    shipped_key = re.search(r'PUBLIC_KEY = """(.*?)"""', source, re.S).group(1)
    assert source.count('"/usr/bin/curl"') == source.count('"/usr/bin/openssl"') == 1
    assert source.count(shipped_key) == 1 and "/usr/bin/gh" not in source
    helper.write_text(source.replace('"/usr/bin/curl"', repr(str(curl)))
                      .replace('"/usr/bin/openssl"', repr(str(checker)))
                      .replace(shipped_key, public.read_text()))

    def reset(**options):
        asset.write_bytes(original)
        sign(signature)
        configuration.write_text(json.dumps({"binary": str(asset), "signature": str(signature), **options}))
        log.write_text("")

    def commands():
        return [json.loads(line) for line in log.read_text().splitlines()]

    def tools():
        return [call["tool"] for call in commands()]

    def run(name, success=True, **overrides):
        directory = base / name
        options = {"commit": COMMIT, "version": VERSION, "bytes": str(len(original)),
                   "sha256": digest, "destination": str(directory), **overrides}
        argv = ["/usr/bin/python3", "-I", str(helper)]
        for option, value in options.items():
            argv.extend(["--" + option, value])
        result = subprocess.run(argv, env=dict(os.environ, GH_TOKEN="fixture-secret",
                                              GITHUB_TOKEN="fixture-secret"),
                                capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert not result.stdout, result.stdout
        assert not sentinel.exists(), "Acquisition executed the release executable"
        assert not list(directory.glob(".artifact-*")), "Temporary downloads were retained"
        if success:
            assert (directory / "omaflow").read_bytes() == original
            assert (directory / "omaflow").stat().st_mode & 0o777 == 0o700
            assert (directory / "omaflow.sig").read_bytes() == signature.read_bytes()
        return result

    reset()
    run("success")
    assert tools() == ["curl", "curl", "openssl"]
    calls = commands()
    urls = [call["args"][-1] for call in calls if call["tool"] == "curl"]
    expected_url = (f"https://github.com/entroit/omaflow/releases/download/commit-{COMMIT}/"
                    "omaflow-x86_64-unknown-linux-gnu")
    assert urls == [expected_url, expected_url + ".sig"]
    assert calls[1]["args"][calls[1]["args"].index("--max-filesize") + 1] == "64"
    assert calls[-1]["args"][:6] == ["pkeyutl", "-verify", "-pubin", "-inkey",
                                     calls[-1]["args"][4], "-rawin"]
    assert not {"GH_TOKEN", "GITHUB_TOKEN", "HOME"}.intersection(calls[-1]["env"])
    print("PASS acquisition checks fixed asset identity and OmaFlow's signature without credentials or execution")

    log.write_text("")
    run("success")
    assert tools() == ["openssl"]
    (base / "success/omaflow").write_bytes(b"x" * len(original))
    log.write_text("")
    run("success")
    assert tools() == ["curl", "curl", "openssl"]
    print("PASS cached bytes require fresh size, digest and signature checks; corrupt cache is replaced")

    for name, data in (("tamper", b"x" * len(original)),
                       ("truncated", original[:-1]), ("oversize", original + b"extra")):
        reset()
        asset.write_bytes(data)
        run(name, success=False)
        assert tools() == ["curl"]
        assert not (base / name / "omaflow").exists()
    print("PASS substituted, truncated and oversized executables fail before the signature or execution")

    reset(curl_fail="signature")
    run("missing-signature", success=False)
    for name, data in (("long-signature", b"x" * 65), ("short-signature", b"x" * 63)):
        reset()
        signature.write_bytes(data)
        run(name, success=False)
        assert "openssl" not in tools()
    for name, signed in (("other-key", {"signer": other_key}),
                         ("other-commit", {"commit": "b" * 40}),
                         ("other-version", {"version": "0.21.7"})):
        reset()
        sign(signature, **signed)
        run(name, success=False)
        assert tools() == ["curl", "curl", "openssl"]
        assert not (base / name / "omaflow").exists()
    reset()
    run("wrong-source", success=False, commit="b" * 40)
    print("PASS missing, malformed, foreign-key and other-release signatures cannot install executable bytes")

    reset()
    for option, value in (("commit", "../main"), ("version", "00.22.0"),
                          ("bytes", "-1"), ("bytes", str(128 * 1024 * 1024 + 1)),
                          ("sha256", "a")):
        run("invalid-input", success=False, **{option: value})
    assert not commands() and not (base / "invalid-input").exists()
    victim = base / "private-file"
    victim.write_bytes(b"keep")
    for name in ("omaflow", "omaflow.sig"):
        directory = base / ("linked-" + name)
        directory.mkdir(mode=0o700)
        (directory / name).symlink_to(victim)
        run(directory.name, success=False)
        assert victim.read_bytes() == b"keep"
    linked_directory = base / "linked-directory"
    linked_directory.symlink_to(base / "success", target_is_directory=True)
    run(linked_directory.name, success=False)
    hardlinked = base / "hardlinked-output"
    hardlinked.mkdir(mode=0o700)
    os.link(victim, hardlinked / "omaflow")
    run(hardlinked.name, success=False)
    public_directory = base / "public-directory"
    public_directory.mkdir(mode=0o755)
    run(public_directory.name, success=False)
    assert not commands()
    print("PASS invalid inputs, linked outputs and non-private directories are rejected before network")

    reset()
    run("preserved")
    previous_binary = (base / "preserved/omaflow").read_bytes()
    previous_signature = (base / "preserved/omaflow.sig").read_bytes()
    reset(curl_fail="executable")
    run("preserved", success=False, commit="b" * 40)
    assert (base / "preserved/omaflow").read_bytes() == previous_binary
    assert (base / "preserved/omaflow.sig").read_bytes() == previous_signature
    assert tools() == ["openssl", "curl"]
    reset()
    sign(signature, signer=other_key)
    run("preserved", success=False, version="0.21.7")
    assert (base / "preserved/omaflow").read_bytes() == previous_binary
    assert (base / "preserved/omaflow.sig").read_bytes() == previous_signature
    print("PASS transient download and signature failures preserve previous verified files and remove partial downloads")
