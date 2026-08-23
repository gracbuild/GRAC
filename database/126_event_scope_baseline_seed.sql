-- =====================================================================
-- 126 Scoped Event Assurance -- baseline entity types + event definitions
--
-- Why this migration exists
-- -------------------------
-- 066 made entity types and events fully org-configurable and shipped NO
-- seed data -- only sp_entity_type_save / sp_event_definition_save. That
-- is correct for a metadata-driven engine, but it means the 124 wrappers
--
--     sp_event_raise_people_lifecycle  -> PEOPLE_ONBOARDING / PEOPLE_OFFBOARDING
--     sp_event_raise_asset_lifecycle   -> ASSET_COMMISSIONING / ASSET_DECOMMISSIONING
--
-- resolve their default event_code against nothing on a fresh org and
-- throw 'event definition not found'. Every organization would have to
-- hand-create four rows with exactly the right codes before the module
-- does anything -- an undocumented setup step that will be missed.
--
-- This seeds those four events (and the two entity types they hang off)
-- for EVERY active organization, idempotently. Orgs remain free to add
-- their own; nothing here is exclusive.
--
-- Checklists and mappings are deliberately NOT seeded: what belongs on an
-- onboarding checklist is the organization's decision, and inventing one
-- would put words in the compliance team's mouth.
--
-- Depends on 066 (tables), 123/124.
-- Rollback: 126_event_scope_baseline_seed_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.entity_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.event_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
BEGIN
    RAISERROR('126: prerequisites missing (run 066 first).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Entity types -- one per subject the 124 resolver understands.
--    entity_category matches the vocabulary already used in 066's column
--    comment (People / Assets / Vendor / Applications / Custom).
-- =====================================================================
MERGE grac_practice.entity_type_master AS target
USING (
    SELECT o.organization_id, v.entity_type_code, v.entity_type_name, v.description, v.entity_category
    FROM   grac_practice.organization o
    CROSS JOIN (VALUES
        (N'PEOPLE', N'People',
         N'Employees, contractors and interns. Subject of onboarding and offboarding assurance.', N'People'),
        (N'ASSET',  N'Asset',
         N'IT and non-IT assets. Subject of commissioning and decommissioning assurance.',        N'Assets')
    ) AS v(entity_type_code, entity_type_name, description, entity_category)
    WHERE  o.status = N'Active'
) AS source
ON  target.organization_id  = source.organization_id
AND target.entity_type_code = source.entity_type_code
WHEN MATCHED THEN UPDATE SET
    entity_type_name = source.entity_type_name,
    description      = source.description,
    entity_category  = source.entity_category,
    status           = N'Active',
    updated_by       = 'seed-126',
    updated_dt       = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (organization_id, entity_type_code, entity_type_name, description,
     entity_category, status, entered_by, entered_dt)
VALUES
    (source.organization_id, source.entity_type_code, source.entity_type_name,
     source.description, source.entity_category, N'Active', 'seed-126', SYSUTCDATETIME());
GO

-- =====================================================================
-- 2. Event definitions.
--    The event_code values are a CONTRACT with 124: change them here and
--    the wrappers stop resolving. Callers that want different codes pass
--    @event_code explicitly rather than renaming these.
-- =====================================================================
MERGE grac_practice.event_definition AS target
USING (
    SELECT o.organization_id, v.event_code, v.event_name, v.description,
           v.entity_category, v.trigger_source
    FROM   grac_practice.organization o
    CROSS JOIN (VALUES
        (N'PEOPLE_ONBOARDING',      N'Person Onboarding',
         N'A person joins the organization in a role. Raises the onboarding checklists mapped to that role.',
         N'People', N'Manual'),
        (N'PEOPLE_OFFBOARDING',     N'Person Offboarding',
         N'A person leaves the organization. Raises the offboarding checklists mapped to the roles they held.',
         N'People', N'Manual'),
        (N'ASSET_COMMISSIONING',    N'Asset Commissioning',
         N'An asset is put into service. Raises the commissioning checklists mapped to its category.',
         N'Assets', N'Manual'),
        (N'ASSET_DECOMMISSIONING',  N'Asset Decommissioning',
         N'An asset is retired from service. Raises the decommissioning checklists mapped to its category.',
         N'Assets', N'Manual')
    ) AS v(event_code, event_name, description, entity_category, trigger_source)
    WHERE  o.status = N'Active'
) AS source
ON  target.organization_id = source.organization_id
AND target.event_code      = source.event_code
WHEN MATCHED THEN UPDATE SET
    event_name      = source.event_name,
    description     = source.description,
    entity_category = source.entity_category,
    status          = N'Active',
    updated_by      = 'seed-126',
    updated_dt      = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN INSERT
    (organization_id, event_code, event_name, description,
     entity_category, trigger_source, status, entered_by, entered_dt)
VALUES
    (source.organization_id, source.event_code, source.event_name, source.description,
     source.entity_category, source.trigger_source, N'Active', 'seed-126', SYSUTCDATETIME());
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
DECLARE @orgs INT = (SELECT COUNT(*) FROM grac_practice.organization WHERE status = N'Active');

SELECT 'entity types seeded for every active org' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_type_master
                   WHERE entity_type_code IN (N'PEOPLE', N'ASSET') AND status = N'Active')
                 >= @orgs * 2
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'four lifecycle events seeded for every active org' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.event_definition
                   WHERE event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING',
                                        N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
                     AND status = N'Active')
                 >= @orgs * 4
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT o.organization_id, o.organization_name AS OrganizationName,
       SUM(CASE WHEN ed.event_code IS NOT NULL THEN 1 ELSE 0 END) AS LifecycleEvents
FROM   grac_practice.organization o
LEFT JOIN grac_practice.event_definition ed
       ON ed.organization_id = o.organization_id
      AND ed.event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING',
                            N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
WHERE  o.status = N'Active'
GROUP BY o.organization_id, o.organization_name
ORDER BY o.organization_id;

PRINT '126 Baseline entity types + lifecycle event definitions seeded.';
PRINT 'NEXT: create checklists, then map them per role / asset category on Scoped Checklist Mapping.';
GO

SET NOEXEC OFF;
GO
