-- =====================================================================
-- 471 ROLLBACK -- re-issue sp_gap_centre_list without GapNumber
--                 (restores 414's body verbatim).
-- =====================================================================
SET NOCOUNT ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_list
    @organization_id     BIGINT        = NULL,
    @source_module_code  NVARCHAR(30)  = NULL,
    @status_code         NVARCHAR(30)  = NULL,
    @search              NVARCHAR(200) = NULL,
    @observation_id      BIGINT        = NULL,
    @page                INT           = 1,
    @page_size           INT           = 25,
    @drill_code          NVARCHAR(20)  = NULL,
    @status_text         NVARCHAR(100) = NULL,
    @severity_text       NVARCHAR(200) = NULL,
    @min_age_days        INT           = NULL,
    @max_age_days        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @search = N'' SET @search = NULL;
    IF @source_module_code = N'' SET @source_module_code = NULL;
    IF @status_code = N'' SET @status_code = NULL;
    IF @drill_code = N'' SET @drill_code = NULL;
    IF @status_text = N'' SET @status_text = NULL;
    IF @severity_text = N'' SET @severity_text = NULL;

    DECLARE @results TABLE (
        RowKey             NVARCHAR(40)  NOT NULL,
        SourceModuleCode   NVARCHAR(30)  NOT NULL,
        CustomGapId        BIGINT        NULL,
        PracticeGapId      BIGINT        NULL,
        PracticeInstanceId BIGINT        NULL,
        IsMaterialized     BIT           NOT NULL,
        Title              NVARCHAR(400) NULL,
        Context            NVARCHAR(800) NULL,
        StatusText         NVARCHAR(100) NULL,
        RawStatusCode      NVARCHAR(30)  NULL,
        LifecycleStateCode NVARCHAR(60)  NULL,
        SeverityText       NVARCHAR(200) NULL,
        OwnerText          NVARCHAR(300) NULL,
        DueDate            DATE          NULL,
        OpenedDt           DATETIME2(3)  NULL,
        LinkedCount        INT           NOT NULL,
        InstanceCode       NVARCHAR(100) NULL,
        InstanceName       NVARCHAR(300) NULL,
        ExistingTaskCount  INT           NOT NULL,
        UrgencyRank        INT           NOT NULL DEFAULT 3,
        SortBucket         INT           NOT NULL,
        PracticeInstanceStatusText NVARCHAR(30)  NULL,
        TaskStatusText             NVARCHAR(30)  NULL,
        RiskStatusText             NVARCHAR(100) NULL,
        ExceptionStatusText        NVARCHAR(30)  NULL
    );

    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, UrgencyRank, SortBucket,
         PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText)
    SELECT f.RowKey, f.SourceModuleCode, f.CustomGapId, f.PracticeGapId, f.PracticeInstanceId,
           f.IsMaterialized, f.Title, f.Context, f.StatusText, f.RawStatusCode, f.LifecycleStateCode,
           f.SeverityText, f.OwnerText,
           f.DueDate, f.OpenedDt, f.LinkedCount,
           f.InstanceCode, f.InstanceName, f.ExistingTaskCount, f.UrgencyRank, f.SortBucket,
           f.PracticeInstanceStatusText, f.TaskStatusText, f.RiskStatusText, f.ExceptionStatusText
      FROM grac_practice.fn_pm_gap_centre_rows(@organization_id, @source_module_code,
                                               @status_code, @search, @observation_id) f
     WHERE (@drill_code IS NULL
            OR (@drill_code = N'open'      AND f.IsOpen      = 1)
            OR (@drill_code = N'pending'   AND f.IsPending   = 1)
            OR (@drill_code = N'overdue'   AND f.IsOverdue   = 1)
            OR (@drill_code = N'completed' AND f.IsCompleted = 1)
            OR (@drill_code = N'noowner'   AND f.IsOpen = 1 AND f.OwnerEmployeeId IS NULL))
       AND (@status_text   IS NULL OR f.StatusText   = @status_text)
       AND (@severity_text IS NULL OR f.SeverityText = @severity_text)
       AND (@min_age_days  IS NULL OR f.AgeDays >= @min_age_days)
       AND (@max_age_days  IS NULL OR f.AgeDays <= @max_age_days);

    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

    SELECT RowKey, SourceModuleCode, CustomGapId, PracticeGapId,
           PracticeInstanceId, IsMaterialized, Title, Context,
           StatusText, RawStatusCode, LifecycleStateCode,
           SeverityText, OwnerText, DueDate, OpenedDt,
           LinkedCount, InstanceCode, InstanceName, ExistingTaskCount,
           PracticeInstanceStatusText, TaskStatusText, RiskStatusText, ExceptionStatusText
    FROM   @results
    ORDER  BY SortBucket, UrgencyRank, OpenedDt DESC, RowKey
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '471 rolled back: sp_gap_centre_list restored without GapNumber.';
GO
