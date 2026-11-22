# Spreadsheet Formulas

This extension evaluates Excel-compatible formulas in ordinary GFM Markdown tables.

Formulas remain Markdown source:

```markdown
| A | B | C | Total |
|---|---|---|-------|
| 2 | 3 | 4 | =SUM(A2:C2) |
```

The calculated value is shown in the editor while the saved file keeps the formula.
Use the table context menu and choose **Keep Values** to replace selected formulas
with their current results in one undoable edit.

Only a single leading `=` starts a formula. Markdown highlight syntax such as
`==important==` stays plain highlighted text and is never evaluated.

Supported references include `A1`, `$A$1`, and `A1:B10`. The initial function set
is documented in the extension release notes.
