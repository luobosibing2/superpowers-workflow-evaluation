# Superpowers Workflow Evaluation

An evidence-first framework for controlled comparisons of coding-agent workflows.
The repository separates reusable experiment machinery, frozen experiment inputs,
platform adaptations, canonical evidence, analysis, and the rendered dashboard
into distinct commits.

The public dataset and conclusions are added in later commits. No credentials,
actor homes, external source checkouts, or unredacted model-session archives are
part of the repository.

## Lifecycle

The reusable lifecycle is:

```text
Prepare -> Run -> Freeze -> Audit -> Judge -> Summarize
```

The pack-based engine lives in `engine/`; generic lifecycle utilities live in
`scripts/`; blind-judge schemas and prompts live in `evaluation/`.

## Safety boundary

Real experiment execution can consume substantial model quota. Start with the
deterministic self-tests and dry-run interfaces documented in
[`engine/README.md`](engine/README.md).

## License

Original code and documentation in this repository are MIT licensed. Third-party
projects, frozen task inputs, and generated product diffs retain their respective
licenses; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
