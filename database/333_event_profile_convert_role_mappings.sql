-- =====================================================================
-- 333 OPTIONAL -- convert existing role-scoped mappings into Profiles
--
-- THIS MIGRATION IS NOT REQUIRED AND IS NOT RUN AUTOMATICALLY.
-- ----------------------------------------------------------
-- 331 left the role-scoped path fully working. An organisation can go on
-- configuring event obligations from the Role Master form indefinitely
-- and never create a profile. This script exists for the organisation
-- that wants its existing role mappings visible as Profiles so that
-- Location and Department can be added to them.
--
-- WHAT IT DOES
-- ------------
-- For every organisation role that has at least one applicability row:
--   1. creates (or finds) a Profile named "Role: <role name>" with a
--      single ORG_ROLE criterion holding that one role
--   2. copies every applicability row of that role to the profile,
--      decision for decision -- is_applicable, rationale, owner role and
--      due days included
--   3. deactivates the source role rows
--
-- WHY STEP 3, GIVEN BOTH PATHS ARE SUPPOSED TO STAY LIVE
-- ------------------------------------------------------
-- Leaving both copies Active is a trap, not a safety net. The resolver
-- de-duplicates per obligation preferring Included over Excluded (131's
-- rule, unchanged). So after an un-tick on the profile copy, the role
-- copy would still say Included and the obligation would go on firing --
-- the admin's change would appear to save and do nothing. Deactivating
-- the source makes the profile authoritative for the roles that were
-- converted, and only for those.
--
-- Set @DeactivateSource = 0 below to copy without deactivating. Do that
-- only for a read-only comparison: with both copies Active the profile
-- can add obligations but cannot remove them.
--
-- WHAT IT DOES NOT DO
-- -------------------
-- Nothing is deleted. Asset-category mappings are not touched. The Role
-- Master form keeps working -- for an unconverted role it is still the
-- place to configure, and for a converted one it shows the deactivated
-- rows, which is the truth.
--
-- SAFE TO RE-RUN. A profile already carrying a decision for an
-- (obligation, event) pair is not overwritten, so a second run adds only
-- what is genuinely new.
--
-- Depends on 329, 330, 331.
-- Rollback: 333_event_profile_convert_role_mappings_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- Configuration
-- =====================================================================
DECLARE @DeactivateSource BIT    = 1;      -- see the header before changing
DECLARE @OrganizationId   BIGINT = NULL;   -- NULL = every organisation

-- =====================================================================
-- Prerequisites
-- =====================================================================
IF OBJECT_ID('grac_practice.event_profile','U') IS NULL
   OR COL_LENGTH('grac_practice.event_obligation_applicability','profile_id') IS NULL
BEGIN
    RAISERROR('333: run 329 first.', 16, 1);
    RETURN;
END

IF OBJECT_ID('grac_practice.fn_pm_event_profile_matches','IF') IS NULL
BEGIN
    RAISERROR('333: run 330 first.', 16, 1);
    RETURN;
END

DECLARE @role_dim_id INT = (
    SELECT dimension_id FROM grac_practice.event_profile_dimension_master
     WHERE dimension_code = N'ORG_ROLE' AND is_active = 1);

IF @role_dim_id IS NULL
BEGIN
    RAISERROR('333: the ORG_ROLE criterion dimension is missing or inactive. Run 329.', 16, 1);
    RETURN;
END

-- =====================================================================
-- The roles worth converting: those that actually carry a decision.
-- A role with no mappings would produce an empty profile nobody asked
-- for.
-- =====================================================================
DECLARE @roles TABLE (
    rowid           INT IDENTITY(1,1) PRIMARY KEY,
    organization_id BIGINT,
    role_id         BIGINT,
    role_name       NVARCHAR(120),
    profile_id      BIGINT NULL);

INSERT INTO @roles(organization_id, role_id, role_name)
SELECT DISTINCT r.organization_id, r.role_id, r.role_name
FROM   grac_practice.organization_role r
WHERE  (@OrganizationId IS NULL OR r.organization_id = @OrganizationId)
  AND  EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability a
                WHERE a.organization_id = r.organization_id
                  AND a.scope_role_id   = r.role_id);

IF NOT EXISTS (SELECT 1 FROM @roles)
BEGIN
    PRINT '333: no role-scoped applicability rows found. Nothing to convert.';
    RETURN;
END

BEGIN TRAN;

DECLARE @rowid INT = 0, @max_rowid INT = (SELECT MAX(rowid) FROM @roles);
DECLARE @org BIGINT, @role BIGINT, @role_nm NVARCHAR(120),
        @profile BIGINT, @criteria BIGINT, @code NVARCHAR(60), @name NVARCHAR(200);

WHILE @rowid < @max_rowid
BEGIN
    SET @rowid = @rowid + 1;

    SELECT @org = organization_id, @role = role_id, @role_nm = role_name
    FROM @roles WHERE rowid = @rowid;

    -- Code is built from the role id, not the name: renaming a role must
    -- not orphan its profile or collide with another code. Same reasoning
    -- as 136's checklist_code.
    SET @code = LEFT(CONCAT(N'ROLE-', @role), 60);
    SET @name = LEFT(CONCAT(N'Role: ', @role_nm), 200);

    SELECT @profile = profile_id
    FROM   grac_practice.event_profile
    WHERE  organization_id = @org AND profile_code = @code;

    IF @profile IS NULL
    BEGIN
        INSERT INTO grac_practice.event_profile
            (organization_id, profile_code, profile_name, description,
             subject_entity, status, entered_by, entered_dt)
        VALUES
            (@org, @code, @name,
             N'Converted from the role-scoped event obligation mapping by migration 333. Add Location or Department criteria to narrow it.',
             N'EMPLOYEE', N'Active', 'seed-333', SYSUTCDATETIME());
        SET @profile = SCOPE_IDENTITY();
    END

    UPDATE @roles SET profile_id = @profile WHERE rowid = @rowid;

    -- The single ORG_ROLE criterion. Re-runnable: the criterion is
    -- replaced rather than duplicated, and the unique index on
    -- (profile_id, dimension_code) would reject a second one anyway.
    SELECT @criteria = criteria_id
    FROM   grac_practice.event_profile_criteria
    WHERE  profile_id = @profile AND dimension_code = N'ORG_ROLE';

    IF @criteria IS NULL
    BEGIN
        INSERT INTO grac_practice.event_profile_criteria
            (profile_id, organization_id, dimension_id, dimension_code,
             match_all, entered_by, entered_dt)
        VALUES
            (@profile, @org, @role_dim_id, N'ORG_ROLE', 0, 'seed-333', SYSUTCDATETIME());
        SET @criteria = SCOPE_IDENTITY();
    END

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_profile_criteria_value
                    WHERE criteria_id = @criteria AND value_id = @role)
        INSERT INTO grac_practice.event_profile_criteria_value
            (criteria_id, profile_id, value_id, value_text, value_label, entered_by, entered_dt)
        VALUES
            (@criteria, @profile, @role, NULL, LEFT(@role_nm, 300), 'seed-333', SYSUTCDATETIME());

    -- Copy the decisions. A pair already decided on the profile is left
    -- alone -- a re-run must not undo an edit made since the first one.
    INSERT INTO grac_practice.event_obligation_applicability
        (organization_id, obligation_id, obligation_label, event_type_id, event_type_code,
         release_id, scope_dimension, scope_role_id, scope_asset_category_id, profile_id,
         is_applicable, rationale, owner_role_id, due_days, status, entered_by, entered_dt)
    SELECT a.organization_id, a.obligation_id, a.obligation_label, a.event_type_id, a.event_type_code,
           a.release_id, N'PROFILE', NULL, NULL, @profile,
           a.is_applicable, a.rationale, a.owner_role_id, a.due_days, a.status,
           'seed-333', SYSUTCDATETIME()
    FROM   grac_practice.event_obligation_applicability a
    WHERE  a.organization_id = @org
      AND  a.scope_role_id   = @role
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.event_obligation_applicability e
                        WHERE e.organization_id = a.organization_id
                          AND e.obligation_id   = a.obligation_id
                          AND e.event_type_id   = a.event_type_id
                          AND e.profile_id      = @profile);

    IF @DeactivateSource = 1
        UPDATE grac_practice.event_obligation_applicability
           SET status     = N'Inactive',
               updated_by = 'seed-333',
               updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @org
           AND scope_role_id   = @role
           AND status          = N'Active';
END

COMMIT TRAN;
GO

-- =====================================================================
-- Report
-- =====================================================================
SELECT 'profiles created by 333' AS Check_,
       CAST(COUNT(1) AS NVARCHAR(20)) AS Result
FROM   grac_practice.event_profile WHERE entered_by = 'seed-333'
UNION ALL
SELECT 'decisions copied to profiles',
       CAST(COUNT(1) AS NVARCHAR(20))
FROM   grac_practice.event_obligation_applicability WHERE entered_by = 'seed-333'
UNION ALL
SELECT 'source role rows deactivated',
       CAST(COUNT(1) AS NVARCHAR(20))
FROM   grac_practice.event_obligation_applicability
 WHERE updated_by = 'seed-333' AND status = N'Inactive' AND scope_role_id IS NOT NULL;

-- What each converted profile now matches. A count of 0 means the role
-- has no active holder -- the conversion is still correct, but nothing
-- will fire until somebody holds that role.
SELECT p.organization_id,
       p.profile_code   AS ProfileCode,
       p.profile_name   AS ProfileName,
       (SELECT COUNT(1)
        FROM   grac_practice.organization_employee e
        WHERE  e.organization_id = p.organization_id
          AND  e.status          = N'Active'
          AND  EXISTS (SELECT 1 FROM grac_practice.fn_pm_event_profile_matches(
                                        p.organization_id, N'EMPLOYEE', e.employee_id) m
                        WHERE m.profile_id = p.profile_id)) AS MatchedEmployees,
       (SELECT COUNT(1) FROM grac_practice.event_obligation_applicability a
         WHERE a.profile_id = p.profile_id AND a.status = N'Active')      AS ActiveDecisions
FROM   grac_practice.event_profile p
WHERE  p.entered_by = 'seed-333'
ORDER BY p.organization_id, p.profile_name;

PRINT '333 role-to-profile conversion complete.';
PRINT 'Converted roles are now configured from the Profiles screen; their Role Master rows are Inactive.';
PRINT 'Roles with no mappings were not converted and still configure from Role Master.';
GO
