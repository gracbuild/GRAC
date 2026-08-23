-- =====================================================================
-- 159 Gap Centre v1 -- header proc
--
-- Cheap read that returns the bootstrap context Gap Detail needs on
-- page load: organization_id, title, code, current state, severity.
-- Placed in a separate migration (not appended to 157) so already-
-- deployed environments only need to run THIS incremental delta.
--
-- WHY THIS EXISTS
-- ---------------
-- The gap-detail page had been asking users to type organization_id
-- into the "Create task" form -- data the system already owns on
-- custom_gap.organization_id. A senior-architect approach: derive it
-- server-side, never trust the browser for it. This proc is the
-- single source of that derivation.
--
-- Depends on 156 (lifecycle_state_id column exists).
-- Rollback: 159_gap_centre_v1_header_proc_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_header
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55160, 'sp_custom_gap_header: custom_gap_id is required.', 1;

    SELECT
        g.custom_gap_id       AS CustomGapId,
        g.organization_id     AS OrganizationId,
        g.title               AS Title,
        g.description         AS Description,
        g.status              AS StatusCode,
        g.priority            AS Priority,
        g.severity_code       AS SeverityCode,
        g.severity_name       AS SeverityName,
        g.owner_display_name  AS OwnerName,
        g.owner_employee_id   AS OwnerEmployeeId,
        g.due_date            AS DueDate,
        s.state_code          AS LifecycleStateCode,
        s.state_name          AS LifecycleStateName,
        g.gap_source_module_code AS SourceModuleCode
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO

PRINT '159 Gap Centre header proc ready.';
GO
