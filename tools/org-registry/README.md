# tools/org-registry

Generator for the Organization Registry (migrations 569-572,
`docs/organization-registry.md`). `spec.py` is the single field specification
(one entry per workbook column of sheets 01-13); `generate.py` writes the
schema, procedures, controlled values / menu, sample-data migrations and the
screen's field definitions from it and the workbook, so they cannot drift.

    pip install openpyxl
    set ORG_REGISTRY_WORKBOOK=C:\path\GRAC_Organization_Registry_Muthoot_Lakeshore_Pilot_Populated.xlsx
    python generate.py

Edit `spec.py`, regenerate, and review the diff of the generated files.
Do not hand-edit the generated files.
