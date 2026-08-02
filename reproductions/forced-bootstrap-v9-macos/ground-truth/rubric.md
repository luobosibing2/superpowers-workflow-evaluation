# Blind product rubric (100 points)

## 1. CLI surface and compatibility - 15

- Repeatable name and ID flags work and preserve order: 7
- Name/ID mutual exclusion and format-output conflict: 5
- Existing no-field behavior and useful help remain intact: 3

## 2. Resolution and diagnostics - 15

- Case-insensitive name resolution with canonical headers: 5
- Unknown name/ID errors contain useful candidates: 6
- Ambiguity is detected deterministically: 4

## 3. Query path and pagination - 15

- Reuses already-returned definitions on the normal path: 5
- Correctly handles projects with more than one field page: 7
- Avoids unnecessary pagination and propagates failures safely: 3

## 4. Field-value rendering - 25

- Scalar types (text, number, select, date): 7
- Structured types (iteration, milestone, repository): 5
- Multi-value types (labels, PRs, users, reviewers): 8
- Missing/unknown values and multiline normalization: 5

## 5. End-to-end table behavior - 15

- Headers and values line up for multiple fields/items: 8
- Values are matched by field ID and missing cells do not shift data: 5
- Existing item-list command path remains reachable: 2

## 6. Failure safety and maintainability - 15

- Invalid input or lookup failure cannot emit a misleading partial result: 6
- Integrates with established repository helpers and data types: 5
- Diff is focused and does not break adjacent behavior: 4

## Validation labels

Record independently from the score:

- Verified: reproduced by a real command or hidden test.
- Static: confirmed from a complete reachable code path.
- Unverified: plausible but not exercised.
- Contradicted: a runnable failure or unreachable path disproves it.

