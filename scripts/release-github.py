#!/usr/bin/env python3
"""Prepare and publish source-bound releases from GitHub Actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPOSITORY = "entroit/omaflow"
WORKFLOW = "release-binary.yml"
GENERATED = ["dist/release.json", "dist/bin/x86_64-unknown-linux-gnu/omaflow"]
ASSET = "omaflow-x86_64-unknown-linux-gnu"


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"{args[0]} failed")
    return result.stdout.strip()


def api(endpoint):
    return json.loads(run("gh", "api", f"repos/{REPOSITORY}/{endpoint}"))


def identity():
    commit = run("git", "rev-parse", "HEAD")
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
            or os.environ.get("GITHUB_SHA") != commit):
        raise ValueError("Production releases must run at their exact source in GitHub Actions.")
    return commit


def prepare():
    source = identity()
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Release preparation requires main.")
    run("git", "diff", "--exit-code", "--", ".", *(f":(exclude){p}" for p in GENERATED))
    run("git", "diff", "--cached", "--exit-code", "--", ".", *(f":(exclude){p}" for p in GENERATED))
    run("git", "add", "--", *GENERATED)
    changed = subprocess.run(["git", "diff", "--cached", "--quiet"]).returncode
    if changed not in (0, 1):
        raise ValueError("Could not inspect generated release files.")
    run("gh", "auth", "setup-git")
    if changed:
        timestamp = run("git", "show", "-s", "--format=%cI", source)
        run("git", "-c", "user.name=github-actions[bot]", "-c",
            "user.email=41898282+github-actions[bot]@users.noreply.github.com",
            "commit", "-m", "Package the CI-built release",
            env=dict(os.environ, GIT_AUTHOR_DATE=timestamp, GIT_COMMITTER_DATE=timestamp))
        run("git", "push", "origin", "HEAD:refs/heads/main")
    elif run("git", "ls-remote", "origin", "refs/heads/main").split()[0] != source:
        raise ValueError("Main advanced during preparation. Run preparation again at current main.")
    commit = run("git", "rev-parse", "HEAD")
    tag = f"commit-{commit}"
    run("git", "push", "origin", f"{commit}:refs/tags/{tag}")
    run("gh", "workflow", "run", WORKFLOW, "--repo", REPOSITORY,
        "--ref", tag, "--field", "publish=true")
    print(f"Prepared {commit}; dispatched publication at {tag}.")


def verify_bundle(binary, bundle, commit):
    with tempfile.TemporaryDirectory(prefix="omaflow-publish-verify-") as scratch:
        run("gh", "attestation", "verify", str(binary), "--bundle", str(bundle),
            "--repo", REPOSITORY, "--source-digest", commit, "--signer-digest", commit,
            "--signer-workflow", f"{REPOSITORY}/.github/workflows/{WORKFLOW}",
            "--source-ref", f"refs/tags/commit-{commit}", "--deny-self-hosted-runners",
            env={"PATH": "/usr/bin", "GH_CONFIG_DIR": f"{scratch}/gh",
                 "XDG_CACHE_HOME": f"{scratch}/cache", "GH_PROMPT_DISABLED": "1"})


def digest(path):
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


def find_release(tag):
    # The tag endpoint omits drafts; authenticated release listings include them.
    pages = json.loads(run("gh", "api", "--paginate", "--slurp",
                           f"repos/{REPOSITORY}/releases?per_page=100"))
    matches = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Multiple releases identify this tag; review the drafts before retrying.")
    return matches[0] if matches else None


def publish(bundle_path):
    commit = identity()
    tag = f"commit-{commit}"
    if os.environ["GITHUB_REF"] != f"refs/tags/{tag}":
        raise ValueError("Publication requires the exact commit-addressed tag.")
    reference = api(f"git/ref/tags/{tag}")["object"]
    if reference["type"] != "commit" or reference["sha"] != commit:
        raise ValueError("The release tag does not identify this source commit.")
    manifest = json.loads(Path("dist/release.json").read_text())
    binary = Path("target/release/omaflow")
    if (binary.stat().st_size != manifest["binary"]["bytes"]
            or digest(binary) != "sha256:" + manifest["binary"]["sha256"]):
        raise ValueError("The built executable does not match committed release metadata.")
    verify_bundle(binary, bundle_path, commit)
    with tempfile.TemporaryDirectory(prefix="omaflow-release-assets-") as directory:
        assets = Path(directory)
        for source, name in [(binary, ASSET), (bundle_path, ASSET + ".sigstore.json"),
                             (Path("dist/release.json"), "release.json"),
                             (Path("release-build.txt"), "release-build.txt")]:
            shutil.copyfile(source, assets / name)
        release = find_release(tag)
        if release is None:
            notes = f"Built and attested from `{commit}`.\n\n" + manifest["summary"]
            notes += "\n\n" + "\n".join("- " + item for item in manifest["changes"])
            run("gh", "release", "create", tag, "--repo", REPOSITORY, "--verify-tag",
                "--target", commit, "--draft", "--latest=false", "--title",
                f"OmaFlow {manifest['version']}", "--notes", notes)
            release = find_release(tag)
            if release is None:
                raise ValueError("The created release draft could not be found.")
        existing = {asset["name"]: asset for asset in release["assets"]}
        for path in list(assets.iterdir()):
            if path.name not in existing:
                if not release["draft"]:
                    raise ValueError("The published release is missing required evidence.")
                run("gh", "release", "upload", tag, str(path), "--repo", REPOSITORY)
            elif path.name == ASSET or path.name == "release.json":
                if existing[path.name].get("digest") != digest(path):
                    raise ValueError("An existing release asset has different bytes; refusing replacement.")
            elif path.name.endswith(".sigstore.json"):
                retained = assets / "retained-bundle"
                retained.mkdir()
                run("gh", "release", "download", tag, "--repo", REPOSITORY,
                    "--pattern", path.name, "--dir", str(retained))
                verify_bundle(binary, retained / path.name, commit)
        if release["draft"]:
            run("gh", "release", "edit", tag, "--repo", REPOSITORY,
                "--draft=false", "--latest=false")
        print(f"https://github.com/{REPOSITORY}/releases/tag/{tag}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "publish"])
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            prepare()
        elif args.bundle is None:
            parser.error("publish requires --bundle")
        else:
            publish(args.bundle)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"Release failed: {error}\n")
