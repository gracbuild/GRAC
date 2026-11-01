-- =====================================================================
-- 472 ROLLBACK -- re-issue sp_exception_request_list without
--                 ExceptionNumber (restores 414's body).
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_exception_request_list
    @organization_id   BIGINT,
    @status_code       NVARCHAR(30) = NULL,
    @request_type_code NVARCHAR(30) = NULL,
    @page_number       INT = 1,
    @page_size         INT = 25,
    @drill_code        NVARCHAR(20) = NULL,
    @min_age_days      INT          = NULL,
    @max_age_days      INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 55210, 'sp_exception_request_list: organization_id is required.', 1;
    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        r.exception_request_id  AS ExceptionRequestId,
        r.organization_id       AS OrganizationId,
        r.custom_gap_id         AS CustomGapId,
        g.title                 AS GapTitle,
        r.task_id               AS TaskId,
        t.task_number           AS TaskNumber,
        t.subject_title         AS TaskTitle,
        r.request_title         AS RequestTitle,
        et.exception_type_name  AS ExceptionTypeName,
        r.status_code           AS StatusCode,
        r.request_type_code     AS RequestTypeCode,
        r.sla_days_original     AS SlaDaysOriginal,
        r.sla_days_requested    AS SlaDaysRequested,
        r.due_at_original       AS DueAtOriginal,
        r.due_at_requested      AS DueAtRequested,
        r.priority_original     AS PriorityOriginal,
        r.priority_requested    AS PriorityRequested,
        r.requested_dt          AS RequestedOn,
        rq.employee_name        AS RequestedByName,
        r.approved_dt           AS ApprovedOn,
        ap.employee_name        AS ApprovedByName,
        r.effective_from        AS EffectiveFrom,
        r.effective_until       AS EffectiveUntil,
        r.rejected_dt           AS RejectedOn,
        rj.employee_name        AS RejectedByName,
        (SELECT COUNT(*) FROM grac_practice.exception_request_attachment a
          WHERE a.exception_request_id = r.exception_request_id) AS AttachmentCount,
        COUNT(*) OVER () AS TotalRows
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.custom_gap                g  ON g.custom_gap_id     = r.custom_gap_id
 LEFT JOIN grac_practice.practice_task             t  ON t.task_id           = r.task_id
 LEFT JOIN grac_practice.exception_type_master     et ON et.exception_type_id = r.exception_type_id
 LEFT JOIN grac_practice.organization_employee     rq ON rq.employee_id       = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee     ap ON ap.employee_id       = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee     rj ON rj.employee_id       = r.rejected_by_employee_id
      JOIN grac_practice.vw_pm_exception_request_state xs ON xs.exception_request_id = r.exception_request_id
     WHERE r.organization_id = @organization_id
       AND (@status_code IS NULL OR r.status_code = @status_code)
       AND (@request_type_code IS NULL OR r.request_type_code = @request_type_code)
       AND (NULLIF(@drill_code, N'') IS NULL
            OR (@drill_code = N'open'    AND xs.is_open   = 1)
            OR (@drill_code = N'lapsed'  AND xs.is_lapsed = 1)
            OR (@drill_code = N'noowner' AND xs.is_open   = 1 AND xs.owner_employee_id IS NULL))
       AND (@min_age_days IS NULL OR xs.age_days >= @min_age_days)
       AND (@max_age_days IS NULL OR xs.age_days <= @max_age_days)
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC
     OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END;
GO
PRINT '472 rolled back: sp_exception_request_list restored without ExceptionNumber.';
GO
