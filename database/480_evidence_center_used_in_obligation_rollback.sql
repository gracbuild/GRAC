-- =====================================================================
-- 480 ROLLBACK -- restore the 477 sp_evidence_center_get body
-- Drops ObligationId / ObligationName from the "Used in" result set by
-- re-issuing the procedure exactly as migration 477 left it. The UI
-- revert (Obligation column back to Practice) ships with the Web tier.
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_get
    @organization_id    BIGINT,
    @evidence_item_id   BIGINT,
    @caller_employee_id BIGINT = NULL,
    @caller_is_admin    BIT    = 0,
    @expiring_days      INT    = 30
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @evidence_item_id IS NULL
        THROW 52781, 'Organization and evidence item are both required.', 1;
    SET @expiring_days = CASE WHEN ISNULL(@expiring_days, 0) < 1 THEN 30 ELSE @expiring_days END;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @visible BIT = 0, @can_edit BIT = 0;

    SELECT @visible  = CASE WHEN v.is_visible = 1 THEN 1 ELSE 0 END,
           @can_edit = CASE WHEN ed.is_editable = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
               i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) ed
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    DECLARE @total INT = 0, @seen INT = 0;
    IF @visible = 1
    BEGIN
        SELECT @total = COUNT(*) FROM grac_practice.evidence_link l
         WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active';
        -- 477: a link counts as seen through its instance, or, for a task
        -- link, through the task (both under View Data Scope).
        SELECT @seen = COUNT(*) FROM grac_practice.evidence_link l
         WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active'
           AND (EXISTS (SELECT 1 FROM grac_practice.practice_instance pi
                         WHERE pi.practice_instance_id = l.practice_instance_id)
                OR (l.target_type = N'Task'
                    AND EXISTS (SELECT 1 FROM grac_practice.practice_task t WHERE t.task_id = l.target_id)));
    END

    -- 1. item
    SELECT i.evidence_item_id       AS EvidenceItemId,
           i.evidence_title         AS EvidenceTitle,
           i.evidence_type_id       AS EvidenceTypeId,
           et.evidence_type_name    AS EvidenceType,
           i.evidence_description   AS EvidenceDescription,
           i.owner_employee_id      AS OwnerEmployeeId,
           ow.employee_name         AS OwnerName,
           i.valid_from             AS ValidFrom,
           i.valid_to               AS ValidTo,
           CASE WHEN i.valid_to IS NULL THEN N'NoExpiry'
                WHEN i.valid_to < @today THEN N'Expired'
                WHEN i.valid_to <= DATEADD(DAY, @expiring_days, @today) THEN N'Expiring'
                ELSE N'Valid' END   AS ValidityState,
           i.classification         AS Classification,
           i.tags                   AS Tags,
           i.status                 AS Status,
           i.created_by_employee_id AS CreatedByEmployeeId,
           COALESCE(cr.employee_name, i.entered_by) AS CreatedByName,
           i.entered_dt             AS EnteredDt,
           i.updated_by             AS UpdatedBy,
           i.updated_dt             AS UpdatedDt,
           f.evidence_file_id       AS CurrentFileId,
           f.version_no             AS CurrentVersionNo,
           f.file_name              AS FileName,
           f.file_size_bytes        AS FileSizeBytes,
           @total                   AS UsedInCount,
           @total - @seen           AS HiddenUsageCount,
           @can_edit                AS CanEdit
    FROM   grac_practice.evidence_item i
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = i.evidence_type_id
    LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = i.owner_employee_id
    LEFT   JOIN grac_practice.organization_employee cr ON cr.employee_id = i.created_by_employee_id
    LEFT   JOIN grac_practice.evidence_item_file f
           ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  @visible = 1;

    -- 2. versions
    SELECT f.evidence_file_id        AS EvidenceFileId,
           f.version_no              AS VersionNo,
           f.is_current              AS IsCurrent,
           f.file_name               AS FileName,
           f.content_type            AS ContentType,
           f.file_size_bytes         AS FileSizeBytes,
           f.version_note            AS VersionNote,
           f.uploaded_by_employee_id AS UploadedByEmployeeId,
           COALESCE(up.employee_name, f.uploaded_by) AS UploadedByName,
           f.uploaded_dt             AS UploadedDt,
           (SELECT COUNT(*) FROM grac_practice.evidence_link l
             WHERE l.evidence_file_id = f.evidence_file_id AND l.status = N'Active') AS PinnedLinkCount
    FROM   grac_practice.evidence_item_file f
    LEFT   JOIN grac_practice.organization_employee up ON up.employee_id = f.uploaded_by_employee_id
    WHERE  f.evidence_item_id = @evidence_item_id
      AND  @visible = 1
    ORDER  BY f.version_no DESC;

    -- 3. used in (477: instance evidence rows and tasks the caller can see)
    SELECT l.evidence_link_id       AS EvidenceLinkId,
           l.target_type            AS TargetType,
           l.target_id              AS TargetId,
           l.practice_instance_id   AS PracticeInstanceId,
           pi.instance_code         AS InstanceCode,
           pi.instance_name         AS InstanceName,
           p.practice_id            AS PracticeId,
           p.practice_code          AS PracticeCode,
           p.practice_name          AS PracticeName,
           COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name) AS EvidenceName,
           t.task_id                AS TaskId,
           t.task_number            AS TaskNumber,
           t.subject_title          AS TaskTitle,
           l.period_from            AS PeriodDate,
           f.version_no             AS PinnedVersionNo,
           CAST(f.is_current AS BIT) AS IsLatest,
           l.link_note              AS LinkNote,
           COALESCE(lb.employee_name, l.linked_by) AS LinkedByName,
           l.linked_dt              AS LinkedDt
    FROM   grac_practice.evidence_link l
    LEFT   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = l.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.practice_instance_evidence e
           ON l.target_type = N'InstanceEvidence' AND e.evidence_id = l.target_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.practice_task t
           ON l.target_type = N'Task' AND t.task_id = l.target_id
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    LEFT   JOIN grac_practice.organization_employee lb ON lb.employee_id = l.linked_by_employee_id
    WHERE  l.evidence_item_id = @evidence_item_id
      AND  l.status = N'Active'
      AND  @visible = 1
      AND  (pi.practice_instance_id IS NOT NULL OR t.task_id IS NOT NULL)
    ORDER  BY p.practice_code, pi.instance_code, l.target_type, l.linked_dt DESC, l.evidence_link_id;
END
GO

PRINT '480 rollback complete: sp_evidence_center_get restored to the 477 body.';
GO
