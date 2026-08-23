-- =====================================================================
-- 151 Document Acknowledgement procedures -- ROLLBACK
--
-- Drops the ack procs. sp_document_upload_workflow_transition is
-- RESTORED to the 147 version (no auto-pending on Approve) so the
-- workflow stays runnable after 151 is rolled but 147 is not.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_document_ack_document_users_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_document_users_list;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_documents_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_documents_list;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_list;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_create','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_create;
GO
IF OBJECT_ID('grac_practice.sp_document_ack_pending_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_document_ack_pending_list;
GO

-- Restore the pre-151 workflow proc (matches 147's version -- no
-- ack-pending insert on Approve). Callers keep working.
CREATE OR ALTER PROCEDURE grac_practice.sp_document_upload_workflow_transition
    @document_id          BIGINT,
    @transition           NVARCHAR(20),
    @decision             NVARCHAR(20) = N'Approve',
    @remark               NVARCHAR(MAX) = NULL,
    @caller_employee_id   BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @document_id IS NULL
        THROW 52740, 'sp_document_upload_workflow_transition: document_id is required.', 1;
    IF @transition IS NULL OR @transition NOT IN (N'Review', N'Approve')
        THROW 52741, 'sp_document_upload_workflow_transition: transition must be Review or Approve.', 1;
    IF @decision IS NULL OR @decision NOT IN (N'Approve', N'Reject')
        THROW 52742, 'sp_document_upload_workflow_transition: decision must be Approve or Reject.', 1;

    DECLARE @cur_stage_id INT;
    SELECT @cur_stage_id = current_stage_id FROM grac_practice.document_upload WHERE document_id = @document_id;
    IF @cur_stage_id IS NULL
        THROW 52743, 'sp_document_upload_workflow_transition: document not found.', 1;

    DECLARE @cur_stage_code NVARCHAR(60) =
        (SELECT stage_code FROM grac_practice.document_stage_master WHERE document_stage_id = @cur_stage_id);

    DECLARE @next_stage_code NVARCHAR(60) = NULL;
    IF @transition = N'Review' AND @cur_stage_code = N'Draft'
        SET @next_stage_code = CASE WHEN @decision = N'Approve' THEN N'Reviewed' ELSE N'Draft' END;
    ELSE IF @transition = N'Approve' AND @cur_stage_code = N'Reviewed'
        SET @next_stage_code = CASE WHEN @decision = N'Approve' THEN N'Published' ELSE N'Draft' END;

    IF @next_stage_code IS NULL
        THROW 52744, 'sp_document_upload_workflow_transition: transition not allowed from the current stage.', 1;

    DECLARE @next_stage_id INT =
        (SELECT document_stage_id FROM grac_practice.document_stage_master WHERE stage_code = @next_stage_code);
    IF @next_stage_id IS NULL
        THROW 52745, 'sp_document_upload_workflow_transition: target stage missing from seed (run 148).', 1;

    DECLARE @change_reason NVARCHAR(60) = CONCAT(@transition, N'-', @decision);

    BEGIN TRAN;

    UPDATE grac_practice.document_upload
       SET current_stage_id = @next_stage_id,
           reviewed_by      = CASE WHEN @transition = N'Review'  THEN @caller_employee_id ELSE reviewed_by END,
           reviewed_on      = CASE WHEN @transition = N'Review'  THEN SYSUTCDATETIME()    ELSE reviewed_on END,
           review_remark    = CASE WHEN @transition = N'Review'  THEN @remark              ELSE review_remark END,
           approved_by      = CASE WHEN @transition = N'Approve' AND @decision = N'Approve' THEN @caller_employee_id ELSE approved_by END,
           approved_on      = CASE WHEN @transition = N'Approve' AND @decision = N'Approve' THEN SYSUTCDATETIME()    ELSE approved_on END,
           approved_remark  = CASE WHEN @transition = N'Approve' THEN @remark              ELSE approved_remark END,
           updated_by       = @caller_display_name,
           updated_dt       = SYSUTCDATETIME()
     WHERE document_id = @document_id;

    INSERT INTO grac_practice.document_upload_history
        (document_id, change_reason,
         from_stage_id, to_stage_id,
         actor_employee_id, remark, acted_by, acted_dt)
    VALUES
        (@document_id, @change_reason,
         @cur_stage_id, @next_stage_id,
         @caller_employee_id, @remark, @caller_display_name, SYSUTCDATETIME());

    COMMIT;

    SELECT @document_id AS DocumentId,
           @next_stage_id AS StageId,
           @next_stage_code AS StageCode;
END
GO

-- End 151 rollback ==================================================
