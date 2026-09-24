-- =====================================================================
-- 302_evidence_dedupe_rollback.sql
--
-- Restores grac_practice.vw_pm_obligation_typed_detail to its 228
-- definition -- the builder below is 228's, unmodified.
--
-- ---------------------------------------------------------------------
-- THIS REINSTATES A KNOWN DEFECT. READ BEFORE RUNNING.
-- ---------------------------------------------------------------------
-- EvidenceJson goes back to listing an evidence row once per path to it.
-- Any evidence that is both stamped with obligation_id and linked from
-- its type table appears twice again, on the Practice View obligation
-- cards, in the Resolve Workspace obligation detail, and in the View
-- Obligations dialog.
--
-- Nothing errors, in either direction. The Practice View renderer keys
-- its evidence blocks on the row's own identity, so a repeated row
-- renders as a repeated block rather than failing.
--
-- NO SCHEMA CHANGE. NO DATA CHANGE. 302 redefined one view and wrote no
-- row.
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @sql NVARCHAR(MAX);
DECLARE @missing NVARCHAR(MAX) = N'';

-- One helper expression per type. Built as text so a table that is not
-- there never reaches the parser.
DECLARE @state NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_state_rule','U') IS NOT NULL
    SET @state = N'COALESCE((SELECT s.* FROM GRAC_New.obligation_state_rule s
             WHERE s.obligation_id = o.obligation_id AND s.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_state_rule, ';

DECLARE @exec NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_execution_spec','U') IS NOT NULL
    SET @exec = N'COALESCE((SELECT es.*, ef.option_label AS ExecutionFrequency
             FROM GRAC_New.obligation_execution_spec es
             LEFT JOIN GRAC_New.reference_option ef ON ef.reference_option_id = es.execution_frequency_id
             WHERE es.obligation_id = o.obligation_id AND es.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_execution_spec, ';

DECLARE @assur NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_assurance_spec','U') IS NOT NULL
    SET @assur = N'COALESCE((SELECT [as].*, af.option_label AS AssuranceFrequency
             FROM GRAC_New.obligation_assurance_spec [as]
             LEFT JOIN GRAC_New.reference_option af ON af.reference_option_id = [as].assurance_frequency_id
             WHERE [as].obligation_id = o.obligation_id AND [as].status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_assurance_spec, ';

DECLARE @event NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_event_response','U') IS NOT NULL
    SET @event = N'COALESCE((SELECT er.* FROM GRAC_New.obligation_event_response er
             WHERE er.obligation_id = o.obligation_id AND er.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_event_response, ';

DECLARE @constr NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_constraint_rule','U') IS NOT NULL
    SET @constr = N'COALESCE((SELECT cr.* FROM GRAC_New.obligation_constraint_rule cr
             WHERE cr.obligation_id = o.obligation_id AND cr.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_constraint_rule, ';

-- Retention: removed from the taxonomy by Control Management. Kept as a
-- column so historical rows still render and so the list procedure's
-- SELECT keeps compiling; it simply resolves to '[]' once the table is
-- gone.
DECLARE @reten NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NOT NULL
    SET @reten = N'COALESCE((SELECT rs.* FROM GRAC_New.obligation_retention_spec rs
             WHERE rs.obligation_id = o.obligation_id AND rs.status = N''Active''
             FOR JSON PATH), N''[]'')';
ELSE SET @missing = @missing + N'obligation_retention_spec, ';

-- Evidence: same story, and its shape is a UNION over however many of
-- the six link tables survive. Built one branch at a time for the same
-- reason as above.
DECLARE @evidence NVARCHAR(MAX) = N'N''[]''';
IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
BEGIN
    DECLARE @links NVARCHAR(MAX) = N'';
    DECLARE @lt SYSNAME, @lc NVARCHAR(60);
    DECLARE link_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.table_name, t.type_code FROM (VALUES
            (N'obligation_state_evidence_link',          N'State'),
            (N'obligation_execution_evidence_link',      N'Execution'),
            (N'obligation_assurance_evidence_link',      N'Assurance'),
            (N'obligation_event_response_evidence_link', N'EventResponse'),
            (N'obligation_constraint_evidence_link',     N'Constraint'),
            (N'obligation_retention_evidence_link',      N'Retention')
        ) AS t(table_name, type_code);
    OPEN link_cursor;
    FETCH NEXT FROM link_cursor INTO @lt, @lc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF OBJECT_ID('GRAC_New.' + @lt, 'U') IS NOT NULL
            SET @links = @links
                + CASE WHEN @links = N'' THEN N'' ELSE N' UNION ALL ' END
                + N'SELECT N''' + @lc + N''' AS TypeCode, obligation_id, obligation_evidence_id, status FROM GRAC_New.' + QUOTENAME(@lt);
        FETCH NEXT FROM link_cursor INTO @lt, @lc;
    END
    CLOSE link_cursor;
    DEALLOCATE link_cursor;

    SET @evidence = N'COALESCE((SELECT * FROM (
                SELECT N''Direct'' AS Source, CAST(NULL AS NVARCHAR(60)) AS LinkTypeCode,
                       roe.obligation_evidence_id AS ObligationEvidenceId,
                       roe.evidence_type_id AS EvidenceTypeId,
                       et.evidence_type_name AS EvidenceType,
                       roe.frequency_id AS FrequencyId,
                       freq.option_label AS Frequency,
                       roe.retention_requirement AS RetentionRequirement,
                       roe.remarks AS Remarks,
                       et.display_order AS DisplayOrder
                FROM GRAC_New.requirement_obligation_evidence roe
                LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
                WHERE roe.obligation_id = o.obligation_id AND roe.status = N''Active'''
        + CASE WHEN @links = N'' THEN N'' ELSE N'
                UNION ALL
                SELECT N''Link'', l.TypeCode, roe2.obligation_evidence_id, roe2.evidence_type_id,
                       et2.evidence_type_name, roe2.frequency_id, freq2.option_label,
                       roe2.retention_requirement, roe2.remarks, et2.display_order
                FROM (' + @links + N') l
                JOIN GRAC_New.requirement_obligation_evidence roe2 ON roe2.obligation_evidence_id = l.obligation_evidence_id
                LEFT JOIN GRAC_New.evidence_type_master et2 ON et2.evidence_type_id = roe2.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq2 ON freq2.reference_option_id = roe2.frequency_id
                WHERE l.obligation_id = o.obligation_id AND l.status = N''Active''' END
        + N'
            ) combined
            ORDER BY combined.Source, ISNULL(combined.DisplayOrder, 999), combined.EvidenceType
            FOR JSON PATH), N''[]'')';
END
ELSE SET @missing = @missing + N'requirement_obligation_evidence, ';

SET @sql = N'CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    -- Assembled by migration 228 from the GRAC_New detail tables present
    -- at the time it ran. A type whose table Control Management has
    -- dropped resolves to the literal ''[]'' -- the column stays so the
    -- consumers keep compiling. Re-run 228 after a CM schema change.
    SELECT
        o.obligation_id AS ObligationId,
        ' + @state    + N' AS StateRulesJson,
        ' + @exec     + N' AS ExecutionSpecsJson,
        ' + @assur    + N' AS AssuranceSpecsJson,
        ' + @event    + N' AS EventResponsesJson,
        ' + @constr   + N' AS ConstraintRulesJson,
        ' + @reten    + N' AS RetentionSpecsJson,
        ' + @evidence + N' AS EvidenceJson
    FROM GRAC_New.requirement_obligation o;';

EXEC sp_executesql @sql;

IF @missing <> N''
    PRINT '228: detail tables not present, their column resolves to [] -- ' + LEFT(@missing, LEN(@missing) - 1);
ELSE
    PRINT '228: every detail table present.';
GO
PRINT '302 rolled back -- evidence duplicates reinstated.';
GO
