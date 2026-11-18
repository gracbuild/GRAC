-- =====================================================================
-- 574_org_registry_defaults_and_menus.sql
--
-- Organization Registry follow-up (2026-11-16, sir):
--
-- 1. NO "NOT YET ASSIGNED" LEGAL ENTITIES. Every organization row (= Legal
--    Entity) that 569 left without an Organization gets one of its own,
--    built from the Legal Entity:
--        organization_code  ORG-<Legal Entity Code>   (unique; "-<id>" added on a clash)
--        registered_name    the Legal Entity's name
--        organization_type  the Legal Entity's entity_type when it is an
--                           OrganizationType value (Bank, NBFC, ...), else Other
--        industry           the Legal Entity's industry, else 'Not specified'
--        country/state/city the Legal Entity's, when they are sheet-15 values
--        record_status      Active (Inactive when the Legal Entity is not Active)
--        data_quality_note  says it was created by 574 with defaults to review
--    One Organization per Legal Entity: which Legal Entities belong to one
--    group is a business fact this script cannot know. Re-assign on
--    Organization Structure -> Legal Entities (field Organization) and set
--    the spare Organization Inactive.
--
-- 2. MANDATORY REGISTRY FIELDS FILLED WITH DEFAULTS on the records GRAC
--    already had (rows created before the registry). Only empty columns
--    are filled; nothing already set changes. Defaults are sheet-15 values:
--        Legal Entity      Entity Type 'Other'
--        Org Unit          Unit Type 'Other', Is Operational 'Yes'
--        Location          Location Code LOC-<id>, State 'Other', Country =
--                          the Legal Entity's country if a sheet-15 value,
--                          else 'India'; Customer-facing 'No'
--        Department        Department Type 'Other'
--        Business Function Function Category 'Other'
--        Team              Team Code TEAM-<id>, Team Type 'Other'
--        Person            Person Category 'Employee' ('Other' for vendor
--                          staff), Person Status 'Active' when the person
--                          is Active else 'Other', Designation
--                          'Not specified' when empty
--        Committee         Committee Code COMM-<id>, Committee Type 'Other',
--                          Committee Mandate 'Not recorded'
--        Committee Member  Membership Code MEM-<id>
--        Business Process  Process Code PROC-<id>, Process Level 'L1',
--                          Process Nature 'Core'
--    Products & Services and Delivery Channels exist only through the
--    registry, so they are complete already.
--
-- 3. THREE MENUS INSTEAD OF THIRTEEN TABS. 'org-registry' becomes
--    "Organization Structure" (Organizations, Legal Entities, Units,
--    Locations, Departments); new 'org-registry-people' "People &
--    Governance" (People, Teams, Committees, Committee Members) and
--    'org-registry-operations' "Business Operations" (Business Functions,
--    Processes, Products & Services, Delivery Channels). All three render
--    the same page and are governed by the one org-registry grant
--    (PracticeController.ScreenPermissionArea) -- so no grants here.
--    Same placement as 570 / 512 (under 'Organization', hidden from the
--    Practice Management sidebar). 274 amended to match.
--
-- Requires 569, 570. Idempotent. ASCII only.
-- Rollback: 574_org_registry_defaults_and_menus_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO
IF OBJECT_ID('grac_practice.registry_organization','U') IS NULL
   OR COL_LENGTH('grac_practice.organization','registry_organization_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_process','process_nature') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.org_registry_master_value WHERE master_group = N'OrganizationType')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-registry')
BEGIN
    PRINT 'ABORT (574): run 569 and 570 first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- ---------------------------------------------------------------------
-- 1. An Organization for every Legal Entity that has none.
-- ---------------------------------------------------------------------
DECLARE @new TABLE (organization_id BIGINT NOT NULL PRIMARY KEY, code NVARCHAR(80) NOT NULL);
INSERT @new (organization_id, code)
SELECT o.organization_id,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.registry_organization r
                          WHERE r.organization_code = LEFT(N'ORG-' + o.organization_code, 80))
            THEN LEFT(N'ORG-' + o.organization_code, 60) + N'-' + CAST(o.organization_id AS NVARCHAR(20))
            ELSE LEFT(N'ORG-' + o.organization_code, 80) END
  FROM grac_practice.organization o
 WHERE o.registry_organization_id IS NULL;

INSERT grac_practice.registry_organization
    (organization_code, registered_name, organization_type, industry, city, state, country,
     record_status, remarks, data_quality_note, entered_by)
SELECT n.code,
       LEFT(o.organization_name, 250),
       ISNULL((SELECT TOP (1) m.value_label FROM grac_practice.org_registry_master_value m
                WHERE m.master_group = N'OrganizationType' AND m.value_label = o.entity_type), N'Other'),
       LEFT(ISNULL(NULLIF(LTRIM(RTRIM(o.industry)), N''), N'Not specified'), 160),
       o.city,
       (SELECT TOP (1) m.value_label FROM grac_practice.org_registry_master_value m
         WHERE m.master_group = N'State' AND m.value_label = o.state_province),
       (SELECT TOP (1) m.value_label FROM grac_practice.org_registry_master_value m
         WHERE m.master_group = N'Country' AND m.value_label = o.country),
       CASE WHEN o.status = N'Active' THEN N'Active' ELSE N'Inactive' END,
       NULL,
       N'Created by migration 574 from Legal Entity ' + o.organization_code
         + N' so that every Legal Entity has an Organization. Organization Type and Industry were taken from the Legal Entity or defaulted (Other / Not specified) -- review, and re-assign the Legal Entity if it belongs to another Organization.',
       N'seed-574'
  FROM @new n JOIN grac_practice.organization o ON o.organization_id = n.organization_id;
PRINT CONCAT('574: Organizations created for unassigned Legal Entities: ', @@ROWCOUNT);

UPDATE o SET registry_organization_id = r.registry_organization_id,
             updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization o
  JOIN @new n ON n.organization_id = o.organization_id
  JOIN grac_practice.registry_organization r ON r.organization_code = n.code
 WHERE o.registry_organization_id IS NULL;
PRINT CONCAT('574: Legal Entities assigned: ', @@ROWCOUNT);

-- ---------------------------------------------------------------------
-- 2. Mandatory registry fields left empty on pre-registry records.
-- ---------------------------------------------------------------------
UPDATE grac_practice.organization
   SET entity_type = N'Other', updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE NULLIF(LTRIM(RTRIM(entity_type)), N'') IS NULL;
PRINT CONCAT('574: Legal Entity Entity Type defaulted: ', @@ROWCOUNT);

UPDATE grac_practice.organization
   SET in_scope_for_grac = N'Yes', updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE in_scope_for_grac IS NULL;

UPDATE grac_practice.organization_division
   SET unit_type      = ISNULL(unit_type, N'Other'),
       is_operational = ISNULL(is_operational, N'Yes'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE unit_type IS NULL OR is_operational IS NULL;
PRINT CONCAT('574: Organization Units defaulted: ', @@ROWCOUNT);

UPDATE l
   SET location_code   = ISNULL(l.location_code,
                           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_location x
                                              WHERE x.organization_id = l.organization_id
                                                AND x.location_code = N'LOC-' + CAST(l.location_id AS NVARCHAR(20)))
                                THEN NULL ELSE N'LOC-' + CAST(l.location_id AS NVARCHAR(20)) END),
       state_province  = ISNULL(NULLIF(LTRIM(RTRIM(l.state_province)), N''), N'Other'),
       country         = ISNULL(NULLIF(LTRIM(RTRIM(l.country)), N''),
                           ISNULL((SELECT TOP (1) m.value_label FROM grac_practice.org_registry_master_value m
                                    WHERE m.master_group = N'Country' AND m.value_label = o.country), N'India')),
       customer_facing = ISNULL(l.customer_facing, N'No'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_location l
  JOIN grac_practice.organization o ON o.organization_id = l.organization_id
 WHERE l.location_code IS NULL OR NULLIF(LTRIM(RTRIM(l.state_province)), N'') IS NULL
    OR NULLIF(LTRIM(RTRIM(l.country)), N'') IS NULL OR l.customer_facing IS NULL;
PRINT CONCAT('574: Locations defaulted: ', @@ROWCOUNT);

UPDATE grac_practice.organization_department
   SET department_type = N'Other', updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE department_type IS NULL;
PRINT CONCAT('574: Departments defaulted: ', @@ROWCOUNT);

-- Only Active / Inactive rows: migration 365's CHECK (WITH NOCHECK) is
-- enforced on any row an UPDATE touches, so a historical Retired / Draft
-- function is left alone rather than failing the whole script.
UPDATE grac_practice.organization_business_function
   SET function_category = N'Other', updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE function_category IS NULL AND status IN (N'Active', N'Inactive');
PRINT CONCAT('574: Business Functions defaulted: ', @@ROWCOUNT);

UPDATE t
   SET team_code = ISNULL(t.team_code,
                     CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_team x
                                        WHERE x.organization_id = t.organization_id
                                          AND x.team_code = N'TEAM-' + CAST(t.team_id AS NVARCHAR(20)))
                          THEN NULL ELSE N'TEAM-' + CAST(t.team_id AS NVARCHAR(20)) END),
       team_classification = ISNULL(t.team_classification, N'Other'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_team t
 WHERE t.team_code IS NULL OR t.team_classification IS NULL;
PRINT CONCAT('574: Teams defaulted: ', @@ROWCOUNT);

UPDATE grac_practice.organization_employee
   SET person_category = ISNULL(person_category, CASE WHEN party_type = N'Vendor' THEN N'Other' ELSE N'Employee' END),
       person_status   = ISNULL(person_status, CASE WHEN status = N'Active' THEN N'Active' ELSE N'Other' END),
       designation     = ISNULL(NULLIF(LTRIM(RTRIM(designation)), N''), N'Not specified'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE person_category IS NULL OR person_status IS NULL OR NULLIF(LTRIM(RTRIM(designation)), N'') IS NULL;
PRINT CONCAT('574: People defaulted: ', @@ROWCOUNT);

UPDATE c
   SET committee_code = ISNULL(c.committee_code,
                          CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_committee x
                                             WHERE x.organization_id = c.organization_id
                                               AND x.committee_code = N'COMM-' + CAST(c.committee_id AS NVARCHAR(20)))
                               THEN NULL ELSE N'COMM-' + CAST(c.committee_id AS NVARCHAR(20)) END),
       committee_type = ISNULL(c.committee_type, N'Other'),
       mandate        = ISNULL(NULLIF(LTRIM(RTRIM(c.mandate)), N''), N'Not recorded'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_committee c
 WHERE c.committee_code IS NULL OR c.committee_type IS NULL OR NULLIF(LTRIM(RTRIM(c.mandate)), N'') IS NULL;
PRINT CONCAT('574: Committees defaulted: ', @@ROWCOUNT);

UPDATE m
   SET membership_code = N'MEM-' + CAST(m.committee_member_id AS NVARCHAR(20)),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_committee_member m
 WHERE m.membership_code IS NULL
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_committee_member x
                    WHERE x.organization_id = m.organization_id
                      AND x.membership_code = N'MEM-' + CAST(m.committee_member_id AS NVARCHAR(20)));
PRINT CONCAT('574: Committee Members defaulted: ', @@ROWCOUNT);

UPDATE p
   SET process_code   = ISNULL(p.process_code,
                          CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_dependency_process x
                                             WHERE x.organization_id = p.organization_id
                                               AND x.process_code = N'PROC-' + CAST(p.process_id AS NVARCHAR(20)))
                               THEN NULL ELSE N'PROC-' + CAST(p.process_id AS NVARCHAR(20)) END),
       process_level  = ISNULL(p.process_level, N'L1'),
       process_nature = ISNULL(p.process_nature, N'Core'),
       updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.organization_dependency_process p
 WHERE p.process_code IS NULL OR p.process_level IS NULL OR p.process_nature IS NULL;
PRINT CONCAT('574: Business Processes defaulted: ', @@ROWCOUNT);

COMMIT;
GO

-- ---------------------------------------------------------------------
-- 3. Menus.
-- ---------------------------------------------------------------------
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'org-registry',            N'Organization Structure', N'Practice/Index/org-registry',            1, N'sitemap',         N'Organization'),
    (N'org-registry-people',     N'People & Governance',    N'Practice/Index/org-registry-people',     2, N'users',           N'Organization'),
    (N'org-registry-operations', N'Business Operations',    N'Practice/Index/org-registry-operations', 3, N'diagram-project', N'Organization')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-574');
PRINT CONCAT('574: registry menu rows upserted: ', @@ROWCOUNT);
GO
UPDATE c SET parent_menu_id = p.menu_id, updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c JOIN grac_practice.menu_master p ON p.menu_key = N'Organization'
 WHERE c.menu_key IN (N'org-registry-people', N'org-registry-operations') AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
UPDATE grac_practice.menu_master SET show_in_sidebar = 0, updated_by = N'seed-574', updated_dt = SYSUTCDATETIME()
 WHERE menu_key IN (N'org-registry-people', N'org-registry-operations') AND show_in_sidebar = 1;
GO

SET NOEXEC OFF;
GO
PRINT '--- 574 verification ---';
SELECT (SELECT COUNT(*) FROM grac_practice.organization WHERE registry_organization_id IS NULL) AS legal_entities_still_unassigned,
       (SELECT COUNT(*) FROM grac_practice.registry_organization WHERE entered_by = N'seed-574') AS organizations_created_by_574;
SELECT menu_key, menu_name, status, show_in_sidebar, display_order,
       (SELECT p.menu_key FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id) AS parent_key
  FROM grac_practice.menu_master m
 WHERE menu_key IN (N'org-registry', N'org-registry-people', N'org-registry-operations', N'organizations')
 ORDER BY display_order;
GO
PRINT '574 complete. Sign out and in again -- the menu is read at sign-in.';
GO
