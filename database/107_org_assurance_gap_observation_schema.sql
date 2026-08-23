-- =====================================================================
-- 107 Organization Assurance (Phase 2) -- Stage 4b Gap Center
--
-- Business context (BRD Part 2 Sec 12 refinement):
--   A single gap frequently represents ONE root corrective issue that
--   surfaces via MANY observations (e.g. "MFA not enforced" surfaces
--   as an observation for every server audited). The 1:1 observation
--   -> gap mapping from migrations 101 + 104 is inadequate for real
--   GRC workflows -- audit teams need to attach multiple pieces of
--   evidence to a single gap, detach mistakenly-attached ones with a
--   documented reason, and merge duplicate gaps together.
--
-- This migration introduces a proper many-to-many junction:
--
--   grac_practice.org_assurance_gap_observation
--
-- And repositions the "Gaps" menu row as "Gap Center", making it the
-- primary landing page (before Observations).
--
-- Data migration: every existing observation.gap_id link is copied
-- into a junction row (idempotent -- safe to re-run).
--
-- The observation.gap_id column is NOT dropped -- it stays as a
-- soft "primary gap" pointer for backward compatibility with older
-- API callers. New code must read from the junction.
--
-- Rollback: 107_org_assurance_gap_observation_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
   OR OBJECT_ID('grac_practice.organization','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
BEGIN
    RAISERROR('107: prerequisites missing (run 001 + 101 + 104).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Junction table -- gap <-> observation
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NULL
CREATE TABLE grac_practice.org_assurance_gap_observation(
    org_assurance_gap_observation_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_oa_gap_obs PRIMARY KEY,
    org_assurance_gap_id             BIGINT NOT NULL,
    org_assurance_observation_id     BIGINT NOT NULL,
    organization_id                  BIGINT NOT NULL,

    -- Was this junction row created by the auto-hook, or manually
    -- attached by a user later? Useful for audit review.
    link_source                      NVARCHAR(30) NOT NULL
        CONSTRAINT df_pm_oa_gap_obs_source DEFAULT N'AUTO',

    linked_by                        NVARCHAR(100) NOT NULL
        CONSTRAINT df_pm_oa_gap_obs_by DEFAULT 'system',
    linked_dt                        DATETIME2 NOT NULL
        CONSTRAINT df_pm_oa_gap_obs_dt DEFAULT SYSUTCDATETIME(),

    -- Detach audit -- when a junction is retired we soft-mark it with
    -- a reason so auditors can see the reassignment trail.
    detach_by                        NVARCHAR(100) NULL,
    detach_dt                        DATETIME2 NULL,
    detach_reason                    NVARCHAR(1000) NULL,

    -- Optional free-text note captured at attach time.
    notes                            NVARCHAR(1000) NULL,

    is_active                        BIT NOT NULL
        CONSTRAINT df_pm_oa_gap_obs_active DEFAULT 1,

    CONSTRAINT fk_pm_oa_gap_obs_gap
        FOREIGN KEY(org_assurance_gap_id)
        REFERENCES grac_practice.org_assurance_gap(org_assurance_gap_id),
    CONSTRAINT fk_pm_oa_gap_obs_obs
        FOREIGN KEY(org_assurance_observation_id)
        REFERENCES grac_practice.org_assurance_observation(org_assurance_observation_id),
    CONSTRAINT fk_pm_oa_gap_obs_org
        FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
    CONSTRAINT ck_pm_oa_gap_obs_source CHECK (
        link_source IN (N'AUTO', N'MANUAL', N'MERGE'))
);
GO

-- One active junction row per (gap, observation) pair. Detached rows
-- can accumulate (they are audit history). A partial unique index
-- (filtered) protects against duplicate active links.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'uq_pm_oa_gap_obs_active'
      AND object_id = OBJECT_ID('grac_practice.org_assurance_gap_observation'))
CREATE UNIQUE INDEX uq_pm_oa_gap_obs_active
    ON grac_practice.org_assurance_gap_observation(
        org_assurance_gap_id, org_assurance_observation_id)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_gap_obs_gap
    ON grac_practice.org_assurance_gap_observation(
        org_assurance_gap_id, is_active,
        org_assurance_gap_observation_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_gap_obs_observation
    ON grac_practice.org_assurance_gap_observation(
        org_assurance_observation_id, is_active,
        org_assurance_gap_observation_id DESC)
    WHERE is_active = 1;
GO

CREATE INDEX ix_pm_oa_gap_obs_org
    ON grac_practice.org_assurance_gap_observation(
        organization_id, is_active, linked_dt DESC)
    WHERE is_active = 1;
GO

-- =====================================================================
-- 2. DATA MIGRATION -- copy existing observation.gap_id links into
--    junction rows. Idempotent -- guarded by NOT EXISTS.
-- =====================================================================
INSERT INTO grac_practice.org_assurance_gap_observation(
    org_assurance_gap_id, org_assurance_observation_id, organization_id,
    link_source, linked_by, linked_dt, is_active)
SELECT o.gap_id,
       o.org_assurance_observation_id,
       o.organization_id,
       N'AUTO',
       ISNULL(o.updated_by, 'system'),
       ISNULL(o.updated_dt, o.entered_dt),
       1
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.org_assurance_gap g
     ON g.org_assurance_gap_id = o.gap_id
    AND g.organization_id      = o.organization_id
    AND g.is_active = 1
WHERE o.gap_id IS NOT NULL
  AND o.is_active = 1
  AND NOT EXISTS (
      SELECT 1
      FROM grac_practice.org_assurance_gap_observation j
      WHERE j.org_assurance_gap_id         = o.gap_id
        AND j.org_assurance_observation_id = o.org_assurance_observation_id
        AND j.is_active = 1);
GO

DECLARE @migrated INT = @@ROWCOUNT;
PRINT '107 data migration: ' + CAST(@migrated AS NVARCHAR(20))
    + ' observation<->gap links copied into junction.';
GO

-- =====================================================================
-- 3. Menu reorder -- Gap Center first, Observations after
--    NOTE: existing menu rows keep their menu_key; only labels and
--    display_order change so upstream permissions + feature flags
--    are unaffected.
-- =====================================================================
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps')
BEGIN
    UPDATE grac_practice.menu_master
    SET menu_name     = N'Gap Center',
        display_order = 470,
        updated_by    = 'seed-107',
        updated_dt    = SYSUTCDATETIME()
    WHERE menu_key = N'org-assurance-gaps';
END
GO

IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-observations')
BEGIN
    UPDATE grac_practice.menu_master
    SET display_order = 472,
        updated_by    = 'seed-107',
        updated_dt    = SYSUTCDATETIME()
    WHERE menu_key = N'org-assurance-observations';
END
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'org_assurance_gap_observation present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'menu order: Gap Center before Observations' AS Check_,
       CASE WHEN (
           (SELECT display_order FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps') <
           (SELECT display_order FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-observations'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'existing observation.gap_id links migrated to junction' AS Check_,
       CASE WHEN NOT EXISTS (
           SELECT 1 FROM grac_practice.org_assurance_observation o
           JOIN grac_practice.org_assurance_gap g
                ON g.org_assurance_gap_id = o.gap_id AND g.is_active = 1
           WHERE o.gap_id IS NOT NULL AND o.is_active = 1
             AND NOT EXISTS (
                 SELECT 1 FROM grac_practice.org_assurance_gap_observation j
                 WHERE j.org_assurance_gap_id         = o.gap_id
                   AND j.org_assurance_observation_id = o.org_assurance_observation_id
                   AND j.is_active = 1))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '107 Organization Assurance Gap Center junction schema deployed.';
GO

SET NOEXEC OFF;
GO
