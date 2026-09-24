# Custom Gap -> Practice mapping (migration 382)

Adds the ability to map relevant Practice(s) to a Custom Gap on the
**Add Custom Gap** form, reusing the same cascading Practice Picker that
Risk Analysis already uses. No new selector was created.

## Reused control
`wwwroot/js/practice-picker.js` (`window.__practicePicker`, migration 282)
-- the same component Risk Centre and Exception Centre mount. On the Add
Custom Gap dialog it is opened in a small dialog (`#gapMapPracticeModal`),
the chosen practice is added to a mapped-practices chip list, and the
selected practice ids ride along in the create payload.

Data source is unchanged: `/practice/api/practice-picker/*`
(PracticePickerService).

## Rule
At least one Practice must be mapped to create a Custom Gap. Enforced in
the UI (submit is blocked) and in the API (`OpenAsync` returns
`PRACTICE_REQUIRED` when the list is empty). The stored procedure stays
tolerant (inserts whatever ids are passed) so no non-UI caller breaks.

## Database (migration 382)
- New table `grac_practice.custom_gap_practice_map` -- one row per mapped
  practice, mirroring `risk_practice_map` (261): `custom_gap_id`,
  `practice_id`, frozen `practice_name`/`practice_code`, `organization_id`,
  `mapped_by_employee_id`, `record_status_id`; `UNIQUE(custom_gap_id, practice_id)`.
- `sp_custom_gap_open` re-issued from its live (368) body with one new
  OPTIONAL trailing parameter `@practice_ids_json` (JSON array of practice
  ids). After the gap row is inserted, one map row per id is created for
  practices in the same organization, with name/code frozen from
  `grac_practice.practice`. NULL/empty -> no rows (older callers unaffected).
- New `sp_custom_gap_practice_map_list @custom_gap_id` -- returns the
  active mapped practices for read-only display.
- Rollback: `382_custom_gap_practice_map_rollback.sql`.

## API
- `POST /api/practice/gaps/custom` (`CustomGapController.Open`,
  `CustomGapService.OpenAsync`) -- request model `CustomGapOpenRequest`
  gains `PracticeIds` (`IReadOnlyList<long>?`, optional/last). Serialized
  to JSON and passed as `@practice_ids_json`.
- `GET /api/practice/gaps/custom/{id}/practices` -- new read endpoint
  (`CustomGapController.Practices` -> `GetPracticesAsync` ->
  `sp_custom_gap_practice_map_list`). Returns `{ data: [ { customGapPracticeMapId,
  customGapId, practiceId, practiceName, practiceCode, mappedDt } ] }`.
  The Web tier reaches it through the existing `custom/{**path}` GET proxy
  (`GapsController.CustomProxyGet`), which requires `organizationId` on the
  query string.

## UI
- `Views/Practice/Partials/gaps.cshtml` -- Add Custom Gap dialog gains a
  "Mapped Practices" chip list + "Map practice" button and a native
  `<dialog>` (`#gapMapPracticeModal`) hosting the shared picker; loads
  `practice-picker.js`. Selected ids are sent as `practiceIds`.
- `wwwroot/js/GapLifecycle/gap-detail.js` and `gap-view.js` -- render the
  mapped practices read-only (they fetch the GET endpoint above). Custom
  gaps have no edit form, so post-creation the mapping is display-only.
