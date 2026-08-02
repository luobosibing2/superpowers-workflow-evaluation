# Feature request

Improve `gh project item-list` so users can show selected project fields as
additional table columns without first looking up opaque field IDs.

Support repeatable selection by human-readable field name and an equivalent
repeatable field-ID form. Name matching should be case-insensitive. Existing
uses of `item-list` must remain compatible, and invalid or ambiguous selections
must fail with actionable errors rather than silently showing the wrong data.

The added columns should display sensible human-readable values for the field
types returned by GitHub Projects. Avoid an extra field-ID preflight request
when the data needed for resolution is already available.

Implement the feature completely in this repository and verify it locally.
The environment has no internet access. Do not attempt to recover upstream Git
history, search for an existing implementation, or inspect paths outside the
current repository. Treat the current repository as the complete workspace.

If you need product-owner input, finish the turn with exactly:

`OPERATOR_QUESTION: <your question>`

When the implementation is complete and verified, finish with exactly:

`IMPLEMENTATION_COMPLETE`
