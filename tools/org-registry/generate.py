"""Regenerates the Organization Registry artefacts from spec.py + the workbook.

    python generate.py            (ORG_REGISTRY_WORKBOOK=<path to the .xlsx>)

Writes database/569-572 (+ rollbacks) and
src/PracticeManagement.Web/wwwroot/js/Organization/org-registry-fields.js.
Requires: pip install openpyxl.
"""
import os
import gen_sql, gen_seed, gen_js

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
DB = os.path.join(ROOT, "database")
out = {
    "569_org_registry_schema.sql": gen_sql.gen_schema(),
    "569_org_registry_schema_rollback.sql": gen_sql.gen_schema_rollback(),
    "570_org_registry_masters_menu.sql": gen_seed.gen_masters(),
    "570_org_registry_masters_menu_rollback.sql": gen_seed.gen_masters_rollback(),
    "571_org_registry_procedures.sql": gen_sql.gen_procs(),
    "571_org_registry_procedures_rollback.sql": gen_sql.gen_procs_rollback(),
    "572_org_registry_sample_data.sql": gen_seed.gen_sample(),
    "572_org_registry_sample_data_rollback.sql": gen_seed.gen_sample_rollback(),
}
for name, text in out.items():
    with open(os.path.join(DB, name), "w", newline="\n") as fh:
        fh.write(text)
with open(os.path.join(ROOT, "src", "PracticeManagement.Web", "wwwroot", "js", "Organization", "org-registry-fields.js"), "w", newline="\n") as fh:
    fh.write(gen_js.gen())
print("Generated", len(out) + 1, "files.")
