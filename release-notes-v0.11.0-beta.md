# Nota Plugins 0.11.0-beta

This release adds the first official extension that writes table metadata through
the Nota extension API.

## Spreadsheet Formulas 0.1.0

- Evaluates Excel-compatible formulas in ordinary GFM Markdown tables.
- Supports `A1`, `$A$1` and range references.
- Includes arithmetic, logical, text, lookup and aggregation functions.
- Keeps formula source in the Markdown file and renders results temporarily.
- Provides a localized **Keep Values** table action that writes selected results
  as one undoable edit.
- Detects formula cycles and reports `#CYCLE!`.
- Distinguishes formula syntax from Markdown highlights, escaped equals and
  inline code.
- Requires Nota 0.17.0-beta or another host providing extension API `v2.4`.
- Enables spreadsheet table mode while installed and locks that setting to avoid
  a partially configured formula workflow.

Older official extensions continue to use API `v2.3` and remain compatible with
the `v2.4` host.

## Validation

- Extension compatibility and manifest checks pass.
- Lua syntax and undeclared-global checks pass.
- Headless formula, function, lookup, cycle and action tests pass.

The previous extension release is Nota Plugins 0.10.0-beta.
