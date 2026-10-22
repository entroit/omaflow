#!/usr/bin/env python3
"""Exercise release preparation and publication with local Git and CLI fixtures."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = "dist/bin/x86_64-unknown-linux-gnu/omaflow"
GENERATED = {BINARY, "dist/release.json"}
DATE = "2026-10-01T12:34:56+00:00"


def git(directory, *args, **kwargs):
    result = subprocess.run(["/usr/bin/git", "-C", str(directory), *args],
                            capture_output=True, text=True, **kwargs)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()


class Fixture:
    def __init__(self, base, name):
        self.base = base / name
        self.base.mkdir()
        self.repo = self.base / "checkout"
        self.repo.mkdir()
        self.origin = self.base / "origin.git"
        self.commands = self.base / "bin"
        self.commands.mkdir()
        self.log = self.base / "gh.jsonl"
        self.log.write_text("")
        self.configuration = self.base / "gh.json"
        self.releases = self.base / "releases.json"
        self.releases.write_text("[]")
        self.storage = self.base / "assets"
        self.storage.mkdir()
        self.cli = self.base / "release-github.py"
        script = (ROOT / "scripts/release-github.py").read_text()
        isolated_path = 'env={"PATH": "/usr/bin",'
        assert script.count(isolated_path) == 1
        script = script.replace(isolated_path,
                                f'env={{"PATH": {str(self.commands) + ":/usr/bin"!r},')
        self.cli.write_text(script)
        gh = self.commands / "gh"
        gh.write_text(f'''#!/usr/bin/python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
with Path({str(self.log)!r}).open("a") as output:
    output.write(json.dumps(args) + "\\n")
configuration = json.loads(Path({str(self.configuration)!r}).read_text())
state_file = Path({str(self.releases)!r})
releases = json.loads(state_file.read_text())
storage = Path({str(self.storage)!r})
if args == ["auth", "setup-git"] or args[:2] == ["workflow", "run"]:
    sys.exit(0)
if args[0] == "api" and args[1].startswith("repos/entroit/omaflow/git/ref/tags/commit-"):
    print(json.dumps({{"object": configuration}}))
    sys.exit(0)
if args[:2] == ["attestation", "verify"]:
    try:
        evidence = json.loads(Path(args[args.index("--bundle") + 1]).read_text())
    except (OSError, ValueError):
        print("Fixture rejected an invalid attestation bundle.", file=sys.stderr)
        sys.exit(1)
    if configuration.get("synthetic_verification"):
        assert "GH_TOKEN" not in os.environ
        assert evidence["fixtureOnly"] is True
        assert evidence["sourceCommit"] == args[args.index("--source-digest") + 1]
        assert evidence["sourceCommit"] == args[args.index("--signer-digest") + 1]
        assert args[args.index("--source-ref") + 1] == "refs/tags/commit-" + evidence["sourceCommit"]
        assert args[args.index("--signer-workflow") + 1] == "entroit/omaflow/.github/workflows/release-binary.yml"
        assert evidence["sha256"] == hashlib.sha256(Path(args[2]).read_bytes()).hexdigest()
        sys.exit(0)
if configuration.get("synthetic_verification"):
    if (args[0] == "api" and "repos/entroit/omaflow/releases" in args
            and "--method" in args and args[args.index("--method") + 1] == "POST"):
        assert os.environ.get("GH_TOKEN") == "synthetic-api-token"
        assert args[args.index("--input") + 1] == "-"
        payload = json.load(sys.stdin)
        assert payload["tag_name"] == "commit-" + configuration["sha"]
        assert payload["target_commitish"] == configuration["sha"]
        assert payload["draft"] is True and payload["make_latest"] == "false"
        assert not any(release["tag_name"] == payload["tag_name"] for release in releases)
        release = {{"tag_name": payload["tag_name"], "draft": True, "assets": [], "newly_created": True}}
        releases.append(release)
        state_file.write_text(json.dumps(releases))
        print(json.dumps(release))
        sys.exit(0)
    if args == ["api", "--paginate", "--slurp", "repos/entroit/omaflow/releases?per_page=100"]:
        assert os.environ.get("GH_TOKEN") == "synthetic-api-token"
        visible = [release for release in releases if not release.get("newly_created")]
        print(json.dumps([visible[:1], visible[1:]]))
        sys.exit(0)
    if args[0] == "api" and args[1].startswith("repos/entroit/omaflow/releases/tags/"):
        tag = args[1].split("/")[-1]
        found = next((release for release in releases if release["tag_name"] == tag and not release["draft"]), None)
        if found is None:
            print("HTTP 404: published release not found", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(found))
        sys.exit(0)
    if args[:2] == ["release", "create"]:
        assert not any(release["tag_name"] == args[2] for release in releases)
        assert "--draft" in args and "--verify-tag" in args
        releases.append({{"tag_name": args[2], "draft": True, "assets": [], "newly_created": True}})
        state_file.write_text(json.dumps(releases))
        sys.exit(0)
    if args[:2] in (["release", "upload"], ["release", "download"], ["release", "edit"]):
        release = next(release for release in releases if release["tag_name"] == args[2])
        if args[1] == "upload":
            assert release["draft"] and "--clobber" not in args
            source = Path(args[3])
            assert not any(asset["name"] == source.name for asset in release["assets"])
            shutil.copyfile(source, storage / source.name)
            release["assets"].append({{"name": source.name, "digest": "sha256:" + hashlib.sha256(source.read_bytes()).hexdigest()}})
        elif args[1] == "download":
            name = args[args.index("--pattern") + 1]
            destination = Path(args[args.index("--dir") + 1]) / name
            shutil.copyfile(storage / name, destination)
        else:
            assert release["draft"] and "--draft=false" in args
            release["draft"] = False
        state_file.write_text(json.dumps(releases))
        sys.exit(0)
print("Fixture does not authorize attestation success or public release operations.", file=sys.stderr)
sys.exit(1)
''')
        gh.chmod(0o700)
        git(self.base, "init", "--bare", "--initial-branch=main", str(self.origin))
        git(self.repo, "init", "--initial-branch=main")
        git(self.repo, "config", "user.name", "Fixture author")
        git(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / "source.rs").write_text("original source\n")
        binary = self.repo / BINARY
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"original executable\n")
        self.write_metadata()
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "Original source",
            env=dict(os.environ, GIT_AUTHOR_DATE=DATE, GIT_COMMITTER_DATE=DATE))
        git(self.repo, "remote", "add", "origin", str(self.origin))
        git(self.repo, "push", "--set-upstream", "origin", "main")
        self.source = git(self.repo, "rev-parse", "HEAD")
        self.configuration.write_text(json.dumps({"type": "commit", "sha": self.source}))
        self.environment = dict(os.environ, PATH=f"{self.commands}:/usr/bin",
                                GITHUB_ACTIONS="true", GITHUB_REPOSITORY="entroit/omaflow",
                                GITHUB_SHA=self.source, GITHUB_REF="refs/heads/main")

    def write_metadata(self):
        binary = self.repo / BINARY
        metadata = {"version": "0.21.4", "summary": "Build releases publicly.",
                    "changes": ["Publish source-bound executables."],
                    "binary": {"path": BINARY, "bytes": binary.stat().st_size,
                               "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}}
        (self.repo / "dist/release.json").write_text(json.dumps(metadata) + "\n")

    def generated_change(self):
        (self.repo / BINARY).write_bytes(b"CI-built executable\n")
        self.write_metadata()

    def execute(self, mode="prepare", success=True, **environment):
        args = ["/usr/bin/python3", "-I", str(self.cli), mode]
        if mode == "publish":
            args.extend(["--bundle", str(self.base / "bundle.json")])
        result = subprocess.run(args, cwd=self.repo,
                                env=dict(self.environment, **environment),
                                capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_no_publication(self):
        assert not any(call[0] == "release" or call[0] == "api" and "/releases" in call[1]
                       for call in self.calls()), self.calls()

    def publication(self):
        target = self.repo / "target/release/omaflow"
        target.parent.mkdir(parents=True)
        shutil.copyfile(self.repo / BINARY, target)
        (self.repo / "release-build.txt").write_text("retained public build log\n")
        bundle = self.base / "bundle.json"
        bundle.write_text(json.dumps({"fixtureOnly": True, "sourceCommit": self.source,
                                      "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                                      "revision": "original"}))
        self.files = {"omaflow-x86_64-unknown-linux-gnu": target,
                      "omaflow-x86_64-unknown-linux-gnu.sigstore.json": bundle,
                      "release.json": self.repo / "dist/release.json",
                      "release-build.txt": self.repo / "release-build.txt"}
        configuration = json.loads(self.configuration.read_text())
        configuration["synthetic_verification"] = True
        self.configuration.write_text(json.dumps(configuration))
        self.environment.update(GITHUB_REF=f"refs/tags/commit-{self.source}",
                                GH_TOKEN="synthetic-api-token")
        self.releases.write_text(json.dumps([{"tag_name": "unrelated", "draft": False, "assets": []}]))

    def seed_release(self, names, draft):
        release = {"tag_name": f"commit-{self.source}", "draft": draft, "assets": []}
        for name in names:
            source = self.files[name]
            shutil.copyfile(source, self.storage / name)
            release["assets"].append({"name": name,
                                      "digest": "sha256:" + hashlib.sha256(source.read_bytes()).hexdigest()})
        releases = json.loads(self.releases.read_text())
        releases.append(release)
        self.releases.write_text(json.dumps(releases))

    def published(self):
        return next(release for release in json.loads(self.releases.read_text())
                    if release["tag_name"] == f"commit-{self.source}")


with tempfile.TemporaryDirectory(prefix="omaflow-release-github-") as directory:
    base = Path(directory)
    fixture = Fixture(base, "generated")
    source_contents = (fixture.repo / "source.rs").read_bytes()
    (fixture.repo / "release-build.txt").write_text("public build evidence\n")
    fixture.generated_change()
    fixture.execute()
    prepared = git(fixture.repo, "rev-parse", "HEAD")
    assert prepared != fixture.source
    assert set(git(fixture.repo, "diff", "--name-only", fixture.source, prepared).splitlines()) == GENERATED
    assert (fixture.repo / "source.rs").read_bytes() == source_contents
    assert git(fixture.repo, "show", "-s", "--format=%an <%ae>", prepared) == (
        "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>")
    assert git(fixture.repo, "show", "-s", "--format=%aI%n%cI", prepared) == git(
        fixture.repo, "show", "-s", "--format=%aI%n%cI", fixture.source)
    assert git(fixture.origin, "rev-parse", "refs/heads/main") == prepared
    assert git(fixture.origin, "rev-parse", f"refs/tags/commit-{prepared}") == prepared
    assert fixture.calls() == [["auth", "setup-git"],
                               ["workflow", "run", "release-binary.yml", "--repo", "entroit/omaflow",
                                "--ref", f"commit-{prepared}", "--field", "publish=true"]]
    assert git(fixture.repo, "status", "--porcelain", "--untracked-files=no") == ""
    assert (fixture.repo / "release-build.txt").read_text() == "public build evidence\n"
    print("PASS preparation commits only CI outputs, preserves source and dates, pushes main and dispatches its exact tag")

    fixture.execute(GITHUB_SHA=prepared)
    assert git(fixture.repo, "rev-parse", "HEAD") == prepared
    assert git(fixture.origin, "rev-parse", f"refs/tags/commit-{prepared}") == prepared
    assert fixture.calls()[-1] == fixture.calls()[1]
    print("PASS retry reuses an existing source commit and tag without an empty commit")

    fixture = Fixture(base, "unchanged")
    fixture.execute()
    assert git(fixture.repo, "rev-parse", "HEAD") == fixture.source
    assert git(fixture.repo, "rev-list", "--count", "HEAD") == "1"
    assert git(fixture.origin, "rev-parse", f"refs/tags/commit-{fixture.source}") == fixture.source
    print("PASS identical release bytes dispatch publication without a generated commit")

    for staged in [False, True]:
        fixture = Fixture(base, "source-staged" if staged else "source-unstaged")
        fixture.generated_change()
        (fixture.repo / "source.rs").write_text("unexpected source modification\n")
        if staged:
            git(fixture.repo, "add", "source.rs")
        fixture.execute(success=False)
        assert git(fixture.repo, "rev-parse", "HEAD") == fixture.source
        assert git(fixture.origin, "rev-parse", "refs/heads/main") == fixture.source
        assert git(fixture.origin, "tag", "--list") == "" and not fixture.calls()
    print("PASS staged and unstaged source changes reject before committing, pushing or dispatching")

    for name, override in [
        ("outside-actions", {"GITHUB_ACTIONS": "false"}),
        ("wrong-repository", {"GITHUB_REPOSITORY": "other/omaflow"}),
        ("wrong-source", {"GITHUB_SHA": "a" * 40}),
        ("wrong-branch", {"GITHUB_REF": "refs/heads/other"}),
    ]:
        fixture = Fixture(base, name)
        fixture.generated_change()
        fixture.execute(success=False, **override)
        assert git(fixture.repo, "rev-parse", "HEAD") == fixture.source
        assert git(fixture.origin, "rev-parse", "refs/heads/main") == fixture.source
        assert not fixture.calls()
    print("PASS preparation requires Actions, the canonical repository, exact source and main")

    for changed in [False, True]:
        fixture = Fixture(base, "concurrent-generated" if changed else "concurrent-unchanged")
        if changed:
            fixture.generated_change()
        competitor = fixture.base / "concurrent"
        git(fixture.base, "clone", str(fixture.origin), str(competitor))
        (competitor / "source.rs").write_text("newer upstream source\n")
        git(competitor, "add", "source.rs")
        git(competitor, "-c", "user.name=Other author", "-c", "user.email=other@example.invalid",
            "commit", "-m", "Main advanced")
        git(competitor, "push", "origin", "HEAD:refs/heads/main")
        advanced = git(competitor, "rev-parse", "HEAD")
        fixture.execute(success=False)
        assert git(fixture.origin, "rev-parse", "refs/heads/main") == advanced
        assert git(fixture.origin, "show", "refs/heads/main:source.rs") == "newer upstream source"
        assert git(fixture.origin, "tag", "--list") == ""
        assert fixture.calls() == [["auth", "setup-git"]]
    print("PASS concurrent main changes survive preparation with and without new generated bytes")

    fixture = Fixture(base, "publication-guards")
    target = fixture.repo / "target/release/omaflow"
    target.parent.mkdir(parents=True)
    shutil.copyfile(fixture.repo / BINARY, target)
    (fixture.base / "bundle.json").write_text("not a valid attestation bundle\n")
    source_ref = f"refs/tags/commit-{fixture.source}"
    for reference in ["refs/heads/main", "refs/tags/commit-" + "b" * 40]:
        fixture.execute("publish", success=False, GITHUB_REF=reference)
        assert not fixture.calls()
    fixture.configuration.write_text(json.dumps({"type": "commit", "sha": "c" * 40}))
    result = fixture.execute("publish", success=False, GITHUB_REF=source_ref)
    assert "tag does not identify" in result.stderr
    fixture.assert_no_publication()
    fixture.configuration.write_text(json.dumps({"type": "commit", "sha": fixture.source}))
    target.write_bytes(b"x" * target.stat().st_size)
    result = fixture.execute("publish", success=False, GITHUB_REF=source_ref)
    assert "does not match committed release metadata" in result.stderr
    fixture.assert_no_publication()
    assert not any(call[:2] == ["attestation", "verify"] for call in fixture.calls())
    print("PASS publication refuses wrong source refs, mismatched tags and wrong executable bytes before release operations")

    shutil.copyfile(fixture.repo / BINARY, target)
    result = fixture.execute("publish", success=False, GITHUB_REF=source_ref)
    assert "invalid attestation bundle" in result.stderr
    assert fixture.calls()[-1][:2] == ["attestation", "verify"]
    fixture.assert_no_publication()
    print("PASS invalid attestation evidence prevents publication")

    # These lifecycle cases use explicit synthetic verification, not cryptographic proof.
    fixture = Fixture(base, "fresh-publication")
    fixture.publication()
    result = fixture.execute("publish")
    assert result.stdout.strip() == f"https://github.com/entroit/omaflow/releases/tag/commit-{fixture.source}"
    published = fixture.published()
    assert not published["draft"]
    assert {asset["name"] for asset in published["assets"]} == set(fixture.files)
    for name, source in fixture.files.items():
        assert (fixture.storage / name).read_bytes() == source.read_bytes()
    operations = [call[:2] for call in fixture.calls() if call[0] == "release"]
    assert operations.count(["release", "create"]) == 0
    assert operations.count(["release", "upload"]) == 4
    assert operations[-1] == ["release", "edit"]
    listings = [call for call in fixture.calls()
                if call[0] == "api" and "releases?per_page=100" in call[-1]]
    assert len(listings) == 1 and "--paginate" in listings[0] and "--slurp" in listings[0]
    assert sum(call[0] == "api" and "POST" in call for call in fixture.calls()) == 1
    print("PASS synthetic lifecycle uses the creation response when a new draft is absent from release listings")

    fixture = Fixture(base, "partial-draft")
    fixture.publication()
    retained_names = ["omaflow-x86_64-unknown-linux-gnu",
                      "omaflow-x86_64-unknown-linux-gnu.sigstore.json"]
    fixture.seed_release(retained_names, draft=True)
    retained = {name: (fixture.storage / name).read_bytes() for name in retained_names}
    fixture.execute("publish")
    assert not fixture.published()["draft"]
    assert {asset["name"] for asset in fixture.published()["assets"]} == set(fixture.files)
    calls = fixture.calls()
    assert not any(call[:2] == ["release", "create"] for call in calls)
    assert not any(call[0] == "api" and "POST" in call for call in calls)
    uploads = [Path(call[3]).name for call in calls if call[:2] == ["release", "upload"]]
    assert set(uploads) == {"release.json", "release-build.txt"}
    assert sum(call[:2] == ["attestation", "verify"] for call in calls) == 2
    for name, data in retained.items():
        assert (fixture.storage / name).read_bytes() == data
    print("PASS synthetic lifecycle finds a partial draft on a later page and resumes without replacing retained assets")

    fixture = Fixture(base, "published-retry")
    fixture.publication()
    fixture.seed_release(fixture.files, draft=False)
    retained = {name: (fixture.storage / name).read_bytes() for name in fixture.files}
    bundle = fixture.base / "bundle.json"
    evidence = json.loads(bundle.read_text())
    evidence["revision"] = "new-run"
    bundle.write_text(json.dumps(evidence))
    fixture.execute("publish")
    calls = fixture.calls()
    assert not any(call[:2] in (["release", "create"], ["release", "upload"], ["release", "edit"])
                   for call in calls)
    assert not any(call[0] == "api" and "POST" in call for call in calls)
    verified = [Path(call[call.index("--bundle") + 1]) for call in calls
                if call[:2] == ["attestation", "verify"]]
    assert len(verified) == 2 and verified[0] == bundle and verified[1].parent.name == "retained-bundle"
    for name, data in retained.items():
        assert (fixture.storage / name).read_bytes() == data
    print("PASS synthetic lifecycle rechecks the published bundle without replacing immutable release evidence")

    (fixture.storage / "omaflow-x86_64-unknown-linux-gnu.sigstore.json").write_text("invalid retained evidence\n")
    fixture.log.write_text("")
    result = fixture.execute("publish", success=False)
    assert "invalid attestation bundle" in result.stderr
    assert not any(call[:2] in (["release", "create"], ["release", "upload"], ["release", "edit"])
                   for call in fixture.calls())
    print("PASS an invalid retained bundle rejects a published retry even when the new synthetic evidence passes")
