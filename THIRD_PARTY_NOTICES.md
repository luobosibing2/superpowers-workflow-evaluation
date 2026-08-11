# Third-party notices

The repository root MIT license applies to original framework, adapter,
publication, analysis, and website material that the repository owner is
authorized to publish. It does not replace third-party licenses or ownership.

## Workflow Arena provenance

The experiment architecture was independently reorganized from the public
[`kvenux/workflow-arena`](https://github.com/kvenux/workflow-arena) source at
commit `0b87a36de85494b15b9fe9991c55fdeeb1dcf713`. No upstream `.git` history,
Fork relationship, mirror metadata, or commit objects were copied. The publisher
has asserted the right to reorganize and release the framework material included
here; this notice records provenance rather than relicensing unrelated upstream
content.

## GitHub CLI

The task baseline, oracle, limited baseline excerpts in judge material, and
candidate-generated product diffs are derived from
[`cli/cli`](https://github.com/cli/cli), which is distributed under its upstream
MIT license.

- baseline: `ae66a1c02e08366858f3070664f493afbe0cdf18`
- oracle: `efe3f165dd297c85fff11473dbf586f2d39fbf86`
- oracle tree: `b4539ca014121861158af022e743c494436f1b1f`

Frozen public task evidence also references GitHub CLI
[issue 13816](https://github.com/cli/cli/issues/13816),
[pull request 13823](https://github.com/cli/cli/pull/13823), and its public review
comments. User-authored issue and review text remains attributable to its
authors and is included only as experiment evidence.

## Superpowers

Full workflow inputs are pinned to
[`obra/superpowers@d884ae04`](https://github.com/obra/superpowers/commit/d884ae04edebef577e82ff7c4e143debd0bbec99).
The Slim treatment is pinned to
[`luobosibing2/superpowers-slim@fa07307f`](https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed).
Vendored Slim skill inputs retain their original MIT license and copyright
notice, including `Copyright (c) 2025 Jesse Vincent`. The later five-method Slim
revision `8607c8c` and its added `code-review` method were not part of the tested
treatment.

## OpenAI Codex

OpenAI Codex CLI 0.145.0 and the hosted `gpt-5.6-terra/high` model produced
candidate, operator, reviewer, and judge evidence. The CLI binary, credentials,
actor homes, raw authenticated sessions, and service-side implementation are not
redistributed.

Exact experiment pins and published artifact hashes are recorded in
[`experiments/five-method/experiment.json`](experiments/five-method/experiment.json)
and [`data/manifest.json`](data/manifest.json).

## cyijun Workflow Arena Luna skill panel

The factual Luna skill-panel v1 CSV and JSON result tables under
[`data/luna-skill-panel-v1/`](data/luna-skill-panel-v1/) are attributed to
[`cyijun/workflow-arena@c746e58`](https://github.com/cyijun/workflow-arena/tree/c746e58bf850bd9bc8326f2172383a28841b2364/reports/luna-skill-panel-v1).
That repository did not declare a repository license at the pinned commit.
Accordingly, this repository preserves the byte-level provenance of the public
factual tables and does not redistribute its HTML report, report prose, or claim
that those records are relicensed under this repository's MIT license. The
source repository also does not publish the raw sessions, per-run diffs, test
logs, or individual judge-verdict files behind the compact tables.
