#!/usr/bin/env python3
"""Exercise release acquisition with isolated external-command fixtures."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMMIT = "a" * 40
WORKFLOW = "entroit/omaflow/.github/workflows/release-binary.yml"


with tempfile.TemporaryDirectory(prefix="omaflow-artifact-test-") as temporary:
    base = Path(temporary)
    configuration = base / "configuration.json"
    log = base / "commands.jsonl"
    sentinel = base / "executed"
    asset = base / "asset"
    original = ("#!/usr/bin/python3\nfrom pathlib import Path\n"
                f"Path({str(sentinel)!r}).write_text('executed')\n").encode()
    digest = hashlib.sha256(original).hexdigest()
    bundle = base / "bundle.json"
    helper = base / "release_artifact.py"
    curl = base / "curl"
    gh = base / "gh"

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
kind = "attestation" if args[-1].endswith(".sigstore.json") else "executable"
if configuration.get("curl_fail") == kind:
    destination.write_bytes(b"partial")
    sys.exit(7)
source = configuration["bundle" if kind == "attestation" else "binary"]
destination.write_bytes(Path(source).read_bytes())
''')
    gh.write_text(f'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import stat
import sys
configuration = json.loads(Path({str(configuration)!r}).read_text())
args = sys.argv[1:]
with Path({str(log)!r}).open("a") as output:
    output.write(json.dumps({{"tool": "gh", "args": args, "env": dict(os.environ),
                             "mode": stat.S_IMODE(Path(args[2]).stat().st_mode)}}) + "\\n")
assert args[:2] == ["attestation", "verify"]
assert args[args.index("--repo") + 1] == "entroit/omaflow"
assert args[args.index("--cert-oidc-issuer") + 1] == "https://token.actions.githubusercontent.com"
assert "--deny-self-hosted-runners" in args
evidence = json.loads(Path(args[args.index("--bundle") + 1]).read_text())
expected = evidence["commit"]
valid = (args[args.index("--source-digest") + 1] == expected
         and args[args.index("--signer-digest") + 1] == expected
         and args[args.index("--source-ref") + 1] == "refs/tags/commit-" + expected
         and args[args.index("--signer-workflow") + 1] == evidence["workflow"])
sys.exit(0 if valid and not configuration.get("gh_fail") else 1)
''')
    curl.chmod(0o700)
    gh.chmod(0o700)
    source = (ROOT / "scripts/release_artifact.py").read_text()
    assert source.count('"/usr/bin/curl"') == source.count('"/usr/bin/gh"') == 1
    helper.write_text(source.replace('"/usr/bin/curl"', repr(str(curl)))
                     .replace('"/usr/bin/gh"', repr(str(gh))))

    def reset(**options):
        asset.write_bytes(original)
        bundle.write_text(json.dumps({"commit": COMMIT, "workflow": WORKFLOW}))
        configuration.write_text(json.dumps({"binary": str(asset), "bundle": str(bundle), **options}))
        log.write_text("")

    def commands():
        return [json.loads(line) for line in log.read_text().splitlines()]

    def run(name, success=True, **overrides):
        directory = base / name
        options = {"commit": COMMIT, "version": "0.22.0", "bytes": str(len(original)),
                   "sha256": digest, "destination": str(directory), **overrides}
        argv = ["/usr/bin/python3", "-I", str(helper)]
        for key, value in options.items():
            argv.extend(["--" + key, value])
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
            assert (directory / "omaflow.sigstore.json").read_bytes() == bundle.read_bytes()
        return result

    reset()
    run("success")
    calls = commands()
    assert [call["tool"] for call in calls] == ["curl", "curl", "gh"]
    urls = [call["args"][-1] for call in calls if call["tool"] == "curl"]
    expected_url = (f"https://github.com/entroit/omaflow/releases/download/commit-{COMMIT}/"
                    "omaflow-x86_64-unknown-linux-gnu")
    assert urls == [expected_url, expected_url + ".sigstore.json"]
    assert calls[-1]["mode"] == 0o600
    environment = calls[-1]["env"]
    assert not {"GH_TOKEN", "GITHUB_TOKEN", "HOME", "GH_HOST"}.intersection(environment)
    for variable in ("GH_CONFIG_DIR", "XDG_CACHE_HOME", "TMPDIR"):
        assert Path(environment[variable]).is_relative_to(base / "success")
    print("PASS acquisition checks fixed asset identity and requests source-bound verification without credentials or execution")

    log.write_text("")
    run("success")
    assert [call["tool"] for call in commands()] == ["gh"]
    (base / "success/omaflow").write_bytes(b"x" * len(original))
    log.write_text("")
    run("success")
    assert [call["tool"] for call in commands()] == ["curl", "curl", "gh"]
    print("PASS cached bytes require fresh size, digest and provenance verification; corrupt cache is replaced")

    for name, data in (("tamper", b"x" * len(original)),
                       ("truncated", original[:-1]), ("oversize", original + b"extra")):
        reset()
        asset.write_bytes(data)
        run(name, success=False)
        assert [call["tool"] for call in commands()] == ["curl"]
        assert not (base / name / "omaflow").exists()
    print("PASS substituted, truncated and oversized executables fail before attestation or execution")

    reset(curl_fail="attestation")
    run("missing-bundle", success=False)
    reset()
    bundle.write_bytes(b"x" * (4 * 1024 * 1024 + 1))
    run("oversized-bundle", success=False)
    assert not any(call["tool"] == "gh" for call in commands())
    reset(gh_fail=True)
    run("unverified", success=False)
    reset()
    run("wrong-source", success=False, commit="b" * 40)
    reset()
    bundle.write_text(json.dumps({"commit": COMMIT, "workflow": "entroit/omaflow/.github/workflows/other.yml"}))
    run("wrong-workflow", success=False)
    print("PASS missing or oversized bundles and rejected signer/source evidence cannot publish executable bytes")

    reset()
    for key, value in (("commit", "../main"), ("version", "00.22.0"),
                       ("bytes", "-1"), ("bytes", str(128 * 1024 * 1024 + 1)),
                       ("sha256", "a")):
        run("invalid-input", success=False, **{key: value})
    assert not commands() and not (base / "invalid-input").exists()
    victim = base / "private-file"
    victim.write_bytes(b"keep")
    for name in ("omaflow", "omaflow.sigstore.json"):
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
    public = base / "public-directory"
    public.mkdir(mode=0o755)
    run(public.name, success=False)
    assert not commands()
    print("PASS invalid inputs, linked outputs and non-private directories are rejected before network")

    reset()
    run("preserved")
    previous_binary = (base / "preserved/omaflow").read_bytes()
    previous_bundle = (base / "preserved/omaflow.sigstore.json").read_bytes()
    reset(curl_fail="executable")
    run("preserved", success=False, commit="b" * 40)
    assert (base / "preserved/omaflow").read_bytes() == previous_binary
    assert (base / "preserved/omaflow.sigstore.json").read_bytes() == previous_bundle
    assert [call["tool"] for call in commands()] == ["gh", "curl"]
    reset(gh_fail=True)
    run("preserved", success=False)
    assert (base / "preserved/omaflow").read_bytes() == previous_binary
    assert (base / "preserved/omaflow.sigstore.json").read_bytes() == previous_bundle
    print("PASS transient download and provenance failures preserve previous verified files and remove partial downloads")
