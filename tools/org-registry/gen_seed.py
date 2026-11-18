"""Generates 570 (controlled values, menu, Legal Entities list columns) and
572 (workbook sample data) from the workbook + spec."""
import re
from spec import ENTITIES, BY_KEY
from workbook import load
from gen_sql import S, HDR_RULE, lit, is_multi
from gen_sql import scalar_fields as _all_scalar_fields

def scalar_fields(ent):
    """The fields the sample-data import handles: not the GRAC fields taken
    over from Organization Administration (noseed) -- 572 predates them."""
    return [f for f in _all_scalar_fields(ent) if not f.get("noseed")]

DATA, MASTERS = load()
ISSUES = []          # (sheet, record, field, value, what happened)

def issue(sheet, rec, field, value, what):
    ISSUES.append((sheet, rec, field, value, what))

def q(v):
    return "NULL" if v is None else lit(v)

# ------------------------------------------------------------ master values
def master_rows():
    """[(group, value, order, is_workbook, note)]"""
    rows = []
    for g, vals in MASTERS.items():
        for i, v in enumerate(vals):
            rows.append((g, v, (i + 1) * 10, 1, None))
    present = {(g, v) for g, v, *_ in rows}
    # sample values that the lists do not contain
    for ent in ENTITIES:
        for f in ent["fields"]:
            if f["kind"] not in ("master", "multimaster", "locationtype", "designation"):
                continue
            g = f["group"] or ("LocationType" if f["kind"] == "locationtype" else None)
            for r in DATA[ent["key"]]:
                raw = r.get(f["key"])
                if raw is None:
                    continue
                vals = [x.strip() for x in raw.split(";")] if f["kind"] == "multimaster" else [raw]
                for v in vals:
                    if not v or (g, v) in present:
                        continue
                    present.add((g, v))
                    if g == "SecuredUnsecured":
                        note = ("Value used in the workbook sample rows (" + ent["sheet"] + "). 14 Field Dictionary links "
                                "'Secured / Unsecured' to YesNo; kept as its own list. Requires data-owner approval.")
                    else:
                        note = ("Value used in the workbook sample rows (" + ent["sheet"] + ") but not listed in "
                                "15 Masters & Codes. Requires data-owner approval.")
                    order = 900 + len([x for x in rows if x[0] == g])
                    rows.append((g, v, order, 0, note))
                    rec = r.get(ent["fields"][0]["key"]) if not ent["fields"][0]["app"] else r.get(ent["fields"][1]["key"])
                    issue(ent["sheet"], rec, f["label"], v,
                          f"Not in 15 Masters & Codes ({g}); added to the list flagged 'not approved' so the row loads as given.")
    return rows

def gen_masters():
    rows = master_rows()
    out = [f"""{HDR_RULE}
-- 570_org_registry_masters_menu.sql
--
-- Organization Registry -- controlled values, menu, Legal Entities list.
--
-- 1. org_registry_master_value <- workbook sheet "15 Masters & Codes"
--    (every list, every value, workbook order). Values that the workbook's
--    own SAMPLE rows use but sheet 15 does not list are added with
--    is_workbook_value = 0 and a source_note: the rows load exactly as
--    given and the screen shows the value flagged "not approved" until a
--    data owner approves it (START HERE: additions require data-owner
--    approval). Nothing is renamed or corrected.
-- 2. location_type_master / committee_designation_master gain the sheet-15
--    LocationType / CommitteeMemberDesignation values they lack: those
--    columns store the master's id (existing FKs), so the values have to
--    exist there. Existing values are untouched.
-- 3. Menu: 'org-registry' (Organization Registry), first in Organization
--    Management; 'organizations' renamed "Legal Entities" -- the existing
--    organization rows ARE the Legal Entity level now. Both rows sit under
--    the 'Organization' group, hidden from the Practice Management sidebar,
--    exactly as 512 placed 'organizations'. 274 is amended to match.
-- 4. sp_org_organization_list (latest body: 518) re-issued with the
--    Legal Entity's Organization and parent Legal Entity added -- the
--    Legal Entities list shows where each sits in the hierarchy.
--
-- Idempotent (MERGE / NOT EXISTS). ASCII only.
-- Rollback: 570_org_registry_masters_menu_rollback.sql
{HDR_RULE}
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF OBJECT_ID('{S}.org_registry_master_value','U') IS NULL
   OR COL_LENGTH('{S}.organization','registry_organization_id') IS NULL
BEGIN
    PRINT 'ABORT (570): run 569_org_registry_schema.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('{S}.menu_master','U') IS NULL
   OR COL_LENGTH('{S}.menu_master','show_in_sidebar') IS NULL
   OR NOT EXISTS (SELECT 1 FROM {S}.menu_master WHERE menu_key = N'Organization')
BEGIN
    PRINT 'ABORT (570): menu_master / the Organization group row is missing (274, 390, 512). Nothing was changed.';
    SET NOEXEC ON;
END
GO

-- 1. Controlled values.
MERGE {S}.org_registry_master_value AS t
USING (VALUES"""]
    vals = []
    for g, v, o, wbv, note in rows:
        vals.append(f"    ({lit(g)}, {lit(v)}, {o}, CAST({wbv} AS BIT), {q(note)})")
    out.append(",\n".join(vals))
    out.append(f""") AS s(master_group, value_label, display_order, is_workbook_value, source_note)
ON t.master_group = s.master_group AND t.value_label = s.value_label
WHEN MATCHED AND (t.display_order <> s.display_order OR t.is_workbook_value <> s.is_workbook_value
                  OR ISNULL(t.source_note, N'') <> ISNULL(s.source_note, N'')) THEN
    UPDATE SET display_order = s.display_order, is_workbook_value = s.is_workbook_value,
               source_note = s.source_note, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (master_group, value_label, display_order, is_workbook_value, source_note, status, entered_by)
    VALUES (s.master_group, s.value_label, s.display_order, s.is_workbook_value, s.source_note, N'Active', N'seed-570');
PRINT CONCAT('570: controlled values merged: ', @@ROWCOUNT);
GO
""")
    # location types
    lts = [v for g, v, *_ in rows if g == "LocationType"]
    lt_vals = []
    used = set()
    for i, v in enumerate(lts):
        code = re.sub(r"[^A-Z0-9]+", "_", v.upper()).strip("_")[:36]
        while code in used:
            code = code[:34] + str(i)
        used.add(code)
        lt_vals.append(f"    ({lit('WB_' + code)}, {lit(v)}, {200 + i * 10})")
    out.append(f"""-- 2a. Location types the registry needs (stored as location_type_id).
INSERT {S}.location_type_master (location_type_code, location_type_name, display_order, is_active, entered_by)
SELECT s.code, s.name, s.display_order, 1, N'seed-570'
  FROM (VALUES
{",\n".join(lt_vals)}
       ) s(code, name, display_order)
 WHERE NOT EXISTS (SELECT 1 FROM {S}.location_type_master x WHERE x.location_type_name = s.name)
   AND NOT EXISTS (SELECT 1 FROM {S}.location_type_master x WHERE x.location_type_code = s.code);
PRINT CONCAT('570: location types added: ', @@ROWCOUNT);
GO
""")
    des = [v for g, v, *_ in rows if g == "CommitteeMemberDesignation"]
    out.append(f"""-- 2b. Committee designations (stored as designation_id), as common
--     (organization_id NULL, is_system 1) designations.
INSERT {S}.committee_designation_master (designation_name, organization_id, is_system, is_active, entered_by)
SELECT s.name, NULL, 1, 1, N'seed-570'
  FROM (VALUES {", ".join("(" + lit(v) + ")" for v in des)}) s(name)
 WHERE NOT EXISTS (SELECT 1 FROM {S}.committee_designation_master x WHERE x.designation_name = s.name AND x.organization_id IS NULL);
PRINT CONCAT('570: committee designations added: ', @@ROWCOUNT);
GO

-- 3. Menu. 'org-registry' first (display_order 3, before 'organizations' 5);
--    'organizations' is the Legal Entities list now.
MERGE {S}.menu_master AS t
USING (VALUES
    -- 'Organizations & Legal Entities' / 1 since 575 (Organization
    -- Management keeps only these two areas); kept here too so a re-run of
    -- 570 does not undo 574 / 575.
    (N'org-registry', N'Organizations & Legal Entities', N'Practice/Index/org-registry', 1, N'sitemap', N'Organization')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-570');
PRINT CONCAT('570: org-registry menu row upserted: ', @@ROWCOUNT);
GO
UPDATE c SET parent_menu_id = p.menu_id, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
  FROM {S}.menu_master c JOIN {S}.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key = N'org-registry' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
UPDATE {S}.menu_master SET show_in_sidebar = 0, updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-registry' AND show_in_sidebar = 1;
UPDATE {S}.menu_master SET menu_name = N'Legal Entities', updated_by = N'seed-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations' AND menu_name <> N'Legal Entities';
PRINT CONCAT('570: organizations menu renamed Legal Entities: ', @@ROWCOUNT);
GO

-- 3b. Grants, as 511 did for Subscription Requests: every active
--     GLOBAL-scope role may VIEW, ADD and EDIT the registry (there is no
--     delete). Other roles are granted in Role Menu Permission as usual;
--     the Web tier additionally requires a GLOBAL-scope sign-in.
IF OBJECT_ID('{S}.organization_role_menu_permission','U') IS NOT NULL
   AND COL_LENGTH('{S}.organization_role','data_scope') IS NOT NULL
    EXEC sp_executesql N'
        INSERT {S}.organization_role_menu_permission
            (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
             status, record_status_id, entered_by, entered_dt)
        SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0, N''Active'',
               (SELECT TOP (1) record_status_id FROM {S}.record_status_master WHERE status_code = N''Active''),
               N''seed-570'', SYSUTCDATETIME()
          FROM {S}.organization_role r
          JOIN {S}.menu_master m ON m.menu_key = N''org-registry''
         WHERE r.data_scope = N''GLOBAL'' AND r.status = N''Active''
           AND NOT EXISTS (SELECT 1 FROM {S}.organization_role_menu_permission e
                            WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
        PRINT CONCAT(''570: GLOBAL-scope role grants inserted: '', @@ROWCOUNT);';
GO
""")
    # 4 org list re-issue
    # 518's sp_org_organization_list body, re-issued with the hierarchy columns.
    import os, re as _re
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "database",
                            "518_organization_list_spoc_email.sql")).read()
    body = _re.search(r"CREATE OR ALTER PROCEDURE grac_practice\.sp_org_organization_list.*?\nGO\n", src, _re.S).group(0)
    anchor = "           fw.total                 AS FrameworkCount,\n"
    assert anchor in body
    body = body.replace(anchor, anchor +
        "           -- 570: where the Legal Entity sits in the Organization Registry.\n"
        "           o.registry_organization_id AS RegistryOrganizationId,\n"
        "           ro.organization_code     AS RegistryOrganizationCode,\n"
        "           ISNULL(ro.registered_name, N'')  AS RegistryOrganization,\n"
        "           o.parent_organization_id AS ParentLegalEntityId,\n"
        "           ISNULL(po.organization_name, N'') AS ParentLegalEntity,\n")
    fa = "    FROM grac_practice.organization o\n"
    assert fa in body
    body = body.replace(fa, fa +
        "    LEFT JOIN grac_practice.registry_organization ro ON ro.registry_organization_id = o.registry_organization_id\n"
        "    LEFT JOIN grac_practice.organization po ON po.organization_id = o.parent_organization_id\n", 1)
    sa = "           OR o.organization_name LIKE '%' + @p_search + '%')"
    assert sa in body
    body = body.replace(sa, "           OR o.organization_name LIKE '%' + @p_search + '%'\n"
                            "           OR ro.registered_name LIKE '%' + @p_search + '%')")
    out.append(f"""-- 4. Legal Entities list (sp_org_organization_list, 518 body + the
--    hierarchy columns). Guarded on every column the 518 body reads.
IF COL_LENGTH('{S}.organization_employee','role_id') IS NULL
   OR COL_LENGTH('{S}.organization_role','role_code') IS NULL
   OR COL_LENGTH('{S}.repository_subscription','subscription_status') IS NULL
   OR COL_LENGTH('{S}.organization','subscription_start_dt') IS NULL
   OR COL_LENGTH('{S}.organization_employee','email') IS NULL
   OR OBJECT_ID('{S}.sp_org_organization_list','P') IS NULL
BEGIN
    PRINT 'ABORT (570 part 4): run 510 and 518 first. Parts 1-3 were applied.';
    SET NOEXEC ON;
END
GO
{body}
SET NOEXEC OFF;
GO
PRINT '--- 570 verification ---';
SELECT master_group, COUNT(*) AS [values], SUM(CASE WHEN is_workbook_value = 0 THEN 1 ELSE 0 END) AS not_in_sheet_15
  FROM {S}.org_registry_master_value GROUP BY master_group ORDER BY master_group;
SELECT menu_key, menu_name, status, show_in_sidebar, display_order,
       (SELECT p.menu_key FROM {S}.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM {S}.menu_master m WHERE menu_key IN (N'org-registry', N'organizations', N'subscription-requests') ORDER BY display_order;
GO
PRINT '570 complete. Sign out and in again -- the menu is read at sign-in.';
GO
""")
    return "\n".join(out)

def gen_masters_rollback():
    return f"""{HDR_RULE}
-- 570_org_registry_masters_menu_rollback.sql
-- Reverses 570: the org-registry menu row, the Legal Entities rename, the
-- location types / designations 570 added (only where nothing uses them),
-- the controlled values, and sp_org_organization_list back to 518.
{HDR_RULE}
SET NOCOUNT ON;
GO
DELETE p FROM {S}.organization_role_menu_permission p
  JOIN {S}.menu_master m ON m.menu_id = p.menu_id WHERE m.menu_key = N'org-registry';
DELETE FROM {S}.menu_master WHERE menu_key = N'org-registry';
UPDATE {S}.menu_master SET menu_name = N'Organizations', updated_by = N'rollback-570', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'organizations';
GO
DELETE lt FROM {S}.location_type_master lt
 WHERE lt.entered_by = N'seed-570'
   AND NOT EXISTS (SELECT 1 FROM {S}.organization_location l WHERE l.location_type_id = lt.location_type_id);
DELETE d FROM {S}.committee_designation_master d
 WHERE d.entered_by = N'seed-570'
   AND NOT EXISTS (SELECT 1 FROM {S}.organization_committee_member m WHERE m.designation_id = d.designation_id);
GO
IF OBJECT_ID('{S}.org_registry_master_value','U') IS NOT NULL
    DELETE FROM {S}.org_registry_master_value WHERE entered_by = N'seed-570';
GO
PRINT '570 rollback: re-run 518_organization_list_spoc_email.sql to restore sp_org_organization_list without the hierarchy columns.';
GO
"""

# ------------------------------------------------------------ 572 sample data
def resolve_and_annotate():
    """Python-side decisions about the sample rows (documented in ISSUES)."""
    orgs, les = DATA["organizations"], DATA["legal-entities"]
    seen = set()
    le_by_name = {l["legalName"]: l for l in les}
    org_of_le = {}
    for o in orgs:
        o["dataQualityNote"] = None
        le = le_by_name.get(o["registeredName"])
        if o["organizationCode"] in seen:
            orig = o["organizationCode"]
            new = "ORG-" + le["legalEntityCode"][3:] if le else orig + "-2"
            o["dataQualityNote"] = (f"The workbook ('01 Organization Profile', second data row) repeats Organization Code "
                                    f"{orig}, already used by the first row. Loaded as {new} so both rows can be stored; "
                                    f"confirm the intended code with the data owner.")
            issue("01 Organization Profile", o["registeredName"], "Organization Code*", orig,
                  f"Duplicate code; loaded as {new} (note kept on the record).")
            o["organizationCode"] = new
        seen.add(o["organizationCode"])
        if le:
            org_of_le[le["legalEntityCode"]] = o["organizationCode"]
    for l in les:
        l["registryOrganizationId"] = org_of_le.get(l["legalEntityCode"])
        if not l["registryOrganizationId"]:
            issue("02 Legal Entities", l["legalEntityCode"], "(Organization link)", None,
                  "No Organization row has this Legal Name; left unassigned.")
    # derived Legal Entity for sheets without one
    dept_le = {d["departmentCode"]: d["legalEntityId"] for d in DATA["departments"]}
    unit_le = {u["unitCode"]: u["legalEntityId"] for u in DATA["units"]}
    for t in DATA["teams"]:
        t["legalEntityId"] = dept_le.get(t["parentDepartmentId"]) or unit_le.get(t["organizationUnitId"])
    for p in DATA["people"]:
        p["legalEntityId"] = dept_le.get(p["departmentId"]) or unit_le.get(p["organizationUnitId"])
    comm_le = {c["committeeCode"]: c["legalEntityId"] for c in DATA["committees"]}
    for m in DATA["committee-members"]:
        m["legalEntityId"] = comm_le.get(m["committeeId"])
    # semicolon lists
    proc_codes = {p["processCode"] for p in DATA["processes"]}
    prefix_links = {}
    prod_codes = {p["productCode"] for p in DATA["products"]}
    for c in DATA["channels"]:
        for key, codes, label in (("productsSupported", prod_codes, "Products / Services Supported (codes)"),
                                  ("processesSupported", proc_codes, "Processes Supported (codes)")):
            out = []
            for code in [x.strip() for x in (c.get(key) or "").split(";") if x.strip()]:
                if code in codes:
                    out.append(code)
                    continue
                cands = sorted(x for x in codes if x.startswith(code + "-"))
                if len(cands) == 1:
                    out.append(cands[0])
                    prefix_links.setdefault((label, code, cands[0]), []).append(c["channelCode"])
                else:
                    issue("13 Delivery Channels", c["channelCode"], label, code, "No such code; not linked.")
            c[key] = out
    for (label, code, target), chans in sorted(prefix_links.items()):
        issue("13 Delivery Channels", ", ".join(chans), label, code,
              f"No process has this code; the one code that extends it, {target}, was linked.")
    for p in DATA["processes"]:
        p["keyRiskCategories"] = [x.strip() for x in (p.get("keyRiskCategories") or "").split(";") if x.strip()]

def src_table(ent, rows):
    """#s_<key> holding the raw workbook values (codes for references)."""
    t = "#s_" + ent["key"].replace("-", "_")
    cols = [f for f in scalar_fields(ent)]
    if ent["key"] in ("teams", "people", "committee-members") and not any(f["key"] == "legalEntityId" for f in cols):
        pass
    names = [f["key"] for f in cols]
    if "legalEntityId" not in names and ent["key"] not in ("organizations", "legal-entities"):
        names.append("legalEntityId")
    defs = ", ".join(f"[{n}] NVARCHAR(MAX) NULL" for n in names)
    lines = [f"CREATE TABLE {t} (rn INT NOT NULL, {defs});"]
    vals = []
    for i, r in enumerate(rows, 1):
        vals.append("(" + ", ".join([str(i)] + [q(r.get(n)) for n in names]) + ")")
    lines.append(f"INSERT {t} (rn, " + ", ".join(f"[{n}]" for n in names) + ") VALUES\n    " + ",\n    ".join(vals) + ";")
    return t, lines

def typed(f, expr):
    k = f["kind"]
    if k == "date": return f"TRY_CONVERT(DATE, {expr}, 23)"
    if k == "number": return f"TRY_CONVERT(BIGINT, {expr})"
    if k == "decimal": return f"TRY_CONVERT(DECIMAL(9,6), {expr})"
    return expr

STATUS_TO_RSID = ("(SELECT TOP (1) record_status_id FROM {S}.record_status_master WHERE status_code = "
                  "CASE WHEN {v} = N'Active' THEN N'Active' WHEN {v} IN (N'Draft', N'Pending Approval') THEN N'Draft' ELSE N'Inactive' END)")

ORDER = ["organizations", "legal-entities", "units", "locations", "departments", "functions", "teams", "people",
         "committees", "products", "processes", "channels", "committee-members"]

def gen_sample():
    resolve_and_annotate()
    L = [f"""{HDR_RULE}
-- 572_org_registry_sample_data.sql
--
-- Organization Registry -- loads the workbook's populated pilot rows
-- (sheets 01-13; Muthoot Finance / Lakeshore Hospital, SYNTHETIC pilot
-- examples per the workbook's START HERE disclaimer). Remarks and their
-- caveats ("illustrative", "to be confirmed", "sample data for pilot
-- only") are loaded verbatim; nothing is presented as verified.
--
-- HOW
--   * One #s_<area> table per sheet holds the workbook values as text, with
--     codes in the reference columns.
--   * Pass 1 matches or inserts every record and builds #m_<area> (workbook
--     code -> GRAC id). A record is matched by its code in its Legal Entity;
--     a Legal Entity also by its exact legal name (an existing GRAC
--     organization is ADOPTED, keeping its own code, never duplicated); a
--     location / team / committee / process also by its name in that Legal
--     Entity when the existing row has no code yet (the code is filled in).
--   * Pass 2 fills every column, references resolved through #m_<area>, and
--     ONLY WHERE THE COLUMN IS STILL EMPTY. So the first run loads the row,
--     a re-run changes nothing, and nothing anyone has edited since is ever
--     overwritten. Bridges are inserted only when missing.
--   * Inserted rows carry entered_by = 'seed-572' (the rollback deletes
--     exactly those).
--
-- WORKBOOK ISSUES handled here (also printed at the end, and listed in
-- docs/organization-registry.md):
""" ]
    hdr_issues = list(ISSUES)
    L_issues_at = len(L)
    # source tables
    # The work tables are session temp tables: drop any left by an earlier
    # run in the same query window (Msg 2714 otherwise), and again at the end.
    temps = [p + k.replace("-", "_") for k in ORDER for p in ("#s_", "#m_")]
    drops = [f"DROP TABLE IF EXISTS {t};" for t in temps]
    body = ["SET NOCOUNT ON;", "SET XACT_ABORT ON;",
            "-- Re-runnable in the same session: earlier runs' work tables go first."] + drops + ["BEGIN TRAN;", ""]
    for key in ORDER:
        ent = BY_KEY[key]
        _, lines = src_table(ent, DATA[key])
        body += [f"-- {ent['sheet']}"] + lines + [f"CREATE TABLE #m_{key.replace('-','_')} (code NVARCHAR(80) NOT NULL PRIMARY KEY, id BIGINT NOT NULL, inserted BIT NOT NULL DEFAULT 0);", ""]

    def m(key): return "#m_" + key.replace("-", "_")
    def s(key): return "#s_" + key.replace("-", "_")

    # ---------- pass 1
    body.append("-- ============================ PASS 1: match or insert ============================")
    # organizations
    ent = BY_KEY["organizations"]
    body.append(f"""-- Organizations (registry_organization): by code.
INSERT {m('organizations')} (code, id) SELECT s.organizationCode, t.registry_organization_id
  FROM {s('organizations')} s JOIN {S}.registry_organization t ON t.organization_code = s.organizationCode;
INSERT {S}.registry_organization (organization_code, registered_name, organization_type, industry, record_status, entered_by)
SELECT s.organizationCode, s.registeredName, s.organizationType, s.industry, s.recordStatus, N'seed-572'
  FROM {s('organizations')} s WHERE NOT EXISTS (SELECT 1 FROM {m('organizations')} x WHERE x.code = s.organizationCode);
INSERT {m('organizations')} (code, id, inserted) SELECT s.organizationCode, t.registry_organization_id, 1
  FROM {s('organizations')} s JOIN {S}.registry_organization t ON t.organization_code = s.organizationCode
 WHERE NOT EXISTS (SELECT 1 FROM {m('organizations')} x WHERE x.code = s.organizationCode);
""")
    # legal entities
    rs = STATUS_TO_RSID.format(S=S, v="s.recordStatus")
    body.append(f"""-- Legal Entities (organization): by code, else ADOPT an existing organization with the same legal name.
INSERT {m('legal-entities')} (code, id) SELECT s.legalEntityCode, t.organization_id
  FROM {s('legal-entities')} s JOIN {S}.organization t ON t.organization_code = s.legalEntityCode;
INSERT {m('legal-entities')} (code, id)
SELECT s.legalEntityCode, MIN(t.organization_id)
  FROM {s('legal-entities')} s JOIN {S}.organization t ON t.organization_name = s.legalName
 WHERE NOT EXISTS (SELECT 1 FROM {m('legal-entities')} x WHERE x.code = s.legalEntityCode)
 GROUP BY s.legalEntityCode;
INSERT {S}.organization (organization_code, organization_name, status, record_status_id, entered_by)
SELECT s.legalEntityCode, s.legalName, s.recordStatus, {rs}, N'seed-572'
  FROM {s('legal-entities')} s WHERE NOT EXISTS (SELECT 1 FROM {m('legal-entities')} x WHERE x.code = s.legalEntityCode);
INSERT {m('legal-entities')} (code, id, inserted) SELECT s.legalEntityCode, t.organization_id, 1
  FROM {s('legal-entities')} s JOIN {S}.organization t ON t.organization_code = s.legalEntityCode
 WHERE NOT EXISTS (SELECT 1 FROM {m('legal-entities')} x WHERE x.code = s.legalEntityCode);
""")
    for key in ORDER[2:]:
        ent = BY_KEY[key]
        sf = scalar_fields(ent)
        code_f = next(f for f in sf if f["kind"] == "code")
        tbl, idc = ent["table"], ent["id"]
        le = "s.legalEntityId"
        # match by code
        body.append(f"-- {ent['title']} ({tbl}): by code in its Legal Entity.")
        body.append(f"""INSERT {m(key)} (code, id) SELECT s.{code_f['key']}, t.{idc}
  FROM {s(key)} s JOIN {m('legal-entities')} l ON l.code = {le}
  JOIN {S}.{tbl} t ON t.organization_id = l.id AND t.{code_f['col']} = s.{code_f['key']};""")
        from gen_sql import UNIQUE_NAME
        if key in UNIQUE_NAME:
            nf = next(f for f in sf if f["col"] == UNIQUE_NAME[key])
            body.append(f"""-- ... else adopt the existing record of the same name (it has no code yet: the code is filled in).
UPDATE t SET t.{code_f['col']} = s.{code_f['key']}, t.updated_by = N'seed-572', t.updated_dt = SYSUTCDATETIME()
  FROM {s(key)} s JOIN {m('legal-entities')} l ON l.code = {le}
  JOIN {S}.{tbl} t ON t.organization_id = l.id AND t.{nf['col']} = s.{nf['key']} AND t.{code_f['col']} IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM {m(key)} x WHERE x.code = s.{code_f['key']});
INSERT {m(key)} (code, id) SELECT s.{code_f['key']}, t.{idc}
  FROM {s(key)} s JOIN {m('legal-entities')} l ON l.code = {le}
  JOIN {S}.{tbl} t ON t.organization_id = l.id AND t.{code_f['col']} = s.{code_f['key']}
 WHERE NOT EXISTS (SELECT 1 FROM {m(key)} x WHERE x.code = s.{code_f['key']});""")
        # insert: required non-ref columns + NOT NULL refs
        cols, vals, joins = [], [], []
        for f in sf:
            if f["col"] == "organization_id":
                continue
            if f["kind"] == "ref":
                if key == "committee-members" and f["key"] in ("committeeId", "personId"):
                    a = "c" if f["key"] == "committeeId" else "p"
                    joins.append(f"JOIN {m(f['ref'])} {a} ON {a}.code = s.{f['key']}")
                    cols.append(f["col"]); vals.append(f"{a}.id")
                continue
            if f["kind"] == "locationtype":
                joins.append(f"JOIN {S}.location_type_master lt ON lt.location_type_name = s.{f['key']}")
                cols.append(f["col"]); vals.append("lt.location_type_id")
                continue
            if f["kind"] == "designation":
                joins.append(f"JOIN {S}.committee_designation_master dz ON dz.designation_name = s.{f['key']} AND dz.organization_id IS NULL")
                cols.append(f["col"]); vals.append("dz.designation_id")
                continue
            if f["required"] or f["col"] == ent["status_col"]:
                cols.append(f["col"]); vals.append(typed(f, "s." + f["key"]))
        cols.insert(0, "organization_id"); vals.insert(0, "l.id")
        if ent["record_status_id"]:
            stf = next(f for f in sf if f["col"] == ent["status_col"])
            cols.append("record_status_id"); vals.append(STATUS_TO_RSID.format(S=S, v="s." + stf["key"]))
        if key == "teams":
            cols.append("team_type"); vals.append("N'InHouse'")
        if key == "people":
            cols.append("party_type"); vals.append("N'Employee'")
        cols.append("entered_by"); vals.append("N'seed-572'")
        jtxt = ("\n  " + "\n  ".join(joins)) if joins else ""
        body.append(f"""INSERT {S}.{tbl} ({", ".join(cols)})
SELECT {", ".join(vals)}
  FROM {s(key)} s JOIN {m('legal-entities')} l ON l.code = {le}{jtxt}
 WHERE NOT EXISTS (SELECT 1 FROM {m(key)} x WHERE x.code = s.{code_f['key']});
INSERT {m(key)} (code, id, inserted) SELECT s.{code_f['key']}, t.{idc}, 1
  FROM {s(key)} s JOIN {m('legal-entities')} l ON l.code = {le}
  JOIN {S}.{tbl} t ON t.organization_id = l.id AND t.{code_f['col']} = s.{code_f['key']}
 WHERE NOT EXISTS (SELECT 1 FROM {m(key)} x WHERE x.code = s.{code_f['key']});
""")
    # ---------- pass 2
    body.append("-- ============================ PASS 2: fill empty columns ============================")
    for key in ORDER:
        ent = BY_KEY[key]
        sf = scalar_fields(ent)
        code_f = next(f for f in sf if f["kind"] == "code")
        tbl, idc = ent["table"], ent["id"]
        sets, joins = [], []
        ji = 0
        for f in sf:
            if f["kind"] == "code" or f["col"] in ("organization_id",):
                continue
            if key == "legal-entities" and f["col"] in ("organization_name",):
                continue
            if f["kind"] == "ref":
                ji += 1
                a = f"r{ji}"
                joins.append(f"LEFT JOIN {m(f['ref'])} {a} ON {a}.code = s.[{f['key']}]")
                val = f"{a}.id"
            elif f["kind"] == "locationtype":
                ji += 1; a = f"r{ji}"
                joins.append(f"LEFT JOIN {S}.location_type_master {a} ON {a}.location_type_name = s.[{f['key']}]")
                val = f"{a}.location_type_id"
            elif f["kind"] == "designation":
                ji += 1; a = f"r{ji}"
                joins.append(f"LEFT JOIN {S}.committee_designation_master {a} ON {a}.designation_name = s.[{f['key']}] AND {a}.organization_id IS NULL")
                val = f"{a}.designation_id"
            else:
                val = typed(f, f"s.[{f['key']}]")
            if key == "people" and f["col"] == "email":
                val = (f"CASE WHEN EXISTS (SELECT 1 FROM {S}.organization_employee e2 WHERE e2.email = s.[officialEmail] "
                       f"AND e2.employee_id <> t.employee_id) THEN NULL ELSE s.[officialEmail] END")
            sets.append(f"t.{f['col']} = COALESCE(t.{f['col']}, {val})")
        if key == "committees":
            sets.append(f"t.review_frequency_id = COALESCE(t.review_frequency_id, (SELECT TOP (1) fm.frequency_id FROM {S}.frequency_master fm "
                        f"WHERE fm.frequency_name = CASE s.[reviewFrequency] WHEN N'Annually' THEN N'Annual' ELSE s.[reviewFrequency] END ORDER BY fm.is_active DESC, fm.frequency_id))")
        jtxt = "\n  ".join(joins)
        body.append(f"""-- {ent['title']}
UPDATE t SET {",\n             ".join(sets)}
  FROM {S}.{tbl} t JOIN {m(key)} me ON me.id = t.{idc}
  JOIN {s(key)} s ON s.[{code_f['key']}] = me.code
  {jtxt};
""")
    # bridges
    ch_prod, ch_proc, risk = [], [], []
    for c in DATA["channels"]:
        ch_prod += [(c["channelCode"], p) for p in c["productsSupported"]]
        ch_proc += [(c["channelCode"], p) for p in c["processesSupported"]]
    for p in DATA["processes"]:
        risk += [(p["processCode"], r) for r in p["keyRiskCategories"]]
    def vl(pairs): return ",\n    ".join(f"({lit(a)}, {lit(b)})" for a, b in pairs)
    body.append(f"""-- Bridges (semicolon lists of sheets 11 and 13), only when missing.
INSERT {S}.organization_channel_product (channel_id, product_service_id, entered_by)
SELECT c.id, p.id, N'seed-572' FROM (VALUES
    {vl(ch_prod)}) v(ch, pr)
  JOIN {m('channels')} c ON c.code = v.ch JOIN {m('products')} p ON p.code = v.pr
 WHERE NOT EXISTS (SELECT 1 FROM {S}.organization_channel_product b WHERE b.channel_id = c.id AND b.product_service_id = p.id);
INSERT {S}.organization_channel_process (channel_id, process_id, entered_by)
SELECT c.id, p.id, N'seed-572' FROM (VALUES
    {vl(ch_proc)}) v(ch, pr)
  JOIN {m('channels')} c ON c.code = v.ch JOIN {m('processes')} p ON p.code = v.pr
 WHERE NOT EXISTS (SELECT 1 FROM {S}.organization_channel_process b WHERE b.channel_id = c.id AND b.process_id = p.id);
INSERT {S}.organization_process_risk_category (process_id, risk_category, entered_by)
SELECT p.id, v.rc, N'seed-572' FROM (VALUES
    {vl(risk)}) v(pc, rc)
  JOIN {m('processes')} p ON p.code = v.pc
 WHERE NOT EXISTS (SELECT 1 FROM {S}.organization_process_risk_category b WHERE b.process_id = p.id AND b.risk_category = v.rc);

COMMIT;

PRINT '--- 572 result: workbook rows -> GRAC records (inserted = new this run) ---';""")
    sel = []
    for key in ORDER:
        sel.append(f"SELECT {lit(BY_KEY[key]['sheet'])} AS sheet, (SELECT COUNT(*) FROM {s(key)}) AS workbook_rows, "
                   f"(SELECT COUNT(*) FROM {m(key)}) AS matched_or_loaded, (SELECT COUNT(*) FROM {m(key)} WHERE inserted = 1) AS inserted_this_run")
    body.append("\nUNION ALL ".join(sel) + ";")
    body.append(f"""SELECT s.personCode AS person_without_email, s.officialEmail AS workbook_email
  FROM {s('people')} s JOIN {m('people')} me ON me.code = s.personCode
  JOIN {S}.organization_employee e ON e.employee_id = me.id
 WHERE s.officialEmail IS NOT NULL AND e.email IS NULL;   -- e-mail already used by another person in GRAC
""")
    for sh, rec, fld, val, what in ISSUES:
        body.append(f"PRINT {lit(f'572 workbook note -- {sh} / {rec} / {fld}: {val} -> {what}')};")
    body += drops
    body.append("GO")
    # header listing issues
    for sh, rec, fld, val, what in ISSUES:
        L.append(f"--   * {sh} / {rec} / {fld} = {val!r}: {what}")
    L.append(f"""--
-- Requires 569, 570 (controlled values / location types / designations).
-- Rollback: 572_org_registry_sample_data_rollback.sql
{HDR_RULE}
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF COL_LENGTH('{S}.organization','registry_organization_id') IS NULL
   OR NOT EXISTS (SELECT 1 FROM {S}.org_registry_master_value)
   OR NOT EXISTS (SELECT 1 FROM {S}.committee_designation_master WHERE designation_name = N'Chairperson' AND organization_id IS NULL)
   OR NOT EXISTS (SELECT 1 FROM {S}.location_type_master WHERE location_type_name = N'Head Office')
BEGIN
    PRINT 'ABORT (572): run 569 and 570 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO""")
    return "\n".join(L) + "\n" + "\n".join(body) + "\nSET NOEXEC OFF;\nGO\nPRINT '572 complete.';\nGO\n"

def gen_sample_rollback():
    L = [f"""{HDR_RULE}
-- 572_org_registry_sample_data_rollback.sql
-- Deletes exactly the rows 572 inserted (entered_by = 'seed-572'), in
-- reverse dependency order. Rows 572 only adopted or filled in are left
-- as they are. If anything else has since come to point at a sample row,
-- the delete fails and the whole rollback is undone (XACT_ABORT).
{HDR_RULE}
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;
DELETE FROM {S}.organization_channel_product WHERE entered_by = N'seed-572';
DELETE FROM {S}.organization_channel_process WHERE entered_by = N'seed-572';
DELETE FROM {S}.organization_process_risk_category WHERE entered_by = N'seed-572';"""]
    # Every registry reference that points at a sample row is cleared first,
    # wherever it sits (an adopted, pre-existing Legal Entity can point at a
    # sample Organization, a sample unit at a sample location, ...).
    for ent in ENTITIES:
        for f in scalar_fields(ent):
            if f["kind"] != "ref" or f["col"] == "organization_id" or f["key"] in ("committeeId", "personId"):
                continue
            tgt = BY_KEY[f["ref"]]
            L.append(f"UPDATE {S}.{ent['table']} SET {f['col']} = NULL WHERE {f['col']} IN "
                     f"(SELECT {tgt['id']} FROM {S}.{tgt['table']} WHERE entered_by = N'seed-572');")
    L.append(f"DELETE b FROM {S}.organization_channel_process b JOIN {S}.organization_dependency_process p ON p.process_id = b.process_id WHERE p.entered_by = N'seed-572';")
    L.append(f"DELETE b FROM {S}.organization_process_risk_category b JOIN {S}.organization_dependency_process p ON p.process_id = b.process_id WHERE p.entered_by = N'seed-572';")
    L.append(f"DELETE b FROM {S}.organization_channel_product b JOIN {S}.organization_product_service p ON p.product_service_id = b.product_service_id WHERE p.entered_by = N'seed-572';")
    for key in reversed(ORDER):
        ent = BY_KEY[key]
        L.append(f"DELETE FROM {S}.{ent['table']} WHERE entered_by = N'seed-572';")
    L.append("COMMIT;\nPRINT '572 rollback complete.';\nGO")
    return "\n".join(L) + "\n"
