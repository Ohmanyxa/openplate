#!/usr/bin/env python3
"""Safe-by-default OpenPlate releases. Python 3.9+, git, gh, uv/uvx and Flutter."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path("apps/openplate_mobile")
VERSION_FILES = (
    Path("pyproject.toml"),
    APP / "pubspec.yaml",
    Path("custom_components/openplate/manifest.json"),
    Path("uv.lock"),
)
WORKFLOWS = ("ci.yml", "hacs.yml")
SEMVER = r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"


class ReleaseError(Exception):
    """An actionable failure; never rolls back user files or rewrites remote history."""


def version_tuple(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(SEMVER, version):
        raise ReleaseError("Version muss X.Y.Z sein, ohne v, Buildnummer oder Prerelease.")
    return tuple(map(int, version.split(".")))


class Commands:
    def __init__(self, root: Path):
        self.root = root

    def run(
        self,
        *args: str,
        cwd: Path | None = None,
        capture: bool = False,
        env: dict[str, str] | None = None,
        timeout: int = 1800,
    ) -> str:
        if not capture:
            print("+ " + shlex.join(args), flush=True)
        try:
            result = subprocess.run(
                args,
                cwd=cwd or self.root,
                env=env,
                check=True,
                text=True,
                stdout=subprocess.PIPE if capture else None,
                stderr=subprocess.PIPE if capture else None,
                timeout=timeout,
            )
        except subprocess.CalledProcessError as error:
            raise ReleaseError(
                f"Befehl fehlgeschlagen: {shlex.join(args)}\n{error.stderr or ''}"
            ) from error
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError(f"{shlex.join(args)}: {error}") from error
        return result.stdout or ""

    def git(self, *args: str) -> str:
        return self.run("git", *args, capture=True)


@dataclass(frozen=True)
class Versions:
    version: str
    build: int
    contents: dict[Path, str]


def read_versions(root: Path) -> Versions:
    contents = {path: (root / path).read_text(encoding="utf-8") for path in VERSION_FILES}
    project = re.search(r"(?ms)^\[project\]\n(.*?)(?=^\[|\Z)", contents[VERSION_FILES[0]])
    python = re.search(r'(?m)^version = "([^"]+)"$', project[1]) if project else None
    flutter = re.search(r"(?m)^version: ([^+\s]+)\+(\d+)$", contents[VERSION_FILES[1]])
    manifest = json.loads(contents[VERSION_FILES[2]])["version"]
    package = re.search(
        r'(?ms)^\[\[package\]\]\nname = "openplate"\nversion = "([^"]+)"',
        contents[VERSION_FILES[3]],
    )
    if not python or not flutter or not package:
        raise ReleaseError("Versionsfelder in pyproject/pubspec/uv.lock nicht eindeutig gefunden.")
    version_tuple(python[1])
    if len({python[1], flutter[1], manifest, package[1]}) != 1:
        raise ReleaseError(
            "Versionsnummern in pyproject, pubspec, HA-Manifest und uv.lock weichen ab."
        )
    return Versions(python[1], int(flutter[2]), contents)


def updated_versions(current: Versions, target: str) -> dict[Path, str]:
    """Only the local project's lock entry changes; dependencies are never upgraded."""
    if version_tuple(target) <= version_tuple(current.version):
        raise ReleaseError("Die neue Version muss größer sein als die aktuelle Version.")
    py, pubspec, manifest, lock = VERSION_FILES
    result = dict(current.contents)
    result[py] = re.sub(
        r'(?ms)(^\[project\]\n.*?^version = ")[^"]+("$)',
        lambda m: m[1] + target + m[2],
        result[py],
        count=1,
    )
    result[pubspec] = re.sub(
        r"(?m)^version: [^\n]+$",
        f"version: {target}+{current.build + 1}",
        result[pubspec],
        count=1,
    )
    manifest_data = json.loads(result[manifest])
    manifest_data["version"] = target
    result[manifest] = json.dumps(manifest_data, indent=2, ensure_ascii=False) + "\n"
    result[lock] = re.sub(
        r'(?m)(^name = "openplate"\nversion = ")[^"]+("$)',
        lambda m: m[1] + target + m[2],
        result[lock],
        count=1,
    )
    return result


def repository(remote: str) -> str:
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?", remote.strip()
    )
    if not match:
        raise ReleaseError("origin muss ein GitHub-HTTPS- oder GitHub-SSH-Repository sein.")
    return match[1]


def uv_command() -> list[str]:
    if shutil.which("uv"):
        result = subprocess.run(["uv", "--version"], capture_output=True, text=True, check=True)
        match = re.search(r"uv (\d+)\.(\d+)", result.stdout)
        if match and tuple(map(int, match.groups())) >= (0, 9):
            return ["uv"]
    if shutil.which("uvx"):
        return ["uvx", "--from", "uv>=0.9,<1", "uv"]
    raise ReleaseError("uv >= 0.9 oder uvx installieren. Die alte System-uv-Version reicht nicht.")


def fingerprint(commands: Commands) -> str:
    """Do not accidentally commit files edited by an IDE/user while tests are running."""
    digest = hashlib.sha256()
    digest.update(commands.git("rev-parse", "HEAD").encode())
    digest.update(commands.git("diff", "--cached", "--binary").encode())
    paths = commands.git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
    for name in sorted(set(paths.split("\0")) - {""}):
        path = commands.root / name
        digest.update(name.encode() + b"\0")
        if path.exists() or path.is_symlink():
            digest.update(str(path.lstat().st_mode).encode() + b"\0")
        if path.is_symlink():
            digest.update(b"symlink:" + os.readlink(path).encode())
        elif path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        elif path.exists():
            raise ReleaseError(f"Nicht unterstütztes Verzeichnis/Submodul im Release: {name}")
        else:
            digest.update(b"deleted")
    return digest.hexdigest()


def verify_tag(commands: Commands, repo: str, tag: str, sha: str, resume: bool) -> bool:
    remote = commands.git(
        "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"
    )
    refs = dict(line.split()[::-1] for line in remote.splitlines())
    remote_sha = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    local = commands.git("tag", "--list", tag).strip()
    local_sha = commands.git("rev-parse", f"{tag}^{{commit}}").strip() if local else None
    if (remote_sha or local_sha) and not resume:
        raise ReleaseError(
            f"Tag {tag} existiert bereits. Kein Überschreiben; ggf. --resume verwenden."
        )
    if any(value and value != sha for value in (remote_sha, local_sha)):
        raise ReleaseError(f"Tag {tag} zeigt auf einen anderen Commit. Neue Version wählen.")
    releases = json.loads(
        commands.run(
            "gh",
            "release",
            "list",
            "--repo",
            repo,
            "--limit",
            "100",
            "--json",
            "tagName,isDraft,isPrerelease",
            capture=True,
        )
    )
    existing = next((release for release in releases if release["tagName"] == tag), None)
    if existing:
        if not resume or not remote_sha or existing["isDraft"] or existing["isPrerelease"]:
            raise ReleaseError(
                f"Release {tag} existiert bereits oder ist ein Draft/Prerelease. Manuell prüfen."
            )
        return True
    return False


def local_checks(commands: Commands, uv: list[str], skip_ios: bool) -> None:
    commands.run(*uv, "sync", "--extra", "dev", "--locked")
    commands.run(*uv, "run", "--locked", "ruff", "check", ".")
    commands.run(*uv, "run", "--locked", "pytest", "-q")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(commands.root) + os.pathsep + env.get("PYTHONPATH", "")
    commands.run(
        *uv,
        "run",
        "--no-project",
        "--python",
        "3.14",
        "--with",
        "homeassistant==2026.10.1",
        "python",
        "-m",
        "unittest",
        "discover",
        "-s",
        "integrations/home_assistant/tests",
        "-v",
        env=env,
    )
    app = commands.root / APP
    commands.run("flutter", "pub", "get", "--enforce-lockfile", cwd=app)
    commands.run("flutter", "analyze", "--no-pub", cwd=app)
    commands.run("flutter", "test", "--no-pub", cwd=app)
    if not skip_ios:
        commands.run("flutter", "build", "ios", "--release", "--no-codesign", "--no-pub", cwd=app)


def wait_for_ci(
    commands: Commands, repo: str, sha: str, timeout: int, clock=time.monotonic, sleep=time.sleep
) -> None:
    deadline = clock() + timeout
    previous = None
    while clock() < deadline:
        states = []
        for workflow in WORKFLOWS:
            runs = json.loads(
                commands.run(
                    "gh",
                    "run",
                    "list",
                    "--repo",
                    repo,
                    "--workflow",
                    workflow,
                    "--commit",
                    sha,
                    "--branch",
                    "main",
                    "--event",
                    "push",
                    "--limit",
                    "1",
                    "--json",
                    "headSha,status,conclusion,url",
                    capture=True,
                    timeout=60,
                )
            )
            if not runs:
                states.append(f"{workflow}: wartet auf Start")
                continue
            run = runs[0]
            if run["headSha"] != sha:
                raise ReleaseError("GitHub-Prüfung gehört nicht zum Release-Commit.")
            if run["status"] == "completed" and run["conclusion"] != "success":
                raise ReleaseError(f"{workflow} fehlgeschlagen/übersprungen: {run['url']}")
            states.append(
                f"{workflow}: " + ("success" if run["status"] == "completed" else run["status"])
            )
        summary = " | ".join(states)
        if summary != previous:
            print(summary, flush=True)
            previous = summary
        if all(state.endswith(": success") for state in states):
            return
        sleep(min(10, max(0, deadline - clock())))
    raise ReleaseError("Timeout beim Warten auf CI/HACS. Kein Tag und kein Release erstellt.")


@contextmanager
def release_lock(commands: Commands):
    lock = Path(commands.git("rev-parse", "--git-path", "openplate-release.lock").strip())
    if not lock.is_absolute():
        lock = commands.root / lock
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise ReleaseError(
            f"Ein Release läuft bereits. Nach einem Absturz Lock manuell prüfen: {lock}"
        ) from error
    try:
        os.write(fd, f"pid={os.getpid()}\n".encode())
        os.close(fd)
        yield
    finally:
        lock.unlink()


def publish(
    args: argparse.Namespace,
    commands: Commands,
    current: Versions,
    target: str,
    repo: str,
    notes: Path | None,
) -> None:
    if commands.git("branch", "--show-current").strip() != "main":
        raise ReleaseError("Nur Branch main wird veröffentlicht; kein automatischer Branchwechsel.")
    if commands.git("status", "--porcelain") and not args.include_working_tree:
        raise ReleaseError(
            "Uncommittete Änderungen: zuerst committen oder --include-working-tree angeben."
        )
    if sys.platform != "darwin" and not args.skip_ios_build:
        raise ReleaseError("iOS-Build benötigt macOS. Nur bewusst mit --skip-ios-build auslassen.")
    for program in ("gh", "flutter"):
        if not shutil.which(program):
            raise ReleaseError(f"{program} ist nicht im PATH.")
    uv = uv_command()
    commands.run("gh", "auth", "status")
    commands.git("var", "GIT_AUTHOR_IDENT")
    commands.git("fetch", "origin", "main")
    commands.git("merge-base", "--is-ancestor", "origin/main", "HEAD")
    sha = commands.git("rev-parse", "HEAD").strip()
    tag = f"v{target}"
    already_published = verify_tag(commands, repo, tag, sha, args.resume)
    if already_published:
        if commands.git("status", "--porcelain"):
            raise ReleaseError(
                "Bereits veröffentlicht, aber lokale Änderungen vorhanden. Neue Version wählen."
            )
        print(f"Bereits veröffentlicht: https://github.com/{repo}/releases/tag/{tag}")
        return
    if (
        commands.git("tag", "--list", tag).strip()
        or commands.git("ls-remote", "--tags", "origin", f"refs/tags/{tag}").strip()
    ) and commands.git("status", "--porcelain"):
        raise ReleaseError("Ein vorhandenes Tag darf keine weiteren Änderungen aufnehmen.")
    if not args.resume:
        if read_versions(commands.root) != current:
            raise ReleaseError("Versionsdateien wurden während der Vorbereitung verändert.")
        for path, content in updated_versions(current, target).items():
            (commands.root / path).write_text(content, encoding="utf-8")
    snapshot = fingerprint(commands)
    local_checks(commands, uv, args.skip_ios_build)
    if fingerprint(commands) != snapshot:
        raise ReleaseError(
            "Dateien/Index wurden während der Prüfungen verändert. "
            "Änderungen prüfen, dann fortsetzen."
        )
    read_versions(commands.root)
    commands.run("git", "diff", "--check")
    if commands.git("status", "--porcelain"):
        commands.run("git", "add", "--all")
        commands.run("git", "diff", "--cached", "--check")
        commands.run("git", "commit", "-m", f"Release {tag}")
    sha = commands.git("rev-parse", "HEAD").strip()
    committed_snapshot = fingerprint(commands)
    commands.run("git", "push", "origin", "HEAD:refs/heads/main")
    wait_for_ci(commands, repo, sha, args.timeout)
    if fingerprint(commands) != committed_snapshot:
        raise ReleaseError("Arbeitsstand wurde gleichzeitig verändert.")
    if commands.git("status", "--porcelain") or commands.git("rev-parse", "HEAD").strip() != sha:
        raise ReleaseError("Lokaler Arbeitsstand wurde nach dem Push verändert.")
    remote_head = commands.git("ls-remote", "origin", "refs/heads/main").split()
    if not remote_head or remote_head[0] != sha:
        raise ReleaseError(
            "origin/main wurde inzwischen verändert. Kein Tag auf veraltetem Stand erstellt."
        )
    if verify_tag(commands, repo, tag, sha, resume=True):
        print(f"Bereits veröffentlicht: https://github.com/{repo}/releases/tag/{tag}")
        return
    if not commands.git("ls-remote", "--tags", "origin", f"refs/tags/{tag}").strip():
        if not commands.git("tag", "--list", tag).strip():
            commands.run("git", "tag", "-a", tag, sha, "-m", f"OpenPlate {tag}")
        commands.run("git", "push", "origin", f"refs/tags/{tag}")
    release_args = [
        "gh",
        "release",
        "create",
        tag,
        "--repo",
        repo,
        "--verify-tag",
        "--target",
        sha,
        "--title",
        f"OpenPlate {tag}",
        "--latest",
    ]
    release_args += ["--notes-file", str(notes)] if notes else ["--generate-notes"]
    commands.run(*release_args)
    print(f"Veröffentlicht: https://github.com/{repo}/releases/tag/{tag}")
    print(
        "HA anschließend über HACS aktualisieren und neu starten. "
        "iPhone-App separat signieren/installieren."
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "version", nargs="?", help="Neue Version X.Y.Z; Standard: nächste Patch-Version"
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Wirklich ändern, prüfen, committen und veröffentlichen",
    )
    parser.add_argument(
        "--include-working-tree",
        action="store_true",
        help="ALLE nicht ignorierten Änderungen mit veröffentlichen",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Angegebene bereits vorbereitete Version fortsetzen, ohne erneut zu erhöhen",
    )
    parser.add_argument(
        "--notes",
        type=Path,
        help="Release-Notizen; sonst docs/releases/vX.Y.Z.md oder GitHub-generiert",
    )
    parser.add_argument(
        "--skip-ios-build", action="store_true", help="Bewusst keinen lokalen iOS-Build ausführen"
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=1800,
        help="Maximale Wartezeit auf GitHub-CI/HACS in Sekunden",
    )
    args = parser.parse_args(argv)
    target = args.version
    try:
        commands = Commands(ROOT)
        if Path(commands.git("rev-parse", "--show-toplevel").strip()).resolve() != ROOT:
            raise ReleaseError("Das Skript muss Teil des OpenPlate-Repositorys sein.")
        current = read_versions(ROOT)
        target = target or ".".join(
            map(str, (*version_tuple(current.version)[:2], version_tuple(current.version)[2] + 1))
        )
        version_tuple(target)
        if args.resume and (not args.version or target != current.version):
            raise ReleaseError(
                "--resume braucht die explizite, aktuell vorbereitete Version X.Y.Z."
            )
        if not args.resume:
            updated_versions(current, target)
        if args.timeout <= 0:
            raise ReleaseError("--timeout muss positiv sein.")
        repo = repository(commands.git("remote", "get-url", "origin"))
        notes = args.notes or ROOT / "docs" / "releases" / f"v{target}.md"
        notes = notes.resolve()
        if args.notes and not notes.is_file():
            raise ReleaseError(f"Release-Notizen fehlen: {notes}")
        if not notes.is_file():
            notes = None
        status = commands.git("status", "--short")
        build = current.build if args.resume else current.build + 1
        print(f"OpenPlate {current.version} → {target}, iPhone-Build {build}\nZiel: {repo} / main")
        print(f"Notizen: {notes or 'GitHub-generiert'}")
        print("Lokaler iOS-Build: " + ("AUSGELASSEN" if args.skip_ios_build else "ja, unsigniert"))
        if status:
            print("Vorhandene Änderungen:\n" + status)
        print(
            "Ablauf: Versionen → Python/HA/Flutter-Tests → iOS-Build "
            "→ Commit/Push → CI + HACS → Tag → Release"
        )
        if not args.publish:
            print(
                "PLAN: Keine Dateien, Commits, Tags oder Veröffentlichungen geändert. "
                "Mit --publish ausführen."
            )
            if status and not args.include_working_tree:
                print(
                    "Für den echten Lauf: Änderungen vorher committen oder ausdrücklich "
                    "--include-working-tree nutzen."
                )
            return 0
        with release_lock(commands):
            publish(args, commands, current, target, repo, notes)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release abgebrochen: {error}", file=sys.stderr)
        print(
            "Keine automatische Rücksetzung. Arbeitsstand/Index prüfen; "
            "vorhandene Commits/Tags bleiben erhalten.",
            file=sys.stderr,
        )
        if target:
            print(
                f"Nach Prüfung ggf.: python3 scripts/release.py {target} --resume --publish",
                file=sys.stderr,
            )
            print(
                "Bei uncommitteten Änderungen zusätzlich --include-working-tree.", file=sys.stderr
            )
        return 1
    except KeyboardInterrupt:
        print(
            "Release unterbrochen. Arbeitsstand prüfen und mit --resume fortsetzen.",
            file=sys.stderr,
        )
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
