# Superpowers: Codex Slim Profile

This local fork keeps four scoped methods from upstream Superpowers v6.1.1. It is
not a complete development workflow and does not bootstrap itself into every
conversation.

## Included skills

- `brainstorming`: clarify design decisions during Plan work.
- `writing-plans`: produce decision-complete plans for substantial changes.
- `systematic-debugging`: investigate failures from evidence to root cause.
- `verification-before-completion`: require fresh evidence before completion claims.

Codex, direct user instructions, and `AGENTS.md` own the overall workflow.
Multi-agent delegation, worktree preparation, implementation, review, and branch
completion remain native Codex or separate-plugin responsibilities.

## Local installation

Register this checkout as the `superpowers-local` marketplace and install
`superpowers@superpowers-local`. Use a new Codex task after installation so the
skill inventory is loaded from the new plugin version.

## Provenance

The baseline is upstream commit
`d884ae04edebef577e82ff7c4e143debd0bbec99` (v6.1.1). `RELEASE-NOTES.md` is
retained as historical upstream material; it does not describe this slim
profile's active contract.

## License

MIT License. See `LICENSE`.
