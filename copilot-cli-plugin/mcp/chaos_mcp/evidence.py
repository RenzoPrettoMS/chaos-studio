# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Durable evidence store access (E2-T2 / E2-T3).

The store lives **outside** the repository and outside any session `tmp/`
directory so that a repo or session wipe cannot destroy a run's evidence
(field evidence F12). Its root is `$CHAOS_EVIDENCE_ROOT`, defaulting to a
per-user application-data directory. Layout::

    $CHAOS_EVIDENCE_ROOT/<scopeHash>/<runId>/{artifacts,raw,rendered}/<name>

Artifacts that must outlive any single run — the mechanism-class ledger — are
keyed by scope instead, under `<scopeHash>/_scope/...`.

This module is the MCP-facing half. It exists **only** so evidence written by
one session is reachable from another; the PowerShell skills keep writing
`$STARTCHAOS_STATE_PATH` as the source of truth and mirror into the same
layout via `scripts/State.ps1`.

Three properties are load-bearing and are enforced here rather than by
convention, because everything reachable through `evidence_get` is reachable
by the model:

1. **Path canonicalization.** Every requested path is resolved *after* symlink
   resolution and rejected unless it is inside the resolved evidence root.
   Absolute paths, drive-qualified paths, UNC paths and `..` traversal are
   rejected before resolution as well.
2. **Key denylist.** Anything under `$CHAOS_KEY_DIR` is rejected even if it
   somehow resolves inside the root. The approval key `k_session` is never
   written to this store.
3. **Redaction.** Values are redacted on write *and* on read, by key name and
   by value shape, so key material that reached an artifact by accident still
   cannot leave through a tool result.

Writes are atomic (temp file + `os.replace`) under an exclusive lock file and
carry a monotonic revision counter, re-expressing the prototype's locked-state
semantics without porting its state engine.
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import shutil
import sys
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

#: Environment variable naming the durable evidence root.
EVIDENCE_ROOT_ENV = "CHAOS_EVIDENCE_ROOT"

#: Environment variable naming the approval-key directory. Never readable
#: through any `evidence_*` entry point.
KEY_DIR_ENV = "CHAOS_KEY_DIR"

#: Environment variable overriding the retention window used by `evidence_prune`.
RETENTION_DAYS_ENV = "CHAOS_EVIDENCE_RETENTION_DAYS"

#: Q9 lean: 90-day retention of aggregates.
DEFAULT_RETENTION_DAYS = 90

#: The three per-run subdirectories. `artifacts` holds schema-validated
#: artifacts, `raw` holds unprocessed query responses, `rendered` holds reports.
KINDS = ("artifacts", "raw", "rendered")

#: Placeholder substituted for anything that looks like key material.
REDACTED = "[REDACTED]"

_APP_DIR = "chaos-studio"

#: `scopeHash` / `runId` are structural path segments and are deliberately far
#: stricter than artifact names.
_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

#: Directory holding artifacts keyed by `scopeId` rather than by `runId` — the
#: mechanism-class ledger must outlive any single run. The leading underscore
#: is what makes it unforgeable: `_SEGMENT` requires an alphanumeric first
#: character, so no caller-supplied `run_id` can ever land here.
SCOPE_SCOPED_DIR = "_scope"

#: Default and maximum page sizes for `evidence_list`.
DEFAULT_PAGE_SIZE = 100
MAX_PAGE_SIZE = 1000

#: Exact key names whose value is always secret.
_DENY_KEY_EXACT = frozenset(
    {
        "key",
        "keys",
        "secret",
        "secrets",
        "password",
        "passwd",
        "pwd",
        "token",
        "credential",
        "credentials",
        "authorization",
        "auth",
        "sas",
        "signature",
        "sig",
    }
)

#: Substrings that make a key name secret-bearing wherever they appear.
_DENY_KEY_HINTS = (
    "secret",
    "password",
    "passwd",
    "token",
    "credential",
    "apikey",
    "api_key",
    "accountkey",
    "account_key",
    "primarykey",
    "secondarykey",
    "sharedaccesskey",
    "connectionstring",
    "connection_string",
    "privatekey",
    "private_key",
    "clientsecret",
    "client_secret",
    "approvalkey",
    "approval_key",
    "sessionkey",
    "session_key",
    "k_session",
    "ksession",
    "bearer",
    "sastoken",
    "sas_token",
)

_BEARER = re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{16,}", re.IGNORECASE)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*")
_HEXKEY = re.compile(r"^[A-Fa-f0-9]{32,}$")
#: Base64 without `-`, `_` or `.`, so Azure resource IDs, GUIDs and ISO
#: timestamps (all of which contain one of those) can never match.
_B64KEY = re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$")

_LOCK_TIMEOUT_SECONDS = 10.0
_LOCK_POLL_SECONDS = 0.01
#: A lock older than this belonged to a process that died mid-write.
_LOCK_STALE_SECONDS = 60.0


class EvidenceError(Exception):
    """Raised for any denied or impossible evidence operation."""

    def __init__(self, message: str, error_type: str = "EvidenceError") -> None:
        super().__init__(message)
        self.error_type = error_type


# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------


def default_evidence_root() -> Path:
    """Per-user application-data location for the store (Q9).

    Explicitly not a repository or session `tmp/` path: F12 recorded two
    `tmp/` wipes that destroyed two runs' worth of evidence.
    """
    home = Path.home()
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or home / "AppData" / "Local")
    elif sys.platform == "darwin":
        base = home / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or home / ".local" / "share")
    return base / _APP_DIR / "evidence"


def default_key_dir() -> Path:
    """Approval-key directory. A sibling of the store, never inside it."""
    return default_evidence_root().parent / "keys"


def evidence_root() -> Path:
    """The configured store root, expanded but not created."""
    override = os.environ.get(EVIDENCE_ROOT_ENV)
    root = Path(override).expanduser() if override else default_evidence_root()
    return root


def key_dir() -> Path:
    """The configured approval-key directory, expanded but not created."""
    override = os.environ.get(KEY_DIR_ENV)
    return Path(override).expanduser() if override else default_key_dir()


def retention_days() -> int:
    raw = os.environ.get(RETENTION_DAYS_ENV)
    if not raw:
        return DEFAULT_RETENTION_DAYS
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_RETENTION_DAYS
    return value if value > 0 else DEFAULT_RETENTION_DAYS


def _resolved_root(create: bool = False) -> Path:
    root = evidence_root()
    if create:
        root.mkdir(parents=True, exist_ok=True)
    # `strict=False` so a not-yet-created root still canonicalizes; symlinks in
    # any existing ancestor are followed here, which is the whole point.
    return root.resolve()


# ---------------------------------------------------------------------------
# Path canonicalization (mandatory)
# ---------------------------------------------------------------------------


def _is_under(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


def _resolve_existing_dir(directory: Path) -> Path:
    """Resolve the deepest existing ancestor, then re-attach the missing tail.

    `Path.resolve()` on the full path is not reliable on Windows while another
    thread is creating or replacing the leaf (it can raise a sharing violation
    mid-walk). Directories, by contrast, are only ever created — never removed
    — during a write, so resolving the directory chain is stable. Symlinked
    directories still resolve, which is what the containment check depends on.
    """
    tail: list[str] = []
    current = directory
    while current.parent != current and not current.exists():
        tail.append(current.name)
        current = current.parent
    resolved = current.resolve()
    for name in reversed(tail):
        resolved = resolved / name
    return resolved


def _resolve_symlinks(path: Path) -> Path:
    """Canonicalize `path`, following symlinks on both the tail and the leaf."""
    resolved = _resolve_existing_dir(path.parent) / path.name
    # `is_symlink()` never opens the file, so it cannot hit a sharing violation.
    if resolved.is_symlink():
        resolved = resolved.resolve()
    return resolved


def _check_segment(value: str, label: str) -> str:
    if not isinstance(value, str) or not _SEGMENT.fullmatch(value):
        raise EvidenceError(
            f"{label} must be a single safe path segment (got {value!r}).",
            "EvidencePathDenied",
        )
    return value


def resolve_within_root(relative_path: str, create: bool = False) -> Path:
    """Canonicalize `relative_path` against the evidence root, or refuse.

    Rejects, in order: absolute/drive-qualified/UNC paths, `..` traversal, any
    result that leaves the resolved root after symlink resolution, and any
    result under `$CHAOS_KEY_DIR`.
    """
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise EvidenceError("path must be a non-empty string.", "EvidencePathDenied")

    normalized = relative_path.replace("\\", "/")
    candidate = Path(normalized)

    if ":" in normalized:
        # Drive qualifiers and NTFS alternate data streams. No legitimate
        # evidence name contains a colon.
        raise EvidenceError(
            f"drive-qualified or stream-qualified paths are not addressable: {relative_path!r}",
            "EvidencePathDenied",
        )
    if candidate.is_absolute() or candidate.drive or normalized.startswith("//"):
        raise EvidenceError(
            f"absolute paths are not addressable in the evidence store: {relative_path!r}",
            "EvidencePathDenied",
        )
    if any(part == ".." for part in candidate.parts):
        raise EvidenceError(
            f"path traversal is not permitted: {relative_path!r}", "EvidencePathDenied"
        )

    root = _resolved_root(create=create)
    resolved = _resolve_symlinks(root / candidate)

    if not _is_under(resolved, root):
        raise EvidenceError(
            f"path resolves outside the evidence root: {relative_path!r}",
            "EvidencePathDenied",
        )

    keys = key_dir()
    try:
        keys_resolved = keys.resolve()
    except OSError:  # pragma: no cover - resolve() is non-strict on all targets
        keys_resolved = keys
    if _is_under(resolved, keys_resolved) or resolved == keys_resolved:
        raise EvidenceError(
            "the approval-key directory is on the evidence path denylist.",
            "EvidencePathDenied",
        )

    return resolved


def _run_segment(run_id: str | None) -> str:
    """Map an optional `run_id` onto its path segment.

    `None` means the artifact is keyed by `scopeId` and must outlive every run,
    so it lands in the unforgeable `_scope` directory instead of a run's.
    """
    if run_id is None:
        return SCOPE_SCOPED_DIR
    return _check_segment(run_id, "run_id")


def _item_path(
    scope_hash: str,
    run_id: str | None,
    kind: str,
    name: str,
    create: bool = False,
) -> Path:
    _check_segment(scope_hash, "scope_hash")
    run_segment = _run_segment(run_id)
    if kind not in KINDS:
        raise EvidenceError(
            f"kind must be one of {', '.join(KINDS)} (got {kind!r}).", "EvidencePathDenied"
        )
    if not isinstance(name, str) or not name.strip():
        raise EvidenceError("name must be a non-empty string.", "EvidencePathDenied")
    return resolve_within_root(f"{scope_hash}/{run_segment}/{kind}/{name}", create=create)


def _resolve_name(name: str | None, artifact_type: str | None) -> str:
    """Accept the item identity under either spelling.

    The design contract calls this parameter `artifact_type` and `evidence_list`
    filters on it; the on-disk envelope and the PowerShell mirror call it
    `name`. They are the same string — the item's file name — so both spellings
    are accepted here rather than leaving a caller who writes `name` and filters
    `artifact_type` with a silently empty page.
    """
    if name and artifact_type and name != artifact_type:
        raise EvidenceError(
            "name and artifact_type name the same item and must not differ "
            f"(got {name!r} and {artifact_type!r}).",
            "EvidenceBadArgument",
        )
    return name or artifact_type or ""


def _is_ascii_digits(value: str) -> bool:
    """True only for a non-empty run of ASCII `0`-`9`.

    `str.isdigit()` alone is not a safe pre-check for `int()`: it is True for
    non-ASCII digit characters, some of which `int()` rejects outright (e.g.
    the superscript `\u00b2`, which would escape as a raw `ValueError`) while
    others it silently accepts (e.g. the Devanagari `\u0967`, which would be
    read as 1). Both are reachable from model-callable tool arguments, so the
    accepted alphabet is pinned to ASCII.
    """
    return bool(value) and value.isascii() and value.isdigit()


def _coerce_revision(value: Any) -> int | None:
    """Turn a caller-supplied `expected_revision` into an int, or a named error.

    Reachable from a model-callable tool, where JSON arguments are not type
    enforced end to end, so a bad value must land in the `{ok, errorType}`
    envelope rather than escape as a `ValueError`. `bool` is excluded
    explicitly because it is a subclass of `int` and would coerce to 0/1.
    """
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise EvidenceError(
            f"expected_revision must be a non-negative integer (got {value!r}).",
            "EvidenceBadRevision",
        )
    if isinstance(value, str):
        if not _is_ascii_digits(value.strip()):
            raise EvidenceError(
                f"expected_revision must be a non-negative integer (got {value!r}).",
                "EvidenceBadRevision",
            )
        value = int(value.strip())
    if value < 0:
        raise EvidenceError(
            f"expected_revision must be a non-negative integer (got {value!r}).",
            "EvidenceBadRevision",
        )
    return value


# ---------------------------------------------------------------------------
# Redaction (mandatory)
# ---------------------------------------------------------------------------


def _key_is_secret(key: str) -> bool:
    lowered = key.lower()
    if lowered in _DENY_KEY_EXACT:
        return True
    return any(hint in lowered for hint in _DENY_KEY_HINTS)


def _value_looks_secret(value: str) -> bool:
    stripped = value.strip()
    if not stripped:
        return False
    return bool(
        _BEARER.search(stripped)
        or _JWT.search(stripped)
        or _HEXKEY.fullmatch(stripped)
        or _B64KEY.fullmatch(stripped)
    )


def _redact_into(obj: Any, pointer: str, found: list[str]) -> Any:
    if isinstance(obj, dict):
        out: dict[str, Any] = {}
        for key, value in obj.items():
            child = f"{pointer}/{_escape_pointer(key)}" if isinstance(key, str) else pointer
            if isinstance(key, str) and _key_is_secret(key):
                out[key] = REDACTED
                found.append(child)
            else:
                out[key] = _redact_into(value, child, found)
        return out
    if isinstance(obj, (list, tuple)):
        return [_redact_into(item, f"{pointer}/{index}", found) for index, item in enumerate(obj)]
    if isinstance(obj, str) and _value_looks_secret(obj):
        found.append(pointer)
        return REDACTED
    return obj


def _escape_pointer(token: str) -> str:
    """RFC 6901 escaping, so a key containing `/` cannot forge a pointer."""
    return token.replace("~", "~0").replace("/", "~1")


def redact_with_paths(obj: Any) -> tuple[Any, list[str]]:
    """Redact `obj` and report the JSON Pointers that were redacted.

    Only the *locations* are reported, never the removed values, so the
    `redactions[]` field of a tool result cannot leak what it suppressed.
    """
    found: list[str] = []
    redacted = _redact_into(obj, "", found)
    return redacted, found


def redact(obj: Any) -> Any:
    """Recursively redact secret-bearing keys and secret-shaped values.

    Applied on write and again on read: an artifact that captured key material
    under an innocuous key name still cannot leave through `evidence_get`.
    """
    return redact_with_paths(obj)[0]


# ---------------------------------------------------------------------------
# Atomic, revisioned writes
# ---------------------------------------------------------------------------


class _FileLock:
    """Exclusive lock scoped to one evidence item.

    `O_CREAT | O_EXCL` is atomic on every platform the plugin supports, which
    keeps concurrent `evidence_put` calls from interleaving their
    read-revision / write-revision pairs.
    """

    def __init__(self, target: Path) -> None:
        self._path = target.with_name(target.name + ".lock")

    def acquire(self) -> None:
        deadline = time.monotonic() + _LOCK_TIMEOUT_SECONDS
        while True:
            try:
                fd = os.open(self._path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.close(fd)
                return
            except OSError as exc:
                # Windows reports EACCES (not EEXIST) while a lock file is in
                # the delete-pending state, which happens routinely when
                # writers contend.
                if exc.errno not in (errno.EEXIST, errno.EACCES):
                    raise
                try:
                    age = time.time() - self._path.stat().st_mtime
                except OSError:
                    age = 0.0
                if age > _LOCK_STALE_SECONDS:
                    self._path.unlink(missing_ok=True)
                    continue
                if time.monotonic() > deadline:
                    raise EvidenceError(
                        f"timed out acquiring the evidence lock at {self._path}.",
                        "EvidenceLocked",
                    ) from exc
                time.sleep(_LOCK_POLL_SECONDS)

    def release(self) -> None:
        try:
            self._path.unlink(missing_ok=True)
        except OSError:  # pragma: no cover - best effort unlock
            pass


@contextmanager
def _item_lock(target: Path) -> Iterator[None]:
    lock = _FileLock(target)
    lock.acquire()
    try:
        yield
    finally:
        lock.release()


def _atomic_write(target: Path, payload: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f"{target.name}.tmp.{os.getpid()}.{time.time_ns()}")
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, target)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:  # pragma: no cover - best effort cleanup
            pass
        raise


def _read_envelope(target: Path) -> dict[str, Any] | None:
    try:
        raw = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise EvidenceError(
            f"evidence item {target.name} is not valid JSON: {exc}", "EvidenceCorrupt"
        ) from exc
    if not isinstance(parsed, dict):
        raise EvidenceError(
            f"evidence item {target.name} is not an evidence envelope.", "EvidenceCorrupt"
        )
    return parsed


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _ok(result: Any) -> dict[str, Any]:
    return {"ok": True, "result": result}


def _fail(exc: EvidenceError) -> dict[str, Any]:
    return {"ok": False, "errorType": exc.error_type, "error": str(exc)}


# ---------------------------------------------------------------------------
# Public operations
# ---------------------------------------------------------------------------


def evidence_put(
    scope_hash: str,
    run_id: str | None,
    name: str = "",
    data: Any = None,
    kind: str = "artifacts",
    expected_revision: int | None = None,
    artifact_type: str | None = None,
) -> dict[str, Any]:
    """Write one evidence item atomically, bumping its revision counter.

    `run_id=None` keys the artifact by scope instead of by run (the
    mechanism-class ledger must outlive any single run). `artifact_type` is an
    accepted alias for `name`, so the same vocabulary works across put, get and
    the `evidence_list` filter. `expected_revision` is the
    optimistic-concurrency guard: pass the revision the caller believes is
    current — or `0` to assert the item does not yet exist — and the write is
    refused with `EvidenceRevisionMismatch` if it has moved on.
    """
    try:
        item_name = _resolve_name(name, artifact_type)
        expected = _coerce_revision(expected_revision)
        target = _item_path(scope_hash, run_id, kind, item_name, create=True)
        redacted, redactions = redact_with_paths(data)
        target.parent.mkdir(parents=True, exist_ok=True)
        with _item_lock(target):
            previous = _read_envelope(target)
            current = int(previous.get("revision", 0)) if previous else 0
            if expected is not None and expected != current:
                raise _RevisionMismatch(expected, current)
            revision = current + 1
            envelope = {
                "evidenceSchemaVersion": 1,
                "scopeHash": scope_hash,
                "runId": run_id,
                "kind": kind,
                "name": item_name,
                "revision": revision,
                "writtenAt": _now_iso(),
                "redacted": True,
                "data": redacted,
            }
            payload = json.dumps(envelope, indent=2, sort_keys=False, default=str) + "\n"
            _atomic_write(target, payload)
    except _RevisionMismatch as exc:
        return exc.envelope()
    except EvidenceError as exc:
        return _fail(exc)
    except OSError as exc:
        return _fail(EvidenceError(str(exc), "EvidenceIOError"))
    return _ok(
        {
            "scopeHash": scope_hash,
            "runId": run_id,
            "kind": kind,
            "name": item_name,
            "artifactType": item_name,
            "revision": revision,
            "relativePath": _relative_path(scope_hash, run_id, kind, item_name),
            "path": str(target),
            "bytes": len(payload.encode("utf-8")),
            "sha256": hashlib.sha256(payload.encode("utf-8")).hexdigest(),
            "digest": hashlib.sha256(payload.encode("utf-8")).hexdigest(),
            "redactions": redactions,
        }
    )


def evidence_get(
    scope_hash: str,
    run_id: str | None,
    name: str = "",
    kind: str = "artifacts",
    artifact_type: str | None = None,
) -> dict[str, Any]:
    """Read one evidence item back, redacted, from any session.

    `artifact_type` is an accepted alias for `name`.
    """
    try:
        item_name = _resolve_name(name, artifact_type)
        target = _item_path(scope_hash, run_id, kind, item_name)
        envelope = _read_envelope(target)
        if envelope is None:
            where = f"run {run_id}" if run_id is not None else f"scope {scope_hash}"
            raise EvidenceError(
                f"no evidence item {kind}/{item_name} for {where}.", "EvidenceNotFound"
            )
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
    except EvidenceError as exc:
        return _fail(exc)
    except OSError as exc:
        return _fail(EvidenceError(str(exc), "EvidenceIOError"))
    result = redact(envelope)
    # `artifact` is the contract name for the payload; `data` is the deprecated
    # on-disk alias, retained because it is the envelope field the PowerShell
    # half writes. See evidence-contract.md §10.
    result["artifact"] = result.get("data")
    result["path"] = str(target)
    result["digest"] = digest
    return _ok(result)


def _relative_path(scope_hash: str, run_id: str | None, kind: str, name: str) -> str:
    return f"{scope_hash}/{run_id if run_id is not None else SCOPE_SCOPED_DIR}/{kind}/{name}"


class _RevisionMismatch(Exception):
    """Optimistic-concurrency failure, reported with both revisions."""

    def __init__(self, expected: int, actual: int) -> None:
        super().__init__(
            f"expected revision {expected} but the item is at revision {actual}."
        )
        self.expected = expected
        self.actual = actual

    def envelope(self) -> dict[str, Any]:
        return {
            "ok": False,
            "errorType": "EvidenceRevisionMismatch",
            "error": str(self),
            "expectedRevision": self.expected,
            "actualRevision": self.actual,
        }


def _page_size(max_items: int | None) -> int:
    # `bool` is a subclass of `int`; excluded so `True` cannot become a page of 1.
    if isinstance(max_items, bool) or not isinstance(max_items, int) or max_items <= 0:
        return DEFAULT_PAGE_SIZE
    return min(max_items, MAX_PAGE_SIZE)


def _decode_token(token: str | None) -> int:
    if token is None:
        return 0
    if not isinstance(token, str) or not _is_ascii_digits(token):
        raise EvidenceError(
            "continuation_token is not a token issued by evidence_list.", "EvidenceBadToken"
        )
    return int(token)


def _run_items(
    scope_hash: str,
    run_id: str | None,
    run_dir: Path,
    artifact_type: str | None,
) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for kind in KINDS:
        kind_dir = run_dir / kind
        if not kind_dir.is_dir():
            continue
        for item in sorted(kind_dir.iterdir()):
            if not item.is_file() or item.name.endswith(".lock") or ".tmp." in item.name:
                continue
            if artifact_type is not None and item.name != artifact_type:
                continue
            envelope = _read_envelope(item) or {}
            items.append(
                {
                    "name": item.name,
                    "kind": kind,
                    "relativePath": _relative_path(scope_hash, run_id, kind, item.name),
                    "revision": envelope.get("revision"),
                    "writtenAt": envelope.get("writtenAt"),
                    "bytes": item.stat().st_size,
                }
            )
    return sorted(items, key=lambda entry: (entry["name"], entry["kind"]))


def evidence_list(
    scope_hash: str | None = None,
    run_id: str | None = None,
    artifact_type: str | None = None,
    max_items: int | None = None,
    continuation_token: str | None = None,
) -> dict[str, Any]:
    """List scopes, the runs of a scope, or the items of a run.

    Never returns item contents. `artifact_type` filters on the item's exact
    `name` as passed to `evidence_put`. Item listings — including a scope's
    `scopeItems`, which accumulate across every run in the scope — are paged:
    `continuationToken` is present only while more items remain.
    """
    try:
        root = _resolved_root(create=True)
        if scope_hash is None:
            scopes = sorted(p.name for p in root.iterdir() if p.is_dir())
            return _ok({"root": str(root), "scopeHashes": scopes})

        offset = _decode_token(continuation_token)
        limit = _page_size(max_items)
        scope_dir = resolve_within_root(_check_segment(scope_hash, "scope_hash"))
        if run_id is None:
            runs = (
                sorted(
                    p.name
                    for p in scope_dir.iterdir()
                    if p.is_dir() and p.name != SCOPE_SCOPED_DIR
                )
                if scope_dir.is_dir()
                else []
            )
            all_scope_items = (
                _run_items(scope_hash, None, scope_dir / SCOPE_SCOPED_DIR, artifact_type)
                if (scope_dir / SCOPE_SCOPED_DIR).is_dir()
                else []
            )
            scope_page = all_scope_items[offset : offset + limit]
            scope_next = offset + len(scope_page)
            scope_token = str(scope_next) if scope_next < len(all_scope_items) else None
            return _ok(
                {
                    "root": str(root),
                    "scopeHash": scope_hash,
                    "runIds": runs,
                    "scopeItems": scope_page,
                    "continuationToken": scope_token,
                }
            )

        run_dir = resolve_within_root(f"{scope_hash}/{_check_segment(run_id, 'run_id')}")
        all_items = _run_items(scope_hash, run_id, run_dir, artifact_type)
        page = all_items[offset : offset + limit]
        next_offset = offset + len(page)
        token = str(next_offset) if next_offset < len(all_items) else None
    except EvidenceError as exc:
        return _fail(exc)
    except OSError as exc:
        return _fail(EvidenceError(str(exc), "EvidenceIOError"))
    return _ok(
        {
            "root": str(root),
            "scopeHash": scope_hash,
            "runId": run_id,
            "items": page,
            "continuationToken": token,
        }
    )


def evidence_prune(days: int | None = None) -> dict[str, Any]:
    """Delete run directories untouched for longer than the retention window.

    Not exposed as an MCP tool: destructive maintenance stays operator-driven
    (`chaos-evidence`, Epic 11). Documented in
    `references/chaos/evidence-contract.md`.
    """
    window = days if days and days > 0 else retention_days()
    cutoff = time.time() - window * 86400
    removed: list[str] = []
    try:
        root = _resolved_root(create=True)
        for scope_dir in sorted(p for p in root.iterdir() if p.is_dir()):
            for run_dir in sorted(p for p in scope_dir.iterdir() if p.is_dir()):
                # Scope-keyed artifacts (the mechanism-class ledger) must
                # outlive every run in the scope, so they are never pruned.
                if run_dir.name == SCOPE_SCOPED_DIR:
                    continue
                newest = max(
                    (f.stat().st_mtime for f in run_dir.rglob("*") if f.is_file()),
                    default=run_dir.stat().st_mtime,
                )
                if newest < cutoff:
                    shutil.rmtree(run_dir, ignore_errors=True)
                    removed.append(f"{scope_dir.name}/{run_dir.name}")
    except OSError as exc:
        return _fail(EvidenceError(str(exc), "EvidenceIOError"))
    return _ok({"root": str(root), "retentionDays": window, "removed": removed})
