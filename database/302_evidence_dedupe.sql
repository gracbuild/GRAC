-- =====================================================================
-- 302_evidence_dedupe.sql
--
-- PURPOSE
--   One row per piece of evidence in
--   grac_practice.vw_pm_obligation_typed_detail.EvidenceJson.
--
-- ---------------------------------------------------------------------
-- THE DEFECT
-- ---------------------------------------------------------------------
-- EvidenceJson is a UNION ALL of two paths to the SAME table:
--
--   Direct : requirement_obligation_evidence rows carrying obligation_id
--            (the legacy 1:M path, still populated)
--   Link   : the same rows reached through one of the six per-type
--            evidence link tables
--
-- An evidence row that is both stamped with obligation_id AND linked
-- from its type table satisfies both arms, so it comes back twice --
-- same obligation_evidence_id, same evidence type, same remarks. On
-- screen that reads as the evidence type printed twice:
--
--     Evidence:  Policy  Policy
--     Evidence:  Procedure Document  Approval Record
--                Procedure Document  Approval Record
--
-- Neither row is wrong. Both describe one piece of evidence, and every
-- consumer of EvidenceJson was listing it once per path rather than
-- once per evidence.
--
-- ---------------------------------------------------------------------
-- THE FIX
-- ---------------------------------------------------------------------
-- ROW_NUMBER() OVER (PARTITION BY ObligationEvidenceId ...) around the
-- existing UNION, keeping the first row per evidence. The Link row wins
-- the tie, because it is the one carrying LinkTypeCode -- keeping the
-- Direct row would discard that classification for no gain.
--
-- The projection is unchanged. Columns are listed by name instead of
-- SELECT * purely so the ranking column stays out of the JSON; the ten
-- keys, their order and their values are what they were before. A
-- caller cannot tell the difference except that repeats are gone.
--
-- Evidence linked from two different type tables also collapses to one
-- row. That is the same rule -- one row per evidence -- and no consumer
-- renders LinkTypeCode: resolve-workspace lists it in hiddenDetailKeys
-- alongside source and obligationevidenceid.
--
-- NOT AFFECTED: sp_resolve_obligation_list.PublishedEvidenceCount. It is
-- computed by its own OUTER APPLY as
-- COUNT(DISTINCT roe.evidence_type_id) and never read this view, so it
-- was already counting each evidence type once.
--
-- ---------------------------------------------------------------------
-- WHY THIS RE-RUNS 228'S BUILDER INSTEAD OF WRITING A VIEW
-- ---------------------------------------------------------------------
-- The view is not hand-written. Migration 228 assembles it with dynamic
-- SQL, probing OBJECT_ID for each GRAC_New detail table and each of the
-- six link tables, so a type whose table Control Management has dropped
-- resolves to the literal '[]' rather than failing to parse. Freezing a
-- static view here would throw that away and break the next time CM
-- changed its schema.
--
-- So the block below is 228's builder, character for character, with
-- the @evidence fragment de-duplicated. Re-running 228 after a CM schema
-- change reinstates the duplicates; re-run THIS file instead, or 228
-- then this one.
--
-- SAFE TO RE-RUN. Requires 228.
-- NO SCHEMA CHANGE. NO DATA CHANGE. One view, redefined.
-- Rollback: 302_evidence_dedupe_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (302): vw_pm_obligation_typed_detail missing -- run 228 first.';
    SET NOEXEC ON;
END
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

    -- (302) One row per obligation_evidence_id.
    --
    -- The UNION below reaches the same requirement_obligation_evidence row
    -- twice whenever an evidence is BOTH stamped with obligation_id (the
    -- legacy 1:M "Direct" path) AND linked through one of the per-type link
    -- tables. Both are legitimate rows, and both describe one piece of
    -- evidence -- so every consumer of EvidenceJson was listing it twice.
    --
    -- ROW_NUMBER over ObligationEvidenceId collapses them. The Link row wins,
    -- because it is the one carrying LinkTypeCode; keeping the Direct row
    -- would throw that classification away for no gain. Columns are named
    -- rather than SELECT *, so the ranking column stays out of the JSON --
    -- the projected shape is byte-for-byte what it was before.
    SET @evidence = N'COALESCE((SELECT deduped.Source, deduped.LinkTypeCode,
                       deduped.ObligationEvidenceId, deduped.EvidenceTypeId, deduped.EvidenceType,
                       deduped.FrequencyId, deduped.Frequency, deduped.RetentionRequirement,
                       deduped.Remarks, deduped.DisplayOrder
                FROM (
                SELECT combined.*,
                       ROW_NUMBER() OVER (PARTITION BY combined.ObligationEvidenceId
                                          ORDER BY CASE WHEN combined.Source = N''Link'' THEN 0 ELSE 1 END,
                                                   combined.LinkTypeCode) AS DedupeRank
                FROM (
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
            ) deduped
            WHERE deduped.DedupeRank = 1
            ORDER BY deduped.Source, ISNULL(deduped.DisplayOrder, 999), deduped.EvidenceType
            FOR JSON PATH), N''[]'')';
END
ELSE SET @missing = @missing + N'requirement_obligation_evidence, ';

SET @sql = N'CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    -- Assembled by migration 302 (evidence de-duplicated) over the 228
    -- builder, from the GRAC_New detail tables present
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
    PRINT '302: detail tables not present, their column resolves to [] -- ' + LEFT(@missing, LEN(@missing) - 1);
ELSE
    PRINT '302: every detail table present.';
GO
-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'vw_pm_obligation_typed_detail present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'evidence de-duplicated',
       CASE WHEN EXISTS (SELECT 1 FROM sys.sql_modules
                         WHERE object_id = OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail')
                           AND definition LIKE '%DedupeRank%')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '302 evidence de-duplication installed.';
GO
