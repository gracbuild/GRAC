-- =====================================================================
-- 342 vw_pm_event_driven_obligation -- custom obligations join the view
-- -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- Puts vw_pm_event_driven_obligation back to 127's single-branch, catalog-
-- only definition. Nothing is deleted by this rollback -- practice_obligation,
-- practice_instance_obligation and event_obligation_applicability rows are
-- all untouched -- but any applicability decision recorded against a
-- custom obligation (341's local_practice_obligation_id /
-- local_instance_obligation_id) becomes UNREACHABLE through this view: the
-- Configure-Checklists screen and the Checklists tab will stop showing
-- those obligations the moment this runs, because every one of them reads
-- the view, not the base tables.
--
-- IF 343/344 HAVE ALREADY BEEN APPLIED, ROLL THOSE BACK FIRST
-- -----------------------------------------------------------------
-- sp_event_obligation_mapping_list, sp_event_obligation_applicability_save
-- and sp_event_obligation_raise (343) and the two Checklists-tab
-- procedures (344) all read local_practice_obligation_id /
-- local_instance_obligation_id off this view. Dropping those columns out
-- from under them here would not fail loudly -- SELECT * still compiles
-- with fewer columns available under a different shape -- it would just
-- make every downstream read of those columns return NULL / error at
-- runtime instead. Roll back 344 then 343 first.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (342 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    PRINT '342 rollback: view is already gone -- nothing to restore onto.';
    SET NOEXEC ON;
END
GO

DECLARE @in_use INT = 0;

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('grac_practice.event_obligation_applicability')
             AND name = 'local_practice_obligation_id')
BEGIN
    DECLARE @sql NVARCHAR(600) = N'SELECT @c = COUNT(*) FROM grac_practice.event_obligation_applicability
                                    WHERE local_practice_obligation_id IS NOT NULL
                                       OR local_instance_obligation_id IS NOT NULL;';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @in_use OUTPUT;
END

IF @in_use > 0
BEGIN
    PRINT '342 rollback: ' + CAST(@in_use AS NVARCHAR(20))
        + ' applicability decision(s) name a custom obligation. Restoring the';
    PRINT '               catalog-only view will make the Checklists tab and';
    PRINT '               Configure-Checklists screen stop showing them --';
    PRINT '               the decisions themselves are NOT deleted, only made';
    PRINT '               unreachable through this view. Proceeding anyway,';
    PRINT '               because the view -- unlike a column -- has no data';
    PRINT '               of its own to lose.';
END

CREATE OR ALTER VIEW grac_practice.vw_pm_event_driven_obligation
AS
    SELECT DISTINCT
        req.organization_id,
        req.organization_requirement_id,
        req.requirement_code,
        req.requirement_name,
        req.applicability_status                                   AS RequirementApplicability,
        p.practice_id,
        p.practice_code,
        p.practice_name,
        p.applicability_status                                     AS PracticeApplicability,
        orm.release_id,
        o.obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))                     AS obligation_label,
        o.obligation_text,
        spec.trigger_mode,
        spec.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(CASE WHEN EXISTS (
                 SELECT 1 FROM grac_practice.repository_subscription s
                  WHERE s.organization_id     = req.organization_id
                    AND s.release_id          = orm.release_id
                    AND s.subscription_status = N'Active'
                    AND s.status              = N'Active')
             THEN 1 ELSE 0 END AS BIT)                             AS is_subscribed
    FROM       grac_practice.organization_requirement req
    LEFT JOIN  grac_practice.practice p
           ON  p.organization_requirement_id = req.organization_requirement_id
          AND  p.organization_id             = req.organization_id
          AND  p.status                      = N'Active'
    LEFT JOIN  GRAC_New.requirement repo_req
           ON  repo_req.requirement_code = req.requirement_code
          AND  repo_req.status           = N'Active'
    JOIN       GRAC_New.obligation_requirement_release_map orm
           ON  orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
          AND  orm.status         = N'Active'
    JOIN       GRAC_New.requirement_obligation o
           ON  o.obligation_id = orm.obligation_id
    JOIN       GRAC_New.obligation_assurance_spec spec
           ON  spec.obligation_id = o.obligation_id
          AND  spec.status        = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = spec.event_type_id
          AND  et.status        = N'Active'
    -- trigger_mode is stored as the CODE by ControlManagement 033.
    WHERE      spec.trigger_mode = N'EventDriven'
      AND      req.status        = N'Active';
GO

PRINT '=== 342 rollback verification ===';

SELECT 'local_practice_obligation_id column gone from the view' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.columns
                              WHERE object_id = OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V')
                                AND name = 'local_practice_obligation_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'local_instance_obligation_id column gone from the view',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.columns
                              WHERE object_id = OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V')
                                AND name = 'local_instance_obligation_id')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '342 rollback complete. vw_pm_event_driven_obligation is 127''s';
PRINT 'catalog-only definition again.';
GO

SET NOEXEC OFF;
GO
