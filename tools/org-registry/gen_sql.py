"""Generates migrations 569 (schema) and 571 (procedures) from spec.py."""
from spec import ENTITIES, EXTERNAL, BY_KEY, sql_type, ref_name_expr, code_expr

S = "grac_practice"
HDR_RULE = "-- " + "=" * 69

# The Legal Entities a caller outside GRAC administration may see / change
# (the Web tier passes the session's allowed organization ids; NULL = all).
ALLOW = "(SELECT TRY_CONVERT(BIGINT, a.[value]) FROM OPENJSON(@allowed_legal_entity_ids) a)"

# GRAC_New.time_zone_master belongs to another module (ControlManagement
# 058) and may not be deployed: it is read only behind OBJECT_ID, into @tz
# (same graceful degrade as 361 / 381). Label = what the screen shows.
TZ_BLOCK = """    DECLARE @tz TABLE (id BIGINT NOT NULL PRIMARY KEY, label NVARCHAR(400) NOT NULL, active BIT NOT NULL);
    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NOT NULL
        INSERT @tz (id, label, active)
        SELECT z.time_zone_id, z.time_zone_name + ISNULL(N' (' + z.iana_time_zone + N')', N''),
               CASE WHEN z.status = N'Active' THEN 1 ELSE 0 END
          FROM GRAC_New.time_zone_master z;
"""

def has_kind(ent, kind):
    return any(f["kind"] == kind for f in ent["fields"])

def pascal(k):
    return k[0].upper() + k[1:]

def base(k):
    return k[:-2] if k.endswith("Id") else k

def le_col_of(ent):
    """Column on `ent`'s table holding its Legal Entity (organization_id)."""
    if ent["key"] == "legal-entities":
        return "organization_id"
    if ent["key"] == "organizations":
        return None
    return "organization_id"

def is_multi(f):
    return f["kind"] in ("multiref", "multimaster")

def scalar_fields(ent):
    return [f for f in ent["fields"] if not is_multi(f)]

def var(f):
    k = f["kind"]
    if k == "date": return "@d_" + f["key"]
    if k == "ref": return "@r_" + f["key"]
    if k == "number": return "@n_" + f["key"]
    if k == "decimal": return "@x_" + f["key"]
    if k in ("locationtype", "designation", "timezone"): return "@i_" + f["key"]
    return "@f_" + f["key"]

def lit(s):
    return "N'" + str(s).replace("'", "''") + "'"

def throw(num, key, msg):
    return f"THROW {num}, {lit('[' + key + '] ' + msg)}, 1;"

# ---------------------------------------------------------------- 569 schema
def gen_schema():
    out = []
    w = out.append
    w(f"""{HDR_RULE}
-- 569_org_registry_schema.sql
--
-- Organization Registry -- schema (workbook "GRAC_Organization_Registry_
-- Muthoot_Lakeshore_Pilot_Populated.xlsx", sheets 01-13 and 15).
--
-- HIERARCHY. Two levels: Organization -> Legal Entity.
--   * Organization (sheet 01, the GRAC tenant / group profile) is NEW:
--     grac_practice.registry_organization.
--   * Legal Entity (sheet 02) IS the existing grac_practice.organization
--     row. Every organization_id already in the database keeps its meaning
--     and its data; it is now read as a Legal Entity and gains the sheet-02
--     columns plus registry_organization_id (up to its Organization) and
--     parent_organization_id (holding / subsidiary structure).
--   * Existing rows are NOT assigned to an Organization here -- that would
--     invent Organization records. They stay registry_organization_id NULL
--     ("not yet assigned") until someone assigns them on the Registry
--     screen. in_scope_for_grac is backfilled 'Yes' (they are GRAC tenants).
--
-- REGISTRY AREAS reuse the tables GRAC already has, so the registry is the
-- one master (START HERE: "must not create duplicate master records"):
--   03 Organization Units  -> organization_division
--   04 Locations           -> organization_location
--   05 Departments         -> organization_department
--   06 Business Functions  -> organization_business_function
--   07 Teams               -> organization_team
--   08 People              -> organization_employee
--   09 Committees          -> organization_committee
--   10 Committee Members   -> organization_committee_member
--   11 Business Processes  -> organization_dependency_process
-- NEW tables only where GRAC had none:
--   12 Products & Services -> organization_product_service
--   13 Delivery Channels   -> organization_delivery_channel
--   bridges                -> organization_channel_product,
--                             organization_channel_process,
--                             organization_process_risk_category
-- Controlled values (sheet 15) -> org_registry_master_value (seeded by 570).
--
-- Every column added here is NULLable: the existing screens (Organization
-- Administration, Dependencies) write these tables through the
-- pm_manage_practice_repository monolith, which knows none of them, and
-- an UPDATE that omits a column leaves it as it is.
--
-- Codes: the existing per-organization UNIQUE constraints already cover
-- division_code / department_code / function_code / employee_code and the
-- global organization_code; new code columns get the same per-Legal-Entity
-- rule as filtered unique indexes (NULL allowed for rows created before
-- the registry). registry_organization.organization_code is global.
--
-- Idempotent: every statement is guarded. ASCII only.
-- Rollback: 569_org_registry_schema_rollback.sql
{HDR_RULE}
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
""")
    prereq = ["organization", "organization_division", "organization_location", "organization_department",
              "organization_business_function", "organization_team", "organization_employee",
              "organization_committee", "organization_committee_member", "organization_dependency_process",
              "location_type_master", "committee_designation_master", "record_status_master", "frequency_master"]
    w("-- Prerequisites: the tables this migration extends (002, 133, 360, 370, 404).")
    w("IF " + "\n   OR ".join(f"OBJECT_ID('{S}.{t}','U') IS NULL" for t in prereq))
    w("BEGIN\n    PRINT 'ABORT (569): a prerequisite table is missing (002/133/360/370/404). Nothing was changed.';\n    SET NOEXEC ON;\nEND\nGO")
    cols = [("organization","address_line1"),("organization","state_province"),("organization_location","address_line1"),
            ("organization_location","country"),("organization_team","team_type"),("organization_employee","party_type"),
            ("organization_dependency_process","effective_dt")]
    w("IF " + "\n   OR ".join(f"COL_LENGTH('{S}.{t}','{c}') IS NULL" for t, c in cols))
    w("BEGIN\n    PRINT 'ABORT (569): run 133, 360 and 404 first (address / team type / party type columns). Nothing was changed.';\n    SET NOEXEC ON;\nEND\nGO\n")

    # master value table
    w(f"""-- 1. Controlled values (sheet 15). One row per value of a list.
--    is_workbook_value = 0 marks a value that appears in the workbook's
--    sample rows but NOT in 15 Masters & Codes (seeded by 570 so those rows
--    can load; shown flagged on screen until a data owner approves it).
IF OBJECT_ID('{S}.org_registry_master_value','U') IS NULL
CREATE TABLE {S}.org_registry_master_value(
    master_value_id   INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_orgreg_master_value PRIMARY KEY,
    master_group      NVARCHAR(60)  NOT NULL,
    value_label       NVARCHAR(120) NOT NULL,
    display_order     INT           NOT NULL CONSTRAINT df_orgreg_master_order DEFAULT 100,
    is_workbook_value BIT           NOT NULL CONSTRAINT df_orgreg_master_wb DEFAULT 1,
    source_note       NVARCHAR(400) NULL,
    status            NVARCHAR(30)  NOT NULL CONSTRAINT df_orgreg_master_status DEFAULT N'Active',
    entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_master_by DEFAULT N'system',
    entered_dt        DATETIME2     NOT NULL CONSTRAINT df_orgreg_master_dt DEFAULT SYSUTCDATETIME(),
    updated_by        NVARCHAR(100) NULL,
    updated_dt        DATETIME2     NULL,
    CONSTRAINT uq_orgreg_master_value UNIQUE(master_group, value_label)
);
GO
""")
    # registry_organization
    org = BY_KEY["organizations"]
    lines = ["    registry_organization_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_registry_organization PRIMARY KEY,"]
    for f in org["fields"]:
        nn = " NOT NULL" if f["required"] else " NULL"
        lines.append(f"    {f['col']} {sql_type(f)}{nn},")
    lines += ["    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_registry_org_by DEFAULT N'system',",
              "    entered_dt DATETIME2 NOT NULL CONSTRAINT df_registry_org_dt DEFAULT SYSUTCDATETIME(),",
              "    updated_by NVARCHAR(100) NULL,",
              "    updated_dt DATETIME2 NULL,",
              "    CONSTRAINT uq_registry_organization_code UNIQUE(organization_code)"]
    w(f"-- 2. Organization (sheet 01) -- the level above Legal Entity.\nIF OBJECT_ID('{S}.registry_organization','U') IS NULL\nCREATE TABLE {S}.registry_organization(\n" + "\n".join(lines) + "\n);\nGO\n")

    # new tables products / channels
    for key in ("products", "channels"):
        ent = BY_KEY[key]
        lines = [f"    {ent['id']} BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_{ent['table']} PRIMARY KEY,"]
        for f in scalar_fields(ent):
            nn = " NOT NULL" if f["required"] else " NULL"
            lines.append(f"    {f['col']} {sql_type(f)}{nn},")
        lines += [f"    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_{ent['table']}_by DEFAULT N'system',",
                  f"    entered_dt DATETIME2 NOT NULL CONSTRAINT df_{ent['table']}_dt DEFAULT SYSUTCDATETIME(),",
                  "    updated_by NVARCHAR(100) NULL,",
                  "    updated_dt DATETIME2 NULL,",
                  f"    CONSTRAINT fk_{ent['table']}_org FOREIGN KEY(organization_id) REFERENCES {S}.organization(organization_id),",
                  f"    CONSTRAINT uq_{ent['table']}_code UNIQUE(organization_id, {ent['code']})"]
        w(f"-- {ent['sheet']} (new table).\nIF OBJECT_ID('{S}.{ent['table']}','U') IS NULL\nCREATE TABLE {S}.{ent['table']}(\n" + "\n".join(lines) + "\n);\nGO\n")

    # columns on existing tables
    w("-- 3. Sheet columns on the existing tables (all NULLable; see header).")
    for ent in ENTITIES:
        if ent["new_table"]:
            continue
        added = [f for f in scalar_fields(ent) if f["new"]]
        if not added:
            continue
        w(f"-- {ent['sheet']} -> {S}.{ent['table']}")
        for f in added:
            w(f"IF COL_LENGTH('{S}.{ent['table']}','{f['col']}') IS NULL\n    ALTER TABLE {S}.{ent['table']} ADD {f['col']} {sql_type(f)} NULL;")
        w("GO")
    # committee extra sync column note: review_frequency_id exists.
    w("")

    # bridge tables
    w(f"""-- 4. Bridges for the semicolon lists of sheets 11 and 13.
IF OBJECT_ID('{S}.organization_channel_product','U') IS NULL
CREATE TABLE {S}.organization_channel_product(
    channel_id         BIGINT NOT NULL,
    product_service_id BIGINT NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_chprod_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_chprod_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_channel_product PRIMARY KEY(channel_id, product_service_id),
    CONSTRAINT fk_orgreg_chprod_channel FOREIGN KEY(channel_id) REFERENCES {S}.organization_delivery_channel(channel_id),
    CONSTRAINT fk_orgreg_chprod_product FOREIGN KEY(product_service_id) REFERENCES {S}.organization_product_service(product_service_id)
);
GO
IF OBJECT_ID('{S}.organization_channel_process','U') IS NULL
CREATE TABLE {S}.organization_channel_process(
    channel_id BIGINT NOT NULL,
    process_id BIGINT NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_chproc_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_chproc_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_channel_process PRIMARY KEY(channel_id, process_id),
    CONSTRAINT fk_orgreg_chproc_channel FOREIGN KEY(channel_id) REFERENCES {S}.organization_delivery_channel(channel_id),
    CONSTRAINT fk_orgreg_chproc_process FOREIGN KEY(process_id) REFERENCES {S}.organization_dependency_process(process_id)
);
GO
IF OBJECT_ID('{S}.organization_process_risk_category','U') IS NULL
CREATE TABLE {S}.organization_process_risk_category(
    process_id    BIGINT        NOT NULL,
    risk_category NVARCHAR(120) NOT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_orgreg_procrisk_by DEFAULT N'system',
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_orgreg_procrisk_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_organization_process_risk_category PRIMARY KEY(process_id, risk_category),
    CONSTRAINT fk_orgreg_procrisk_process FOREIGN KEY(process_id) REFERENCES {S}.organization_dependency_process(process_id)
);
GO
""")
    # FKs for refs (new columns only, + products/channels)
    w("-- 5. Referential integrity for every new reference column.")
    n = 0
    for ent in ENTITIES:
        for f in scalar_fields(ent):
            if f["kind"] != "ref" or not (f["new"] or ent["new_table"]):
                continue
            if ent["new_table"] and f["col"] == "organization_id":
                continue
            tgt = BY_KEY[f["ref"]]
            fk = f"fk_orgreg_{ent['table'].replace('organization_','org_')}_{f['col']}"[:120]
            w(f"IF COL_LENGTH('{S}.{ent['table']}','{f['col']}') IS NOT NULL AND OBJECT_ID('{S}.{fk}','F') IS NULL\n"
              f"    ALTER TABLE {S}.{ent['table']} ADD CONSTRAINT {fk} FOREIGN KEY({f['col']}) REFERENCES {S}.{tgt['table']}({tgt['id']});")
            n += 1
    w("GO\n")

    # filtered unique indexes for new code columns
    w("-- 6. Codes: unique per Legal Entity (filtered: rows created before the registry have none).")
    for ent in ENTITIES:
        cf = next(f for f in ent["fields"] if f["kind"] == "code")
        if ent["new_table"] or not cf["new"]:
            continue
        ix = f"ux_orgreg_{ent['table'].replace('organization_','org_')}_code"
        lecol = "organization_id"
        w(f"IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = '{ix}' AND object_id = OBJECT_ID('{S}.{ent['table']}'))\n"
          f"    EXEC('CREATE UNIQUE INDEX {ix} ON {S}.{ent['table']}({lecol}, {cf['col']}) WHERE {cf['col']} IS NOT NULL');")
    w("GO\n")
    w(f"""IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_orgreg_org_registry_org' AND object_id = OBJECT_ID('{S}.organization'))
    EXEC('CREATE INDEX ix_orgreg_org_registry_org ON {S}.organization(registry_organization_id)');
GO

-- 7. Existing organizations are GRAC tenants, so they are in GRAC scope.
--    Nothing else is backfilled: the sheet-02 columns stay empty until the
--    Legal Entity is edited, and no Organization is invented for them.
IF COL_LENGTH('{S}.organization','in_scope_for_grac') IS NOT NULL
    EXEC('UPDATE {S}.organization SET in_scope_for_grac = N''Yes'' WHERE in_scope_for_grac IS NULL');
GO

PRINT '--- 569 verification ---';
SELECT t.name AS table_name, COUNT(c.column_id) AS columns_now
  FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
 WHERE SCHEMA_NAME(t.schema_id) = '{S}'
   AND t.name IN ('registry_organization','organization','organization_division','organization_location',
                  'organization_department','organization_business_function','organization_team',
                  'organization_employee','organization_committee','organization_committee_member',
                  'organization_dependency_process','organization_product_service',
                  'organization_delivery_channel','org_registry_master_value')
 GROUP BY t.name ORDER BY t.name;
GO
SET NOEXEC OFF;
GO
PRINT '569 complete. Next: 570 (masters, menu), 571 (procedures), 572 (sample data).';
GO""")
    return "\n".join(out) + "\n"

def gen_schema_rollback():
    out = [f"""{HDR_RULE}
-- 569_org_registry_schema_rollback.sql
-- Reverses 569. DESTRUCTIVE: drops the registry tables and every column
-- 569 added (their data is lost). Run 572, 571 and 570 rollbacks first.
{HDR_RULE}
SET NOCOUNT ON;
GO"""]
    w = out.append
    # drop FKs
    for ent in ENTITIES:
        for f in scalar_fields(ent):
            if f["kind"] != "ref" or not (f["new"] or ent["new_table"]):
                continue
            if ent["new_table"] and f["col"] == "organization_id":
                continue
            fk = f"fk_orgreg_{ent['table'].replace('organization_','org_')}_{f['col']}"[:120]
            w(f"IF OBJECT_ID('{S}.{fk}','F') IS NOT NULL ALTER TABLE {S}.{ent['table']} DROP CONSTRAINT {fk};")
    w("GO")
    for t in ("organization_process_risk_category", "organization_channel_process", "organization_channel_product",
              "organization_delivery_channel", "organization_product_service"):
        w(f"IF OBJECT_ID('{S}.{t}','U') IS NOT NULL DROP TABLE {S}.{t};")
    w("GO")
    for ent in ENTITIES:
        cf = next(f for f in ent["fields"] if f["kind"] == "code")
        if ent["new_table"] or not cf["new"]:
            continue
        ix = f"ux_orgreg_{ent['table'].replace('organization_','org_')}_code"
        w(f"IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = '{ix}') DROP INDEX {ix} ON {S}.{ent['table']};")
    w(f"IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_orgreg_org_registry_org') DROP INDEX ix_orgreg_org_registry_org ON {S}.organization;")
    w("GO")
    for ent in ENTITIES:
        if ent["new_table"]:
            continue
        for f in scalar_fields(ent):
            if f["new"]:
                w(f"IF COL_LENGTH('{S}.{ent['table']}','{f['col']}') IS NOT NULL ALTER TABLE {S}.{ent['table']} DROP COLUMN {f['col']};")
    w("GO")
    w(f"IF OBJECT_ID('{S}.registry_organization','U') IS NOT NULL DROP TABLE {S}.registry_organization;")
    w(f"IF OBJECT_ID('{S}.org_registry_master_value','U') IS NOT NULL DROP TABLE {S}.org_registry_master_value;")
    w("GO\nPRINT '569 rollback complete.';\nGO")
    return "\n".join(out) + "\n"

# ---------------------------------------------------------------- 571 procs
def joins_and_selects(ent, alias="t"):
    """SELECT list + LEFT JOINs for the list procedure."""
    sel, joins = [], []
    ji = 0
    for f in ent["fields"]:
        k, P = f["key"], pascal(f["key"])
        if f["kind"] == "ref":
            tgt = BY_KEY[f["ref"]]
            ji += 1
            a = f"j{ji}"
            joins.append(f"LEFT JOIN {S}.{tgt['table']} {a} ON {a}.{tgt['id']} = {alias}.{f['col']}")
            b = pascal(base(k))
            sel.append(f"{alias}.{f['col']} AS {P}")
            sel.append(f"{code_expr(tgt, a)} AS {b}Code")
            sel.append(f"{ref_name_expr(tgt, a)} AS {b}Name")
        elif f["kind"] == "locationtype":
            ji += 1; a = f"j{ji}"
            joins.append(f"LEFT JOIN {S}.location_type_master {a} ON {a}.location_type_id = {alias}.{f['col']}")
            sel.append(f"{a}.location_type_name AS {P}")
        elif f["kind"] == "designation":
            ji += 1; a = f"j{ji}"
            joins.append(f"LEFT JOIN {S}.committee_designation_master {a} ON {a}.designation_id = {alias}.{f['col']}")
            sel.append(f"{a}.designation_name AS {P}")
        elif f["kind"] == "timezone":
            ji += 1; a = f"j{ji}"
            joins.append(f"LEFT JOIN @tz {a} ON {a}.id = {alias}.{f['col']}")
            sel.append(f"{a}.label AS {P}")
        elif f["kind"] == "multiref":
            tgt = BY_KEY[f["ref"]]
            sel.append(f"(SELECT b.{f['col']} AS id, {code_expr(tgt, 'x')} AS code, {ref_name_expr(tgt,'x')} AS name\n"
                       f"         FROM {S}.{f['multi_table']} b JOIN {S}.{tgt['table']} x ON x.{tgt['id']} = b.{f['col']}\n"
                       f"        WHERE b.{ent['id']} = {alias}.{ent['id']} ORDER BY {code_expr(tgt, 'x')}, {ref_name_expr(tgt,'x')} FOR JSON PATH) AS {P}")
        elif f["kind"] == "multimaster":
            sel.append(f"(SELECT b.{f['col']} AS v FROM {S}.{f['multi_table']} b\n"
                       f"        WHERE b.{ent['id']} = {alias}.{ent['id']} ORDER BY b.{f['col']} FOR JSON PATH) AS {P}")
        else:
            sel.append(f"{alias}.{f['col']} AS {P}")
    return sel, joins

def gen_list(ent):
    sel, joins = joins_and_selects(ent)
    key, t = ent["key"], ent["table"]
    name_expr = ref_name_expr(ent, "t")
    code = ent["code"]
    fixed = [f"t.{ent['id']} AS Id", f"t.{code} AS Code", f"{name_expr} AS Name", f"t.{ent['status_col']} AS Status"]
    if key == "organizations":
        fixed += ["CAST(NULL AS BIGINT) AS LegalEntityId", "CAST(NULL AS NVARCHAR(80)) AS LegalEntityCode",
                  "CAST(NULL AS NVARCHAR(250)) AS LegalEntityName",
                  "t.registry_organization_id AS RegistryOrganizationId", "t.organization_code AS RegistryOrganizationCode",
                  "t.registered_name AS RegistryOrganizationName",
                  f"(SELECT COUNT(*) FROM {S}.organization o2 WHERE o2.registry_organization_id = t.registry_organization_id) AS LegalEntityCount"]
        lejoin = ""
        where_org = "(@registry_organization_id <= 0 OR t.registry_organization_id = @registry_organization_id)"
        where_le = ("(@allowed_legal_entity_ids IS NULL OR t.registry_organization_id IN (SELECT ax.registry_organization_id FROM "
                    + S + ".organization ax WHERE ax.organization_id IN " + ALLOW + "))")
    else:
        lealias = "t" if key == "legal-entities" else "le"
        if key != "legal-entities":
            lejoin = f"LEFT JOIN {S}.organization le ON le.organization_id = t.organization_id"
        else:
            lejoin = ""
        fixed += [f"{lealias}.organization_id AS LegalEntityId", f"{lealias}.organization_code AS LegalEntityCode",
                  f"{lealias}.organization_name AS LegalEntityName",
                  f"{lealias}.registry_organization_id AS RegistryOrganizationId",
                  "ro.organization_code AS RegistryOrganizationCode", "ro.registered_name AS RegistryOrganizationName"]
        lejoin += f"\n      LEFT JOIN {S}.registry_organization ro ON ro.registry_organization_id = {lealias}.registry_organization_id"
        where_org = (f"(@registry_organization_id = 0 OR (@registry_organization_id = -1 AND {lealias}.registry_organization_id IS NULL)"
                     f" OR {lealias}.registry_organization_id = @registry_organization_id)")
        where_le = (f"(@legal_entity_id = 0 OR {lealias}.organization_id = @legal_entity_id)"
                    f"\n       AND (@allowed_legal_entity_ids IS NULL OR {lealias}.organization_id IN {ALLOW})")
        if key == "legal-entities":
            fixed += [f"(SELECT COUNT(*) FROM {S}.organization c WHERE c.parent_organization_id = t.organization_id) AS ChildLegalEntityCount"]
    fixed += ["t.entered_by AS EnteredBy", "t.entered_dt AS EnteredDate",
              "COALESCE(t.updated_by, t.entered_by) AS UpdatedBy", "COALESCE(t.updated_dt, t.entered_dt) AS UpdatedDate"]
    search = f"(@search = N'' OR t.{code} LIKE N'%' + @search + N'%' OR {name_expr} LIKE N'%' + @search + N'%'"
    if key == "committee-members":
        search += " OR j1.committee_name LIKE N'%' + @search + N'%' OR j2.employee_name LIKE N'%' + @search + N'%'"
    if key == "people":
        search += " OR t.email LIKE N'%' + @search + N'%' OR t.designation LIKE N'%' + @search + N'%'"
    search += ")"
    order = "t.registered_name" if key == "organizations" else (f"{'t' if key=='legal-entities' else 'le'}.organization_name, t.{code}")
    p = f"{S}.sp_orgreg_{key.replace('-','_')}_list"
    allsel = ",\n           ".join(fixed + sel)
    alljoin = "\n      ".join([lejoin] + joins) if lejoin else "\n      ".join(joins)
    return f"""CREATE OR ALTER PROCEDURE {p}
    @registry_organization_id BIGINT = 0,   -- 0 all, -1 Legal Entities not yet assigned
    @legal_entity_id          BIGINT = 0,
    @id                       BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL, -- JSON array of organization_ids; NULL = every Legal Entity
    @status                   NVARCHAR(40)  = N'',
    @search                   NVARCHAR(200) = N''
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = LTRIM(RTRIM(ISNULL(@search, N'')));
    SET @status = LTRIM(RTRIM(ISNULL(@status, N'')));
{TZ_BLOCK if has_kind(ent, "timezone") else ""}    SELECT {allsel}
      FROM {S}.{t} t
      {alljoin}
     WHERE (@id = 0 OR t.{ent['id']} = @id)
       AND {where_org}
       AND {where_le}
       AND (@status = N'' OR t.{ent['status_col']} = @status)
       AND {search}
     ORDER BY {order};
END;
GO
"""

DATE_PAIRS = [("effectiveFrom", "effectiveTo"), ("openingDate", "closureDate"), ("joiningDate", "exitDate"),
              ("memberSince", "memberUntil"), ("launchDate", "withdrawalDate")]

UNIQUE_NAME = {"locations": "location_name", "teams": "team_name", "committees": "committee_name", "processes": "process_name"}

def scope_check(ent, f, le_var):
    """T-SQL that enforces f['scope'] for a scalar ref (variable @r_key)."""
    tgt = BY_KEY[f["ref"]]
    v = var(f)
    if tgt["key"] == "organizations" or f["scope"] == "any":
        return ""
    tle = "organization_id"
    if ent["key"] == "legal-entities":
        # The Legal Entity being saved: its Organization comes from the payload.
        if tgt["key"] == "legal-entities":
            cond = (f"EXISTS (SELECT 1 FROM {S}.organization x WHERE x.organization_id = {v} "
                    f"AND ((x.registry_organization_id IS NOT NULL AND x.registry_organization_id = @r_registryOrganizationId) OR x.organization_id = @id))")
        else:
            cond = (f"EXISTS (SELECT 1 FROM {S}.{tgt['table']} x JOIN {S}.organization xl ON xl.organization_id = x.{tle} "
                    f"WHERE x.{tgt['id']} = {v} AND (x.{tle} = @id OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = @r_registryOrganizationId)))")
        return (f"    IF {v} IS NOT NULL AND NOT {cond}\n        {throw(52703, f['key'], f['label'].rstrip('*') + ' must belong to the same Organization.')}\n")
    if f["scope"] == "le":
        cond = f"EXISTS (SELECT 1 FROM {S}.{tgt['table']} x WHERE x.{tgt['id']} = {v} AND x.{tle} = {le_var})"
        msg = "must belong to the same Legal Entity."
    else:
        cond = (f"EXISTS (SELECT 1 FROM {S}.{tgt['table']} x JOIN {S}.organization xl ON xl.organization_id = x.{tle}\n"
                f"                        JOIN {S}.organization me ON me.organization_id = {le_var}\n"
                f"                       WHERE x.{tgt['id']} = {v} AND (xl.organization_id = me.organization_id\n"
                f"                         OR (xl.registry_organization_id IS NOT NULL AND xl.registry_organization_id = me.registry_organization_id)))")
        msg = "must belong to the same Organization."
    return f"    IF {v} IS NOT NULL AND NOT {cond}\n        {throw(52703, f['key'], f['label'].rstrip('*') + ' ' + msg)}\n"

def gen_save(ent):
    key, t, idc = ent["key"], ent["table"], ent["id"]
    p = f"{S}.sp_orgreg_{key.replace('-','_')}_save"
    fields = ent["fields"]
    L = []
    a = L.append
    a(f"""CREATE OR ALTER PROCEDURE {p}
    @id      BIGINT = 0,
    @payload NVARCHAR(MAX),
    @actor   NVARCHAR(100),
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = GRAC administration (every Legal Entity)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @id = ISNULL(@id, 0);
    IF @payload IS NULL OR ISJSON(@payload) <> 1
        THROW 52700, N'[] The request body is not valid JSON.', 1;
    IF NULLIF(LTRIM(RTRIM(@actor)), N'') IS NULL
        THROW 52700, N'[] The signed-in user is required.', 1;
    IF @id > 0 AND NOT EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id)
        THROW 52705, N'[] The {ent['single']} no longer exists. Reload the list.', 1;
""")
    if key in ("organizations", "legal-entities"):
        a(f"""    -- Organizations and Legal Entities are maintained by GRAC administration
    -- (Organization Management); an organization's own users see them read-only.
    IF @allowed_legal_entity_ids IS NOT NULL
        THROW 52707, N'[] {ent['title']} are maintained in Organization Management.', 1;
""")
    else:
        a(f"""    -- Outside GRAC administration a record of another Legal Entity is out of reach.
    IF @allowed_legal_entity_ids IS NOT NULL AND @id > 0
       AND NOT EXISTS (SELECT 1 FROM {S}.{t} x WHERE x.{idc} = @id AND x.organization_id IN {ALLOW})
        THROW 52707, N'[] This record belongs to a Legal Entity you do not have access to.', 1;
""")
    # raw text values
    sf = scalar_fields(ent)
    a("    -- Raw values (text; OPENJSON so long text is never truncated).")
    for f in sf:
        a(f"    DECLARE @f_{f['key']} NVARCHAR(MAX);")
    a("    SELECT " + ",\n           ".join(f"@f_{f['key']} = NULLIF(LTRIM(RTRIM(j.[{f['key']}])), N'')" for f in sf))
    a("      FROM OPENJSON(@payload) WITH (" + ",\n           ".join(f"[{f['key']}] NVARCHAR(MAX) N'$.{f['key']}'" for f in sf) + ") j;\n")
    # typed
    for f in sf:
        k, kind = f["key"], f["kind"]
        lab = f["label"].rstrip("*")
        if kind == "date":
            a(f"    DECLARE @d_{k} DATE = TRY_CONVERT(DATE, LEFT(@f_{k}, 10), 23);")
            a(f"    IF @f_{k} IS NOT NULL AND @d_{k} IS NULL {throw(52701, k, lab + ' must be a date (yyyy-mm-dd).')}")
        elif kind == "ref":
            a(f"    DECLARE @r_{k} BIGINT = TRY_CONVERT(BIGINT, @f_{k});")
            a(f"    IF @f_{k} IS NOT NULL AND @r_{k} IS NULL {throw(52701, k, lab + ' is not a valid selection.')}")
        elif kind == "number":
            a(f"    DECLARE @n_{k} BIGINT = TRY_CONVERT(BIGINT, @f_{k});")
            a(f"    IF @f_{k} IS NOT NULL AND (@n_{k} IS NULL OR @n_{k} < 0) {throw(52701, k, lab + ' must be a whole number, 0 or more.')}")
        elif kind == "decimal":
            a(f"    DECLARE @x_{k} DECIMAL(9,6) = TRY_CONVERT(DECIMAL(9,6), @f_{k});")
            rng = 90 if k == "latitude" else 180
            a(f"    IF @f_{k} IS NOT NULL AND (@x_{k} IS NULL OR @x_{k} < -{rng} OR @x_{k} > {rng}) {throw(52701, k, lab + f' must be a number between -{rng} and {rng}.')}")
        elif kind in ("locationtype", "designation"):
            a(f"    DECLARE @i_{k} INT = NULL;")
        elif kind == "timezone":
            a(f"    DECLARE @i_{k} BIGINT = NULL;")
    a("")
    # required
    a("    -- Mandatory fields (workbook '*', plus GRAC links marked required in the spec).")
    for f in sf:
        if f["required"]:
            a(f"    IF @f_{f['key']} IS NULL {throw(52701, f['key'], f['label'].rstrip('*') + ' is required.')}")
    # lengths
    for f in sf:
        if f["kind"] in ("code", "text", "email", "url", "textarea") and f["length"]:
            a(f"    IF LEN(@f_{f['key']}) > {f['length']} {throw(52701, f['key'], f['label'].rstrip('*') + ' cannot be longer than ' + str(f['length']) + ' characters.')}")
        if f["kind"] == "email":
            a(f"    IF @f_{f['key']} IS NOT NULL AND (@f_{f['key']} NOT LIKE N'%_@_%._%' OR CHARINDEX(N' ', @f_{f['key']}) > 0) {throw(52701, f['key'], f['label'].rstrip('*') + ' is not a valid e-mail address.')}")
        if f["kind"] == "ddmm":
            k = f["key"]
            a(f"    IF @f_{k} IS NOT NULL AND (@f_{k} NOT LIKE N'[0-3][0-9]-[01][0-9]' OR TRY_CONVERT(DATE, N'2000-' + RIGHT(@f_{k}, 2) + N'-' + LEFT(@f_{k}, 2), 23) IS NULL) {throw(52701, k, f['label'].rstrip('*') + ' must be a day and month as DD-MM, e.g. 01-04.')}")
        if f["kind"] == "url":
            k = f["key"]
            a(f"    IF @f_{k} IS NOT NULL AND @f_{k} NOT LIKE N'http%://%' {throw(52701, k, f['label'].rstrip('*') + ' must start with http:// or https://.')}")
    # date pairs
    keys = {f["key"] for f in sf}
    for x, y in DATE_PAIRS:
        if x in keys and y in keys:
            lx = next(f for f in sf if f["key"] == x)["label"].rstrip("*")
            ly = next(f for f in sf if f["key"] == y)["label"].rstrip("*")
            a(f"    IF @d_{x} IS NOT NULL AND @d_{y} IS NOT NULL AND @d_{y} < @d_{x} {throw(52701, y, ly + ' cannot be before ' + lx + '.')}")
    a("")
    # masters
    a("    -- Controlled values (15 Masters & Codes). A value that is not on the list")
    a("    -- is accepted only when it is the value the record already holds, so an")
    a("    -- older record can still be saved without being forced to change it.")
    for f in sf:
        k = f["key"]
        lab = f["label"].rstrip("*")
        if f["kind"] == "master":
            g = f["group"]
            a(f"""    IF @f_{k} IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM {S}.org_registry_master_value m WHERE m.master_group = {lit(g)} AND m.value_label = @f_{k} AND m.status = N'Active')
            SELECT @f_{k} = m.value_label FROM {S}.org_registry_master_value m WHERE m.master_group = {lit(g)} AND m.value_label = @f_{k};
        ELSE IF NOT EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND {f['col']} = @f_{k})
            {throw(52702, k, lab + ': the value is not in the approved list (' + g + ').')}
    END""")
            if ent.get("status_only_active_inactive") and k == "recordStatus":
                a(f"    IF @f_{k} NOT IN (N'Active', N'Inactive') {throw(52702, k, 'A business function can only be Active or Inactive (migration 365).')}")
        elif f["kind"] == "locationtype":
            a(f"""    SELECT TOP (1) @i_{k} = lt.location_type_id FROM {S}.location_type_master lt
     WHERE lt.location_type_name = @f_{k} ORDER BY lt.is_active DESC, lt.location_type_id;
    IF @f_{k} IS NOT NULL AND @i_{k} IS NULL {throw(52702, k, lab + ': the value is not in the approved list (LocationType).')}""")
        elif f["kind"] == "choice":
            codes = ", ".join(lit(c) for c, _ in f["choices"])
            names = " / ".join(n for _, n in f["choices"])
            a(f"""    IF @f_{k} IS NOT NULL AND @f_{k} NOT IN ({codes})
       AND NOT EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND {f['col']} = @f_{k})
        {throw(52702, k, lab + ' must be one of: ' + names + '.')}""")
        elif f["kind"] == "timezone":
            a(TZ_BLOCK.rstrip("\n"))
            a(f"""    IF OBJECT_ID(N'GRAC_New.time_zone_master', N'U') IS NULL
        -- Time zones not deployed: the screen cannot show or pick one, so
        -- the record keeps the one it has.
        SET @i_{k} = (SELECT {f['col']} FROM {S}.{t} WHERE {idc} = @id);
    ELSE IF @f_{k} IS NOT NULL
    BEGIN
        SELECT TOP (1) @i_{k} = z.id FROM @tz z WHERE z.label = @f_{k} ORDER BY z.active DESC, z.id;
        IF @i_{k} IS NULL {throw(52702, k, lab + ': the value is not in the time zone list.')}
        IF NOT EXISTS (SELECT 1 FROM @tz z WHERE z.id = @i_{k} AND z.active = 1)
           AND NOT EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND {f['col']} = @i_{k})
            {throw(52702, k, lab + ': the selected time zone is not Active.')}
    END""")
    a("")
    # LE resolution
    if key == "legal-entities":
        le_var = "@id"
    elif key == "organizations":
        le_var = None
    elif ent.get("le_from"):
        fk, tt, tid = ent["le_from"]
        a(f"    DECLARE @le BIGINT = (SELECT organization_id FROM {S}.{tt} WHERE {tid} = @r_{fk});")
        a(f"    IF @r_{fk} IS NOT NULL AND @le IS NULL {throw(52703, fk, 'The selected committee does not exist.')}")
        le_var = "@le"
    else:
        a("    DECLARE @le BIGINT = @r_legalEntityId;")
        a(f"    IF @le IS NOT NULL AND NOT EXISTS (SELECT 1 FROM {S}.organization WHERE organization_id = @le) {throw(52703, 'legalEntityId', 'The selected Legal Entity does not exist.')}")
        a(f"    IF @id > 0 AND EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND organization_id <> @le)")
        a(f"       AND EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND organization_id IS NOT NULL)")
        a(f"        {throw(52703, 'legalEntityId', 'A ' + ent['single'] + ' cannot be moved to another Legal Entity: other records refer to it there. Mark it Inactive and create it in the other Legal Entity.')}")
        le_var = "@le"
    if le_var == "@le":
        fk = ent["le_from"][0] if ent.get("le_from") else "legalEntityId"
        a(f"    IF @allowed_legal_entity_ids IS NOT NULL AND (@le IS NULL OR @le NOT IN {ALLOW})")
        a(f"        {throw(52707, fk, 'You can only maintain records of your own Legal Entities.')}")
    # designation resolution (needs @le)
    for f in sf:
        if f["kind"] == "designation":
            k = f["key"]
            a(f"""    SELECT TOP (1) @i_{k} = d.designation_id FROM {S}.committee_designation_master d
     WHERE d.designation_name = @f_{k} AND (d.organization_id IS NULL OR d.organization_id = {le_var})
     ORDER BY CASE WHEN d.organization_id IS NULL THEN 1 ELSE 0 END, d.is_active DESC, d.designation_id;
    IF @f_{k} IS NOT NULL AND @i_{k} IS NULL {throw(52702, k, f['label'].rstrip('*') + ': the value is not in the approved list (CommitteeMemberDesignation).')}""")
    a("")
    if key == "teams":
        a("    IF @f_teamSourcing = N'InHouse' SET @r_vendorId = NULL;   -- an in-house team has no vendor (133)")
    # refs existence + scope + self
    a("    -- References: the record must exist (and belong where the field says).")
    for f in sf:
        if f["kind"] != "ref":
            continue
        tgt = BY_KEY[f["ref"]]
        k = f["key"]
        lab = f["label"].rstrip("*")
        if key != "legal-entities" and k == "legalEntityId":
            continue
        a(f"    IF @r_{k} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM {S}.{tgt['table']} WHERE {tgt['id']} = @r_{k}) {throw(52703, k, lab + ': the selected record does not exist.')}")
        if le_var:
            sc = scope_check(ent, f, le_var)
            if sc:
                a(sc.rstrip("\n"))
        if f["ref"] == key:
            pcol = f["col"]
            a(f"""    IF @r_{k} IS NOT NULL AND @id > 0
    BEGIN
        IF @r_{k} = @id {throw(52706, k, lab + ' cannot be the record itself.')}
        DECLARE @walk_{k} BIGINT = @r_{k}, @guard_{k} INT = 0;
        WHILE @walk_{k} IS NOT NULL AND @guard_{k} < 100
        BEGIN
            IF @walk_{k} = @id {throw(52706, k, lab + ' would make a loop: this record is already above it.')}
            SET @walk_{k} = (SELECT {pcol} FROM {S}.{t} WHERE {idc} = @walk_{k});
            SET @guard_{k} += 1;
        END
    END""")
    if key == "teams":
        # 133's rule: a vendor-managed team names an Active vendor of its
        # Legal Entity; an in-house team has none.
        a(f"""    IF @f_teamSourcing = N'Vendor' AND @r_vendorId IS NULL {throw(52701, 'vendorId', 'Vendor is required for a vendor-managed team. Register the vendor first, then select it here.')}
    IF @f_teamSourcing = N'Vendor'
       AND NOT EXISTS (SELECT 1 FROM {S}.organization_dependency_vendor v WHERE v.vendor_id = @r_vendorId AND v.status = N'Active')
       AND NOT EXISTS (SELECT 1 FROM {S}.{t} WHERE {idc} = @id AND vendor_id = @r_vendorId)
        {throw(52703, 'vendorId', 'Vendor: the selected vendor is not Active.')}""")
    # multis
    for f in ent["fields"]:
        if not is_multi(f):
            continue
        k = f["key"]
        lab = f["label"].rstrip("*")
        if f["kind"] == "multiref":
            tgt = BY_KEY[f["ref"]]
            a(f"""    DECLARE @m_{k} TABLE (v BIGINT NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.{k}')) = 1
        INSERT @m_{k}(v) SELECT DISTINCT TRY_CONVERT(BIGINT, j.[value]) FROM OPENJSON(@payload, N'$.{k}') j
         WHERE TRY_CONVERT(BIGINT, j.[value]) IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_{k} m WHERE NOT EXISTS (SELECT 1 FROM {S}.{tgt['table']} x WHERE x.{tgt['id']} = m.v AND x.organization_id = {le_var}))
        {throw(52703, k, lab + ': every selection must exist in the same Legal Entity.')}""")
        else:
            g = f["group"]
            a(f"""    DECLARE @m_{k} TABLE (v NVARCHAR(120) NOT NULL PRIMARY KEY);
    IF ISJSON(JSON_QUERY(@payload, N'$.{k}')) = 1
        INSERT @m_{k}(v) SELECT DISTINCT LTRIM(RTRIM(j.[value])) FROM OPENJSON(@payload, N'$.{k}') j
         WHERE NULLIF(LTRIM(RTRIM(j.[value])), N'') IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @m_{k} m WHERE NOT EXISTS (SELECT 1 FROM {S}.org_registry_master_value x WHERE x.master_group = {lit(g)} AND x.value_label = m.v AND x.status = N'Active')
                                       AND NOT EXISTS (SELECT 1 FROM {S}.{f['multi_table']} b WHERE b.{ent['id']} = @id AND b.{f['col']} = m.v))
        {throw(52702, k, lab + ': a value is not in the approved list (' + g + ').')}""")
    a("")
    # uniqueness
    code = next(f for f in sf if f["kind"] == "code")
    a("    -- Unique codes.")
    if key in ("organizations", "legal-entities"):
        a(f"    IF EXISTS (SELECT 1 FROM {S}.{t} WHERE {code['col']} = @f_{code['key']} AND {idc} <> @id) {throw(52704, code['key'], code['label'].rstrip('*') + ' is already used by another ' + ent['single'] + '.')}")
    else:
        a(f"    IF EXISTS (SELECT 1 FROM {S}.{t} WHERE organization_id = {le_var} AND {code['col']} = @f_{code['key']} AND {idc} <> @id) {throw(52704, code['key'], code['label'].rstrip('*') + ' is already used in this Legal Entity.')}")
    if key in UNIQUE_NAME:
        nf = next(f for f in sf if f["col"] == UNIQUE_NAME[key])
        a(f"    IF EXISTS (SELECT 1 FROM {S}.{t} WHERE organization_id = {le_var} AND {nf['col']} = @f_{nf['key']} AND {idc} <> @id) {throw(52704, nf['key'], nf['label'].rstrip('*') + ' is already used in this Legal Entity.')}")
    if key == "people":
        a(f"    IF @f_officialEmail IS NOT NULL AND EXISTS (SELECT 1 FROM {S}.organization_employee WHERE email = @f_officialEmail AND employee_id <> @id) {throw(52704, 'officialEmail', 'Official Email is already used by another person in GRAC.')}")
    if key == "committee-members":
        a(f"    IF EXISTS (SELECT 1 FROM {S}.organization_committee_member WHERE committee_id = @r_committeeId AND employee_id = @r_personId AND committee_member_id <> @id) {throw(52704, 'personId', 'This person is already a member of this committee (one membership per person per committee).')}")
    a("")
    # record status id
    if ent["record_status_id"]:
        a(f"""    DECLARE @rsid INT = (SELECT TOP (1) record_status_id FROM {S}.record_status_master
                          WHERE status_code = CASE WHEN @f_{next(f for f in sf if f['col']==ent['status_col'])['key']} = N'Active' THEN N'Active'
                                                   WHEN @f_{next(f for f in sf if f['col']==ent['status_col'])['key']} IN (N'Draft', N'Pending Approval') THEN N'Draft'
                                                   ELSE N'Inactive' END);
    IF @rsid IS NULL SET @rsid = (SELECT TOP (1) record_status_id FROM {S}.record_status_master WHERE status_code = N'Active');""")
    # extras per entity
    extra_cols = []
    if key == "committees":
        a(f"""    DECLARE @freq_id INT = (SELECT TOP (1) fm.frequency_id FROM {S}.frequency_master fm
                             WHERE fm.frequency_name = CASE @f_reviewFrequency WHEN N'Annually' THEN N'Annual' ELSE @f_reviewFrequency END
                             ORDER BY fm.is_active DESC, fm.frequency_id);""")
        extra_cols.append(("review_frequency_id", "@freq_id"))
    if key == "functions":
        a(f"    DECLARE @owner_name NVARCHAR(200) = (SELECT employee_name FROM {S}.organization_employee WHERE employee_id = @r_functionOwnerPersonId);")
    if ent.get("le_from"):
        extra_cols.append(("organization_id", "@le"))
    if ent["record_status_id"]:
        extra_cols.append(("record_status_id", "@rsid"))

    cols = [(f["col"], var(f)) for f in sf] + extra_cols
    if key == "functions":
        cols.append(("owner_name", "COALESCE(@owner_name, owner_name)"))
    a("")
    bcols = ", ".join(dict.fromkeys([c for c, v in cols if c != "owner_name"] + ([ent['status_col']])))
    a(f"    -- Before-image of the registry columns only (never the whole row: organization_employee carries password_hash).")
    a(f"    DECLARE @before NVARCHAR(MAX) = CASE WHEN @id > 0 THEN (SELECT {bcols} FROM {S}.{t} WHERE {idc} = @id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END;")
    a("    BEGIN TRAN;")
    # insert
    ins_cols = [c for c, v in cols if c != "owner_name"]
    ins_vals = [v for c, v in cols if c != "owner_name"]
    if key == "functions":
        ins_cols.append("owner_name"); ins_vals.append("@owner_name")
    if key == "people":
        ins_cols.append("party_type"); ins_vals.append("N'Employee'")
    ins_cols += ["entered_by"]
    ins_vals += ["@actor"]
    a("    IF @id = 0")
    a("    BEGIN")
    a(f"        INSERT {S}.{t} (" + ", ".join(ins_cols) + ")")
    a("        VALUES (" + ", ".join(ins_vals) + ");")
    a("        SET @id = CAST(SCOPE_IDENTITY() AS BIGINT);")
    a("    END")
    a("    ELSE")
    a("    BEGIN")
    a(f"        UPDATE {S}.{t} SET " + ",\n               ".join(f"{c} = {v}" for c, v in cols) +
      ",\n               updated_by = @actor, updated_dt = SYSUTCDATETIME()")
    a(f"         WHERE {idc} = @id;")
    a("    END")
    for f in ent["fields"]:
        if not is_multi(f):
            continue
        k, bt, bc = f["key"], f["multi_table"], f["col"]
        xc = "".join(", " + c for c, _ in (f["multi_extra"] or []))
        xv = "".join(", " + v for _, v in (f["multi_extra"] or []))
        a(f"""    IF JSON_QUERY(@payload, N'$.{k}') IS NOT NULL
    BEGIN
        DELETE b FROM {S}.{bt} b WHERE b.{ent['id']} = @id AND NOT EXISTS (SELECT 1 FROM @m_{k} m WHERE m.v = b.{bc});
        INSERT {S}.{bt} ({ent['id']}, {bc}{xc}, entered_by)
        SELECT @id, m.v{xv}, @actor FROM @m_{k} m
         WHERE NOT EXISTS (SELECT 1 FROM {S}.{bt} b WHERE b.{ent['id']} = @id AND b.{bc} = m.v);
    END""")
    a(f"""    INSERT {S}.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'org-registry/{key}', @id, N'SAVE', @before, @payload, N'Active', @actor);
    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'{ent['single']} saved.' AS Message, @id AS Id;
END;
GO
""")
    return "\n".join(L)

def gen_lookups():
    parts = []
    for ent in ENTITIES:
        if ent["key"] == "committee-members":
            continue
        k = ent["key"]
        if k == "organizations":
            parts.append(f"""    SELECT N'organizations' AS Kind, t.registry_organization_id AS Id, t.organization_code AS Code, t.registered_name AS Name,
           CAST(NULL AS BIGINT) AS LegalEntityId, t.registry_organization_id AS RegistryOrganizationId,
           CAST(NULL AS BIGINT) AS ParentId, t.record_status AS Status
      FROM {S}.registry_organization t
     WHERE @allowed_legal_entity_ids IS NULL
        OR t.registry_organization_id IN (SELECT ax.registry_organization_id FROM {S}.organization ax WHERE ax.organization_id IN {ALLOW})""")
            continue
        if k == "legal-entities":
            parts.append(f"""    SELECT N'legal-entities', t.organization_id, t.organization_code, t.organization_name,
           t.organization_id, t.registry_organization_id, t.parent_organization_id, t.status
      FROM {S}.organization t
     WHERE (@registry_organization_id = 0 OR t.registry_organization_id = @registry_organization_id
        OR (@registry_organization_id = -1 AND t.registry_organization_id IS NULL))
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN {ALLOW})""")
            continue
        parent = next((f["col"] for f in ent["fields"] if f["kind"] == "ref" and f["ref"] == k), None)
        pexpr = f"t.{parent}" if parent else "CAST(NULL AS BIGINT)"
        parts.append(f"""    SELECT {lit(k)}, t.{ent['id']}, t.{ent['code']}, {ref_name_expr(ent,'t')},
           t.organization_id, le.registry_organization_id, {pexpr}, t.{ent['status_col']}
      FROM {S}.{ent['table']} t JOIN {S}.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN {ALLOW})""")
    for ext in EXTERNAL:
        parts.append(f"""    SELECT {lit(ext['key'])}, t.{ext['id']}, {code_expr(ext, 't')}, {ref_name_expr(ext,'t')},
           t.organization_id, le.registry_organization_id, CAST(NULL AS BIGINT), t.{ext['status_col']}
      FROM {S}.{ext['table']} t JOIN {S}.organization le ON le.organization_id = t.organization_id
     WHERE (@registry_organization_id = 0 OR le.registry_organization_id = @registry_organization_id
            OR (@registry_organization_id = -1 AND le.registry_organization_id IS NULL))
       AND (@legal_entity_id = 0 OR t.organization_id = @legal_entity_id)
       AND (@allowed_legal_entity_ids IS NULL OR t.organization_id IN {ALLOW})""")
    union = "\n    UNION ALL\n".join(parts)
    return f"""CREATE OR ALTER PROCEDURE {S}.sp_orgreg_lookups
    @registry_organization_id BIGINT = 0,
    @legal_entity_id          BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = every Legal Entity
AS
BEGIN
    SET NOCOUNT ON;
{TZ_BLOCK}
    -- 1. Controlled values. LocationType and CommitteeMemberDesignation come
    --    from the existing FK masters (location_type_master,
    --    committee_designation_master) because those columns store their ids;
    --    the 570 rows of the same groups only say which values the workbook lists.
    SELECT m.master_group AS [Group], m.value_label AS Value, m.is_workbook_value AS IsWorkbookValue,
           m.source_note AS Note, m.display_order AS DisplayOrder, CAST(NULL AS BIGINT) AS LegalEntityId
      FROM {S}.org_registry_master_value m
     WHERE m.status = N'Active' AND m.master_group NOT IN (N'LocationType', N'CommitteeMemberDesignation')
    UNION ALL
    SELECT N'LocationType', lt.location_type_name, ISNULL(m.is_workbook_value, CAST(0 AS BIT)),
           ISNULL(m.source_note, N'Existing GRAC location type (not in 15 Masters & Codes).'),
           ISNULL(m.display_order, 500 + lt.display_order), CAST(NULL AS BIGINT)
      FROM {S}.location_type_master lt
      LEFT JOIN {S}.org_registry_master_value m ON m.master_group = N'LocationType' AND m.value_label = lt.location_type_name
     WHERE lt.is_active = 1
    UNION ALL
    SELECT N'CommitteeMemberDesignation', d.designation_name, ISNULL(m.is_workbook_value, CAST(0 AS BIT)),
           ISNULL(m.source_note, CASE WHEN d.organization_id IS NULL THEN N'Existing GRAC designation (not in 15 Masters & Codes).'
                                      ELSE N'Designation added by this Legal Entity.' END),
           ISNULL(m.display_order, 500), d.organization_id
      FROM {S}.committee_designation_master d
      LEFT JOIN {S}.org_registry_master_value m ON m.master_group = N'CommitteeMemberDesignation' AND m.value_label = d.designation_name
     WHERE d.is_active = 1
       AND (d.organization_id IS NULL OR @legal_entity_id = 0 OR d.organization_id = @legal_entity_id)
       AND (d.organization_id IS NULL OR @allowed_legal_entity_ids IS NULL OR d.organization_id IN {ALLOW})
    UNION ALL
    -- Time zones (Locations), from another module's table: empty until it is deployed.
    SELECT N'TimeZone', z.label, CAST(1 AS BIT), CAST(NULL AS NVARCHAR(400)), 0, CAST(NULL AS BIGINT)
      FROM @tz z
     WHERE z.active = 1
     ORDER BY [Group], DisplayOrder, Value;

    -- 2. Records that reference fields pick from (code + name, with the
    --    Legal Entity / Organization the screen filters dependent choices by).
{union}
     ORDER BY Kind, Code;
END;
GO
"""

def gen_summary():
    cnt = []
    for ent in ENTITIES:
        if ent["key"] in ("organizations", "legal-entities"):
            continue
        P = "".join(w.capitalize() for w in ent["key"].split("-"))
        cnt.append(f"           (SELECT COUNT(*) FROM {S}.{ent['table']} x WHERE x.organization_id = o.organization_id) AS {P}")
    return f"""CREATE OR ALTER PROCEDURE {S}.sp_orgreg_summary
    @registry_organization_id BIGINT = 0,
    @allowed_legal_entity_ids NVARCHAR(MAX) = NULL   -- JSON array; NULL = every Legal Entity
AS
BEGIN
    SET NOCOUNT ON;
    -- One row per Legal Entity: where it sits in the hierarchy and how many
    -- records each registry area holds for it (the Registry's hierarchy panel).
    SELECT o.organization_id AS LegalEntityId, o.organization_code AS LegalEntityCode, o.organization_name AS LegalEntityName,
           o.parent_organization_id AS ParentLegalEntityId, o.registry_organization_id AS RegistryOrganizationId,
           o.status AS Status, o.in_scope_for_grac AS InScopeForGrac,
{",\n".join(cnt)}
      FROM {S}.organization o
     WHERE (@registry_organization_id = 0 OR o.registry_organization_id = @registry_organization_id
        OR (@registry_organization_id = -1 AND o.registry_organization_id IS NULL))
       AND (@allowed_legal_entity_ids IS NULL OR o.organization_id IN {ALLOW})
     ORDER BY o.organization_name;
END;
GO
"""

def gen_procs():
    out = [f"""{HDR_RULE}
-- 571_org_registry_procedures.sql
--
-- Organization Registry -- every read and write the Registry screen makes.
-- Generated from one field specification (docs/organization-registry.md
-- lists it), so the thirteen areas follow exactly the same rules:
--
--   sp_orgreg_lookups      controlled values + pickable records
--   sp_orgreg_summary      Legal Entities with per-area record counts
--   sp_orgreg_<area>_list  rows (filter: Organization / Legal Entity /
--                          status / search / one id), reference fields
--                          returned as id + code + name
--   sp_orgreg_<area>_save  insert (@id = 0) or update; @payload is the
--                          form as JSON, keys = the field keys
--
-- @allowed_legal_entity_ids (every procedure): NULL for GRAC administration
-- (Organization Management, GLOBAL scope); otherwise the JSON array of the
-- caller's organization ids, set by the Web tier from the session -- reads
-- are limited to those Legal Entities (and their Organizations), saves to
-- records of those Legal Entities, and Organizations / Legal Entities are
-- read-only (Practice Management -> Organization, 575).
--
-- Save rules (in order): JSON + actor; record exists; types (date, number,
-- id); mandatory fields; lengths and formats; controlled values (a value
-- off the list is kept only if the record already holds it); references
-- exist and belong to the same Legal Entity / Organization; no parent
-- loops; unique codes. Writes one practice_audit_trace row (before/after)
-- per save. There is NO delete: a record is retired by its status, and
-- inactive / closed records stay for traceability (workbook START HERE).
--
-- Errors: THROW 52700-52707 (52707: outside the caller's Legal Entities). The message starts with "[fieldKey] " so the
-- Api can return the field and the screen can mark it.
--
-- Requires 569. ASCII only. Rollback: 571_org_registry_procedures_rollback.sql
{HDR_RULE}
SET NOCOUNT ON;
SET NOEXEC OFF;
GO
IF OBJECT_ID('{S}.registry_organization','U') IS NULL
   OR OBJECT_ID('{S}.org_registry_master_value','U') IS NULL
   OR OBJECT_ID('{S}.organization_delivery_channel','U') IS NULL
   OR COL_LENGTH('{S}.organization','registry_organization_id') IS NULL
   OR COL_LENGTH('{S}.organization_employee','person_status') IS NULL
   OR COL_LENGTH('{S}.organization_dependency_process','process_code') IS NULL
BEGIN
    PRINT 'ABORT (571): run 569_org_registry_schema.sql first. Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- The Organization Administration columns the registry took over (2026-11-16).
IF COL_LENGTH('{S}.organization_location','time_zone_id') IS NULL
   OR COL_LENGTH('{S}.organization_business_function','criticality') IS NULL
   OR COL_LENGTH('{S}.organization_team','vendor_id') IS NULL
   OR OBJECT_ID('{S}.organization_dependency_vendor','U') IS NULL
   OR OBJECT_ID('{S}.organization_team_member','U') IS NULL
BEGIN
    PRINT 'ABORT (571): run 133, 360 and 362 first (team vendor, location time zone, team members). Nothing was changed.';
    SET NOEXEC ON;
END
GO
-- Every column the procedures read that 569 did not add (Msg 207 inside a
-- CREATE PROCEDURE does not stop the script, so it is checked up front).
IF @@RS_GUARD@@
BEGIN
    PRINT 'ABORT (571): a record_status_id column the procedures write is missing (see 002 / 008 / 370). Nothing was changed.';
    SET NOEXEC ON;
END
GO
"""]
    rs_tables = [e["table"] for e in ENTITIES if e["record_status_id"]]
    out[0] = out[0].replace("@@RS_GUARD@@", "\n   OR ".join(f"COL_LENGTH('{S}.{t}','record_status_id') IS NULL" for t in rs_tables))
    out.append(gen_lookups())
    out.append(gen_summary())
    for ent in ENTITIES:
        out.append(gen_list(ent))
        out.append(gen_save(ent))
    out.append("SET NOEXEC OFF;\nGO\nPRINT '571 complete: Organization Registry procedures created. Restart the Api is NOT required (no shim probe).';\nGO\n")
    return "\n".join(out)

def proc_names():
    names = ["sp_orgreg_lookups", "sp_orgreg_summary"]
    for ent in ENTITIES:
        k = ent["key"].replace("-", "_")
        names += [f"sp_orgreg_{k}_list", f"sp_orgreg_{k}_save"]
    return names

def gen_procs_rollback():
    lines = [f"{HDR_RULE}\n-- 571_org_registry_procedures_rollback.sql -- drops the procedures 571 created.\n{HDR_RULE}\nSET NOCOUNT ON;\nGO"]
    for n in proc_names():
        lines.append(f"IF OBJECT_ID('{S}.{n}','P') IS NOT NULL DROP PROCEDURE {S}.{n};")
    lines.append("GO\nPRINT '571 rollback complete.';\nGO")
    return "\n".join(lines) + "\n"
