-- =====================================================================
-- 5. sp_org_assurance_execution_scope_review_get -- Step 3 in My Audits.
--    One shape, three result sets:
--      1 header     ReviewId (NULL = not reviewed yet), VersionNo,
--                   ReviewStatus, ApprovedBy, ApprovedDt, IsFrozen
--      2 categories CategoryCode, CategoryName, DisplayOrder, ItemCount,
--                   IsIncluded
--      3 items      CategoryCode, RecordId, RecordCode, RecordName, Status,
--                   Reason, IsKept, ExclusionReason, IsManual, ManualNote
--    Frozen with a snapshot: the snapshot (latest version). Frozen before
--    563: the header only. Live: the discovery over the scope now, every
--    record kept, the definition's category ticks.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_execution_scope_review_get
    @organization_id BIGINT,
    @execution_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL OR @execution_id IS NULL
        THROW 54009, 'organization_id and execution_id are required.', 1;

    DECLARE @def BIGINT, @ver BIGINT, @frozen DATETIME2;
    SELECT @def    = e.org_assurance_definition_id,
           @ver    = e.org_assurance_definition_version_id,
           @frozen = e.scope_frozen_at
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id
       AND e.organization_id = @organization_id
       AND e.is_active = 1;
    IF @def IS NULL
        THROW 54010, 'Execution not found or not accessible in this organization.', 1;

    DECLARE @review_id BIGINT = (SELECT TOP 1 r.org_assurance_execution_scope_review_id
                                   FROM grac_practice.org_assurance_execution_scope_review r
                                  WHERE r.org_assurance_execution_id = @execution_id
                                    AND r.organization_id = @organization_id
                                  ORDER BY r.version_no DESC);

    IF @review_id IS NOT NULL
    BEGIN
        SELECT r.org_assurance_execution_scope_review_id AS ReviewId,
               r.version_no    AS VersionNo,
               r.review_status AS ReviewStatus,
               r.approved_by   AS ApprovedBy,
               r.approved_dt   AS ApprovedDt,
               CAST(1 AS BIT)  AS IsFrozen
          FROM grac_practice.org_assurance_execution_scope_review r
         WHERE r.org_assurance_execution_scope_review_id = @review_id;

        SELECT c.category_code AS CategoryCode, c.category_name AS CategoryName,
               c.display_order AS DisplayOrder, c.item_count AS ItemCount,
               c.is_included   AS IsIncluded
          FROM grac_practice.org_assurance_execution_scope_review_category c
         WHERE c.org_assurance_execution_scope_review_id = @review_id
         ORDER BY c.display_order;

        SELECT i.category_code AS CategoryCode, i.record_id AS RecordId,
               i.record_code   AS RecordCode,   i.record_name AS RecordName,
               i.record_status AS Status,       i.related_reason AS Reason,
               i.is_kept       AS IsKept,       i.exclusion_reason AS ExclusionReason,
               i.is_manual     AS IsManual,     i.manual_note AS ManualNote
          FROM grac_practice.org_assurance_execution_scope_review_item i
         WHERE i.org_assurance_execution_scope_review_id = @review_id
         ORDER BY i.category_code, i.is_manual, i.record_code, i.record_name;
        RETURN;
    END

    CREATE TABLE #scope_review_cat (category_code NVARCHAR(40) NULL, category_name NVARCHAR(80) NULL,
                                    display_order INT NULL, item_count BIGINT NULL, is_included BIT NULL);
    CREATE TABLE #scope_review_out (category_code NVARCHAR(40) NULL, record_id BIGINT NULL,
                                    record_code NVARCHAR(120) NULL, record_name NVARCHAR(400) NULL,
                                    status NVARCHAR(60) NULL, reason NVARCHAR(MAX) NULL);
    IF @frozen IS NULL
    BEGIN
        EXEC grac_practice.sp_org_assurance_scope_discover
             @organization_id = @organization_id,
             @definition_id   = @def,
             @version_id      = @ver,
             @execution_id    = @execution_id;
        INSERT #scope_review_cat (category_code, category_name, display_order, item_count, is_included)
        VALUES (N'MANUAL', N'Manual Items', 99, 0, 1);
    END

    SELECT CAST(NULL AS BIGINT)        AS ReviewId,
           CAST(NULL AS INT)           AS VersionNo,
           CAST(NULL AS NVARCHAR(30))  AS ReviewStatus,
           CAST(NULL AS NVARCHAR(100)) AS ApprovedBy,
           CAST(NULL AS DATETIME2)     AS ApprovedDt,
           CAST(CASE WHEN @frozen IS NULL THEN 0 ELSE 1 END AS BIT) AS IsFrozen;

    SELECT c.category_code AS CategoryCode, c.category_name AS CategoryName,
           c.display_order AS DisplayOrder, ISNULL(c.item_count, 0) AS ItemCount,
           CAST(CASE WHEN c.category_code = N'PRACTICE_INSTANCE' THEN 1
                     ELSE ISNULL(c.is_included, 1) END AS BIT) AS IsIncluded
      FROM #scope_review_cat c
     ORDER BY c.display_order;

    SELECT o.category_code AS CategoryCode, o.record_id AS RecordId,
           o.record_code   AS RecordCode,   o.record_name AS RecordName,
           o.status        AS Status,       o.reason AS Reason,
           CAST(1 AS BIT)  AS IsKept,       CAST(NULL AS NVARCHAR(1000)) AS ExclusionReason,
           CAST(0 AS BIT)  AS IsManual,     CAST(NULL AS NVARCHAR(1000)) AS ManualNote
      FROM #scope_review_out o
     ORDER BY o.category_code, o.record_code, o.record_name;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '563 schema' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_execution_scope_review','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_execution_scope_review_category','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.org_assurance_execution_scope_review_item','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '563 procedures',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_live_scope')) LIKE '%#scope_review_pi%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_scope_discover')) LIKE '%@execution_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_execution_freeze_scope')) LIKE '%@review_json%'
             AND OBJECT_ID('grac_practice.sp_org_assurance_execution_scope_review_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '563 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
