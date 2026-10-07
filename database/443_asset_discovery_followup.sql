-- =====================================================================
-- 443  Discovery follow-up: register a new candidate as a Draft asset,
--      stale-asset review (aging rule, source confirmation, dependency
--      review) leading to a decommission request
--      (Asset & Contract Management, Phase 7 increment 4a)
--
-- REQUEST
-- -------
--   BRD v1.7 5.6.3 "Reconciliation Outcomes": Create Candidate -- "create
--   staged candidate; do not activate until validation rules pass";
--   Retire / Stale -- "require aging rule, source confirmation and
--   dependency review before retirement". 19.3 "Disabling or retiring a
--   connector requires reason, impact analysis and stale-data handling";
--   19.5 "Confidence alone shall not authorize protected overwrite, merge,
--   split or retirement". 5.6.5 every result traceable. Plan:
--   docs/asset-contract-management.md (Phase 7.4a, D109-D116).
--
-- WHAT THIS DOES
-- --------------
--   1. Candidate registration: a New candidate (or Manual review) exception
--      is registered through the Asset Register form (prefilled from the
--      observation, validated by sp_asset_register_save, saved as Draft --
--      activation keeps every lifecycle gate); the new action REGISTER of
--      sp_asset_reconciliation_resolve then links the source record to it
--      (confirmed link, field precedence) and closes the exception as
--      Registered. sp_asset_discovery_candidate_get feeds the form.
--   2. Aging rule per organization (asset_stale_setting, default 90 days):
--      an asset is stale when it has source links, none is fresh (expected
--      interval x stale multiplier, 442) and no source has seen it for the
--      aging period. fn_asset_stale_state, fn_asset_stale_dependencies.
--   3. Stale review (asset_stale_review): opened on a stale asset; source
--      confirmation (absent -> continue, present -> closed as still in
--      use); dependency review (relationships with blockers, contract
--      coverage, open activities, workflows, pending lifecycle change, open
--      reconciliation exceptions, risks -- snapshot kept); then either
--      dismiss (still in use; not listed again for one aging period) or
--      request decommission, which runs the Asset Register lifecycle move
--      to Pending Decommission (sp_asset_lifecycle_transition: its gates
--      and approval apply). An asset observed again after the review opened
--      cannot be sent to decommission from it.
--
-- NOT DONE HERE: merge (7.4b) and split (7.4c); automatic opening of
--   reviews or tasks for stale assets (the list is the work queue);
--   bulk decommission.
--
-- ERROR NUMBERS: 54780-54799
--   54780 organization not found          54781 asset not found
--   54782 asset not stale                 54783 review already open
--   54784 review not found                54785 changed by someone else
--   54786 review not open                 54787 action not valid
--   54788 note required                   54789 source outcome required
--   54790 decommission prerequisites      54791 observed again
--   54792 aging rule                      54793 register: not a new asset
--
-- ALSO EDITED: sp_asset_reconciliation_resolve (442) re-issued with the
--   REGISTER action; API (AssetConfig service / controller / models), Web
--   proxy, asset-discovery.cshtml / .js (Stale assets tab, Register
--   action), asset-register.js (candidate prefill and link), docs.
-- DEPENDS ON: 428, 429, 433, 435, 438, 440, 441, 442; 265 (risk dependency maps --
--   265 replaced the 261 risk_asset_map).
-- Rollback: 443_asset_discovery_followup_rollback.sql (restores the 442
--   body of sp_asset_reconciliation_resolve).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_reconciliation_resolve','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_discovery_apply','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_discovery_link','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_discovery_setting','U') IS NULL
   OR COL_LENGTH('grac_practice.asset_reconciliation_exception','resolution') IS NULL
   OR COL_LENGTH('grac_practice.asset_discovery_observation','payload_json') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_relationship_edges') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_ci_catalog') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_lifecycle_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_workflow_case','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_activity_occurrence','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_contract_coverage','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
   OR COL_LENGTH('grac_practice.dependency_type_master','dependency_type_code') IS NULL
   OR COL_LENGTH('grac_practice.business_service','service_code') IS NULL
BEGIN
    RAISERROR('ABORT (443): run 265, 428, 429, 433, 435, 438, 440, 441 and 442 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Aging rule and stale reviews (5.6.3 Retire / Stale)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_stale_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_stale_setting (
        organization_id   BIGINT        NOT NULL CONSTRAINT pk_pm_astale_set PRIMARY KEY
            CONSTRAINT fk_pm_astale_set_org REFERENCES grac_practice.organization(organization_id),
        retire_after_days INT           NOT NULL CONSTRAINT ck_pm_astale_set_days CHECK (retire_after_days BETWEEN 1 AND 3650),
        updated_by        NVARCHAR(100) NOT NULL,
        updated_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_astale_set_udt DEFAULT SYSUTCDATETIME()
    );
    PRINT '443: asset_stale_setting created.';
END
GO

IF OBJECT_ID('grac_practice.asset_stale_review','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_stale_review (
        review_id                BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_astale_rev PRIMARY KEY,
        organization_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_astale_rev_org REFERENCES grac_practice.organization(organization_id),
        asset_id                 BIGINT         NOT NULL
            CONSTRAINT fk_pm_astale_rev_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        status                   NVARCHAR(24)   NOT NULL
            CONSTRAINT ck_pm_astale_rev_status CHECK (status IN (N'OPEN', N'DISMISSED', N'DECOMMISSION_REQUESTED')),
        last_observed_dt         DATETIME2      NULL,     -- when the review opened
        days_unseen              INT            NULL,
        retire_after_days        INT            NOT NULL,
        link_count               INT            NOT NULL,
        source_outcome           NVARCHAR(10)   NULL
            CONSTRAINT ck_pm_astale_rev_src CHECK (source_outcome IS NULL OR source_outcome IN (N'ABSENT', N'PRESENT')),
        source_note              NVARCHAR(1000) NULL,
        source_confirmed_by      NVARCHAR(100)  NULL,
        source_confirmed_dt      DATETIME2      NULL,
        dependency_note          NVARCHAR(1000) NULL,
        dependency_snapshot      NVARCHAR(MAX)  NULL,     -- JSON of fn_asset_stale_dependencies at review time
        dependency_blockers      INT            NULL,
        dependencies_reviewed_by NVARCHAR(100)  NULL,
        dependencies_reviewed_dt DATETIME2      NULL,
        decision_note            NVARCHAR(1000) NULL,
        change_id                BIGINT         NULL
            CONSTRAINT fk_pm_astale_rev_change REFERENCES grac_practice.asset_lifecycle_change(change_id),
        change_result            NVARCHAR(20)   NULL,
        opened_by                NVARCHAR(100)  NOT NULL,
        opened_dt                DATETIME2      NOT NULL CONSTRAINT df_pm_astale_rev_odt DEFAULT SYSUTCDATETIME(),
        closed_by                NVARCHAR(100)  NULL,
        closed_dt                DATETIME2      NULL,
        record_version           ROWVERSION     NOT NULL
    );
    CREATE UNIQUE INDEX ux_pm_astale_rev_open ON grac_practice.asset_stale_review(asset_id) WHERE status = N'OPEN';
    CREATE INDEX ix_pm_astale_rev_org ON grac_practice.asset_stale_review(organization_id, status, closed_dt DESC);
    PRINT '443: asset_stale_review created.';
END
GO

-- =====================================================================
-- 2. Stale state and dependency review (D110-D112)
-- =====================================================================
-- Per asset with discovery source links: links, fresh links (expected
-- interval x stale multiplier, as fn_asset_discovery_confidence), last
-- observation, days unseen, the aging rule (default 90 days) and the open
-- review. IsStale: no fresh link, unseen longer than the aging rule, and
-- not already on the way out (Pending Decommission or later). IsListed:
-- an open review, or stale and not dismissed within the last aging period.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stale_state (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
           ISNULL(s.status_code, N'ACTIVE') AS StatusCode, ISNULL(s.status_name, N'Active') AS StatusName,
           l.links AS LinkCount, ISNULL(l.fresh_links, 0) AS FreshLinkCount, l.last_seen AS LastObservedDt,
           DATEDIFF(DAY, l.last_seen, SYSUTCDATETIME()) AS DaysUnseen, st.retire_after_days AS RetireAfterDays,
           CAST(f.is_stale AS BIT) AS IsStale,
           rv.review_id AS OpenReviewId, dm.dismissed_dt AS LastDismissedDt,
           CAST(CASE WHEN rv.review_id IS NOT NULL THEN 1
                     WHEN f.is_stale = 1 AND (dm.dismissed_dt IS NULL
                                              OR dm.dismissed_dt < DATEADD(DAY, -st.retire_after_days, SYSUTCDATETIME())) THEN 1
                     ELSE 0 END AS BIT) AS IsListed
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
     CROSS APPLY (SELECT ISNULL((SELECT MAX(x.stale_multiplier) FROM grac_practice.asset_discovery_setting x
                                  WHERE x.organization_id = @organization_id), 3) AS stale_multiplier,
                         ISNULL((SELECT MAX(y.retire_after_days) FROM grac_practice.asset_stale_setting y
                                  WHERE y.organization_id = @organization_id), 90) AS retire_after_days) st
     -- the freshness flag is computed per link first: an aggregate cannot mix the
     -- outer settings with inner columns (Msg 8124).
     CROSS APPLY (SELECT COUNT(*) AS links, MAX(k.last_seen_dt) AS last_seen, SUM(fr.is_fresh) AS fresh_links
                    FROM grac_practice.asset_discovery_link k
                    JOIN grac_practice.asset_discovery_source src ON src.source_id = k.source_id
                   CROSS APPLY (SELECT CASE WHEN k.last_seen_dt >= DATEADD(HOUR, -src.expected_interval_hours * st.stale_multiplier,
                                                                            SYSUTCDATETIME()) THEN 1 ELSE 0 END AS is_fresh) fr
                   WHERE k.asset_id = a.asset_id) l
     CROSS APPLY (SELECT CASE WHEN ISNULL(l.fresh_links, 0) = 0
                               AND l.last_seen < DATEADD(DAY, -st.retire_after_days, SYSUTCDATETIME())
                               AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'PENDING_DECOMMISSION', N'SANITIZATION_PENDING',
                                                                             N'DISPOSAL_APPROVAL', N'DISPOSED', N'ARCHIVED')
                              THEN 1 ELSE 0 END AS is_stale) f
     OUTER APPLY (SELECT TOP 1 r.review_id FROM grac_practice.asset_stale_review r
                   WHERE r.asset_id = a.asset_id AND r.status = N'OPEN') rv
     OUTER APPLY (SELECT MAX(r.closed_dt) AS dismissed_dt FROM grac_practice.asset_stale_review r
                   WHERE r.asset_id = a.asset_id AND r.status = N'DISMISSED') dm
     WHERE a.organization_id = @organization_id AND l.links > 0;
GO

-- What still relies on or refers to the asset (dependency review, 5.6.3 /
-- 19.3 impact analysis). IsBlocker: an active critical relationship not
-- accepted for retirement (the 440 gate refuses sanitization / disposal),
-- or a lifecycle change awaiting approval (the move would be refused).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stale_dependencies (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(N'RELATIONSHIP' AS NVARCHAR(16)) AS ItemKind,
           CAST(ISNULL(c.CiName, CONCAT(e.DependentKind, N' #', e.DependentId)) AS NVARCHAR(400)) AS ItemName,
           CAST(CONCAT(t.type_name, CASE WHEN e.IsCritical = 1 THEN N' - critical' ELSE N'' END,
                       CASE WHEN e.RetirementAccepted = 1 THEN N' - accepted for retirement' ELSE N'' END) AS NVARCHAR(600)) AS Detail,
           CAST(CASE WHEN e.IsCritical = 1 AND e.RetirementAccepted = 0 THEN 1 ELSE 0 END AS BIT) AS IsBlocker
      FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1) e
      JOIN grac_practice.asset_relationship_type t ON t.type_code = e.TypeCode
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = e.DependentKind AND c.CiId = e.DependentId
     WHERE e.ProviderKind = N'ASSET' AND e.ProviderId = @asset_id
    UNION ALL
    SELECT N'CONTRACT', CAST(CONCAT(k.contract_number, N' ', k.contract_name) AS NVARCHAR(400)),
           CAST(CONCAT(cv.coverage_type, N' - ', LOWER(cv.coverage_state)) AS NVARCHAR(600)), CAST(0 AS BIT)
      FROM grac_practice.asset_contract_coverage cv
      JOIN grac_practice.asset_contract_version v ON v.version_id = cv.version_id
      JOIN grac_practice.entity_status_master vs ON vs.entity_status_id = v.current_status_id
      JOIN grac_practice.asset_contract k ON k.contract_id = cv.contract_id
     WHERE cv.asset_id = @asset_id AND vs.status_code = N'ACTIVE' AND cv.coverage_state = N'COVERED' AND k.organization_id = @organization_id
    UNION ALL
    SELECT N'ACTIVITY', CAST(tp.template_name AS NVARCHAR(400)), CAST(CONCAT(N'Open, due ', CONVERT(NVARCHAR(10), o.due_date, 23)) AS NVARCHAR(600)),
           CAST(0 AS BIT)
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = o.template_code
     WHERE o.asset_id = @asset_id AND o.status = N'OPEN' AND o.organization_id = @organization_id
    UNION ALL
    SELECT N'WORKFLOW', CAST(d.workflow_name AS NVARCHAR(400)), CAST(CONCAT(N'Open case: ', LEFT(w.reason, 500)) AS NVARCHAR(600)), CAST(0 AS BIT)
      FROM grac_practice.asset_workflow_case w
      JOIN grac_practice.asset_workflow_definition d ON d.workflow_code = w.workflow_code
     WHERE w.asset_id = @asset_id AND w.case_status = N'OPEN' AND w.organization_id = @organization_id
    UNION ALL
    SELECT N'LIFECYCLE', CAST(CONCAT(lc.from_status_code, N' -> ', lc.to_status_code) AS NVARCHAR(400)),
           CAST(N'Lifecycle change awaiting approval' AS NVARCHAR(600)), CAST(1 AS BIT)
      FROM grac_practice.asset_lifecycle_change lc
     WHERE lc.asset_id = @asset_id AND lc.change_status = N'PENDING_APPROVAL'
    UNION ALL
    SELECT N'RECONCILIATION', CAST(CONCAT(x.exception_kind, CASE WHEN x.field_key IS NULL THEN N'' ELSE N' - ' + x.field_key END) AS NVARCHAR(400)),
           CAST(N'Open reconciliation exception' AS NVARCHAR(600)), CAST(0 AS BIT)
      FROM grac_practice.asset_reconciliation_exception x
     WHERE (x.asset_id = @asset_id OR x.other_asset_id = @asset_id) AND x.status = N'OPEN' AND x.organization_id = @organization_id
    UNION ALL
    SELECT N'RISK', CAST(CONCAT(r.risk_number, N' ', r.risk_title) AS NVARCHAR(400)), CAST(CONCAT(N'Risk status: ', r.status_code) AS NVARCHAR(600)),
           CAST(0 AS BIT)
      FROM grac_practice.risk_dependency_map m   -- 265 (replaced the 261 risk_asset_map); category Asset as 002 resolves it
      JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                  AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
      JOIN grac_practice.risk_register r ON r.risk_register_id = m.risk_register_id
     WHERE m.dependency_object_id = @asset_id AND m.organization_id = @organization_id;
GO
PRINT '443: stale state and dependency functions created.';
GO

-- =====================================================================
-- 3. Aging rule, review opening and review actions
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_stale_setting_save
    @organization_id   BIGINT,
    @retire_after_days INT,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54780, 'Organization not found.', 1;
    IF ISNULL(@retire_after_days, 0) NOT BETWEEN 1 AND 3650
        THROW 54792, 'The aging rule is 1-3650 days without any source observation.', 1;
    DECLARE @before INT = (SELECT retire_after_days FROM grac_practice.asset_stale_setting WHERE organization_id = @organization_id);
    BEGIN TRAN;
    MERGE grac_practice.asset_stale_setting AS t
    USING (SELECT @organization_id AS organization_id) AS s ON t.organization_id = s.organization_id
    WHEN MATCHED THEN UPDATE SET retire_after_days = @retire_after_days, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (organization_id, retire_after_days, updated_by) VALUES (@organization_id, @retire_after_days, @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-stale-setting', @organization_id, N'UPDATE',
            (SELECT ISNULL(@before, 90) AS retireAfterDays FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @retire_after_days AS retireAfterDays FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO

-- Opens a review on a stale asset (one open review per asset).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_stale_review_open
    @organization_id BIGINT,
    @asset_id        BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54781, 'Asset not found for this organization.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_stale_review WHERE asset_id = @asset_id AND status = N'OPEN')
        THROW 54783, 'A stale review is already open for this asset.', 1;
    DECLARE @stale BIT, @last DATETIME2, @days INT, @retire INT, @links INT;
    SELECT @stale = IsStale, @last = LastObservedDt, @days = DaysUnseen, @retire = RetireAfterDays, @links = LinkCount
      FROM grac_practice.fn_asset_stale_state(@organization_id) WHERE AssetId = @asset_id;
    IF ISNULL(@stale, 0) = 0
        THROW 54782, 'The asset is not stale: it has a fresh source observation, was seen within the aging rule, has no source link, or is already pending decommission.', 1;
    DECLARE @id BIGINT;
    BEGIN TRAN;
    INSERT grac_practice.asset_stale_review
        (organization_id, asset_id, status, last_observed_dt, days_unseen, retire_after_days, link_count, opened_by)
    VALUES (@organization_id, @asset_id, N'OPEN', @last, @days, @retire, @links, @actor);
    SET @id = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-stale-review', @id, N'OPEN', NULL,
            (SELECT @asset_id AS assetId, @last AS lastObservedDt, @days AS daysUnseen, @retire AS retireAfterDays, @links AS links
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @id AS ReviewId, N'OPENED' AS Result;
END
GO

-- Review actions:
--   CONFIRM_SOURCE        @source_outcome ABSENT (continue) | PRESENT (closed:
--                         still in use -- check the connector scope), note required
--   REVIEW_DEPENDENCIES   note required; the dependency list is kept as a snapshot
--   DISMISS               note required; not listed again for one aging period
--   REQUEST_DECOMMISSION  needs source ABSENT and the dependency review, no
--                         observation since the review opened, and a reason
--                         (note); runs the lifecycle move to Pending
--                         Decommission (its gates and approval apply).
-- REQUEST_DECOMMISSION returns the lifecycle result set first; the last
-- result set is always ReviewId, Result, ChangeId.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_stale_review_action
    @organization_id         BIGINT,
    @review_id               BIGINT,
    @action                  NVARCHAR(24),
    @source_outcome          NVARCHAR(10)   = NULL,
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
    SET @source_outcome = NULLIF(UPPER(LTRIM(RTRIM(@source_outcome))), N'');
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @found BIT = 0, @asset BIGINT, @status NVARCHAR(24), @rv BIGINT, @opened DATETIME2, @src_outcome NVARCHAR(10),
            @src_note NVARCHAR(1000), @dep_note NVARCHAR(1000), @dep_dt DATETIME2, @last DATETIME2;
    SELECT @found = 1, @asset = asset_id, @status = status, @rv = CONVERT(BIGINT, record_version), @opened = opened_dt,
           @src_outcome = source_outcome, @src_note = source_note, @dep_note = dependency_note, @dep_dt = dependencies_reviewed_dt,
           @last = last_observed_dt
      FROM grac_practice.asset_stale_review
     WHERE review_id = @review_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54784, 'Stale review not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54785, 'The review was changed by someone else; reload it and try again.', 1;
    IF @status <> N'OPEN' THROW 54786, 'This review is already closed.', 1;
    IF @action NOT IN (N'CONFIRM_SOURCE', N'REVIEW_DEPENDENCIES', N'DISMISS', N'REQUEST_DECOMMISSION')
        THROW 54787, 'That action is not available for a stale review.', 1;
    IF @note IS NULL
        THROW 54788, 'Record the note (source confirmation, dependency review, reason).', 1;
    IF @action = N'CONFIRM_SOURCE' AND ISNULL(@source_outcome, N'') NOT IN (N'ABSENT', N'PRESENT')
        THROW 54789, 'Record what the source owner confirmed: absent or still present.', 1;
    -- Seen again by any source since the review opened (5.6.3: no retirement on stale evidence).
    DECLARE @seen_again DATETIME2 = (SELECT MAX(last_seen_dt) FROM grac_practice.asset_discovery_link
                                      WHERE asset_id = @asset AND last_seen_dt > ISNULL(@last, @opened));
    IF @action = N'REQUEST_DECOMMISSION'
    BEGIN
        IF ISNULL(@src_outcome, N'') <> N'ABSENT' OR @dep_dt IS NULL
            THROW 54790, 'Record the source confirmation (absent) and the dependency review first.', 1;
        IF @seen_again IS NOT NULL
            THROW 54791, 'A source observed the asset again after the review opened; dismiss the review.', 1;
    END

    DECLARE @result NVARCHAR(24) = @action, @change BIGINT, @change_result NVARCHAR(20), @snapshot NVARCHAR(MAX), @blockers INT,
            @reason NVARCHAR(1000), @reference NVARCHAR(400), @evidence NVARCHAR(1000);
    IF @action = N'REVIEW_DEPENDENCIES'
    BEGIN
        SET @snapshot = (SELECT ItemKind AS kind, ItemName AS name, Detail AS detail, IsBlocker AS isBlocker
                           FROM grac_practice.fn_asset_stale_dependencies(@organization_id, @asset) FOR JSON PATH);
        SET @blockers = (SELECT COUNT(*) FROM grac_practice.fn_asset_stale_dependencies(@organization_id, @asset) WHERE IsBlocker = 1);
    END
    IF @action = N'REQUEST_DECOMMISSION'
        SELECT @reason = @note, @reference = CONCAT(N'Stale review SR-', @review_id),
               @evidence = LEFT(CONCAT(N'Not observed by any source since ', CONVERT(NVARCHAR(19), @last, 120),
                                       N' UTC. Source confirmation: ', @src_note, N' Dependency review: ', @dep_note), 1000);

    BEGIN TRAN;
    IF @action = N'CONFIRM_SOURCE'
    BEGIN
        UPDATE grac_practice.asset_stale_review
           SET source_outcome = @source_outcome, source_note = @note, source_confirmed_by = @actor, source_confirmed_dt = SYSUTCDATETIME(),
               status = CASE WHEN @source_outcome = N'PRESENT' THEN N'DISMISSED' ELSE status END,
               decision_note = CASE WHEN @source_outcome = N'PRESENT' THEN @note ELSE decision_note END,
               closed_by = CASE WHEN @source_outcome = N'PRESENT' THEN @actor ELSE closed_by END,
               closed_dt = CASE WHEN @source_outcome = N'PRESENT' THEN SYSUTCDATETIME() ELSE closed_dt END
         WHERE review_id = @review_id;
        SET @result = CASE WHEN @source_outcome = N'PRESENT' THEN N'DISMISSED' ELSE N'SOURCE_CONFIRMED' END;
    END
    ELSE IF @action = N'REVIEW_DEPENDENCIES'
    BEGIN
        UPDATE grac_practice.asset_stale_review
           SET dependency_note = @note, dependency_snapshot = @snapshot, dependency_blockers = @blockers,
               dependencies_reviewed_by = @actor, dependencies_reviewed_dt = SYSUTCDATETIME()
         WHERE review_id = @review_id;
        SET @result = N'DEPENDENCIES_REVIEWED';
    END
    ELSE IF @action = N'DISMISS'
    BEGIN
        UPDATE grac_practice.asset_stale_review
           SET status = N'DISMISSED', decision_note = @note, closed_by = @actor, closed_dt = SYSUTCDATETIME()
         WHERE review_id = @review_id;
        SET @result = N'DISMISSED';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_transition
             @organization_id = @organization_id, @asset_id = @asset, @to_status_code = N'PENDING_DECOMMISSION',
             @reason_text = @reason, @reference_text = @reference, @evidence_text = @evidence,
             @actor_employee_id = @actor_employee_id, @actor = @actor,
             @out_change_id = @change OUTPUT, @out_result = @change_result OUTPUT;
        UPDATE grac_practice.asset_stale_review
           SET status = N'DECOMMISSION_REQUESTED', decision_note = @note, change_id = @change, change_result = @change_result,
               closed_by = @actor, closed_dt = SYSUTCDATETIME()
         WHERE review_id = @review_id;
        SET @result = N'DECOMMISSION_REQUESTED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-stale-review', @review_id, @action, N'{"status":"OPEN"}',
            (SELECT @asset AS assetId, @result AS result, @source_outcome AS sourceOutcome, @note AS note, @blockers AS blockers,
                    @change AS changeId, @change_result AS changeResult FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @review_id AS ReviewId, @result AS Result, @change AS ChangeId, @change_result AS ChangeResult;
END
GO
PRINT '443: stale review writers created.';
GO

-- =====================================================================
-- 4. Stale review readers
-- =====================================================================
-- 1. settings  2. rows. @view: NULL = stale assets and open reviews,
-- CLOSED = closed reviews.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_stale_reviews
    @organization_id BIGINT,
    @view            NVARCHAR(10)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54780, 'Organization not found.', 1;
    SET @view = NULLIF(UPPER(LTRIM(RTRIM(@view))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT ISNULL((SELECT retire_after_days FROM grac_practice.asset_stale_setting WHERE organization_id = @organization_id), 90) AS RetireAfterDays,
           ISNULL((SELECT stale_multiplier FROM grac_practice.asset_discovery_setting WHERE organization_id = @organization_id), 3) AS StaleMultiplier;
    IF @view = N'CLOSED'
    BEGIN
        SELECT r.review_id AS ReviewId, r.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
               ISNULL(s.status_name, N'Active') AS StatusName, r.link_count AS LinkCount, CAST(NULL AS INT) AS FreshLinkCount,
               r.last_observed_dt AS LastObservedDt, r.days_unseen AS DaysUnseen, CAST(NULL AS BIT) AS IsStale,
               r.status AS ReviewStatus, r.source_outcome AS SourceOutcome, r.dependencies_reviewed_dt AS DependenciesReviewedDt,
               r.dependency_blockers AS DependencyBlockers, r.opened_dt AS OpenedDt, r.opened_by AS OpenedBy, r.closed_dt AS ClosedDt,
               r.closed_by AS ClosedBy, r.change_result AS ChangeResult, r.decision_note AS DecisionNote,
               CONVERT(BIGINT, r.record_version) AS RecordVersion, COUNT(*) OVER () AS TotalRows
          FROM grac_practice.asset_stale_review r
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id
          LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
         WHERE r.organization_id = @organization_id AND r.status <> N'OPEN'
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR ty.asset_type_name LIKE N'%' + @search + N'%')
         ORDER BY r.closed_dt DESC, r.review_id DESC
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
    ELSE
    BEGIN
        SELECT r.review_id AS ReviewId, x.AssetId, x.AssetName, x.AssetTypeName, x.StatusName, x.LinkCount, x.FreshLinkCount,
               x.LastObservedDt, x.DaysUnseen, x.IsStale,
               r.status AS ReviewStatus, r.source_outcome AS SourceOutcome, r.dependencies_reviewed_dt AS DependenciesReviewedDt,
               r.dependency_blockers AS DependencyBlockers, r.opened_dt AS OpenedDt, r.opened_by AS OpenedBy, r.closed_dt AS ClosedDt,
               r.closed_by AS ClosedBy, r.change_result AS ChangeResult, r.decision_note AS DecisionNote,
               CONVERT(BIGINT, r.record_version) AS RecordVersion, COUNT(*) OVER () AS TotalRows
          FROM grac_practice.fn_asset_stale_state(@organization_id) x
          LEFT JOIN grac_practice.asset_stale_review r ON r.review_id = x.OpenReviewId
         WHERE x.IsListed = 1
           AND (@search IS NULL OR x.AssetName LIKE N'%' + @search + N'%' OR x.AssetTypeName LIKE N'%' + @search + N'%')
         ORDER BY CASE WHEN r.review_id IS NULL THEN 1 ELSE 0 END, x.DaysUnseen DESC, x.AssetName
        OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
    END
END
GO

-- One asset: 1. stale state with the open review  2. source links
-- 3. dependency review items  4. reviews (newest first).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_stale_review_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54781, 'Asset not found for this organization.', 1;
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
           ISNULL(s.status_name, N'Active') AS StatusName, ISNULL(x.LinkCount, 0) AS LinkCount, ISNULL(x.FreshLinkCount, 0) AS FreshLinkCount,
           x.LastObservedDt, x.DaysUnseen, ISNULL(x.IsStale, CAST(0 AS BIT)) AS IsStale,
           ISNULL(x.RetireAfterDays, ISNULL((SELECT retire_after_days FROM grac_practice.asset_stale_setting
                                              WHERE organization_id = @organization_id), 90)) AS RetireAfterDays,
           r.review_id AS ReviewId, r.status AS ReviewStatus, r.source_outcome AS SourceOutcome, r.source_note AS SourceNote,
           r.source_confirmed_by AS SourceConfirmedBy, r.source_confirmed_dt AS SourceConfirmedDt, r.dependency_note AS DependencyNote,
           r.dependency_blockers AS DependencyBlockers, r.dependencies_reviewed_by AS DependenciesReviewedBy,
           r.dependencies_reviewed_dt AS DependenciesReviewedDt, r.opened_by AS OpenedBy, r.opened_dt AS OpenedDt,
           CONVERT(BIGINT, r.record_version) AS RecordVersion,
           CAST(CASE WHEN r.review_id IS NOT NULL AND EXISTS (
                         SELECT 1 FROM grac_practice.asset_discovery_link k
                          WHERE k.asset_id = a.asset_id AND k.last_seen_dt > ISNULL(r.last_observed_dt, r.opened_dt)) THEN 1 ELSE 0 END AS BIT) AS SeenAgain
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.fn_asset_stale_state(@organization_id) x ON x.AssetId = a.asset_id
      LEFT JOIN grac_practice.asset_stale_review r ON r.asset_id = a.asset_id AND r.status = N'OPEN'
     WHERE a.asset_id = @asset_id;
    SELECT l.link_id AS LinkId, src.source_name AS SourceName, src.is_active AS SourceActive, src.last_run_dt AS SourceLastRunDt,
           src.last_run_status AS SourceLastRunStatus, l.external_key AS ExternalKey, l.link_method AS LinkMethod,
           l.first_seen_dt AS FirstSeenDt, l.last_seen_dt AS LastSeenDt, src.expected_interval_hours AS ExpectedIntervalHours,
           DATEDIFF(DAY, l.last_seen_dt, SYSUTCDATETIME()) AS DaysUnseen
      FROM grac_practice.asset_discovery_link l
      JOIN grac_practice.asset_discovery_source src ON src.source_id = l.source_id
     WHERE l.asset_id = @asset_id
     ORDER BY l.last_seen_dt DESC;
    SELECT ItemKind, ItemName, Detail, IsBlocker
      FROM grac_practice.fn_asset_stale_dependencies(@organization_id, @asset_id)
     ORDER BY IsBlocker DESC, ItemKind, ItemName;
    SELECT review_id AS ReviewId, status AS ReviewStatus, last_observed_dt AS LastObservedDt, days_unseen AS DaysUnseen,
           source_outcome AS SourceOutcome, source_note AS SourceNote, dependency_note AS DependencyNote,
           dependency_blockers AS DependencyBlockers, decision_note AS DecisionNote, change_id AS ChangeId, change_result AS ChangeResult,
           opened_by AS OpenedBy, opened_dt AS OpenedDt, closed_by AS ClosedBy, closed_dt AS ClosedDt
      FROM grac_practice.asset_stale_review
     WHERE asset_id = @asset_id AND organization_id = @organization_id
     ORDER BY review_id DESC;
END
GO
PRINT '443: stale review readers created.';
GO

-- =====================================================================
-- 5. Candidate registration (5.6.3 Create Candidate; D109)
-- =====================================================================
-- Feeds the Asset Register form: 1. the exception  2. the observed values
-- that name a dictionary field (the form maps list values by label).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_candidate_get
    @organization_id BIGINT,
    @exception_id    BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @payload NVARCHAR(MAX), @found BIT = 0;
    SELECT @found = 1, @payload = o.payload_json
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
     WHERE e.exception_id = @exception_id AND e.organization_id = @organization_id;
    IF @found = 0 THROW 54773, 'Reconciliation exception not found for this organization.', 1;
    SELECT e.exception_id AS ExceptionId, e.exception_kind AS ExceptionKind, e.status AS Status, s.source_name AS SourceName,
           e.external_key AS ExternalKey, o.observed_dt AS ObservedDt, e.match_score AS MatchScore, e.asset_id AS AssetId,
           a.asset_name AS AssetName, CAST(CASE WHEN @payload IS NULL THEN 0 ELSE 1 END AS BIT) AS HasPayload,
           CONVERT(BIGINT, e.record_version) AS RecordVersion
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_source s ON s.source_id = e.source_id
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = e.asset_id
     WHERE e.exception_id = @exception_id;
    SELECT f.field_key AS FieldKey, f.display_label AS FieldLabel, f.data_type_code AS DataTypeCode, f.lookup_source AS LookupSource,
           LEFT(CAST(j.[value] AS NVARCHAR(MAX)), 400) AS ObservedValue
      FROM OPENJSON(ISNULL(@payload, N'{}')) j
      -- OPENJSON keys are Latin1_General_BIN2: compare in the database collation (Msg 468)
      JOIN grac_practice.asset_field_definition f ON f.field_key = j.[key] COLLATE DATABASE_DEFAULT
     WHERE j.[type] IN (1, 2) AND NULLIF(LTRIM(RTRIM(CAST(j.[value] AS NVARCHAR(MAX)))), N'') IS NOT NULL
     ORDER BY f.display_label;
END
GO

-- =====================================================================
-- 6. sp_asset_reconciliation_resolve (442) re-issued: action REGISTER
-- =====================================================================
-- REGISTER (New candidate / Manual review): @asset_id is the Draft asset
-- registered for the candidate on the Asset Register form, with no source
-- link yet; it is then handled as LINK and the exception is closed as
-- REGISTERED. Every other action is unchanged.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_reconciliation_resolve
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @action                  NVARCHAR(20),
    @asset_id                BIGINT         = NULL,
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
    DECLARE @found BIT = 0, @kind NVARCHAR(16), @status NVARCHAR(10), @rv BIGINT, @obs BIGINT, @source BIGINT, @key NVARCHAR(200),
            @exc_asset BIGINT, @other BIGINT, @field NVARCHAR(100), @observed NVARCHAR(400), @score INT, @payload NVARCHAR(MAX);
    SELECT @found = 1, @kind = e.exception_kind, @status = e.status, @rv = CONVERT(BIGINT, e.record_version), @obs = e.observation_id,
           @source = e.source_id, @key = e.external_key, @exc_asset = e.asset_id, @other = e.other_asset_id, @field = e.field_key,
           @observed = e.observed_value, @score = e.match_score, @payload = o.payload_json
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
     WHERE e.exception_id = @exception_id AND e.organization_id = @organization_id;
    IF @found = 0 THROW 54773, 'Reconciliation exception not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54774, 'The exception was changed by someone else; reload it and try again.', 1;
    IF @status <> N'OPEN' THROW 54775, 'This exception is already resolved.', 1;
    -- REGISTER: link a new candidate to the Draft asset just registered for it (D109).   -- 443
    DECLARE @registered BIT = 0;   -- 443
    IF @action = N'REGISTER'   -- 443
    BEGIN   -- 443
        IF @kind NOT IN (N'NEW_CANDIDATE', N'MANUAL_REVIEW')   -- 443
            THROW 54793, 'Only a new candidate or a manual review can be registered as a new asset.', 1;   -- 443
        IF @asset_id IS NULL   -- 443
           OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a   -- 443
                            JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id   -- 443
                           WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id AND s.status_code = N'DRAFT')   -- 443
           OR EXISTS (SELECT 1 FROM grac_practice.asset_discovery_link k WHERE k.asset_id = @asset_id)   -- 443
            THROW 54793, 'Register the candidate as a new Draft asset first (Asset Register). An asset already linked to a source is linked with Link.', 1;   -- 443
        SELECT @action = N'LINK', @registered = 1;   -- 443
    END   -- 443
    IF NOT ((@kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE') AND @action IN (N'LINK', N'IGNORE'))
         OR (@kind = N'DUPLICATE' AND @action IN (N'LINK', N'NOT_DUPLICATE', N'IGNORE'))
         OR (@kind = N'CONFLICT' AND @action IN (N'ACCEPT_OBSERVED', N'KEEP_CURRENT')))
        THROW 54776, 'That action is not available for this exception.', 1;
    IF @action IN (N'IGNORE', N'NOT_DUPLICATE', N'KEEP_CURRENT') AND @note IS NULL
        THROW 54778, 'Record the reason in the note.', 1;
    IF @action = N'LINK'
    BEGIN
        SET @asset_id = COALESCE(@asset_id, CASE WHEN @kind = N'SUGGESTED_MATCH' THEN @exc_asset END);
        IF @asset_id IS NULL OR (@kind = N'DUPLICATE' AND @asset_id NOT IN (@exc_asset, @other))
           OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                            LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                           WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id
                             AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DISPOSED', N'ARCHIVED'))
            THROW 54777, 'Select the register asset to link (for a duplicate, one of the two assets).', 1;
        IF @payload IS NULL
            THROW 54776, 'The observation details are past their retention; wait for the next observation of this record.', 1;
    END
    IF @action = N'ACCEPT_OBSERVED' AND @payload IS NULL AND @observed IS NULL
        THROW 54776, 'The observed value is no longer available.', 1;

    DECLARE @upd INT, @conf INT, @result NVARCHAR(20) = CASE WHEN @registered = 1 THEN N'REGISTERED' ELSE @action END;   -- 443
    BEGIN TRAN;
    IF @action = N'LINK'
    BEGIN
        EXEC grac_practice.sp_asset_discovery_apply @observation_id = @obs, @asset_id = @asset_id, @link_method = N'CONFIRMED',
             @match_score = @score, @actor = @actor, @out_updated = @upd OUTPUT, @out_conflicts = @conf OUTPUT;
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = CASE WHEN @registered = 1 THEN N'REGISTERED' ELSE N'LINKED' END,   -- 443
               resolution_note = ISNULL(@note, CONCAT(N'Linked to asset ', @asset_id, N'.')),   -- 443
               resolved_by = @actor, resolved_dt = SYSUTCDATETIME(), asset_id = @asset_id, updated_dt = SYSUTCDATETIME()
         WHERE status = N'OPEN' AND exception_kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE', N'DUPLICATE')
           AND (exception_id = @exception_id OR (@key IS NOT NULL AND source_id = @source AND external_key = @key));
        UPDATE grac_practice.asset_discovery_observation
           SET matched_asset_id = @asset_id,
               result_text = LEFT(CONCAT(result_text, N' Linked by ', @actor, N': ', @upd, N' field(s) updated, ', @conf, N' conflict(s).'), 1000)
         WHERE observation_id = @obs;
    END
    ELSE IF @action = N'ACCEPT_OBSERVED'
    BEGIN
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @exc_asset, @field_key = @field, @value = @observed, @actor = @actor;
        UPDATE grac_practice.asset_attribute_source SET applied = 1 WHERE asset_id = @exc_asset AND field_key = @field AND source_id = @source;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-register', @exc_asset, N'DISCOVERY', NULL,
                (SELECT @exception_id AS exceptionId, @field AS fieldKey, @observed AS acceptedValue FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    END
    ELSE IF @action = N'NOT_DUPLICATE'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_duplicate_decision
                        WHERE asset_id_low = CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END
                          AND asset_id_high = CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END)
            INSERT grac_practice.asset_duplicate_decision (asset_id_low, asset_id_high, note, decided_by)
            VALUES (CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END,
                    CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END, @note, @actor);
    END
    IF @action <> N'LINK'
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = @action, resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
               updated_dt = SYSUTCDATETIME()
         WHERE exception_id = @exception_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-reconciliation-exception', @exception_id, @action, N'{"status":"OPEN"}',
            (SELECT @result AS resolution, @asset_id AS assetId, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);   -- 443
    COMMIT;
    SELECT @exception_id AS ExceptionId, @result AS Result;
END
GO
PRINT '443: sp_asset_reconciliation_resolve re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '443-a tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_stale_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_stale_review','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_astale_rev_open')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '443-b functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_stale_state') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_stale_dependencies') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_stale_setting_save', 'sp_asset_stale_review_open', 'sp_asset_stale_review_action',
                                'sp_asset_stale_reviews', 'sp_asset_stale_review_get', 'sp_asset_discovery_candidate_get')) = 6
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '443-c resolve re-issued with REGISTER',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_reconciliation_resolve')) LIKE '%N''REGISTER''%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_reconciliation_resolve')) LIKE '%N''REGISTERED''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '443-d stale state and dependency functions run',
       CASE WHEN (SELECT COUNT(*) FROM (SELECT TOP 1 AssetId FROM grac_practice.fn_asset_stale_state(
                                            (SELECT TOP 1 organization_id FROM grac_practice.organization ORDER BY organization_id))) x) >= 0
             AND (SELECT COUNT(*) FROM grac_practice.fn_asset_stale_dependencies(-1, -1)) = 0
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs: a discovery source S (442) with interval 1 h; a New candidate
--   exception from S; asset A linked to S (auto match or link) and not
--   observed for a while; users E (asset-discovery EDIT, asset-register
--   ADD) and A (asset-register APPROVE).
--   1. Asset Discovery -> Reconciliation queue: New candidate -> Register.
--      The Asset Register opens on New asset with the source record named;
--      choose the asset type -> the form is prefilled from the observation
--      (list values matched by label). Save -> the asset is Draft and the
--      exception closes as Registered (the queue shows it under Resolved);
--      the asset has a confirmed link to S.
--   2. Register a candidate, then try Register again for another exception
--      on that asset -> refused (already linked: use Link).
--   3. Stale assets: set the aging rule to 1 day; asset A unseen for more
--      than a day (and its link not fresh) is listed. Start review ->
--      Request decommission is refused until the source confirmation
--      (absent) and the dependency review are recorded; the dependency
--      list shows relationships (critical ones flagged), contract
--      coverage, open activities, workflows, pending lifecycle change,
--      reconciliation exceptions and risks.
--   4. Request decommission (reason) -> the lifecycle move Active ->
--      Pending Decommission is requested (approval by A on the Asset
--      Register Lifecycle tab); the review closes as Decommission
--      requested with the change result.
--   5. Another stale asset: source confirms Present -> review closed
--      (dismissed); Dismiss -> not listed again for one aging period.
--   6. Import a batch observing asset A while its review is open -> Request
--      decommission is refused (observed again); the review shows "seen
--      again".
-- =====================================================================
