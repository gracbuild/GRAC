-- =====================================================================
-- 554  An engagement's Branch narrows its scope (branch audit)
--
-- REQUEST (2026-11-14, sir)
--   "If we need to audit a branch, can we do it today?" -- no: the
--   engagement's Branch was free text, used by nothing, and the scope has
--   no branch filter. Decisions (sir): a branch IS a Location (Location
--   master); a practice instance belongs to a branch through its LOCATION
--   dependency resolved in Operationalize.
--
-- MODEL
--   The audit definition's scope stays the full set. An engagement with a
--   Branch (organization_location) audits only what is at that branch:
--     PRACTICE_INSTANCE  kept when an active practice_dependency_resolution
--                        row of type LOCATION points at the branch (the
--                        415 View Data Scope rule)
--     ASSET              kept when organization_dependency_asset.location_id
--                        is the branch
--     anything else      (departments, vendors, legacy dimensions) kept
--   Narrowing only removes; it never adds.
--
-- WHAT THIS DOES
--   1. NEW sp_org_assurance_scope_resolution_narrow_location(@organization_id,
--      @resolution_id, @location_id): narrows a resolved snapshot and
--      recomputes its totals. No transaction of its own, no ROLLBACK --
--      nests in the callers' transactions.
--   2. sp_org_assurance_scope_dimension_values (534 body) + BRANCH: the
--      organization's active Locations (the engagement's Branch picker,
--      GET scope-dimensions/BRANCH/values). BRANCH stays non-pickable, so
--      the Scope Builder is unchanged.
--   3. sp_org_assurance_plan_item_start_execution (552 body): with a
--      Branch, each audit's scope is resolved (EXECUTION), narrowed and
--      handed to materialize as its snapshot (materialize unchanged). An
--      audit with nothing at the branch stops the start: 53942.
--   4. sp_org_assurance_engagement_scope_preview (552 body): View Scope
--      narrowed the same way -- a saved engagement by its own Branch, an
--      unsaved pick by @location_id.
--   Engagements saved before 554 carry only a Branch NAME (free text): no
--   id, so they are not narrowed; the dialog shows them as text only.
--
-- ERRORS: 53939 ids required; 53940 the branch is not a Location of the
--   organization; 53941 scope snapshot not found; 53942 an audit has
--   nothing in scope at the branch.
-- DEPENDS ON: 534, 545, 552.
-- Rollback: 554_engagement_branch_scope_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_engagement_definition','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_scope_statement_instance','IF') IS NULL
      AND OBJECT_ID('grac_practice.fn_org_scope_statement_instance','TF') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_plan_item','assigned_branch_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','location_id') IS NULL
BEGIN
    PRINT 'ABORT (554): run 534, 545 and 552 first. Nothing was changed.';
    RAISERROR('554_engagement_branch_scope: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Narrow a resolved scope to one branch (Location)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scope_resolution_narrow_location
    @organization_id BIGINT,
    @resolution_id   BIGINT,
    @location_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @resolution_id IS NULL OR @location_id IS NULL
        THROW 53939, 'organization_id, resolution_id and location_id are required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_location
                    WHERE location_id = @location_id AND organization_id = @organization_id)
        THROW 53940, 'The branch is not a Location of this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_scope_resolution
                    WHERE org_assurance_scope_resolution_id = @resolution_id
                      AND organization_id = @organization_id)
        THROW 53941, 'Scope snapshot not found.', 1;

    -- Practice instances: linked to the Location in Operationalize.
    DELETE e
      FROM grac_practice.org_assurance_scope_resolution_entity e
     WHERE e.org_assurance_scope_resolution_id = @resolution_id
       AND e.dimension_code = N'PRACTICE_INSTANCE'
       AND NOT EXISTS (
            SELECT 1
              FROM grac_practice.practice_dependency_resolution r
              JOIN grac_practice.dependency_type_master dt
                ON dt.dependency_type_id = r.dependency_type_id
               AND (dt.dependency_type_code = N'LOCATION' OR dt.dependency_type_name = N'Location')
             WHERE r.practice_instance_id   = e.entity_id
               AND r.organization_id        = @organization_id
               AND r.is_active              = 1
               AND r.resolved_dependency_id = @location_id);

    -- Assets: at the Location.
    DELETE e
      FROM grac_practice.org_assurance_scope_resolution_entity e
     WHERE e.org_assurance_scope_resolution_id = @resolution_id
       AND e.dimension_code = N'ASSET'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                        WHERE a.asset_id = e.entity_id AND a.location_id = @location_id);

    -- Totals, as the resolver writes them.
    DECLARE @summary NVARCHAR(MAX) = (
        SELECT dimension_code AS dimensionCode, COUNT(*) AS entityCount
          FROM grac_practice.org_assurance_scope_resolution_entity
         WHERE org_assurance_scope_resolution_id = @resolution_id
         GROUP BY dimension_code
         ORDER BY dimension_code
           FOR JSON PATH);
    DECLARE @total BIGINT = (
        SELECT COUNT_BIG(*) FROM grac_practice.org_assurance_scope_resolution_entity
         WHERE org_assurance_scope_resolution_id = @resolution_id);

    UPDATE grac_practice.org_assurance_scope_resolution
       SET total_entity_count = @total,
           summary_json       = @summary
     WHERE org_assurance_scope_resolution_id = @resolution_id;
END
GO
