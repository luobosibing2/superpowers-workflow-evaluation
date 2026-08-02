#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

import jsonschema


EXPECTED_DIMENSIONS = [
    ("CLI surface and compatibility", 15),
    ("Resolution and diagnostics", 15),
    ("Query path and pagination", 15),
    ("Field-value rendering", 25),
    ("End-to-end table behavior", 15),
    ("Failure safety and maintainability", 15),
]
ALLOWED_PACKAGE_FILES = {
    "contract.md",
    "judge-prompt.md",
    "manifest.json",
    "product.diff",
    "rubric.md",
    "task.md",
    "tests.log",
    "baseline/pkg/cmd/project/item-list/item_list.go",
    "baseline/pkg/cmd/project/shared/queries/queries.go",
    "baseline/pkg/cmd/project/shared/queries/resolve_fields.go",
}
LEAK_RE = re.compile(
    r"slim-0[1-3]|superpowers|brainstorming|writing-plans|systematic-debugging|"
    r"verification-before-completion|condition-map|operator-decisions|workflow-arena|"
    r"forced-bootstrap|/Users/|/private/var/|auth\.json|api[_ -]?key|secret[_ -]?key",
    re.IGNORECASE,
)
RAW_ESCAPE_RE = re.compile(
    r"\.\./|/Users/|/private/|\b(?:state|reports)/|evaluation/results|condition-map|blind-map|"
    r"\bgit\s|\bfind\s+/",
    re.IGNORECASE,
)


def load(path: Path):
    return json.loads(path.read_text())


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    source = root.parent / "forced-bootstrap-v9-macos"
    schema_path = root / "evaluation/judge-output.schema.json"
    prompt_path = root / "evaluation/judge-prompt.md"
    schema = load(schema_path)

    if sha256(schema_path) != sha256(source / "evaluation/judge-output.schema.json"):
        raise SystemExit("judge schema differs from frozen v9")
    if sha256(prompt_path) != sha256(source / "evaluation/judge-prompt.md"):
        raise SystemExit("judge prompt differs from frozen v9")

    blind_map = load(root / "state/blind-map.json")
    mapping = {entry["candidate"]: entry["run"] for entry in blind_map["candidates"]}
    if sorted(mapping) != ["Candidate-A", "Candidate-B", "Candidate-C"]:
        raise SystemExit("blind labels are not exactly Candidate-A..C")
    if sorted(mapping.values()) != ["slim-01", "slim-02", "slim-03"]:
        raise SystemExit("blind map is not a bijection over slim-01..03")

    package_hashes = {}
    for candidate in sorted(mapping):
        package = root / "evaluation/candidates" / candidate
        actual = {str(path.relative_to(package)) for path in package.rglob("*") if path.is_file()}
        if actual != ALLOWED_PACKAGE_FILES:
            raise SystemExit(f"unexpected package files for {candidate}: {sorted(actual ^ ALLOWED_PACKAGE_FILES)}")
        manifest_path = package / "manifest.json"
        manifest = load(manifest_path)
        if manifest["candidate"] != candidate or len(manifest["files"]) != 9:
            raise SystemExit(f"invalid package manifest for {candidate}")
        for entry in manifest["files"]:
            path = package / entry["name"]
            if path.stat().st_size != entry["bytes"] or sha256(path) != entry["sha256"]:
                raise SystemExit(f"package manifest mismatch: {candidate}/{entry['name']}")
        for path in package.rglob("*"):
            if path.is_file() and path.name != "manifest.json" and LEAK_RE.search(path.read_text(errors="replace")):
                raise SystemExit(f"anonymous input leakage: {candidate}/{path.relative_to(package)}")
        package_hashes[candidate] = sha256(manifest_path)

    thread_ids = set()
    sessions = []
    replicate_starts = {1: [], 2: []}
    replicate_ends = {1: [], 2: []}
    for replicate in (1, 2):
        for candidate in sorted(mapping):
            result_root = root / "evaluation/results" / f"judge-{replicate:02d}" / candidate
            final_path = result_root / "judge.final.json"
            metadata_path = result_root / "metadata.json"
            raw_path = result_root / "judge.jsonl"
            if not all(path.is_file() for path in (final_path, metadata_path, raw_path)):
                raise SystemExit(f"incomplete judge evidence: replicate={replicate} candidate={candidate}")
            verdict = load(final_path)
            jsonschema.Draft202012Validator(schema).validate(verdict)
            if verdict["candidate"] != candidate:
                raise SystemExit(f"candidate mismatch in verdict: {final_path}")
            observed_dimensions = [(row["name"], row["maxScore"]) for row in verdict["dimensions"]]
            if observed_dimensions != EXPECTED_DIMENSIONS:
                raise SystemExit(f"rubric dimension drift: {final_path}")
            if sum(row["score"] for row in verdict["dimensions"]) != verdict["totalScore"]:
                raise SystemExit(f"score sum mismatch: {final_path}")
            if LEAK_RE.search(final_path.read_text()):
                raise SystemExit(f"deblinding leak in verdict: {final_path}")

            metadata = load(metadata_path)
            expected_metadata = {
                "candidate": candidate,
                "replicate": replicate,
                "model": "gpt-5.6-terra",
                "reasoningEffort": "high",
                "sandbox": "read-only",
                "plugins": "none",
                "network": "disabled",
                "codexVersion": "codex-cli 0.145.0",
            }
            for key, value in expected_metadata.items():
                if metadata.get(key) != value:
                    raise SystemExit(f"judge metadata mismatch for {candidate}/{replicate}: {key}")
            replicate_starts[replicate].append(parse_time(metadata["startedAtUtc"]))
            replicate_ends[replicate].append(parse_time(metadata["endedAtUtc"]))

            started_ids = []
            completed_turns = 0
            commands = []
            for line in raw_path.read_text().splitlines():
                if not line.strip():
                    continue
                event = json.loads(line)
                if event.get("type") == "thread.started":
                    started_ids.append(event["thread_id"])
                if event.get("type") == "turn.completed":
                    completed_turns += 1
                item = event.get("item") or {}
                if event.get("type") == "item.completed" and item.get("type") == "command_execution":
                    command = item.get("command", "")
                    commands.append(command)
                    if RAW_ESCAPE_RE.search(command):
                        raise SystemExit(f"judge command crossed anonymous-package boundary: {raw_path}: {command}")
            if len(started_ids) != 1 or completed_turns != 1:
                raise SystemExit(f"judge thread/turn cardinality mismatch: {raw_path}")
            if started_ids[0] in thread_ids:
                raise SystemExit(f"duplicate judge thread id: {started_ids[0]}")
            thread_ids.add(started_ids[0])
            sessions.append(
                {
                    "candidate": candidate,
                    "replicate": replicate,
                    "threadId": started_ids[0],
                    "score": verdict["totalScore"],
                    "commandCount": len(commands),
                    "packageManifestSha256": package_hashes[candidate],
                    "verdictSha256": sha256(final_path),
                    "rawJsonlSha256": sha256(raw_path),
                    "metadataSha256": sha256(metadata_path),
                }
            )

    if min(replicate_starts[2]) < max(replicate_ends[1]):
        raise SystemExit("judge replicate 2 overlapped replicate 1")

    audit = {
        "schemaVersion": 1,
        "status": "passed",
        "judgeSessions": len(sessions),
        "uniqueThreads": len(thread_ids),
        "anonymousPackageLeakMatches": 0,
        "verdictLeakMatches": 0,
        "observedBoundaryCrossingCommands": 0,
        "replicate2StartedAfterReplicate1": True,
        "promptSha256": sha256(prompt_path),
        "schemaSha256": sha256(schema_path),
        "sessions": sessions,
    }
    output = root / "evaluation/judge-audit.json"
    output.write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n")
    print("Judge audit passed: 6 verdicts, 6 unique threads, zero anonymous-input/final leakage.")


if __name__ == "__main__":
    main()
