-- =====================================================================
-- 177 Extend sp_custom_gap_header with duplicate_of_gap_id +
--     invalid_reason so the UI can surface the parent gap linkage on
--     Duplicate-state gaps (and the Invalid rationale on Invalid ones).
--
-- WHY
-- ---
-- Sir's ask: on a Duplicate gap, show the parent gap id + the parent's
-- analysis details. The header proc already knows the current gap has
-- a duplicate_of_gap_id column (schema 156), it just wasn't returning
-- it. Once exposed, the UI can:
--   * render a "Duplicate of Gap #N -- <title>" strip
--   * call /gaps/{parentId}/analysis and render the parent's analysis
--     in read-only mode
--
-- ADDITIVE. Rollback: 177_gap_header_duplicate_details_rollback.sql
--   (restores 173's header proc).
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
        g.custom_gap_id            AS CustomGapId,
        g.organization_id          AS OrganizationId,
        g.title                    AS Title,
        g.description              AS Description,
        g.status                   AS StatusCode,
        g.priority                 AS Priority,
        g.severity_code            AS SeverityCode,
        g.severity_name            AS SeverityName,
        g.owner_display_name       AS OwnerName,
        g.owner_employee_id        AS OwnerEmployeeId,
        g.due_date                 AS DueDate,
        s.state_code               AS LifecycleStateCode,
        s.state_name               AS LifecycleStateName,
        s.is_terminal              AS LifecycleIsTerminal,
        s.is_valid_terminal        AS LifecycleIsValidTerminal,
        g.gap_source_module_code   AS SourceModuleCode,
        -- NEW in 177: expose parent + invalid rationale.
        g.duplicate_of_gap_id      AS DuplicateOfGapId,
        p.title                    AS DuplicateOfGapTitle,
        g.invalid_reason           AS InvalidReason
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO

PRINT '177 gap header duplicate details ready.';
GO
