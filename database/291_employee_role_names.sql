-- =====================================================================
-- 291_employee_role_names.sql
--
-- PURPOSE
--   1. grac_practice.fn_employee_role_names -- one place that answers
--      "which roles does this employee hold?" as display text.
--   2. sp_risk_acceptance_get returns the accepting employee's roles
--      alongside the name, so Risk Acceptance can read
--      "Vinod - Risk Owner".
--
-- ---------------------------------------------------------------------
-- WHY A FUNCTION AND NOT A JOIN IN EACH QUERY
-- ---------------------------------------------------------------------
-- Two very different callers need the same answer:
--
--   * sp_risk_acceptance_get, below.
--   * The dependency-object picker, whose SQL is BUILT IN C#
--     (PracticeRepositoryService.QueryDependencyOptionsFallbackAsync).
--     That query is config-driven -- it selects an id column and a
--     display column from whichever of nine source tables a dependency
--     category names -- and it applies NO table alias. A correlated
--     subquery there would reference organization_employee_role, which
--     has an employee_id column of its own, so the outer reference
--     would silently bind to the inner table. A scalar function takes
--     the value as an argument and cannot be captured that way.
--
-- organization_employee_role is a plain many-to-many with NO primary or
-- priority flag, so nothing in the data says which single role to show.
-- Showing all of them, comma separated, is therefore the only answer
-- that never hides a role the person actually holds. STRING_AGG is
-- already the codebase's way of doing this (12 migrations use it).
--
-- Returns NULL, not an empty string, when the employee holds no active
-- role -- callers test for "no role" and must not have to distinguish
-- NULL from N''.
--
-- PERFORMANCE
--   Scalar, so it evaluates per row. Both callers are bounded: the
--   picker fetches at most 500 options, and the acceptance read returns
--   one row. It is deliberately NOT used in the register list, which is
--   paged and would evaluate it 25 times per page for no benefit --
--   that list shows the name only.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DOES NOT CHANGE
-- ---------------------------------------------------------------------
-- Nothing is stored differently. risk_register.accepted_by_name still
-- holds the name exactly as it always did, and AcceptedByName is
-- returned unchanged; the roles arrive as a SEPARATE column so the UI
-- composes the label and no stored value acquires a role suffix.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/291_employee_role_names_rollback.sql
-- DEPENDS ON: 027 (organization_employee_role, organization_role),
--             264 (sp_risk_acceptance_get, which this re-issues).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.organization_employee_role','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN
    PRINT 'ABORT (291): organization_employee_role / organization_role missing. Run 027 first.';
    RAISERROR('291_employee_role_names: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_risk_acceptance_get','P') IS NULL
BEGIN
    PRINT 'ABORT (291): sp_risk_acceptance_get missing. Run 264 first.';
    RAISERROR('291_employee_role_names: sp_risk_acceptance_get not found.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_employee_role_names
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_employee_role_names
(
    @employee_id BIGINT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @employee_id IS NULL RETURN NULL;

    DECLARE @names NVARCHAR(400);

    SELECT @names = STRING_AGG(CAST(ro.role_name AS NVARCHAR(400)), N', ')
                        WITHIN GROUP (ORDER BY ro.role_name)
      FROM grac_practice.organization_employee_role er
      JOIN grac_practice.organization_role ro
            ON ro.role_id = er.role_id
     WHERE er.employee_id = @employee_id
       AND er.status = N'Active'
       AND ro.status = N'Active';

    -- NULLIF so an employee with no active role reads as "no role" and
    -- not as an empty label the caller then has to trim.
    RETURN NULLIF(LTRIM(RTRIM(ISNULL(@names, N''))), N'');
END;
GO

-- =====================================================================
-- 2. sp_risk_acceptance_get -- re-issued from 264
--
-- IDENTICAL to 264 except for the single AcceptedByRoleNames column
-- marked below. Every other column, join, guard and CASE is reproduced
-- verbatim: this is a CREATE OR ALTER of the whole procedure, so
-- anything dropped here would disappear from the live definition.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_acceptance_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56609, 'sp_risk_acceptance_get: risk_register_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_register
                    WHERE risk_register_id = @risk_register_id)
        THROW 56610, 'sp_risk_acceptance_get: risk not found.', 1;

    SELECT r.risk_register_id        AS RiskRegisterId,
           r.risk_number             AS RiskNumber,
           r.risk_title              AS RiskTitle,
           r.status_code             AS StatusCode,
           r.risk_owner_employee_id  AS RiskOwnerEmployeeId,
           ow.employee_name          AS RiskOwnerName,
           r.treatment_option_code   AS TreatmentOptionCode,
           r.treatment_option_name   AS TreatmentOptionName,
           r.inherent_rating_code    AS InherentRatingCode,
           r.residual_rating_code    AS ResidualRatingCode,
           r.residual_pending        AS ResidualPending,
           r.analysis_pending        AS AnalysisPending,

           r.accepted_by_employee_id AS AcceptedByEmployeeId,
           COALESCE(ab.employee_name, r.accepted_by_name) AS AcceptedByName,
           -- THE ONLY ADDITION IN 291. Separate from AcceptedByName on
           -- purpose: the name stays exactly what it was, and the UI
           -- composes "Name - Role" for display only. NULL when the
           -- acceptor holds no active role, or when acceptance recorded
           -- only a free-text name with no employee row behind it.
           grac_practice.fn_employee_role_names(r.accepted_by_employee_id)
                                     AS AcceptedByRoleNames,
           r.accepted_dt             AS AcceptedOn,
           r.acceptance_note         AS AcceptanceNote,
           r.next_review_date        AS NextReviewDate,
           r.last_reviewed_dt        AS LastReviewedOn,
           r.review_count            AS ReviewCount,
           st.workflow_stage_code    AS WorkflowStageCode,
           st.open_treatment_task_count AS OpenTreatmentTaskCount,

           CAST(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0
                     WHEN ISNULL(r.analysis_pending, 1) = 1        THEN 0
                     WHEN r.treatment_option_code IS NULL          THEN 0
                     ELSE 1 END AS BIT)              AS CanAccept,

           CASE WHEN r.status_code IN (N'Closed', N'Retired')
                     THEN N'This risk is closed or retired.'
                WHEN ISNULL(r.analysis_pending, 1) = 1
                     THEN N'Complete the risk analysis first.'
                WHEN r.treatment_option_code IS NULL
                     THEN N'Choose a treatment option first.'
                WHEN r.treatment_option_code = N'Tolerate'
                     THEN N'Tolerate / Accept -- this risk goes straight to acceptance.'
                WHEN ISNULL(r.residual_pending, 1) = 1
                     THEN N'Residual risk has not been assessed. You may still accept, but assessing it first is the intended order.'
                ELSE N'Ready to accept.'
           END                                        AS AcceptGuidance
      FROM grac_practice.risk_register r
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
      LEFT JOIN grac_practice.organization_employee ab ON ab.employee_id = r.accepted_by_employee_id
      LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.risk_register_id = @risk_register_id;
END;
GO

PRINT '291: fn_employee_role_names created; sp_risk_acceptance_get returns AcceptedByRoleNames.';
GO

SET NOEXEC OFF;
GO
