-- =====================================================================
-- 503_governance_dashboard_insights_rollback.sql
--
-- Restores sp_dashboard_governance to the 456 body (copied verbatim from
-- 456_implementation_status_not_updated_default.sql, section 6). Nothing
-- else was changed by 503. Revert the Web files with it
-- (management-dashboard.js, management-dashboard.cshtml,
-- ManagementDashboards.cs, practice-management.css) -- the 503 page
-- reads the extra rows defensively, so it also runs on the 456 body.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_dashboard_governance
    @organization_id    BIGINT,
    @caller_employee_id BIGINT = NULL,
    @is_admin           BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57312, 'sp_dashboard_governance: organization_id is required.', 1;
    SET @is_admin = ISNULL(@is_admin, 0);

    -- A non-admin with no employee record owns nothing (398's rule for
    -- an unmatched caller): every count is zero rather than an error.
    SELECT pi.practice_instance_id,
           pi.primary_owner_id,
           COALESCE(ims.status_name, pi.implementation_status) AS implementation_status
      INTO #ins
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
      LEFT JOIN grac_practice.implementation_status_master ims
             ON ims.implementation_status_id = pi.implementation_status_id
     WHERE pi.organization_id = @organization_id
       AND pi.status = N'Active'
       AND (@is_admin = 1 OR (@caller_employee_id IS NOT NULL AND pi.primary_owner_id = @caller_employee_id));

    -- ---- 0. KPIs --------------------------------------------------------
    SELECT k.SectionKey, k.SectionTitle, k.KpiKey, k.Label, k.Value, k.IsAlert, k.SortOrder
      FROM (
        SELECT N'instances' AS SectionKey,
               CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END AS SectionTitle,
               N'total' AS KpiKey, N'Total' AS Label, COUNT(*) AS Value, CAST(0 AS BIT) AS IsAlert, 1 AS SortOrder
          FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'implemented', N'Implemented',
                         SUM(CASE WHEN implementation_status = N'Implemented' THEN 1 ELSE 0 END), 0, 2 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'partial', N'Partially implemented',
                         SUM(CASE WHEN implementation_status = N'Partially Implemented' THEN 1 ELSE 0 END), 0, 3 FROM #ins
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'notimplemented', N'Not implemented',
                         SUM(CASE WHEN implementation_status = N'Not Implemented' THEN 1 ELSE 0 END), 1, 4 FROM #ins
        -- 456: the default status. Without this tile those instances
        -- would drop out of every KPI except Total.
        UNION ALL SELECT N'instances', CASE WHEN @is_admin = 1 THEN N'Practice instances' ELSE N'Your practice instances' END,
                         N'notupdated', N'Not updated',
                         SUM(CASE WHEN implementation_status = N'Not Updated' THEN 1 ELSE 0 END), 0, 5 FROM #ins
        -- Only an admin sees unowned instances in Operationalize, so only
        -- an admin gets this tile.
        UNION ALL SELECT N'instances', N'Practice instances', N'noowner', N'No owner',
                         SUM(CASE WHEN primary_owner_id IS NULL THEN 1 ELSE 0 END), 1, 6
                    FROM #ins WHERE @is_admin = 1
                  HAVING @is_admin = 1
      ) k
     ORDER BY k.SortOrder;

    -- ---- 1. Ageing: none. Practice instances carry no due, review or
    --      target date, so no ageing is invented. Empty set, same shape.
    SELECT CAST(NULL AS NVARCHAR(40)) AS GroupKey, CAST(NULL AS NVARCHAR(200)) AS GroupTitle,
           CAST(NULL AS NVARCHAR(20)) AS BandCode, CAST(NULL AS NVARCHAR(60)) AS BandName,
           CAST(NULL AS INT) AS SortOrder, CAST(NULL AS INT) AS MinDays, CAST(NULL AS INT) AS MaxDays,
           CAST(NULL AS INT) AS ItemCount
     WHERE 1 = 0;

    -- ---- 2. Distributions: instances by implementation status ----------
    -- ItemKey is the value Operationalize's Status filter takes.
    SELECT N'instances_status' AS GroupKey, N'Practice instances by implementation status' AS GroupTitle,
           implementation_status AS ItemKey, ISNULL(implementation_status, N'(not set)') AS ItemLabel,
           COUNT(*) AS ItemCount, CAST(NULL AS NVARCHAR(20)) AS ColourHex,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, implementation_status) AS SortOrder
      FROM #ins
     GROUP BY implementation_status
     ORDER BY SortOrder;

    -- ---- 3. Lists: none (the page lists releases from subscribed-
    --      frameworks and attention items from dashboard-summary).
    SELECT CAST(NULL AS NVARCHAR(40)) AS ListKey, CAST(NULL AS NVARCHAR(200)) AS ListTitle,
           CAST(NULL AS BIGINT) AS RecordId, CAST(NULL AS NVARCHAR(100)) AS RefText,
           CAST(NULL AS NVARCHAR(400)) AS Title, CAST(NULL AS NVARCHAR(300)) AS OwnerName,
           CAST(NULL AS NVARCHAR(100)) AS StatusText, CAST(NULL AS DATE) AS DateValue,
           CAST(NULL AS INT) AS SortOrder
     WHERE 1 = 0;
END
GO

PRINT '503 rollback: sp_dashboard_governance restored to the 456 body.';
GO
