# Blind product judge

Evaluate the anonymous candidate only from the files in the current directory.
Do not inspect parent or sibling directories, Git history, environment state,
network resources, session metadata, or condition labels. Do not infer which
workflow produced the candidate.

Read `task.md`, `contract.md`, `rubric.md`, `product.diff`, `tests.log`, and all
files below `baseline/`. Treat `product.diff` as a patch applied to that frozen
baseline: unchanged baseline functions remain part of the candidate. Follow
calls into the supplied baseline context before deciding a behavior is present
or absent. If the supplied context is still insufficient, label the claim
`Unverified`; do not guess from a function name.

Score every rubric dimension independently. Tests affect the validation label
and confidence, not the requirement score by themselves. A passing broad test
does not prove an unexercised behavior. Never award behavior absent from the
diff merely because the contract requires it.

Use only these validation labels:

- `Verified`: directly supported by a command result in `tests.log`.
- `Static`: confirmed by a complete reachable path visible in the diff.
- `Unverified`: plausible, incomplete, or lacking sufficient evidence.
- `Contradicted`: disproved by the diff or a command result.

Return JSON matching the supplied schema. Keep each justification concise and
cite anonymous evidence only, such as a baseline path, diff hunk, or test
command. Do not name the underlying run.
