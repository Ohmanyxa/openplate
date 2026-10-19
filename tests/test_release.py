"""Release orchestration tests never contact GitHub, run builds or publish anything."""

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import pytest

SPEC = importlib.util.spec_from_file_location(
    "openplate_release", Path(__file__).resolve().parents[1] / "scripts/release.py"
)
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)

SHA = "a" * 40


@pytest.fixture
def root(tmp_path):
    contents = {
        release.VERSION_FILES[0]: (
            '[build-system]\nversion = "unchanged"\n'
            '[project]\nname = "openplate"\nversion = "0.7.0"\n'
        ),
        release.VERSION_FILES[1]: "name: openplate_mobile\nversion: 0.7.0+8\n",
        release.VERSION_FILES[2]: '{\n  "domain": "openplate",\n  "version": "0.7.0"\n}\n',
        release.VERSION_FILES[3]: (
            'version = 1\n[[package]]\nname = "other"\nversion = "0.7.0"\n'
            '[[package]]\nname = "openplate"\nversion = "0.7.0"\n'
        ),
    }
    for path, content in contents.items():
        destination = tmp_path / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
    return tmp_path


def test_version_update_changes_all_four_fields_and_only_our_lock_entry(root):
    current = release.read_versions(root)
    updated = release.updated_versions(current, "0.8.0")
    for path, content in updated.items():
        (root / path).write_text(content)
    actual = release.read_versions(root)
    assert (actual.version, actual.build) == ("0.8.0", 9)
    assert 'name = "other"\nversion = "0.7.0"' in updated[Path("uv.lock")]
    assert '[build-system]\nversion = "unchanged"' in updated[Path("pyproject.toml")]


@pytest.mark.parametrize("target", ["0.7.0", "0.6.0", "v0.8.0", "0.8.0-beta", "01.8.0", "bad"])
def test_invalid_and_backwards_versions_are_rejected(root, target):
    with pytest.raises(release.ReleaseError):
        release.updated_versions(release.read_versions(root), target)


def test_inconsistent_versions_are_rejected(root):
    (root / release.VERSION_FILES[1]).write_text("version: 0.8.0+9\n")
    with pytest.raises(release.ReleaseError, match="weichen ab"):
        release.read_versions(root)


@pytest.mark.parametrize(
    "url", ["https://github.com/Ohmanyxa/openplate.git", "git@github.com:Ohmanyxa/openplate.git"]
)
def test_repository_parses_https_and_ssh(url):
    assert release.repository(url) == "Ohmanyxa/openplate"


def test_non_github_remote_is_rejected():
    with pytest.raises(release.ReleaseError):
        release.repository("https://evil.test/Ohmanyxa/openplate.git")


def test_default_plan_is_local_read_only(root, monkeypatch, capsys):
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, capture_output=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "remote",
            "add",
            "origin",
            "https://github.com/Ohmanyxa/openplate.git",
        ],
        check=True,
    )
    monkeypatch.setattr(release, "ROOT", root)
    before = {path: (root / path).read_bytes() for path in release.VERSION_FILES}
    publish = Mock(side_effect=AssertionError("dry-run must not publish"))
    monkeypatch.setattr(release, "publish", publish)
    assert release.main(["0.8.0"]) == 0
    assert "PLAN" in capsys.readouterr().out
    assert before == {path: (root / path).read_bytes() for path in release.VERSION_FILES}
    assert not (root / ".git/openplate-release.lock").exists()
    publish.assert_not_called()


class Clock:
    value = 0

    def now(self):
        return self.value

    def sleep(self, duration):
        self.value += duration


class CiCommands:
    def __init__(self, responder):
        self.responder = responder
        self.calls = []

    def run(self, *args, **kwargs):
        self.calls.append(args)
        return json.dumps(self.responder(args))


def run_state(conclusion="success", status="completed", sha=SHA):
    return [
        {
            "headSha": sha,
            "status": status,
            "conclusion": conclusion,
            "url": "https://example.test/run",
        }
    ]


def test_ci_waits_for_both_workflows_and_exact_commit():
    clock = Clock()
    commands = CiCommands(lambda _: run_state() if clock.value >= 10 else [])
    release.wait_for_ci(commands, "Ohmanyxa/openplate", SHA, 30, clock.now, clock.sleep)
    workflows = {args[args.index("--workflow") + 1] for args in commands.calls}
    assert workflows == {"ci.yml", "hacs.yml"}
    assert all(SHA in args for args in commands.calls)


@pytest.mark.parametrize("conclusion", ["failure", "skipped", "cancelled", "timed_out"])
def test_failed_or_skipped_ci_blocks_release(conclusion):
    clock = Clock()
    with pytest.raises(release.ReleaseError, match="fehlgeschlagen/übersprungen"):
        release.wait_for_ci(
            CiCommands(lambda _: run_state(conclusion)), "x/y", SHA, 20, clock.now, clock.sleep
        )


def test_missing_ci_times_out_instead_of_silently_skipping():
    clock = Clock()
    with pytest.raises(release.ReleaseError, match="Timeout"):
        release.wait_for_ci(CiCommands(lambda _: []), "x/y", SHA, 12, clock.now, clock.sleep)


def test_ci_for_wrong_sha_is_rejected():
    clock = Clock()
    with pytest.raises(release.ReleaseError, match="Release-Commit"):
        release.wait_for_ci(
            CiCommands(lambda _: run_state(sha="b" * 40)), "x/y", SHA, 20, clock.now, clock.sleep
        )


class PublishCommands:
    def __init__(self, root, dirty=True):
        self.root = root
        self.dirty = dirty
        self.calls = []

    def git(self, *args):
        self.calls.append(("git", *args))
        if args == ("branch", "--show-current"):
            return "main\n"
        if args == ("status", "--porcelain"):
            return " M pyproject.toml\n" if self.dirty else ""
        if args == ("rev-parse", "HEAD"):
            return SHA
        if args == ("ls-remote", "origin", "refs/heads/main"):
            return f"{SHA}\trefs/heads/main\n"
        return ""

    def run(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ("git", "commit"):
            self.dirty = False
        return ""


@pytest.fixture
def publication(root, monkeypatch):
    commands = PublishCommands(root)
    monkeypatch.setattr(release.shutil, "which", lambda name: f"/fake/{name}")
    monkeypatch.setattr(release, "uv_command", lambda: ["uv"])
    monkeypatch.setattr(release.sys, "platform", "darwin")
    monkeypatch.setattr(release, "verify_tag", lambda *a, **kw: False)
    monkeypatch.setattr(release, "fingerprint", lambda _: "snapshot")
    monkeypatch.setattr(
        release, "local_checks", lambda *a: commands.calls.append(("local-checks",))
    )
    monkeypatch.setattr(release, "wait_for_ci", lambda *a: commands.calls.append(("ci-success",)))
    args = argparse.Namespace(
        include_working_tree=True, skip_ios_build=False, resume=False, timeout=60
    )
    return commands, args


def test_publish_tags_only_after_checks_and_push(publication):
    commands, args = publication
    release.publish(args, commands, release.read_versions(commands.root), "0.8.0", "x/y", None)
    calls = commands.calls
    checks = calls.index(("local-checks",))
    commit = next(i for i, call in enumerate(calls) if call[:2] == ("git", "commit"))
    ci = calls.index(("ci-success",))
    tag = next(i for i, call in enumerate(calls) if call[:3] == ("git", "tag", "-a"))
    create = next(i for i, call in enumerate(calls) if call[:3] == ("gh", "release", "create"))
    assert checks < commit < ci < tag < create
    assert "--verify-tag" in calls[create]
    assert "--generate-notes" in calls[create]
    assert not any("--force" in call or "reset" in call for call in calls)


def test_ci_failure_never_creates_tag_or_release(publication, monkeypatch):
    commands, args = publication
    monkeypatch.setattr(release, "wait_for_ci", Mock(side_effect=release.ReleaseError("CI failed")))
    with pytest.raises(release.ReleaseError, match="CI failed"):
        release.publish(args, commands, release.read_versions(commands.root), "0.8.0", "x/y", None)
    assert not any(call[:3] == ("git", "tag", "-a") for call in commands.calls)
    assert not any(call[:3] == ("gh", "release", "create") for call in commands.calls)
    assert release.read_versions(commands.root).version == "0.8.0"


def test_dirty_worktree_needs_explicit_opt_in(publication):
    commands, args = publication
    args.include_working_tree = False
    with pytest.raises(release.ReleaseError, match="include-working-tree"):
        release.publish(args, commands, release.read_versions(commands.root), "0.8.0", "x/y", None)
    assert release.read_versions(commands.root).version == "0.7.0"


def test_edits_during_checks_stop_before_commit(publication, monkeypatch):
    commands, args = publication
    snapshots = iter(["before", "changed"])
    monkeypatch.setattr(release, "fingerprint", lambda _: next(snapshots))
    with pytest.raises(release.ReleaseError, match="während der Prüfungen"):
        release.publish(args, commands, release.read_versions(commands.root), "0.8.0", "x/y", None)
    assert not any(call[:2] == ("git", "commit") for call in commands.calls)


def test_resume_does_not_bump_build_again(publication):
    commands, args = publication
    args.resume = True
    release.publish(args, commands, release.read_versions(commands.root), "0.7.0", "x/y", None)
    assert release.read_versions(commands.root).build == 8


def test_tag_checks_peel_annotated_tags_and_reject_retargeting():
    commands = Mock()
    commands.git.side_effect = [f"object\trefs/tags/v0.8.0\n{SHA}\trefs/tags/v0.8.0^{{}}\n", ""]
    commands.run.return_value = "[]"
    assert not release.verify_tag(commands, "x/y", "v0.8.0", SHA, True)
    commands.git.side_effect = [f"{'b' * 40}\trefs/tags/v0.8.0\n", ""]
    with pytest.raises(release.ReleaseError, match="anderen Commit"):
        release.verify_tag(commands, "x/y", "v0.8.0", SHA, True)


def test_published_resume_is_idempotent_and_drafts_are_not_overwritten():
    commands = Mock()
    commands.git.side_effect = [f"{SHA}\trefs/tags/v0.8.0\n", ""]
    commands.run.return_value = json.dumps(
        [{"tagName": "v0.8.0", "isDraft": False, "isPrerelease": False}]
    )
    assert release.verify_tag(commands, "x/y", "v0.8.0", SHA, True)
    commands.git.side_effect = [f"{SHA}\trefs/tags/v0.8.0\n", ""]
    commands.run.return_value = json.dumps(
        [{"tagName": "v0.8.0", "isDraft": True, "isPrerelease": False}]
    )
    with pytest.raises(release.ReleaseError, match="Draft/Prerelease"):
        release.verify_tag(commands, "x/y", "v0.8.0", SHA, True)


def test_lock_rejects_parallel_runs_and_cleans_up_after_failure(root):
    (root / ".git").mkdir()
    commands = Mock(root=root)
    commands.git.return_value = ".git/openplate-release.lock"
    lock = root / ".git/openplate-release.lock"
    with pytest.raises(ValueError, match="simulated failure"), release.release_lock(commands):
        assert "pid=" in lock.read_text()
        with (
            pytest.raises(release.ReleaseError, match="läuft bereits"),
            release.release_lock(commands),
        ):
            pytest.fail("parallel release acquired the lock")
        assert lock.exists()
        raise ValueError("simulated failure")
    assert not lock.exists()


def test_old_system_uv_uses_modern_uvx_fallback(monkeypatch):
    monkeypatch.setattr(release.shutil, "which", lambda name: f"/fake/{name}")
    monkeypatch.setattr(release.subprocess, "run", Mock(return_value=Mock(stdout="uv 0.2.23\n")))
    assert release.uv_command() == ["uvx", "--from", "uv>=0.9,<1", "uv"]


def test_local_checks_cover_all_suites_and_optional_ios_build(root):
    for skip_ios in (False, True):
        commands = Mock(root=root)
        release.local_checks(commands, ["uv"], skip_ios)
        calls = [call.args for call in commands.run.call_args_list]
        assert ("uv", "sync", "--extra", "dev", "--locked") in calls
        assert ("uv", "run", "--locked", "pytest", "-q") in calls
        assert any("homeassistant==2026.10.1" in args for args in calls)
        assert ("flutter", "pub", "get", "--enforce-lockfile") in calls
        assert ("flutter", "analyze", "--no-pub") in calls
        assert ("flutter", "test", "--no-pub") in calls
        ios = ("flutter", "build", "ios", "--release", "--no-codesign", "--no-pub")
        assert (ios in calls) is not skip_ios
