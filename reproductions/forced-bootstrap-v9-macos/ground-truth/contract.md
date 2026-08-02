# Hidden behavior contract

## Trigger and compatibility

1. `gh project item-list NUMBER --owner OWNER --field NAME` adds the selected
   project field as a table column.
2. `--field` is repeatable. Repeated columns preserve request order.
3. `--field-id ID` provides an equivalent repeatable node-ID form.
4. `--field` and `--field-id` cannot be combined.
5. Either field-selection form conflicts with explicit formatted/JSON output,
   because that output does not use table columns. The command fails clearly
   rather than ignoring a flag.
6. With neither flag, existing table and formatted output remain unchanged.
7. Help includes a realistic repeated-field example.

## Resolution and diagnostics

1. Field-name matching is case-insensitive.
2. The displayed header uses the canonical field name returned by GitHub.
3. Unknown names fail with actionable candidate field names.
4. Ambiguous case-insensitive names fail and identify candidate IDs in a
   deterministic order.
5. Unknown IDs fail with candidate fields shown as name and ID.
6. Requested columns and their values are associated by field node ID, not by
   coincidental display name or list position.

## Data path and pagination

1. Normal field resolution reuses the project field definitions already
   returned by the item-list query; it does not add an unconditional preflight
   lookup.
2. When the returned field-definition connection indicates more pages and
   extra columns were requested, resolution obtains the complete field list.
3. No extra field-list pagination request is made when no extra column was
   requested.
4. Failures while retrieving or resolving fields stop output and propagate a
   useful error; partially misleading tables are not printed.

## Value rendering

Each selected value is rendered as one human-readable table cell:

- absent or unknown value: empty cell;
- text: text;
- number: compact decimal representation without forced trailing zeros;
- single-select: option name;
- date: date string;
- iteration and milestone: title;
- labels: names joined by comma and space;
- pull requests: URLs joined by comma and space;
- repository: URL;
- users: logins joined by comma and space;
- reviewers: user logins and team names joined by comma and space.

Carriage returns are removed and newlines become spaces so multiline values do
not corrupt row alignment. Multi-column and multi-item output keeps every value
under the correct header. An item missing one selected field gets an empty cell
without shifting later columns.

## End-to-end acceptance

The command performs owner/project resolution, obtains items and field
definitions, resolves requested fields, maps each item's field values, and
renders the extended table through the existing command path. Existing limit,
query, no-results, host-capability, and exporter behavior remains compatible
unless a documented flag conflict applies.

## Non-requirements

- No new UI outside the CLI table.
- No required class, function, or file layout.
- No requirement to reproduce the historical patch.
- Automated tests are validation evidence, not rubric points by themselves.

