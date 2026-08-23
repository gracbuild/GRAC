-- Restore 173-body of sp_custom_gap_header (no DuplicateOf* / InvalidReason).
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
        s.is_terminal         AS LifecycleIsTerminal,
        s.is_valid_terminal   AS LifecycleIsValidTerminal,
        g.gap_source_module_code AS SourceModuleCode
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '177 rollback complete.';
GO
