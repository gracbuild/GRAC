# Organization Practices - grid heading before/after load (2026-10-08)

## Problem
While the grid loaded, the header showed the screen-definition columns
(Code / Practice Instance Name / Applicability Status / Implementation Status /
Practice Owner / Practice Instance Count / Actions). After the rows arrived,
practice.js replaced them with the practice columns (Practice Code / Practice
Name / Applicability Status / Implementation Status / Owner / Origin Type /
Actions). Two different headings for one screen.

Cause: `Manage.cshtml` rendered `Model.Columns` into `#practiceGridHead`, and
`renderGridHeader()` (run at the start of every load) re-rendered the same
generic columns (with `columnLabel` turning `Name` into "Practice Instance
Name"). Only the after-load renderers (`renderRequirementControlGroups` -- now `renderRequirementStatementGroups`, see organization-practices-statement-grouping.md,
`renderStatementPracticeRows`) used the practice columns.

## Change (UI only - no API / DB change)
- `wwwroot/js/practice.js`
  - New `practiceGridHeadings` + `practiceHeaderCells()` - single source for
    the Organization Practices header (bulk-select cell, 6 columns, Actions).
  - `renderGridHeader()` uses it for `organization-requirements`, so the
    loading header equals the loaded header.
  - `renderStatementPracticeRows()` and each Control group's header row use
    the same helper (the three hand-written copies are gone).
  - `listColumnCount()` returns the practice column count for this screen, so
    Loading / empty / error rows and the Control group row span the table.
  - `renderRows()` empty state now goes through `setListMessage()` (same
    colspan rule) instead of `screen.Columns.length + 1`.
- `Views/Practice/Manage.cshtml` - no server-rendered header for
  `organization-requirements`; practice.js draws it.

After deploying: Ctrl+F5 (practice.js is cached).
