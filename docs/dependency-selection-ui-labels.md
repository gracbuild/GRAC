# Dependency selection UI — control sizing and self-describing labels (2026-09-28)

UI-only change. No API, service, database, filtering, cascade or save behaviour changed.

## Where the Dependency UI lives (traced)

| Screen | Implementation |
|---|---|
| Operationalize → Resolve workspace → Dependencies | `Views/Practice/Partials/resolve-workspace.cshtml` (`renderDependencyTable`, `buildAssetFilterCells`, `buildDepartmentPickerCell`, `wireCheckcombo`, `wireApplyTick`) |
| Risk Analysis → Impact Analysis / Impact Details, and every other Risk Centre page that mounts the scope panel (`.risk-map-host`: analysis, residual, review, view, acceptance) | `wwwroot/js/RiskCentre/risk-centre.js` (`depRow`, `assetFilterCells`, `departmentPickerCell`, `comboText`, `applyPersonFilters`) — one shared function, so all of those pages change together |

The two are separate implementations of the same pattern, so the same rules were applied to both. No shared code was introduced: each already had its own combo helpers.

## What changed

1. **Applicability control size (Resolve workspace).**
   - The Applicability select now uses the shared `.pm-input` control, set to the 40px height of the `.pm-checkcombo-trigger` pickers beside it (one scoped rule in the partial's `<style>`).
   - Table cells centre vertically.
   - The Risk Centre table has no Applicability column. Its pickers were already 40px.
2. **Self-describing control text.** Every combo now carries `data-checkcombo-empty`, the text it shows with nothing ticked:

   | Control | Text when nothing is ticked |
   |---|---|
   | Asset Category filter | All Asset Category |
   | Asset Sub-category filter | All Asset Sub Category |
   | Asset Type filter | All Asset Type |
   | Department picker (Person row) | All Department |
   | Person picker | All Users; "All Users (selected departments)" when departments are ticked |
   | Asset picker (beside the filters) | Select Assets |
   | Vendor / Team / Committee / Location / Business Function | Select... (unchanged; named by the Objects column) |

   The separate labels above these controls ("Asset category", "Asset sub-category", "Asset type", "Department", "Objects", "Assets", "Persons") are removed. The control text says the same thing. Each filter keeps its name as the trigger's `title` tooltip.
3. **Consistent empty text.** Each file now has one helper, `comboEmptyText(combo)`, which every "nothing ticked" path uses:
   - after a tick or untick;
   - after a No answer resets the row;
   - on the department → person narrowing.

   This also fixes an inconsistency: an asset filter used to change from "All" to "Select..." after a tick was removed.
4. **Row alignment.** With the labels gone, the Asset and Person filter rows (`.rw-asset-row`, `.risk-asset-row`) centre their controls on one line instead of aligning to the bottom.

## Not changed

- Applicability logic.
- Asset Category / Sub-category / Type filtering.
- Department → Person narrowing.
- The Vendor / Team / Committee / Location / Business Function pickers.
- Save paths, which read checkboxes and `data-object-name`, never the trigger text.
- Stored resolutions.

`practice.js` also calls `dependency-options` for its generic entity forms. Those are not this Dependency section: they have no applicability or filter rows, so they were left alone.

## Fix: "This category is not in the catalogue on this database." on every row (Operationalize)

**Symptom.** On Operationalize, one practice showed the warning on all seven dependency rows while the other practices of the same organization rendered correctly.

**Cause.** The table is painted by `loadDependencies()` and repainted by `loadDependencyTypes()` when the catalogue (`sp_resolve_dependency_type_list`) arrives. The repaint was gated on `dependencyCategories.length`, the categories already declared for the instance in `practice_instance_dependency`. For an instance with none declared yet, that list is empty, so the repaint never happened. The first paint, which ran before the catalogue arrived, stayed on screen with every `typeId` null.

**Fix** (`Views/Practice/Partials/resolve-workspace.cshtml` only):
- A `dependenciesLoaded` flag replaces the `.length` gate. The catalogue load repaints whenever the dependencies load has finished, with or without rows.
- A `depRenderSeq` token makes an older, still-awaiting `renderDependencyTable()` call yield to a newer one, so a slow first paint cannot overwrite the corrected one.

There are no database, API or behaviour changes beyond the table now rendering for instances that have no declared categories.
