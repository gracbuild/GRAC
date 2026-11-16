-- =====================================================================
-- 515 ROLLBACK -- puts back the vw_repo_src_framework_statement definition
-- found on UAT before 515 (the early 478 OUTER APPLY draft), as read by
-- diagnose_change_detect_8711_b.sql on 2026-11-04.
--
-- WARNING: that definition is what raises Msg 8711 in change detection.
-- Roll back only to return to the exact previous state.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW grac_practice.[vw_repo_src_framework_statement]
AS
    -- Built by grac_practice.sp_repo_build_source_view (migration 391)
    -- from the columns grac_new.framework_statement had when it ran.
    -- Re-run 391 after a Control Management schema change.
    SELECT src.[framework_statement_id], src.[release_id], src.[structure_node_id], src.[statement_reference], src.[statement_title], src.[statement_text], src.[display_order], src.[status], src.[entered_by], src.[entered_dt], src.[updated_by], src.[updated_dt], src.[statement_type], src.[remarks],
           cls.classification_ids AS classification_ids,
           cls.classification_names AS classification_names,
           HASHBYTES('SHA2_256',
               (SELECT src.[framework_statement_id], src.[release_id], src.[structure_node_id], src.[statement_reference], src.[statement_title], src.[statement_text], src.[display_order], src.[status], src.[statement_type], src.[remarks], cls.classification_ids AS classification_ids,
           cls.classification_names AS classification_names
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS content_hash
    FROM grac_new.framework_statement src
    OUTER APPLY (
        SELECT STRING_AGG(CONVERT(NVARCHAR(20), m.statement_classification_id), N',')
                   WITHIN GROUP (ORDER BY m.statement_classification_id) AS classification_ids,
               STRING_AGG(CAST(c.classification_name AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY c.display_order, c.classification_name) AS classification_names
        FROM   grac_new.framework_statement_classification_map m
        JOIN   grac_new.statement_classification c
               ON c.statement_classification_id = m.statement_classification_id
        WHERE  m.framework_statement_id = src.framework_statement_id
          AND  m.status = N'Active') cls;
GO
PRINT '515 rollback complete (previous view restored).';
GO
