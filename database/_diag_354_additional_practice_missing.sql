-- =====================================================================
-- _diag_354_additional_practice_missing  (read-only)
--
-- Report: after running migration 354, a practice that had already been
-- mapped as "Additional" on a risk (by hand, via Map Practice) is not
-- showing in that risk's Existing Practice Map panel anymore.
--
-- What 354 actually touches, so the candidate causes are narrow:
--   * sp_risk_register_insert  -- CREATE time only. Cannot affect a risk
--     that already exists, so it is not in scope for this report.
--   * sp_risk_mapping_sync_primary -- runs on every /mapping GET. When
--     risk_register.linked_practice_id was NULL (true for every
--     gap-sourced risk registered since 261, until 354 derived it),
--     it now derives a practice id and, if no Primary row exists yet
--     for THIS risk, either:
--       (a) promotes an EXISTING risk_practice_map row for that same
--           practice_id from 'Additional' to 'Primary' -- the row is
--           not deleted, only relabelled -- or
--       (b) INSERTs a brand-new Primary row via sp_risk_practice_map,
--           which never touches or removes any other row.
--   Neither path can delete a risk_practice_map row. The only procedure
--   that deletes one is sp_risk_practice_unmap, which always writes a
--   'PracticeUnmapped' risk_register_history row when it runs -- so if
--   the row is genuinely gone, section 4 below will show who/what did
--   it and when.
--
-- HOW TO USE
--   Set @RiskId below (or leave it and set @RiskNumber instead -- fill
--   in only one). Run as-is. Paste back everything it prints/returns.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @RiskId     BIGINT       = NULL;   -- <<< risk_register_id, if you know it
DECLARE @RiskNumber NVARCHAR(50) = NULL;   -- <<< or the risk number instead, e.g. N'RSK-000123'

IF @RiskId IS NULL AND @RiskNumber IS NOT NULL
    SELECT @RiskId = risk_register_id FROM grac_practice.risk_register WHERE risk_number = @RiskNumber;

IF @RiskId IS NULL
BEGIN
    PRINT 'Set @RiskId or @RiskNumber at the top of this script and re-run.';
    RETURN;
END

PRINT '=== 1. The risk itself -- what 354''s derivation would use =====';
SELECT r.risk_register_id AS RiskId, r.risk_number AS RiskNumber, r.risk_title AS RiskTitle,
       r.source_type_code AS SourceTypeCode, r.source_record_id AS SourceRecordId,
       r.linked_practice_id AS LinkedPracticeId,
       p.practice_name      AS LinkedPracticeName,
       r.entered_dt AS RegisteredDt, r.updated_by AS LastUpdatedBy, r.updated_dt AS LastUpdatedDt
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.practice p ON p.practice_id = r.linked_practice_id
 WHERE r.risk_register_id = @RiskId;

PRINT '';
PRINT '=== 2. Every risk_practice_map row this risk has, right now =====';
-- If the practice you mapped is still here, this is the decisive
-- evidence: NOT deleted -- at worst relabelled Primary (see note column).
SELECT pm.risk_practice_map_id AS RiskPracticeMapId,
       pm.practice_id          AS PracticeId,
       pm.practice_name        AS PracticeNameFrozen,
       pm.map_source_code      AS MapSourceCode,
       pm.mapped_dt            AS MappedDt,
       pm.mapped_by_employee_id AS MappedByEmployeeId,
       pm.record_status_id     AS RecordStatusId,
       pm.entered_by           AS EnteredBy,
       pm.entered_dt           AS EnteredDt,
       pm.updated_by           AS UpdatedBy,
       pm.updated_dt           AS UpdatedDt,
       CASE WHEN pm.map_source_code = N'Primary'
                 AND pm.updated_dt IS NOT NULL
                 AND pm.updated_by LIKE N'%system%'
            THEN 'Possibly promoted from Additional to Primary by 354''s derivation -- check UpdatedDt against when you ran 354'
            ELSE ''
       END AS Note
  FROM grac_practice.risk_practice_map pm
 WHERE pm.risk_register_id = @RiskId
 ORDER BY pm.map_source_code, pm.mapped_dt;

PRINT '';
PRINT '=== 3. Does this risk have an UNMAP event in its history? =======';
-- The only procedure that deletes a risk_practice_map row. If your
-- practice is missing from section 2 entirely, this should explain why.
SELECT h.history_id AS HistoryId,
       h.action_code AS ActionCode,
       h.remark      AS Remark,
       h.actor_display_name AS ActorDisplayName,
       h.entered_dt  AS EnteredDt
  FROM grac_practice.risk_register_history h
 WHERE h.risk_register_id = @RiskId
   AND h.action_code IN (N'PracticeMapped', N'PracticeUnmapped', N'Register')
 ORDER BY h.entered_dt DESC;

PRINT '';
PRINT '=== 4. What the Existing Practice Map panel is told, right now ===';
-- The actual proc the /mapping endpoint calls. If your practice shows
-- up here (result set 1 of this EXEC), the data is correct and this is
-- a screen/rendering question, not a database one.
EXEC grac_practice.sp_risk_mapping_get @risk_register_id = @RiskId;

PRINT '';
PRINT 'Read top to bottom: section 2 is ground truth for what exists;';
PRINT 'section 3 explains any row that is genuinely gone; section 4 is';
PRINT 'exactly what the screen you are looking at was handed.';
