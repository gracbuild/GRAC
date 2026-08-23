-- =====================================================================
-- 130 Event Assurance -- split coverage into "decided" and "applicable"
--
-- WHAT WAS WRONG
-- --------------
-- Ticking an obligation showed the role at 100%. Unticking it -- recording
-- an explicit "not applicable" with a reason -- left it at 100%.
--
-- The number was not miscalculated. sp_event_obligation_coverage_list
-- counts obligations that have a DECISION recorded, and "not applicable"
-- is a decision. So the count was right and the screen was misleading:
-- 100% next to a role where every obligation had been excluded reads as
-- "fully covered" when it means "fully triaged, nothing applies".
--
-- One percentage cannot answer both questions:
--   * Have all obligations been triaged?      -> the GAP metric
--   * How many actually apply to this role?   -> the WORKLOAD metric
--
-- Collapsing them would have to sacrifice one. A GRC screen needs both:
-- an undecided obligation is an unknown, an excluded obligation is a
-- documented judgement, and treating those as the same thing is how a
-- compliance hole gets signed off. So the procedure now returns three
-- counts and the screen renders decided% as the ring with the applicable
-- count beside it.
--
-- Signature is unchanged, and the three existing result columns are
-- preserved, so nothing that already reads this procedure breaks.
--
-- Depends on 127, 128, 129.
-- Rollback: 130_event_obligation_coverage_split_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_event_obligation_coverage_list','P') IS NULL
BEGIN
    RAISERROR('130: run 128 first.', 16, 1);
    RETURN;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_obligation_coverage_list
    @organization_id BIGINT,
    @scope_dimension NVARCHAR(40),
    @event_type_id   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @scope_dimension IS NULL
        THROW 67320, 'sp_event_obligation_coverage_list: organization_id and scope_dimension are required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 67321, 'sp_event_obligation_coverage_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;

    -- Denominator: distinct event-driven obligations actually reaching this
    -- organization. DISTINCT matters -- the view fans out per requirement /
    -- practice / release path (see 129).
    DECLARE @total INT = (
        SELECT COUNT(DISTINCT obligation_id)
        FROM   grac_practice.vw_pm_event_driven_obligation
        WHERE  organization_id = @organization_id
          AND  is_subscribed   = 1
          AND  (@event_type_id IS NULL OR event_type_id = @event_type_id));

    IF @scope_dimension = N'ORG_ROLE'
        SELECT N'ORG_ROLE'                      AS ScopeDimension,
               r.role_id                        AS ScopeValueId,
               r.role_name                      AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT a.obligation_id)  AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations,
               -- NEW: of the decided ones, how many actually apply.
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN a.obligation_id END)
                                                AS ExcludedObligations
        FROM      grac_practice.organization_role r
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id = r.organization_id
              AND a.scope_role_id   = r.role_id
              AND a.status          = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     r.organization_id = @organization_id
          AND     r.status          = N'Active'
        GROUP BY  r.role_id, r.role_name
        ORDER BY  UndecidedObligations DESC, r.role_name;
    ELSE
        SELECT N'ASSET_CATEGORY'                AS ScopeDimension,
               ac.asset_category_id             AS ScopeValueId,
               ac.asset_category_name           AS ScopeValueName,
               @total                           AS TotalObligations,
               COUNT(DISTINCT a.obligation_id)  AS DecidedObligations,
               @total - COUNT(DISTINCT a.obligation_id) AS UndecidedObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END)
                                                AS ApplicableObligations,
               COUNT(DISTINCT CASE WHEN a.is_applicable = 0 THEN a.obligation_id END)
                                                AS ExcludedObligations
        FROM      grac_practice.dependency_asset_category_master ac
        LEFT JOIN grac_practice.event_obligation_applicability a
               ON a.organization_id         = @organization_id
              AND a.scope_asset_category_id = ac.asset_category_id
              AND a.status                  = N'Active'
              AND (@event_type_id IS NULL OR a.event_type_id = @event_type_id)
        WHERE     ac.is_active = 1
        GROUP BY  ac.asset_category_id, ac.asset_category_name
        ORDER BY  UndecidedObligations DESC, ac.asset_category_name;
END;
GO

SELECT 'coverage proc returns ApplicableObligations' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_coverage_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '130 Coverage split into decided / applicable / excluded deployed.';
GO
