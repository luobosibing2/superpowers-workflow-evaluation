# Local Development Rules

This repository is a Codex-only slim profile, not the upstream complete workflow.

- Keep exactly four skill directories: `brainstorming`, `writing-plans`,
  `systematic-debugging`, and `verification-before-completion`.
- Do not add session-start injection or a top-level workflow router.
- Do not make planning authorize implementation or delegation.
- Keep the four `SKILL.md` files at or below 500 lines in total.
- Update `tests/test_slim_contract.py` when the public skill contract changes.
