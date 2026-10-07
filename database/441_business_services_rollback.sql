-- =====================================================================
-- 441 rollback -- Business services
--
--   * removes the Business Services menu row and its grants;
--   * restores the 440 bodies verbatim: fn_asset_ci_catalog,
--     sp_asset_relationship_history_add, sp_asset_relationship_save,
--     sp_asset_relationship_action, sp_asset_relationships,
--     sp_asset_relationship_get, sp_asset_ci_impact;
--   * drops the business-service procedures, functions and tables;
--   * relationships to or from a service or a contract are retired (kept for
--     history); the relationship kind vocabulary goes back WITH NOCHECK;
--     Supports Service is inactive again; the role column is dropped.
-- practice_audit_trace rows stay as history. Deploy the API / Web without
-- the 441 changes first. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'business-services';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'business-services';
PRINT '441 rollback: menu row removed.';
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_tree;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_conflicts;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_services;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_config_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_setting_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_retirement_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_retire_apply;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_business_service_history_add;
PRINT '441 rollback: service procedures dropped.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_ci_impact
    @organization_id         BIGINT,
    @ci_kind                 NVARCHAR(12),
    @ci_id                   BIGINT,
    @direction               NVARCHAR(10)  = N'DOWNSTREAM',
    @max_depth               INT           = 5,
    @critical_only           BIT           = 0,
    @preview_relationship_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ci_kind = UPPER(LTRIM(RTRIM(ISNULL(@ci_kind, N''))));
    SET @direction = UPPER(LTRIM(RTRIM(ISNULL(@direction, N'DOWNSTREAM'))));
    SET @max_depth = CASE WHEN ISNULL(@max_depth, 5) < 1 THEN 1 WHEN @max_depth > 10 THEN 10 ELSE @max_depth END;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @direction NOT IN (N'DOWNSTREAM', N'UPSTREAM')
       OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_ci_catalog(@organization_id) WHERE CiKind = @ci_kind AND CiId = @ci_id)
        THROW 54720, 'Select a configuration item of this organization and the direction (downstream or upstream).', 1;

    CREATE TABLE #edge (rel BIGINT NOT NULL, type_code NVARCHAR(30) NOT NULL, crit BIT NOT NULL,
                        dk NVARCHAR(12) NOT NULL, di BIGINT NOT NULL, pk NVARCHAR(12) NOT NULL, pi BIGINT NOT NULL);
    INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
    SELECT RelationshipId, TypeCode, IsCritical, DependentKind, DependentId, ProviderKind, ProviderId
      FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1)
     WHERE ISNULL(@critical_only, 0) = 0 OR IsCritical = 1;
    IF @preview_relationship_id IS NOT NULL
        INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
        SELECT e.RelationshipId, e.TypeCode, e.IsCritical, e.DependentKind, e.DependentId, e.ProviderKind, e.ProviderId
          FROM grac_practice.fn_asset_relationship_edges(@organization_id, 0) e
         WHERE e.RelationshipId = @preview_relationship_id
           AND NOT EXISTS (SELECT 1 FROM #edge x WHERE x.rel = e.RelationshipId);

    CREATE TABLE #seen (k NVARCHAR(12) NOT NULL, i BIGINT NOT NULL, lvl INT NOT NULL, rel BIGINT NULL,
                        from_k NVARCHAR(12) NULL, from_i BIGINT NULL, PRIMARY KEY (k, i));
    INSERT #seen (k, i, lvl) VALUES (@ci_kind, @ci_id, 0);
    DECLARE @lvl INT = 0;
    WHILE @lvl < @max_depth
    BEGIN
        -- one row per newly reached CI: the lowest relationship id reaching it from this level
        INSERT #seen (k, i, lvl, rel, from_k, from_i)
        SELECT x.k, x.i, @lvl + 1, x.rel, x.from_k, x.from_i
          FROM (SELECT CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END AS k,
                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END AS i,
                       e.rel, s.k AS from_k, s.i AS from_i,
                       ROW_NUMBER() OVER (PARTITION BY CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END,
                                                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END
                                          ORDER BY e.crit DESC, e.rel) AS rn
                  FROM #edge e
                  JOIN #seen s ON s.lvl = @lvl
                              AND ((@direction = N'DOWNSTREAM' AND s.k = e.pk AND s.i = e.pi)
                                   OR (@direction = N'UPSTREAM' AND s.k = e.dk AND s.i = e.di))) x
         WHERE x.rn = 1
           AND NOT EXISTS (SELECT 1 FROM #seen z WHERE z.k = x.k AND z.i = x.i);
        IF @@ROWCOUNT = 0 BREAK;
        SET @lvl = @lvl + 1;
    END

    SELECT s.k AS CiKind, s.i AS CiId, c.CiName, c.CiClass, c.CiStatus, s.lvl AS ImpactLevel, s.rel AS ViaRelationshipId,
           e.type_code AS ViaTypeCode,
           CASE WHEN @direction = N'DOWNSTREAM' THEN
                     CASE t.dependent_side WHEN N'SOURCE' THEN t.type_name ELSE t.inverse_label END
                ELSE CASE t.dependent_side WHEN N'SOURCE' THEN t.inverse_label ELSE t.type_name END END AS ViaLabel,
           e.crit AS ViaCritical, s.from_k AS FromKind, s.from_i AS FromId, fc.CiName AS FromName,
           CAST(CASE WHEN e.rel = @preview_relationship_id THEN 1 ELSE 0 END AS BIT) AS ViaPreview
      FROM #seen s
      JOIN #edge e ON e.rel = s.rel
      JOIN grac_practice.asset_relationship_type t ON t.type_code = e.type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = s.k AND c.CiId = s.i
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) fc ON fc.CiKind = s.from_k AND fc.CiId = s.from_i
     WHERE s.lvl > 0
     ORDER BY s.lvl, c.CiKind, c.CiName;

    SELECT @ci_kind AS CiKind, @ci_id AS CiId, (SELECT CiName FROM grac_practice.fn_asset_ci_catalog(@organization_id)
                                                  WHERE CiKind = @ci_kind AND CiId = @ci_id) AS CiName,
           @direction AS Direction, @max_depth AS MaxDepth,
           (SELECT COUNT(*) FROM #seen WHERE lvl > 0) AS ReachedCount,
           (SELECT COUNT(*) FROM #seen s JOIN #edge e ON e.rel = s.rel WHERE s.lvl > 0 AND e.crit = 1) AS CriticalCount,
           (SELECT MAX(lvl) FROM #seen) AS DeepestLevel;
END
GO
PRINT '441 rollback: sp_asset_ci_impact restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_get
    @organization_id BIGINT,
    @relationship_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                    WHERE relationship_id = @relationship_id AND organization_id = @organization_id)
        THROW 54709, 'Relationship not found for this organization.', 1;
    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide, r.source_kind AS SourceKind, r.source_id AS SourceId,
           sc.CiName AS SourceName, sc.CiClass AS SourceClass, sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind,
           r.target_id AS TargetId, tc.CiName AS TargetName, tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus,
           r.is_critical AS IsCritical, r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight,
           r.status AS Status, r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, r.owner_employee_id AS OwnerEmployeeId,
           ow.employee_name AS OwnerName, r.verifier_employee_id AS VerifierEmployeeId, vf.employee_name AS VerifierName,
           r.evidence_reference AS EvidenceReference, r.change_reference AS ChangeReference, r.reason AS Reason, r.in_loop AS InLoop,
           r.version_no AS VersionNo, r.proposed_by AS ProposedBy, r.proposed_dt AS ProposedDt, r.approved_by AS ApprovedBy,
           r.approved_dt AS ApprovedDt, r.pending_action AS PendingAction, r.pending_json AS PendingJson,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.pending_dt AS PendingDt,
           r.retirement_accepted AS RetirementAccepted, r.retirement_note AS RetirementNote,
           r.retirement_accepted_by AS RetirementAcceptedBy, r.retirement_accepted_dt AS RetirementAcceptedDt,
           r.status_note AS StatusNote, CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.relationship_id = @relationship_id;
    SELECT h.history_id AS HistoryId, h.version_no AS VersionNo, h.action_code AS ActionCode, h.status AS Status,
           h.note AS Note, h.actor AS Actor, e.employee_name AS ActorName, h.entered_dt AS EnteredDt, h.snapshot_json AS SnapshotJson
      FROM grac_practice.asset_relationship_history h
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = h.actor_employee_id
     WHERE h.relationship_id = @relationship_id
     ORDER BY h.history_id DESC;
END
GO
PRINT '441 rollback: sp_asset_relationship_get restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationships
    @organization_id BIGINT,
    @ci_kind         NVARCHAR(12)  = NULL,
    @ci_id           BIGINT        = NULL,
    @type_code       NVARCHAR(30)  = NULL,
    @status          NVARCHAR(10)  = NULL,
    @critical_only   BIT           = 0,
    @pending_only    BIT           = 0,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    SET @ci_kind = NULLIF(UPPER(LTRIM(RTRIM(@ci_kind))), N'');
    SET @type_code = NULLIF(UPPER(LTRIM(RTRIM(@type_code))), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    EXEC grac_practice.sp_asset_relationship_sync @organization_id = @organization_id, @actor = @actor;

    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide,
           r.source_kind AS SourceKind, r.source_id AS SourceId, sc.CiName AS SourceName, sc.CiClass AS SourceClass,
           sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind, r.target_id AS TargetId, tc.CiName AS TargetName,
           tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus, r.is_critical AS IsCritical,
           r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight, r.status AS Status,
           r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, ow.employee_name AS OwnerName,
           vf.employee_name AS VerifierName, r.in_loop AS InLoop, r.version_no AS VersionNo, r.pending_action AS PendingAction,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.retirement_accepted AS RetirementAccepted,
           r.proposed_by AS ProposedBy, r.approved_by AS ApprovedBy, r.approved_dt AS ApprovedDt, r.status_note AS StatusNote,
           CONVERT(BIGINT, r.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.organization_id = @organization_id
       AND (@ci_kind IS NULL OR @ci_id IS NULL
            OR (r.source_kind = @ci_kind AND r.source_id = @ci_id) OR (r.target_kind = @ci_kind AND r.target_id = @ci_id))
       AND (@type_code IS NULL OR r.relationship_type_code = @type_code)
       AND ((@status IS NULL AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')) OR @status = N'ALL' OR r.status = @status)
       AND (ISNULL(@critical_only, 0) = 0 OR r.is_critical = 1)
       AND (ISNULL(@pending_only, 0) = 0 OR r.status = N'PROPOSED' OR r.pending_action IS NOT NULL)
       AND (@search IS NULL OR sc.CiName LIKE N'%' + @search + N'%' OR tc.CiName LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN r.status = N'PROPOSED' OR r.pending_action IS NOT NULL THEN 0 WHEN r.status = N'DISPUTED' THEN 1
                   WHEN r.status = N'ACTIVE' THEN 2 ELSE 3 END,
              r.is_critical DESC, sc.CiName, t.display_order, tc.CiName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '441 rollback: sp_asset_relationships restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_action
    @organization_id         BIGINT,
    @relationship_id         BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @critical BIT, @pending NVARCHAR(10), @pending_json NVARCHAR(MAX),
            @pending_by NVARCHAR(100), @pending_emp BIGINT, @pending_reason NVARCHAR(1000), @proposed_by NVARCHAR(100),
            @proposed_emp BIGINT, @type NVARCHAR(30), @sk NVARCHAR(12), @si BIGINT, @tk NVARCHAR(12), @ti BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @critical = is_critical, @pending = pending_action,
           @pending_json = pending_json, @pending_by = pending_by, @pending_emp = pending_by_employee_id,
           @pending_reason = pending_reason, @proposed_by = proposed_by, @proposed_emp = proposed_by_employee_id,
           @type = relationship_type_code, @sk = source_kind, @si = source_id, @tk = target_kind, @ti = target_id
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT')
        THROW 54715, 'The action is Approve, Reject, Withdraw, Dispute, Confirm, Retire or Accept for retirement.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @action IN (N'REJECT', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT') AND @note IS NULL
        THROW 54713, 'Enter the note for this action.', 1;

    DECLARE @result NVARCHAR(20), @loop BIT, @hist NVARCHAR(20) = @action;
    BEGIN TRAN;
    IF @action = N'APPROVE' AND @status = N'PROPOSED'
    BEGIN
        IF @critical = 1 AND (@proposed_by = @actor OR (@proposed_emp IS NOT NULL AND @proposed_emp = @actor_employee_id))
            THROW 54716, 'Segregation of duties: the person who proposed a critical relationship cannot approve it.', 1;
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = @relationship_id,
             @type_code = @type, @source_kind = @sk, @source_id = @si, @target_kind = @tk, @target_id = @ti, @out_loop = @loop OUTPUT;
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', in_loop = ISNULL(@loop, 0), approved_by = @actor,
               approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(), status_note = @note,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'APPROVE' AND @pending IS NOT NULL
    BEGIN
        IF @pending_by = @actor OR (@pending_emp IS NOT NULL AND @pending_emp = @actor_employee_id)
            THROW 54716, 'Segregation of duties: the person who requested the change cannot approve it.', 1;
        IF @pending = N'UPDATE'
        BEGIN
            UPDATE r
               SET is_critical = ISNULL(j.isCritical, 0), dependency_criticality = j.dependencyCriticality, impact_weight = j.impactWeight,
                   effective_from = j.effectiveFrom, effective_to = j.effectiveTo, confidence_pct = j.confidencePct,
                   owner_employee_id = j.ownerEmployeeId, verifier_employee_id = j.verifierEmployeeId,
                   evidence_reference = j.evidenceReference, change_reference = j.changeReference, reason = j.reason,
                   version_no = version_no + 1
              FROM grac_practice.asset_relationship r
             CROSS APPLY OPENJSON(@pending_json) WITH (
                    isCritical BIT, dependencyCriticality NVARCHAR(10), impactWeight DECIMAL(5, 2), effectiveFrom DATE,
                    effectiveTo DATE, confidencePct INT, ownerEmployeeId BIGINT, verifierEmployeeId BIGINT,
                    evidenceReference NVARCHAR(400), changeReference NVARCHAR(200), reason NVARCHAR(1000)) j
             WHERE r.relationship_id = @relationship_id;
            SET @result = N'UPDATED';
            SET @hist = N'APPROVE_CHANGE';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @pending_reason, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
            SET @hist = N'APPROVE_RETIRE';
        END
        UPDATE grac_practice.asset_relationship
           SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
               pending_dt = NULL, approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
    END
    ELSE IF @action IN (N'REJECT', N'WITHDRAW') AND (@status = N'PROPOSED' OR @pending IS NOT NULL)
    BEGIN
        IF @action = N'WITHDRAW'
           AND ((@pending IS NOT NULL AND ISNULL(@pending_by, N'') <> @actor)
                OR (@pending IS NULL AND @proposed_by <> @actor))
            THROW 54716, 'Only the person who proposed the relationship or requested the change can withdraw it.', 1;
        IF @pending IS NOT NULL
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
                   pending_dt = NULL, status_note = ISNULL(@note, N'Withdrawn by the requester.'),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = @status;
            SET @hist = CONCAT(@action, N'_CHANGE');
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = ISNULL(@note, N'Withdrawn by the proposer.'), version_no = version_no + 1,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'DISPUTE' AND @status = N'ACTIVE' AND @pending IS NULL
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'DISPUTED', status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'DISPUTED';
    END
    ELSE IF @action = N'CONFIRM' AND @status = N'DISPUTED'
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', status_note = @note, version_no = version_no + 1,
               approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'RETIRE' AND @status IN (N'ACTIVE', N'DISPUTED', N'INACTIVE') AND @pending IS NULL
    BEGIN
        IF @status = N'ACTIVE' AND @critical = 1
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = N'RETIRE', pending_json = NULL, pending_reason = @note, pending_by = @actor,
                   pending_by_employee_id = @actor_employee_id, pending_dt = SYSUTCDATETIME(),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'PENDING_APPROVAL';
            SET @hist = N'RETIRE_REQUEST';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @note, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'ACCEPT_RETIREMENT' AND @status = N'ACTIVE' AND @critical = 1
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET retirement_accepted = 1, retirement_note = @note, retirement_accepted_by = @actor,
               retirement_accepted_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACCEPTED';
    END
    ELSE
        THROW 54715, 'This action is not available for the relationship in its current status.', 1;

    EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = @hist, @note = @note,
         @actor = @actor, @actor_employee_id = @actor_employee_id;
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO
PRINT '441 rollback: sp_asset_relationship_action restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_save
    @organization_id         BIGINT,
    @relationship_id         BIGINT         = NULL,
    @relationship_type_code  NVARCHAR(30)   = NULL,
    @source_kind             NVARCHAR(12)   = NULL,
    @source_id               BIGINT         = NULL,
    @target_kind             NVARCHAR(12)   = NULL,
    @target_id               BIGINT         = NULL,
    @is_critical             BIT            = 0,
    @dependency_criticality  NVARCHAR(10)   = NULL,
    @impact_weight           DECIMAL(5, 2)  = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @confidence_pct          INT            = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @verifier_employee_id    BIGINT         = NULL,
    @evidence_reference      NVARCHAR(400)  = NULL,
    @change_reference        NVARCHAR(200)  = NULL,
    @reason                  NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @relationship_type_code = UPPER(LTRIM(RTRIM(ISNULL(@relationship_type_code, N''))));
    SET @source_kind = UPPER(LTRIM(RTRIM(ISNULL(@source_kind, N''))));
    SET @target_kind = UPPER(LTRIM(RTRIM(ISNULL(@target_kind, N''))));
    SET @is_critical = ISNULL(@is_critical, 0);
    SET @dependency_criticality = NULLIF(UPPER(LTRIM(RTRIM(@dependency_criticality))), N'');
    SET @evidence_reference = NULLIF(LTRIM(RTRIM(@evidence_reference)), N'');
    SET @change_reference = NULLIF(LTRIM(RTRIM(@change_reference)), N'');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @effective_from = ISNULL(@effective_from, @today);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54714, 'The effective-to date must be on or after the effective-from date.', 1;
    IF @dependency_criticality IS NOT NULL AND @dependency_criticality NOT IN (N'CRITICAL', N'HIGH', N'MEDIUM', N'LOW')
        THROW 54717, 'The dependency criticality is Critical, High, Medium or Low.', 1;
    IF @is_critical = 1 AND @dependency_criticality IS NULL
        THROW 54717, 'Select the dependency criticality of a critical dependency.', 1;
    IF @impact_weight IS NOT NULL AND @impact_weight NOT BETWEEN 0 AND 100
        THROW 54717, 'The impact weight is between 0 and 100.', 1;
    IF @confidence_pct IS NOT NULL AND @confidence_pct NOT BETWEEN 0 AND 100
        THROW 54717, 'The confidence is between 0 and 100.', 1;
    IF (@owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = @owner_employee_id AND organization_id = @organization_id
                                                          AND status = N'Active'))
       OR (@verifier_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                              WHERE employee_id = @verifier_employee_id AND organization_id = @organization_id
                                                                AND status = N'Active'))
        THROW 54718, 'The owner and the verifier must be active employees of the organization.', 1;

    DECLARE @loop BIT, @id BIGINT, @result NVARCHAR(20);
    IF @relationship_id IS NULL
    BEGIN
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = NULL,
             @type_code = @relationship_type_code, @source_kind = @source_kind, @source_id = @source_id,
             @target_kind = @target_kind, @target_id = @target_id, @out_loop = @loop OUTPUT;
        BEGIN TRAN;
        INSERT grac_practice.asset_relationship
            (organization_id, relationship_type_code, source_kind, source_id, target_kind, target_id, is_critical,
             dependency_criticality, impact_weight, status, effective_from, effective_to, source_code, confidence_pct,
             owner_employee_id, verifier_employee_id, evidence_reference, change_reference, reason, in_loop,
             proposed_by, proposed_by_employee_id, entered_by)
        VALUES (@organization_id, @relationship_type_code, @source_kind, @source_id, @target_kind, @target_id, @is_critical,
                @dependency_criticality, @impact_weight, N'PROPOSED', @effective_from, @effective_to, N'MANUAL', @confidence_pct,
                @owner_employee_id, @verifier_employee_id, @evidence_reference, @change_reference, @reason, ISNULL(@loop, 0),
                @actor, @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @id, @action_code = N'PROPOSE', @note = @reason,
             @actor = @actor, @actor_employee_id = @actor_employee_id;
        COMMIT;
        SELECT @id AS RelationshipId, N'PROPOSED' AS Result;
        RETURN;
    END

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @was_critical BIT, @pending NVARCHAR(10);
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @was_critical = is_critical, @pending = pending_action
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @status IN (N'INACTIVE', N'RETIRED')
        THROW 54711, 'An inactive or retired relationship is kept for history and cannot be changed.', 1;
    IF @pending IS NOT NULL
        THROW 54712, 'A change of this relationship is waiting for approval; approve, reject or withdraw it first.', 1;
    IF @status = N'ACTIVE' AND @reason IS NULL
        THROW 54713, 'Enter the reason for changing an active relationship.', 1;

    BEGIN TRAN;
    IF @status = N'ACTIVE' AND (@was_critical = 1 OR @is_critical = 1)
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET pending_action = N'UPDATE', pending_reason = @reason, pending_by = @actor, pending_by_employee_id = @actor_employee_id,
               pending_dt = SYSUTCDATETIME(),
               pending_json = (SELECT @is_critical AS isCritical, @dependency_criticality AS dependencyCriticality,
                                      @impact_weight AS impactWeight, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                                      @confidence_pct AS confidencePct, @owner_employee_id AS ownerEmployeeId,
                                      @verifier_employee_id AS verifierEmployeeId, @evidence_reference AS evidenceReference,
                                      @change_reference AS changeReference, @reason AS reason
                                  FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'CHANGE_REQUEST',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET is_critical = @is_critical, dependency_criticality = @dependency_criticality, impact_weight = @impact_weight,
               effective_from = @effective_from, effective_to = @effective_to, confidence_pct = @confidence_pct,
               owner_employee_id = @owner_employee_id, verifier_employee_id = @verifier_employee_id,
               evidence_reference = @evidence_reference, change_reference = @change_reference, reason = @reason,
               version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'UPDATE',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'UPDATED';
    END
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO
PRINT '441 rollback: sp_asset_relationship_save restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_history_add
    @relationship_id   BIGINT,
    @action_code       NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor             NVARCHAR(100),
    @actor_employee_id BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.asset_relationship_history
        (relationship_id, organization_id, version_no, action_code, status, snapshot_json, note, actor, actor_employee_id)
    SELECT r.relationship_id, r.organization_id, r.version_no, @action_code, r.status,
           (SELECT r2.relationship_type_code AS typeCode, r2.source_kind AS sourceKind, r2.source_id AS sourceId,
                   r2.target_kind AS targetKind, r2.target_id AS targetId, r2.is_critical AS isCritical,
                   r2.dependency_criticality AS dependencyCriticality, r2.impact_weight AS impactWeight, r2.status AS status,
                   r2.effective_from AS effectiveFrom, r2.effective_to AS effectiveTo, r2.source_code AS sourceCode,
                   r2.confidence_pct AS confidencePct, r2.verification_status AS verificationStatus,
                   r2.owner_employee_id AS ownerEmployeeId, r2.verifier_employee_id AS verifierEmployeeId,
                   r2.evidence_reference AS evidenceReference, r2.change_reference AS changeReference, r2.reason AS reason,
                   r2.in_loop AS inLoop, r2.pending_action AS pendingAction, r2.retirement_accepted AS retirementAccepted
              FROM grac_practice.asset_relationship r2 WHERE r2.relationship_id = r.relationship_id
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           @note, @actor, @actor_employee_id
      FROM grac_practice.asset_relationship r
     WHERE r.relationship_id = @relationship_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-relationship', h.relationship_id, @action_code, NULL, h.snapshot_json, N'Active', @actor
      FROM grac_practice.asset_relationship_history h
     WHERE h.history_id = SCOPE_IDENTITY();
END
GO
PRINT '441 rollback: sp_asset_relationship_history_add restored.';
GO

-- 440 body (verbatim).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ci_catalog (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT N'ASSET' AS CiKind, a.asset_id AS CiId, CAST(a.asset_name AS NVARCHAR(400)) AS CiName,
           CAST(ISNULL(ty.asset_type_name, N'Asset') AS NVARCHAR(200)) AS CiClass,
           CAST(ISNULL(s.status_name, N'Active') AS NVARCHAR(120)) AS CiStatus,
           CAST(CASE WHEN ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED') THEN 0 ELSE 1 END AS BIT) AS IsUsable,
           a.owner_id AS OwnerEmployeeId
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
     WHERE a.organization_id = @organization_id
    UNION ALL
    SELECT N'APPLICATION', p.application_id, CAST(p.application_name AS NVARCHAR(400)), CAST(N'Application' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.business_owner_id
      FROM grac_practice.organization_dependency_application p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'PROCESS', p.process_id, CAST(p.process_name AS NVARCHAR(400)), CAST(N'Process' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.process_owner_id
      FROM grac_practice.organization_dependency_process p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'VENDOR', v.vendor_id, CAST(v.vendor_name AS NVARCHAR(400)), CAST(N'Vendor' AS NVARCHAR(200)),
           CAST(v.status AS NVARCHAR(120)), CAST(CASE WHEN v.status = N'Active' THEN 1 ELSE 0 END AS BIT), v.relationship_owner_id
      FROM grac_practice.organization_dependency_vendor v
     WHERE v.organization_id = @organization_id
    UNION ALL
    SELECT N'LOCATION', l.location_id, CAST(l.location_name AS NVARCHAR(400)), CAST(N'Location' AS NVARCHAR(200)),
           CAST(l.status AS NVARCHAR(120)), CAST(CASE WHEN l.status = N'Active' THEN 1 ELSE 0 END AS BIT), l.location_head_id
      FROM grac_practice.organization_location l
     WHERE l.organization_id = @organization_id;
GO
PRINT '441 rollback: fn_asset_ci_catalog restored.';
GO

DROP FUNCTION IF EXISTS grac_practice.fn_business_service_conflicts;
DROP FUNCTION IF EXISTS grac_practice.fn_business_service_consumers;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_duration_hours;
GO

UPDATE grac_practice.asset_relationship
   SET status = N'RETIRED', status_note = N'Business services were rolled back (441).', pending_action = NULL, pending_json = NULL,
       pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL, pending_dt = NULL,
       updated_by = N'rollback-441', updated_dt = SYSUTCDATETIME()
 WHERE status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
   AND (source_kind IN (N'SERVICE', N'CONTRACT') OR target_kind IN (N'SERVICE', N'CONTRACT'));
PRINT CONCAT('441 rollback: service / contract relationships retired: ', @@ROWCOUNT);
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_rel_skind' AND definition LIKE '%CONTRACT%')
BEGIN
    ALTER TABLE grac_practice.asset_relationship DROP CONSTRAINT ck_pm_asset_rel_skind;
    ALTER TABLE grac_practice.asset_relationship WITH NOCHECK ADD CONSTRAINT ck_pm_asset_rel_skind
        CHECK (source_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE'));
    ALTER TABLE grac_practice.asset_relationship DROP CONSTRAINT ck_pm_asset_rel_tkind;
    ALTER TABLE grac_practice.asset_relationship WITH NOCHECK ADD CONSTRAINT ck_pm_asset_rel_tkind
        CHECK (target_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE'));
END
GO
IF COL_LENGTH('grac_practice.asset_relationship', 'service_role') IS NOT NULL
    ALTER TABLE grac_practice.asset_relationship DROP COLUMN service_role;
GO
UPDATE grac_practice.asset_relationship_type
   SET is_active = 0, inactive_reason = N'Available with business services (Phase 7.2).', source_kinds = N'ASSET,APPLICATION,PROCESS,VENDOR',
       description = N'Asset contributes to a business service.'
 WHERE type_code = N'SUPPORTS_SERVICE';
GO

DROP TABLE IF EXISTS grac_practice.business_service_consumer;
DROP TABLE IF EXISTS grac_practice.business_service_history;
DROP TABLE IF EXISTS grac_practice.business_service_setting;
DROP TABLE IF EXISTS grac_practice.business_service;
PRINT '441 rollback: tables dropped.';
GO

SELECT '441 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.business_service','U') IS NULL
             AND COL_LENGTH('grac_practice.asset_relationship', 'service_role') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_ci_catalog')) NOT LIKE '%business_service%'
             AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship_type WHERE type_code = N'SUPPORTS_SERVICE' AND is_active = 0)
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
