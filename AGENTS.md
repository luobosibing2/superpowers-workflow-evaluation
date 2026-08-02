# Repository Guidelines

## Purpose

This repository publishes a controlled workflow experiment, its sanitized
evidence, analysis, and dashboard. Treat frozen experiment inputs and canonical
results as evidence, not as application fixtures that may be rewritten for
convenience.

## Structure

- `engine/` and `scripts/`: reusable lifecycle and deterministic validation.
- `experiments/`: frozen task, treatment, rubric, and actor inputs.
- `reproductions/`: macOS adapters and self-tests; runtime state stays ignored.
- `results/` and `data/`: canonical sanitized evidence and derived manifests.
- `docs/`: analysis whose numeric claims must rebuild from published evidence.
- `site/`: the five-method dashboard; it consumes published data only.

## Evidence rules

Never commit credentials, actor homes, raw unredacted sessions, external
checkouts, or machine-specific absolute paths. Do not replace, delete, or merge
superseded evidence into canonical results. Any changed metric must be rebuilt
from the underlying verdicts and run receipts.

## Validation

Run deterministic PowerShell self-tests, `node scripts/audit-results.mjs`, and
the site build/tests before publishing. Real candidate or judge execution is not
part of ordinary repository validation and must never be triggered implicitly.
