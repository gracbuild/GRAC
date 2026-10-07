-- =====================================================================
-- 444  Asset merge: survivor and duplicates, preview, impact analysis,
--      validation, approval (two-person for critical CIs), execution with
--      per-object outcomes, aliases, recovery
--      (Asset & Contract Management, Phase 7 increment 4b)
--
-- REQUEST
-- -------
--   BRD v1.7 5.6.3 Merge -- "preserve surviving ID, aliases, source links,
--   history, relationships, evidence and audit"; Potential Duplicate -- "do
--   not merge automatically unless explicitly approved". 19.4 Merge and
--   Split Approval Governance: initiation (survivor and duplicates), preview
--   (field, source, history, relationship, attachment and task
--   differences), impact analysis (services, contracts, risks,
--   attestations, tasks, reports, integrations), validation (protected
--   conflicts resolved, survivor meets mandatory rules), approval
--   (configured approver; two-person control for critical CIs), execution
--   (per-object outcomes, recoverable state), recovery (restorative event
--   where technically possible), audit (before / after IDs, values, actor,
--   reason, approval); open workflow items explicitly reassigned or linked,
--   never silently closed; aliases and external identifiers stay
--   searchable; recovery never erases the original event. 19.5 confidence
--   alone never authorizes a merge. Plan: docs/asset-contract-management.md
--   (Phase 7.4b, D115-D124).
--
-- WHAT THIS DOES
-- --------------
--   1. Merge events (asset_merge_split_event, kind MERGE; split reuses them
--      in 7.4c): survivor + 1-10 duplicates, reason, field choices; Draft ->
--      Pending approval -> Approved -> Executed (-> Recovered), or Rejected /
--      Cancelled. Members, approvals, per-object outcomes.
--   2. Plan (fn_asset_merge_plan) -- the one source for preview and
--      execution: relationships, discovery links, per-source values, open
--      reconciliation exceptions, contract coverage, open activity
--      occurrences, active restrictive-use reviews, risk mappings, risk
--      links, practice dependency resolutions -> MOVE to the survivor, END
--      (would duplicate a survivor relationship or join the survivor to
--      itself), RESOLVE (duplicate review of the pair) or KEEP (stays with the
--      merged record). Blockers (fn_asset_merge_blockers): open items that
--      cannot move silently -- pending lifecycle change, open workflow case,
--      open attestation, open verification exception, pending technology
--      exception, open stale review, conflicting open occurrence or
--      restrictive review, invalid assets.
--   3. Field values: the survivor keeps its values; empty survivor values
--      are filled from the first duplicate holding one; a field choice takes
--      a duplicate value instead (user-entered value fields only).
--   4. Execution: per duplicate, the plan is applied with one outcome row per
--      object (before / after); aliases (name, ID, asset tag, serial, finance
--      number, hostname, MAC, cloud ID) are kept searchable on the survivor;
--      the duplicate is archived (status Archived through a system merge
--      rule, record Inactive, merged_into_asset_id = survivor). History rows
--      (lifecycle, installations, custody, attestations, results, renewals,
--      notifications, retired relationships) stay with the merged record.
--   5. Recovery: every outcome row is reversed where still possible (newest
--      first); the event becomes Recovered and keeps its rows.
--   6. Asset Register search also finds aliases (sp_asset_register_list).
--
-- NOT DONE HERE: split (7.4c); bulk merge jobs; merging across
--   organizations; moving history rows.
--
-- ERROR NUMBERS: 52900-52914 (the 547xx / 548xx asset ranges are full)
--   52900 organization not found          52901 asset not found
--   52902 merge event not found           52903 changed by someone else
--   52904 survivor / duplicates invalid   52905 asset in another open event
--   52906 reason required                 52907 status does not allow it
--   52908 blockers                        52909 approver not allowed
--   52910 note required                   52911 action not valid
--   52912 field choice invalid            52913 1-10 duplicates
--   52914 asset is merged
--
-- ALSO EDITED: sp_asset_register_list (429) re-issued (alias search); API
--   (AssetConfig service / controller / models), Web proxy,
--   asset-discovery.cshtml / .js (Merges tab, merge from a duplicate
--   review), docs.
-- DEPENDS ON: 002, 035, 265, 428-433, 435, 438-443.
-- Rollback: 444_asset_merge_rollback.sql (restores the 429 body of
--   sp_asset_register_list; merged assets stay merged -- recover them first).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_stale_review','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_relationship_history_add','P') IS NULL
   OR COL_LENGTH('grac_practice.asset_relationship','service_role') IS NULL
   OR OBJECT_ID('grac_practice.asset_discovery_link','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_attribute_source','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_reconciliation_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_contract_coverage','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_activity_occurrence','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_restrictive_review','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_attestation','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_verification_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_technology_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_workflow_case','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_status_phase','U') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
   OR COL_LENGTH('grac_practice.risk_register','linked_asset_id') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_register_list','P') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NULL
BEGIN
    RAISERROR('ABORT (444): run 265, 428-433, 435, 438-443 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Merged record pointer, events, members, approvals, outcomes, aliases
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.organization_dependency_asset
        ADD merged_into_asset_id BIGINT NULL
            CONSTRAINT fk_pm_org_dep_asset_merged REFERENCES grac_practice.organization_dependency_asset(asset_id);
    PRINT '444: organization_dependency_asset.merged_into_asset_id added.';
END
GO

IF OBJECT_ID('grac_practice.asset_merge_split_event','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_merge_split_event (
        event_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_amse PRIMARY KEY,
        organization_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_amse_org REFERENCES grac_practice.organization(organization_id),
        event_kind               NVARCHAR(10)   NOT NULL CONSTRAINT ck_pm_amse_kind CHECK (event_kind IN (N'MERGE', N'SPLIT')),
        survivor_asset_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_amse_survivor REFERENCES grac_practice.organization_dependency_asset(asset_id),
        status                   NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_amse_status CHECK (status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED', N'EXECUTED', N'RECOVERED',
                                                           N'REJECTED', N'CANCELLED')),
        reason                   NVARCHAR(1000) NULL,
        field_choices_json       NVARCHAR(MAX)  NULL,     -- {"fieldKey": duplicateAssetId}
        is_critical              BIT            NOT NULL CONSTRAINT df_pm_amse_crit DEFAULT 0,
        approvals_required       INT            NOT NULL CONSTRAINT df_pm_amse_appr DEFAULT 1,
        preview_json             NVARCHAR(MAX)  NULL,     -- plan counts when submitted
        requested_by             NVARCHAR(100)  NOT NULL,
        requested_by_employee_id BIGINT         NULL,
        requested_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_amse_rdt DEFAULT SYSUTCDATETIME(),
        submitted_dt             DATETIME2      NULL,
        decided_note             NVARCHAR(1000) NULL,     -- rejection / cancellation note
        executed_by              NVARCHAR(100)  NULL,
        executed_dt              DATETIME2      NULL,
        recovered_by             NVARCHAR(100)  NULL,
        recovered_dt             DATETIME2      NULL,
        recovery_reason          NVARCHAR(1000) NULL,
        closed_dt                DATETIME2      NULL,
        record_version           ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_amse_org ON grac_practice.asset_merge_split_event(organization_id, status, event_id DESC);
    PRINT '444: asset_merge_split_event created.';
END
GO

IF OBJECT_ID('grac_practice.asset_merge_split_member','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_merge_split_member (
        event_id     BIGINT       NOT NULL CONSTRAINT fk_pm_amsm_event REFERENCES grac_practice.asset_merge_split_event(event_id),
        asset_id     BIGINT       NOT NULL CONSTRAINT fk_pm_amsm_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        member_role  NVARCHAR(10) NOT NULL CONSTRAINT ck_pm_amsm_role CHECK (member_role IN (N'DUPLICATE', N'RESULT')),
        sequence_no  INT          NOT NULL,
        CONSTRAINT pk_pm_amsm PRIMARY KEY (event_id, asset_id)
    );
    CREATE INDEX ix_pm_amsm_asset ON grac_practice.asset_merge_split_member(asset_id);
    PRINT '444: asset_merge_split_member created.';
END
GO

IF OBJECT_ID('grac_practice.asset_merge_split_approval','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_merge_split_approval (
        approval_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_amsa PRIMARY KEY,
        event_id             BIGINT         NOT NULL CONSTRAINT fk_pm_amsa_event REFERENCES grac_practice.asset_merge_split_event(event_id),
        decision             NVARCHAR(10)   NOT NULL CONSTRAINT ck_pm_amsa_dec CHECK (decision IN (N'APPROVE', N'REJECT')),
        note                 NVARCHAR(1000) NULL,
        approver             NVARCHAR(100)  NOT NULL,
        approver_employee_id BIGINT         NULL,
        decided_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_amsa_dt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_amsa_event ON grac_practice.asset_merge_split_approval(event_id);
    PRINT '444: asset_merge_split_approval created.';
END
GO

IF OBJECT_ID('grac_practice.asset_merge_split_object','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_merge_split_object (
        object_row_id  BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_amso PRIMARY KEY,
        event_id       BIGINT         NOT NULL CONSTRAINT fk_pm_amso_event REFERENCES grac_practice.asset_merge_split_event(event_id),
        object_kind    NVARCHAR(20)   NOT NULL,
        object_id      BIGINT         NULL,
        object_key     NVARCHAR(200)  NULL,
        object_label   NVARCHAR(400)  NULL,
        from_asset_id  BIGINT         NOT NULL,
        to_asset_id    BIGINT         NOT NULL,
        outcome        NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_amso_outcome CHECK (outcome IN (N'MOVED', N'ENDED', N'RESOLVED', N'KEPT', N'FILLED', N'REPLACED',
                                                             N'ALIASED', N'ARCHIVED')),
        before_value   NVARCHAR(MAX)  NULL,
        after_value    NVARCHAR(MAX)  NULL,
        detail         NVARCHAR(600)  NULL,
        recovered      BIT            NOT NULL CONSTRAINT df_pm_amso_rec DEFAULT 0,
        recovery_note  NVARCHAR(400)  NULL,
        entered_dt     DATETIME2      NOT NULL CONSTRAINT df_pm_amso_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_amso_event ON grac_practice.asset_merge_split_object(event_id, object_row_id);
    PRINT '444: asset_merge_split_object created.';
END
GO

IF OBJECT_ID('grac_practice.asset_alias','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_alias (
        alias_id        BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_alias PRIMARY KEY,
        organization_id BIGINT        NOT NULL,
        asset_id        BIGINT        NOT NULL CONSTRAINT fk_pm_asset_alias_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        alias_kind      NVARCHAR(30)  NOT NULL,     -- NAME | ASSET_ID | or the dictionary field key
        alias_value     NVARCHAR(400) NOT NULL,
        source_asset_id BIGINT        NOT NULL,
        event_id        BIGINT        NOT NULL CONSTRAINT fk_pm_asset_alias_event REFERENCES grac_practice.asset_merge_split_event(event_id),
        is_active       BIT           NOT NULL CONSTRAINT df_pm_asset_alias_act DEFAULT 1,
        entered_by      NVARCHAR(100) NOT NULL,
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_asset_alias_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_alias_value ON grac_practice.asset_alias(organization_id, alias_value) INCLUDE (asset_id, is_active);
    CREATE INDEX ix_pm_asset_alias_asset ON grac_practice.asset_alias(asset_id);
    PRINT '444: asset_alias created.';
END
GO

-- =====================================================================
-- 2. System merge rules: any status -> Archived (merged record) and back
--    (recovery). Role ASSET_MERGE only and no 429 gate: they are not user
--    moves -- the Lifecycle tab, sp_asset_lifecycle_transition and the
--    matrix use role-free rules with a gate only (D119). The 429
--    verification checks 429-a / 429-b now look at role-free rules only.
-- =====================================================================
MERGE grac_practice.entity_state_transition_rule AS t
USING (
    SELECT N'Asset' AS entity_type, s.status_code AS from_status_code, N'ARCHIVED' AS to_status_code, N'ASSET_MERGE' AS actor_role_code,
           CAST(1 AS BIT) AS requires_reason, N'Merged into another asset (444)' AS description
      FROM grac_practice.entity_status_master s
     WHERE s.entity_type = N'Asset' AND s.status_code <> N'ARCHIVED'
    UNION ALL
    SELECT N'Asset', N'ARCHIVED', s.status_code, N'ASSET_MERGE', CAST(1 AS BIT), N'Merge recovered (444)'
      FROM grac_practice.entity_status_master s
     WHERE s.entity_type = N'Asset' AND s.status_code <> N'ARCHIVED'
) AS s
ON t.entity_type = s.entity_type AND t.from_status_code = s.from_status_code AND t.to_status_code = s.to_status_code
   AND t.actor_role_code = s.actor_role_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (s.entity_type, s.from_status_code, s.to_status_code, s.actor_role_code, s.requires_reason, 0, s.description, N'seed-444');
PRINT CONCAT('444: merge transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Blockers, plan, field comparison, impact (D116-D118)
-- =====================================================================
-- What stops merging @duplicate into @survivor: invalid assets, and open
-- items of the duplicate that cannot move silently (19.4 "open workflow
-- items shall be explicitly reassigned or linked") -- they are finished,
-- cancelled or withdrawn first.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_merge_blockers (@organization_id BIGINT, @survivor BIGINT, @duplicate BIGINT)
RETURNS TABLE
AS
RETURN
    WITH a AS (
        SELECT x.asset_id, x.asset_name, x.merged_into_asset_id, ISNULL(s.status_code, N'ACTIVE') AS status_code
          FROM grac_practice.organization_dependency_asset x
          LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = x.current_status_id
         WHERE x.organization_id = @organization_id AND x.asset_id IN (@survivor, @duplicate))
    SELECT CAST(N'SAME_ASSET' AS NVARCHAR(30)) AS BlockerCode,
           CAST(N'The survivor cannot also be a duplicate.' AS NVARCHAR(600)) AS Detail
     WHERE @survivor = @duplicate
    UNION ALL
    SELECT N'NOT_FOUND', CAST(CONCAT(N'Asset #', v.id, N' is not an asset of this organization.') AS NVARCHAR(600))
      FROM (VALUES (@survivor), (@duplicate)) v(id)
     WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.asset_id = v.id)
    UNION ALL
    SELECT N'NOT_IN_USE', CAST(CONCAT(a.asset_name, N' is ', LOWER(a.status_code), N' or already merged.') AS NVARCHAR(600))
      FROM a WHERE a.status_code IN (N'DISPOSED', N'ARCHIVED') OR a.merged_into_asset_id IS NOT NULL
    UNION ALL
    SELECT N'PENDING_LIFECYCLE', CAST(CONCAT(N'Lifecycle change ', c.from_status_code, N' -> ', c.to_status_code,
                                             N' awaits approval; approve, reject or cancel it.') AS NVARCHAR(600))
      FROM grac_practice.asset_lifecycle_change c WHERE c.asset_id = @duplicate AND c.change_status = N'PENDING_APPROVAL'
    UNION ALL
    SELECT N'OPEN_WORKFLOW', CAST(CONCAT(N'Workflow case #', w.case_id, N' (', w.workflow_code, N') is open; complete or cancel it.') AS NVARCHAR(600))
      FROM grac_practice.asset_workflow_case w WHERE w.asset_id = @duplicate AND w.case_status = N'OPEN'
    UNION ALL
    SELECT N'OPEN_ATTESTATION', CAST(CONCAT(N'Attestation #', t.attestation_id, N' is ', LOWER(t.status), N'; complete or cancel it.') AS NVARCHAR(600))
      FROM grac_practice.asset_attestation t
     WHERE t.asset_id = @duplicate AND t.status NOT IN (N'CONFIRMED', N'RESOLVED', N'CLOSED', N'CANCELLED')
    UNION ALL
    SELECT N'OPEN_VERIFICATION', CAST(CONCAT(N'Verification exception #', e.exception_id, N' is ', LOWER(s.status_code), N'; resolve or cancel it.') AS NVARCHAR(600))
      FROM grac_practice.asset_verification_exception e
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = e.current_status_id
     WHERE e.asset_id = @duplicate AND s.status_code NOT IN (N'RESOLVED', N'CLOSED', N'CANCELLED')
    UNION ALL
    SELECT N'PENDING_TECH_EXCEPTION', CAST(CONCAT(N'Technology exception #', x.exception_id, N' awaits approval; decide or withdraw it.') AS NVARCHAR(600))
      FROM grac_practice.asset_technology_exception x WHERE x.asset_id = @duplicate AND x.status = N'PENDING_APPROVAL'
    UNION ALL
    SELECT N'OPEN_STALE_REVIEW', CAST(N'A stale review is open; dismiss or complete it.' AS NVARCHAR(600))
      FROM grac_practice.asset_stale_review r WHERE r.asset_id = @duplicate AND r.status = N'OPEN'
    UNION ALL
    SELECT N'OCCURRENCE_CONFLICT', CAST(CONCAT(N'Both assets have an open "', o.template_code, N'" activity; complete or cancel one.') AS NVARCHAR(600))
      FROM grac_practice.asset_activity_occurrence o
     WHERE o.asset_id = @duplicate AND o.status = N'OPEN'
       AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o2
                    WHERE o2.asset_id = @survivor AND o2.template_code = o.template_code AND o2.status = N'OPEN')
    UNION ALL
    SELECT N'RESTRICTIVE_CONFLICT', CAST(CONCAT(N'Both assets have an active restrictive-use review "', rr.title, N'"; decide one.') AS NVARCHAR(600))
      FROM grac_practice.asset_restrictive_review rr
     WHERE rr.asset_id = @duplicate AND rr.status IN (N'OPEN', N'DECIDED')
       AND EXISTS (SELECT 1 FROM grac_practice.asset_restrictive_review r2
                    WHERE r2.asset_id = @survivor AND r2.status IN (N'OPEN', N'DECIDED') AND r2.source_kind = rr.source_kind
                      AND r2.source_code = rr.source_code AND r2.trigger_code = rr.trigger_code);
GO

-- The plan for one duplicate: every object that refers to it and what an
-- execution does with it now (preview and execution read the same rows).
--   MOVE     repointed to the survivor
--   END      relationship retired: it would join the survivor to itself or
--            duplicate a current survivor relationship
--   RESOLVE  open duplicate review of the survivor / duplicate pair closed
--   KEEP     stays with the merged record (the survivor already holds the
--            equivalent, or it belongs to a closed contract version)
CREATE OR ALTER FUNCTION grac_practice.fn_asset_merge_plan (@organization_id BIGINT, @survivor BIGINT, @duplicate BIGINT)
RETURNS TABLE
AS
RETURN
    -- relationships (5.4): new endpoints computed first
    SELECT CAST(N'RELATIONSHIP' AS NVARCHAR(20)) AS ObjectKind, r.relationship_id AS ObjectId,
           CAST(NULL AS NVARCHAR(200)) AS ObjectKey,
           CAST(CONCAT(t.type_name, N': ', CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @duplicate THEN N'(this asset)'
                                                ELSE ISNULL(cs.CiName, CONCAT(r.source_kind, N' #', r.source_id)) END,
                       N' -> ', CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @duplicate THEN N'(this asset)'
                                     ELSE ISNULL(ct.CiName, CONCAT(r.target_kind, N' #', r.target_id)) END) AS NVARCHAR(400)) AS ObjectLabel,
           CAST(CASE WHEN n.ns_kind = N'ASSET' AND n.ns_id = @survivor AND n.nt_kind = N'ASSET' AND n.nt_id = @survivor THEN N'END'
                     WHEN EXISTS (SELECT 1 FROM grac_practice.asset_relationship q
                                   WHERE q.organization_id = r.organization_id AND q.relationship_id <> r.relationship_id
                                     AND q.relationship_type_code = r.relationship_type_code AND q.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                                     AND q.source_kind = n.ns_kind AND q.source_id = n.ns_id AND q.target_kind = n.nt_kind AND q.target_id = n.nt_id)
                          THEN N'END' ELSE N'MOVE' END AS NVARCHAR(10)) AS Outcome,
           CAST(CONCAT(LOWER(r.status), CASE WHEN r.is_critical = 1 THEN N', critical' ELSE N'' END,
                       CASE WHEN n.ns_kind = N'ASSET' AND n.ns_id = @survivor AND n.nt_kind = N'ASSET' AND n.nt_id = @survivor
                            THEN N' (joins the two merged assets)' ELSE N'' END) AS NVARCHAR(600)) AS Detail,
           CAST(N'Relationships and services' AS NVARCHAR(40)) AS Domain
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
     CROSS APPLY (SELECT CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @duplicate THEN N'ASSET' ELSE r.source_kind END AS ns_kind,
                         CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @duplicate THEN @survivor ELSE r.source_id END AS ns_id,
                         CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @duplicate THEN N'ASSET' ELSE r.target_kind END AS nt_kind,
                         CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @duplicate THEN @survivor ELSE r.target_id END AS nt_id) n
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) cs ON cs.CiKind = r.source_kind AND cs.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) ct ON ct.CiKind = r.target_kind AND ct.CiId = r.target_id
     WHERE r.organization_id = @organization_id AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
       AND ((r.source_kind = N'ASSET' AND r.source_id = @duplicate) OR (r.target_kind = N'ASSET' AND r.target_id = @duplicate))
    UNION ALL
    -- discovery source links (442)
    SELECT N'DISCOVERY_LINK', l.link_id, l.external_key, CAST(CONCAT(s.source_name, N': ', l.external_key) AS NVARCHAR(400)),
           N'MOVE', CAST(CONCAT(N'last seen ', CONVERT(NVARCHAR(16), l.last_seen_dt, 120)) AS NVARCHAR(600)), N'Discovery and integrations'
      FROM grac_practice.asset_discovery_link l
      JOIN grac_practice.asset_discovery_source s ON s.source_id = l.source_id
     WHERE l.asset_id = @duplicate
    UNION ALL
    -- values reported per source (442)
    SELECT N'ATTRIBUTE_SOURCE', x.source_id, x.field_key, CAST(CONCAT(s.source_name, N': ', x.field_key) AS NVARCHAR(400)),
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_attribute_source y
                              WHERE y.asset_id = @survivor AND y.field_key = x.field_key AND y.source_id = x.source_id)
                THEN N'KEEP' ELSE N'MOVE' END,
           CAST(LEFT(x.observed_value, 400) AS NVARCHAR(600)), N'Discovery and integrations'
      FROM grac_practice.asset_attribute_source x
      JOIN grac_practice.asset_discovery_source s ON s.source_id = x.source_id
     WHERE x.asset_id = @duplicate
    UNION ALL
    -- open reconciliation exceptions (442)
    SELECT N'RECON_EXCEPTION', e.exception_id, NULL,
           CAST(CONCAT(e.exception_kind, CASE WHEN e.field_key IS NULL THEN N'' ELSE N' - ' + e.field_key END) AS NVARCHAR(400)),
           CASE WHEN e.exception_kind = N'DUPLICATE'
                 AND ((e.asset_id = @duplicate AND e.other_asset_id = @survivor) OR (e.asset_id = @survivor AND e.other_asset_id = @duplicate))
                THEN N'RESOLVE' ELSE N'MOVE' END,
           CAST(N'open' AS NVARCHAR(600)), N'Tasks and open items'
      FROM grac_practice.asset_reconciliation_exception e
     WHERE e.organization_id = @organization_id AND e.status = N'OPEN' AND (e.asset_id = @duplicate OR e.other_asset_id = @duplicate)
    UNION ALL
    -- contract coverage (435): lines of contract versions still in force or in preparation move
    SELECT N'COVERAGE', cv.coverage_id, cv.coverage_type,
           CAST(CONCAT(k.contract_number, N' ', k.contract_name, N' v', v.version_no, N' - ', cv.coverage_type) AS NVARCHAR(400)),
           CASE WHEN vs.status_code NOT IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL', N'APPROVED', N'ACTIVE') THEN N'KEEP'
                WHEN EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage c2
                              WHERE c2.version_id = cv.version_id AND c2.asset_id = @survivor AND c2.coverage_type = cv.coverage_type)
                THEN N'KEEP' ELSE N'MOVE' END,
           CAST(CONCAT(LOWER(vs.status_code), N' version, ', LOWER(cv.coverage_state)) AS NVARCHAR(600)), N'Contracts'
      FROM grac_practice.asset_contract_coverage cv
      JOIN grac_practice.asset_contract_version v ON v.version_id = cv.version_id
      JOIN grac_practice.entity_status_master vs ON vs.entity_status_id = v.current_status_id
      JOIN grac_practice.asset_contract k ON k.contract_id = cv.contract_id
     WHERE cv.asset_id = @duplicate AND k.organization_id = @organization_id
    UNION ALL
    -- open activity occurrences (438) -- their Task Centre tasks follow
    SELECT N'OCCURRENCE', o.occurrence_id, o.template_code,
           CAST(CONCAT(tp.template_name, N' due ', CONVERT(NVARCHAR(10), o.due_date, 23)) AS NVARCHAR(400)),
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o2
                              WHERE o2.asset_id = @survivor AND o2.template_code = o.template_code AND o2.status = N'OPEN')
                THEN N'BLOCK' ELSE N'MOVE' END,
           CAST(CASE WHEN o.task_id IS NULL THEN N'open' ELSE CONCAT(N'open, task #', o.task_id) END AS NVARCHAR(600)), N'Tasks and open items'
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = o.template_code
     WHERE o.asset_id = @duplicate AND o.status = N'OPEN' AND o.organization_id = @organization_id
    UNION ALL
    -- active restrictive-use reviews (439)
    SELECT N'RESTRICTIVE_REVIEW', rr.review_id, rr.review_key, CAST(rr.title AS NVARCHAR(400)),
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_restrictive_review r2
                              WHERE r2.asset_id = @survivor AND r2.status IN (N'OPEN', N'DECIDED') AND r2.source_kind = rr.source_kind
                                AND r2.source_code = rr.source_code AND r2.trigger_code = rr.trigger_code)
                THEN N'BLOCK' ELSE N'MOVE' END,
           CAST(LOWER(rr.status) AS NVARCHAR(600)), N'Tasks and open items'
      FROM grac_practice.asset_restrictive_review rr
     WHERE rr.asset_id = @duplicate AND rr.status IN (N'OPEN', N'DECIDED') AND rr.organization_id = @organization_id
    UNION ALL
    -- risk dependency mappings, category Asset (265)
    SELECT N'RISK_MAP', m.risk_dependency_map_id, NULL, CAST(CONCAT(r.risk_number, N' ', r.risk_title) AS NVARCHAR(400)),
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map m2
                              WHERE m2.risk_register_id = m.risk_register_id AND m2.dependency_type_id = m.dependency_type_id
                                AND m2.dependency_object_id = @survivor)
                THEN N'KEEP' ELSE N'MOVE' END,
           CAST(CONCAT(N'risk status ', r.status_code) AS NVARCHAR(600)), N'Risks'
      FROM grac_practice.risk_dependency_map m
      JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                  AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
      JOIN grac_practice.risk_register r ON r.risk_register_id = m.risk_register_id
     WHERE m.dependency_object_id = @duplicate AND m.organization_id = @organization_id
    UNION ALL
    -- risks whose linked asset is the duplicate (205)
    SELECT N'RISK_LINK', r.risk_register_id, NULL, CAST(CONCAT(r.risk_number, N' ', r.risk_title) AS NVARCHAR(400)), N'MOVE',
           CAST(CONCAT(N'risk status ', r.status_code) AS NVARCHAR(600)), N'Risks'
      FROM grac_practice.risk_register r
     WHERE r.linked_asset_id = @duplicate AND r.organization_id = @organization_id
    UNION ALL
    -- practice dependency resolutions, category Asset (002 Operationalize)
    SELECT N'PRACTICE_RESOLUTION', p.resolution_id, NULL,
           CAST(CONCAT(N'Practice instance #', p.practice_instance_id, N' - ', p.resolved_dependency_name) AS NVARCHAR(400)),
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.practice_dependency_resolution p2
                              WHERE p2.organization_id = p.organization_id AND p2.practice_instance_id = p.practice_instance_id
                                AND p2.dependency_type_id = p.dependency_type_id AND p2.resolved_dependency_id = @survivor)
                THEN N'KEEP' ELSE N'MOVE' END,
           CAST(p.resolution_status AS NVARCHAR(600)), N'Practices and obligations'
      FROM grac_practice.practice_dependency_resolution p
      JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = p.dependency_type_id
                                                  AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
     WHERE p.resolved_dependency_id = @duplicate AND p.organization_id = @organization_id;
GO

-- Field comparison of one duplicate with the survivor (value fields; user-
-- entered types only are mergeable). Make / model show their names.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_merge_fields (@survivor BIGINT, @duplicate BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT f.field_key AS FieldKey, f.display_label AS FieldLabel, f.data_type_code AS DataTypeCode,
           sv.value_text AS SurvivorValue, dv.value_text AS DuplicateValue,
           CAST(COALESCE(sm.make_name, so.model_name, LEFT(sv.value_text, 400)) AS NVARCHAR(400)) AS SurvivorDisplay,
           CAST(COALESCE(dm.make_name, dd.model_name, LEFT(dv.value_text, 400)) AS NVARCHAR(400)) AS DuplicateDisplay,
           CAST(CASE WHEN dt.is_user_entered = 1 AND f.is_system_field = 0 THEN 1 ELSE 0 END AS BIT) AS IsMergeable,
           CAST(CASE WHEN sv.value_text IS NULL THEN 0 WHEN dv.value_text IS NULL THEN 0
                     WHEN sv.value_text = dv.value_text THEN 0 ELSE 1 END AS BIT) AS IsDifferent
      FROM grac_practice.asset_field_definition f
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code
      LEFT JOIN grac_practice.asset_field_value sv ON sv.asset_id = @survivor AND sv.field_definition_id = f.field_definition_id
      LEFT JOIN grac_practice.asset_field_value dv ON dv.asset_id = @duplicate AND dv.field_definition_id = f.field_definition_id
      LEFT JOIN grac_practice.asset_make sm ON f.data_type_code = N'MAKE' AND sm.make_id = TRY_CONVERT(INT, sv.value_text)
      LEFT JOIN grac_practice.asset_model so ON f.data_type_code = N'MODEL' AND so.model_id = TRY_CONVERT(BIGINT, sv.value_text)
      LEFT JOIN grac_practice.asset_make dm ON f.data_type_code = N'MAKE' AND dm.make_id = TRY_CONVERT(INT, dv.value_text)
      LEFT JOIN grac_practice.asset_model dd ON f.data_type_code = N'MODEL' AND dd.model_id = TRY_CONVERT(BIGINT, dv.value_text)
     WHERE f.storage_kind = N'VALUE' AND (sv.asset_id IS NOT NULL OR dv.asset_id IS NOT NULL);
GO

-- Impact per asset (19.4 impact analysis): what refers to it, by domain --
-- what moves (plan) and what stays as history with the merged record.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_merge_impact (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(N'Business services supported' AS NVARCHAR(60)) AS ImpactItem,
           (SELECT COUNT(*) FROM grac_practice.asset_relationship r
             WHERE r.organization_id = @organization_id AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
               AND ((r.source_kind = N'ASSET' AND r.source_id = @asset_id AND r.target_kind = N'SERVICE')
                    OR (r.target_kind = N'ASSET' AND r.target_id = @asset_id AND r.source_kind = N'SERVICE'))) AS ItemCount, 10 AS SortOrder
    UNION ALL SELECT N'Current relationships', (SELECT COUNT(*) FROM grac_practice.asset_relationship r
             WHERE r.organization_id = @organization_id AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
               AND ((r.source_kind = N'ASSET' AND r.source_id = @asset_id) OR (r.target_kind = N'ASSET' AND r.target_id = @asset_id))), 20
    UNION ALL SELECT N'Contract coverage lines', (SELECT COUNT(*) FROM grac_practice.asset_contract_coverage c WHERE c.asset_id = @asset_id), 30
    UNION ALL SELECT N'Risks (mapped or linked)', (SELECT COUNT(*) FROM grac_practice.risk_dependency_map m
              JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                          AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
             WHERE m.dependency_object_id = @asset_id AND m.organization_id = @organization_id)
            + (SELECT COUNT(*) FROM grac_practice.risk_register r WHERE r.linked_asset_id = @asset_id AND r.organization_id = @organization_id), 40
    UNION ALL SELECT N'Attestations', (SELECT COUNT(*) FROM grac_practice.asset_attestation t WHERE t.asset_id = @asset_id), 50
    UNION ALL SELECT N'Open tasks (activities, reconciliation)',
            (SELECT COUNT(*) FROM grac_practice.asset_activity_occurrence o WHERE o.asset_id = @asset_id AND o.status = N'OPEN' AND o.task_id IS NOT NULL)
            + (SELECT COUNT(*) FROM grac_practice.asset_reconciliation_exception e
                WHERE (e.asset_id = @asset_id OR e.other_asset_id = @asset_id) AND e.status = N'OPEN' AND e.task_id IS NOT NULL), 60
    UNION ALL SELECT N'Practice dependency resolutions', (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution p
              JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = p.dependency_type_id
                                                          AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
             WHERE p.resolved_dependency_id = @asset_id AND p.organization_id = @organization_id), 70
    UNION ALL SELECT N'Discovery source records (integrations)', (SELECT COUNT(*) FROM grac_practice.asset_discovery_link l WHERE l.asset_id = @asset_id), 80
    UNION ALL SELECT N'History kept: lifecycle changes', (SELECT COUNT(*) FROM grac_practice.asset_lifecycle_change c WHERE c.asset_id = @asset_id), 90
    UNION ALL SELECT N'History kept: custody records', (SELECT COUNT(*) FROM grac_practice.asset_assignment_history h WHERE h.asset_id = @asset_id), 91
    UNION ALL SELECT N'History kept: completed activities', (SELECT COUNT(*) FROM grac_practice.asset_activity_occurrence o
                                                               WHERE o.asset_id = @asset_id AND o.status <> N'OPEN'), 92
    UNION ALL SELECT N'History kept: workflow cases', (SELECT COUNT(*) FROM grac_practice.asset_workflow_case w WHERE w.asset_id = @asset_id), 93;
GO
PRINT '444: merge blockers, plan, fields and impact functions created.';
GO

-- =====================================================================
-- 4. Merge event writers (D115, D120)
-- =====================================================================
-- Critical CI (19.4 two-person control): the survivor or a duplicate has
-- criticality Critical, or a current critical relationship relies on it.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_merge_critical (@organization_id BIGINT, @event_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT CAST(CASE WHEN EXISTS (
                SELECT 1
                  FROM (SELECT survivor_asset_id AS asset_id FROM grac_practice.asset_merge_split_event WHERE event_id = @event_id
                        UNION SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id) m
                  JOIN grac_practice.organization_dependency_asset a ON a.asset_id = m.asset_id
                  LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
                 WHERE c.criticality_code = N'Critical'
                    OR EXISTS (SELECT 1 FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1) e
                                WHERE e.ProviderKind = N'ASSET' AND e.ProviderId = m.asset_id AND e.IsCritical = 1))
                THEN 1 ELSE 0 END AS BIT) AS IsCritical;
GO

-- New or changed Draft: survivor, duplicates (JSON array of asset ids,
-- 1-10), reason, field choices ({"fieldKey": duplicateAssetId}).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_save
    @organization_id         BIGINT,
    @event_id                BIGINT         = NULL,
    @survivor_asset_id       BIGINT,
    @duplicates_json         NVARCHAR(MAX),
    @reason                  NVARCHAR(1000) = NULL,
    @field_choices_json      NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    SET @field_choices_json = NULLIF(LTRIM(RTRIM(@field_choices_json)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 52900, 'Organization not found.', 1;
    IF @event_id IS NOT NULL
    BEGIN
        DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT;
        SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version)
          FROM grac_practice.asset_merge_split_event
         WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'MERGE';
        IF @found = 0 THROW 52902, 'Merge not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 52903, 'The merge was changed by someone else; reload it and try again.', 1;
        IF @status <> N'DRAFT' THROW 52907, 'Only a draft merge can be changed.', 1;
    END

    DECLARE @dups TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, seq INT NOT NULL);
    IF ISJSON(ISNULL(@duplicates_json, N'')) = 1
        INSERT @dups (asset_id, seq)
        SELECT d.asset_id, ROW_NUMBER() OVER (ORDER BY MIN(d.ord))
          FROM (SELECT TRY_CONVERT(BIGINT, j.[value]) AS asset_id, CAST(j.[key] AS INT) AS ord FROM OPENJSON(@duplicates_json) j) d
         WHERE d.asset_id IS NOT NULL
         GROUP BY d.asset_id;
    IF (SELECT COUNT(*) FROM @dups) NOT BETWEEN 1 AND 10
        THROW 52913, 'Choose 1 to 10 duplicate assets.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @survivor_asset_id AND organization_id = @organization_id)
       OR EXISTS (SELECT 1 FROM @dups d WHERE NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                                                           WHERE a.asset_id = d.asset_id AND a.organization_id = @organization_id))
        THROW 52901, 'Asset not found for this organization.', 1;
    IF EXISTS (SELECT 1 FROM @dups WHERE asset_id = @survivor_asset_id)
       OR EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                    LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                   WHERE (a.asset_id = @survivor_asset_id OR a.asset_id IN (SELECT asset_id FROM @dups))
                     AND (a.merged_into_asset_id IS NOT NULL OR ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED')))
        THROW 52904, 'The survivor and the duplicates must be different assets in use (not disposed, archived or merged).', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_event e
                WHERE e.organization_id = @organization_id AND e.status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED')
                  AND e.event_id <> ISNULL(@event_id, -1)
                  AND (e.survivor_asset_id = @survivor_asset_id OR e.survivor_asset_id IN (SELECT asset_id FROM @dups)
                       OR EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_member m
                                   WHERE m.event_id = e.event_id
                                     AND (m.asset_id = @survivor_asset_id OR m.asset_id IN (SELECT asset_id FROM @dups)))))
        THROW 52905, 'One of these assets is already in another open merge or split; finish or cancel it first.', 1;
    -- Field choices: mergeable value fields, each naming a duplicate that holds a value.
    IF @field_choices_json IS NOT NULL
    BEGIN
        IF ISJSON(@field_choices_json) = 0 OR LEFT(@field_choices_json, 1) <> N'{'
            THROW 52912, 'The field choices are not valid.', 1;
        IF EXISTS (SELECT 1 FROM OPENJSON(@field_choices_json) j
                    LEFT JOIN grac_practice.asset_field_definition f ON f.field_key = j.[key] COLLATE DATABASE_DEFAULT AND f.storage_kind = N'VALUE'
                                                                     AND f.is_system_field = 0
                    LEFT JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code AND dt.is_user_entered = 1
                    LEFT JOIN @dups d ON d.asset_id = TRY_CONVERT(BIGINT, j.[value])
                    LEFT JOIN grac_practice.asset_field_value v ON v.asset_id = d.asset_id AND v.field_definition_id = f.field_definition_id
                   WHERE dt.data_type_code IS NULL OR d.asset_id IS NULL OR v.asset_id IS NULL)
            THROW 52912, 'Each field choice names a user-entered value field and a duplicate that holds a value for it.', 1;
    END

    DECLARE @id BIGINT = @event_id, @result NVARCHAR(20) = CASE WHEN @event_id IS NULL THEN N'CREATED' ELSE N'SAVED' END;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        INSERT grac_practice.asset_merge_split_event
            (organization_id, event_kind, survivor_asset_id, status, reason, field_choices_json, requested_by, requested_by_employee_id)
        VALUES (@organization_id, N'MERGE', @survivor_asset_id, N'DRAFT', @reason, @field_choices_json, @actor, @actor_employee_id);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_merge_split_event
           SET survivor_asset_id = @survivor_asset_id, reason = @reason, field_choices_json = @field_choices_json
         WHERE event_id = @id;
        DELETE FROM grac_practice.asset_merge_split_member WHERE event_id = @id;
    END
    INSERT grac_practice.asset_merge_split_member (event_id, asset_id, member_role, sequence_no)
    SELECT @id, asset_id, N'DUPLICATE', seq FROM @dups;
    UPDATE e
       SET is_critical = c.IsCritical, approvals_required = CASE WHEN c.IsCritical = 1 THEN 2 ELSE 1 END
      FROM grac_practice.asset_merge_split_event e
     CROSS APPLY grac_practice.fn_asset_merge_critical(@organization_id, @id) c
     WHERE e.event_id = @id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-merge', @id, CASE WHEN @event_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, NULL,
            (SELECT @survivor_asset_id AS survivorAssetId, JSON_QUERY(@duplicates_json) AS duplicates, @reason AS reason,
                    JSON_QUERY(@field_choices_json) AS fieldChoices FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS EventId, @result AS Result;
END
GO

-- =====================================================================
-- 5. Execution of one duplicate (internal; called inside the EXECUTE
--    transaction of sp_asset_merge_action). Outcome rows first, then the
--    change, so every row carries its before / after values.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_execute_one
    @organization_id    BIGINT,
    @event_id           BIGINT,
    @survivor           BIGINT,
    @duplicate          BIGINT,
    @field_choices_json NVARCHAR(MAX)  = NULL,
    @actor_employee_id  BIGINT         = NULL,
    @actor              NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @plan TABLE (object_kind NVARCHAR(20) NOT NULL, object_id BIGINT NULL, object_key NVARCHAR(200) NULL,
                         object_label NVARCHAR(400) NULL, outcome NVARCHAR(10) NOT NULL, detail NVARCHAR(600) NULL);
    INSERT @plan (object_kind, object_id, object_key, object_label, outcome, detail)
    SELECT ObjectKind, ObjectId, ObjectKey, ObjectLabel, Outcome, Detail
      FROM grac_practice.fn_asset_merge_plan(@organization_id, @survivor, @duplicate);
    IF EXISTS (SELECT 1 FROM @plan WHERE outcome = N'BLOCK')
       OR EXISTS (SELECT 1 FROM grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, @duplicate))
        THROW 52908, 'The merge has blockers; open it to see them.', 1;
    DECLARE @survivor_name NVARCHAR(300) = (SELECT asset_name FROM grac_practice.organization_dependency_asset WHERE asset_id = @survivor);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE), @note NVARCHAR(400) = CONCAT(N'Merge #', @event_id, N': asset #', @duplicate,
                                                                                    N' merged into #', @survivor, N'.');

    -- ---------------------------------------------------------- relationships
    DECLARE @rid BIGINT, @rout NVARCHAR(10);
    DECLARE rel_cur CURSOR LOCAL STATIC FOR
        SELECT object_id, outcome FROM @plan WHERE object_kind = N'RELATIONSHIP' ORDER BY object_id;
    OPEN rel_cur;
    FETCH NEXT FROM rel_cur INTO @rid, @rout;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rout = N'MOVE'
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @duplicate, @survivor, N'MOVED',
                   (SELECT r.source_id AS sourceId, r.target_id AS targetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   (SELECT CASE WHEN r.source_kind = N'ASSET' AND r.source_id = @duplicate THEN @survivor ELSE r.source_id END AS sourceId,
                           CASE WHEN r.target_kind = N'ASSET' AND r.target_id = @duplicate THEN @survivor ELSE r.target_id END AS targetId
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
              FROM grac_practice.asset_relationship r JOIN @plan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
             WHERE r.relationship_id = @rid;
            UPDATE grac_practice.asset_relationship
               SET source_id = CASE WHEN source_kind = N'ASSET' AND source_id = @duplicate THEN @survivor ELSE source_id END,
                   target_id = CASE WHEN target_kind = N'ASSET' AND target_id = @duplicate THEN @survivor ELSE target_id END,
                   version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @rid;
            EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'MERGE_MOVE', @note = @note,
                 @actor = @actor, @actor_employee_id = @actor_employee_id;
        END
        ELSE
        BEGIN
            INSERT grac_practice.asset_merge_split_object
                (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
            SELECT @event_id, N'RELATIONSHIP', r.relationship_id, p.object_label, @duplicate, @survivor, N'ENDED',
                   (SELECT r.status AS status, r.effective_to AS effectiveTo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                   N'{"status":"RETIRED"}', p.detail
              FROM grac_practice.asset_relationship r JOIN @plan p ON p.object_kind = N'RELATIONSHIP' AND p.object_id = r.relationship_id
             WHERE r.relationship_id = @rid;
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', effective_to = CASE WHEN @today < effective_from THEN effective_from ELSE @today END,
                   status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @rid;
            EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'MERGE_END', @note = @note,
                 @actor = @actor, @actor_employee_id = @actor_employee_id;
        END
        FETCH NEXT FROM rel_cur INTO @rid, @rout;
    END
    CLOSE rel_cur;
    DEALLOCATE rel_cur;

    -- ---------------------------------------------------------- discovery links and per-source values
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'DISCOVERY_LINK', p.object_id, p.object_key, p.object_label, @duplicate, @survivor, N'MOVED', p.detail
      FROM @plan p WHERE p.object_kind = N'DISCOVERY_LINK';
    UPDATE l SET asset_id = @survivor
      FROM grac_practice.asset_discovery_link l JOIN @plan p ON p.object_kind = N'DISCOVERY_LINK' AND p.object_id = l.link_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'ATTRIBUTE_SOURCE', p.object_id, p.object_key, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM @plan p WHERE p.object_kind = N'ATTRIBUTE_SOURCE';
    UPDATE x SET asset_id = @survivor
      FROM grac_practice.asset_attribute_source x
      JOIN @plan p ON p.object_kind = N'ATTRIBUTE_SOURCE' AND p.outcome = N'MOVE' AND p.object_id = x.source_id AND p.object_key = x.field_key
     WHERE x.asset_id = @duplicate;

    -- ---------------------------------------------------------- open reconciliation exceptions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, detail)
    SELECT @event_id, N'RECON_EXCEPTION', e.exception_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'RESOLVE' THEN N'RESOLVED' ELSE N'MOVED' END,
           (SELECT e.asset_id AS assetId, e.other_asset_id AS otherAssetId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), p.detail
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.object_id = e.exception_id;
    UPDATE e
       SET status = N'RESOLVED', resolution = N'MERGED', resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'RESOLVE'
                                                                      AND p.object_id = e.exception_id;
    UPDATE e
       SET asset_id = CASE WHEN e.asset_id = @duplicate THEN @survivor ELSE e.asset_id END,
           other_asset_id = CASE WHEN e.other_asset_id = @duplicate THEN @survivor ELSE e.other_asset_id END,
           updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_reconciliation_exception e JOIN @plan p ON p.object_kind = N'RECON_EXCEPTION' AND p.outcome = N'MOVE'
                                                                      AND p.object_id = e.exception_id;

    -- ---------------------------------------------------------- coverage, occurrences, restrictive reviews
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, p.object_kind, p.object_id, p.object_key, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, p.detail
      FROM @plan p WHERE p.object_kind IN (N'COVERAGE', N'OCCURRENCE', N'RESTRICTIVE_REVIEW');
    UPDATE c SET asset_id = @survivor
      FROM grac_practice.asset_contract_coverage c JOIN @plan p ON p.object_kind = N'COVERAGE' AND p.outcome = N'MOVE' AND p.object_id = c.coverage_id;
    UPDATE o SET asset_id = @survivor, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o JOIN @plan p ON p.object_kind = N'OCCURRENCE' AND p.outcome = N'MOVE' AND p.object_id = o.occurrence_id;
    UPDATE r SET asset_id = @survivor
      FROM grac_practice.asset_restrictive_review r JOIN @plan p ON p.object_kind = N'RESTRICTIVE_REVIEW' AND p.outcome = N'MOVE' AND p.object_id = r.review_id;

    -- ---------------------------------------------------------- risks and practice resolutions
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'RISK_MAP', m.risk_dependency_map_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, m.dependency_object_name,
           CASE p.outcome WHEN N'MOVE' THEN @survivor_name END, p.detail
      FROM grac_practice.risk_dependency_map m JOIN @plan p ON p.object_kind = N'RISK_MAP' AND p.object_id = m.risk_dependency_map_id;
    UPDATE m SET dependency_object_id = @survivor, dependency_object_name = @survivor_name, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.risk_dependency_map m JOIN @plan p ON p.object_kind = N'RISK_MAP' AND p.outcome = N'MOVE' AND p.object_id = m.risk_dependency_map_id;

    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, detail)
    SELECT @event_id, N'RISK_LINK', p.object_id, p.object_label, @duplicate, @survivor, N'MOVED', p.detail
      FROM @plan p WHERE p.object_kind = N'RISK_LINK';
    UPDATE r SET linked_asset_id = @survivor
      FROM grac_practice.risk_register r JOIN @plan p ON p.object_kind = N'RISK_LINK' AND p.object_id = r.risk_register_id;

    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value, detail)
    SELECT @event_id, N'PRACTICE_RESOLUTION', d.resolution_id, p.object_label, @duplicate, @survivor,
           CASE p.outcome WHEN N'MOVE' THEN N'MOVED' ELSE N'KEPT' END, d.resolved_dependency_name,
           CASE p.outcome WHEN N'MOVE' THEN LEFT(@survivor_name, 300) END, p.detail
      FROM grac_practice.practice_dependency_resolution d JOIN @plan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.object_id = d.resolution_id;
    UPDATE d SET resolved_dependency_id = @survivor, resolved_dependency_name = LEFT(@survivor_name, 300), updated_by = @actor,
                 updated_dt = SYSUTCDATETIME()
      FROM grac_practice.practice_dependency_resolution d JOIN @plan p ON p.object_kind = N'PRACTICE_RESOLUTION' AND p.outcome = N'MOVE'
                                                                     AND p.object_id = d.resolution_id;

    -- ---------------------------------------------------------- field values (D117)
    -- Filled: the survivor has no value and no choice names another duplicate;
    -- replaced: a field choice names this duplicate.
    DECLARE @fv TABLE (field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL, label NVARCHAR(200) NULL,
                       before_text NVARCHAR(MAX) NULL, after_text NVARCHAR(MAX) NOT NULL, outcome NVARCHAR(10) NOT NULL);
    INSERT @fv (field_definition_id, field_key, label, before_text, after_text, outcome)
    SELECT f.field_definition_id, f.field_key, f.display_label, sv.value_text, dv.value_text,
           CASE WHEN sv.asset_id IS NULL THEN N'FILLED' ELSE N'REPLACED' END
      FROM grac_practice.asset_field_value dv
      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = dv.field_definition_id AND f.storage_kind = N'VALUE'
                                                 AND f.is_system_field = 0
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = f.data_type_code AND dt.is_user_entered = 1
      LEFT JOIN grac_practice.asset_field_value sv ON sv.asset_id = @survivor AND sv.field_definition_id = dv.field_definition_id
      OUTER APPLY (SELECT TOP 1 TRY_CONVERT(BIGINT, j.[value]) AS chosen FROM OPENJSON(ISNULL(@field_choices_json, N'{}')) j
                    WHERE j.[key] COLLATE DATABASE_DEFAULT = f.field_key) ch
     WHERE dv.asset_id = @duplicate
       AND ((ch.chosen = @duplicate AND ISNULL(sv.value_text, N'') <> dv.value_text)
            OR (ch.chosen IS NULL AND sv.asset_id IS NULL));
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value)
    SELECT @event_id, N'FIELD', field_definition_id, field_key, label, @duplicate, @survivor, outcome, before_text, after_text FROM @fv;
    MERGE grac_practice.asset_field_value AS t
    USING (SELECT dv.field_definition_id, dv.value_text, dv.value_number, dv.value_date, dv.value_ref
             FROM grac_practice.asset_field_value dv JOIN @fv x ON x.field_definition_id = dv.field_definition_id
            WHERE dv.asset_id = @duplicate) AS s
       ON t.asset_id = @survivor AND t.field_definition_id = s.field_definition_id
    WHEN MATCHED THEN UPDATE SET value_text = s.value_text, value_number = s.value_number, value_date = s.value_date, value_ref = s.value_ref,
                                 updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
                          VALUES (@survivor, s.field_definition_id, s.value_text, s.value_number, s.value_date, s.value_ref, @actor);

    -- ---------------------------------------------------------- aliases (D118)
    DECLARE @al TABLE (alias_id BIGINT NOT NULL, alias_kind NVARCHAR(30) NOT NULL, alias_value NVARCHAR(400) NOT NULL);
    INSERT grac_practice.asset_alias (organization_id, asset_id, alias_kind, alias_value, source_asset_id, event_id, entered_by)
    OUTPUT inserted.alias_id, inserted.alias_kind, inserted.alias_value INTO @al (alias_id, alias_kind, alias_value)
    SELECT @organization_id, @survivor, k.kind, k.val, @duplicate, @event_id, @actor
      FROM (SELECT N'NAME' AS kind, CAST(a.asset_name AS NVARCHAR(400)) AS val
              FROM grac_practice.organization_dependency_asset a WHERE a.asset_id = @duplicate
            UNION ALL
            SELECT N'ASSET_ID', CAST(CONCAT(N'#', @duplicate) AS NVARCHAR(400))
            UNION ALL
            SELECT f.field_key, CAST(LEFT(v.value_text, 400) AS NVARCHAR(400))
              FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
             WHERE v.asset_id = @duplicate
               AND f.field_key IN (N'asset_tag', N'serial_number', N'finance_asset_number', N'hostname', N'mac_address', N'cloud_resource_identifier')) k
     WHERE k.val IS NOT NULL AND LTRIM(RTRIM(k.val)) <> N''
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value sv
                        JOIN grac_practice.asset_field_definition sf ON sf.field_definition_id = sv.field_definition_id
                       WHERE sv.asset_id = @survivor AND sf.field_key = k.kind AND sv.value_text = k.val)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_alias x
                        WHERE x.asset_id = @survivor AND x.alias_kind = k.kind AND x.alias_value = k.val AND x.is_active = 1);
    INSERT grac_practice.asset_merge_split_object (event_id, object_kind, object_id, object_key, object_label, from_asset_id, to_asset_id, outcome, after_value)
    SELECT @event_id, N'ALIAS', alias_id, alias_kind, CONCAT(alias_kind, N': ', alias_value), @duplicate, @survivor, N'ALIASED', alias_value FROM @al;

    -- ---------------------------------------------------------- the merged record (D119)
    DECLARE @from NVARCHAR(60), @from_id INT, @rs INT, @st NVARCHAR(30), @legacy NVARCHAR(30), @to_id INT, @log BIGINT;
    SELECT @from = COALESCE(cs.status_code, ls.status_code), @from_id = a.current_status_id, @rs = a.record_status_id, @st = a.status,
           @legacy = a.lifecycle_status
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @duplicate;
    INSERT grac_practice.asset_merge_split_object
        (event_id, object_kind, object_id, object_label, from_asset_id, to_asset_id, outcome, before_value, after_value)
    VALUES (@event_id, N'ASSET_RECORD', @duplicate, CONCAT(N'Asset #', @duplicate), @duplicate, @survivor, N'ARCHIVED',
            (SELECT @from AS statusCode, @st AS status, @rs AS recordStatusId, @legacy AS lifecycleStatus FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'{"statusCode":"ARCHIVED"}');
    DECLARE @reason_text NVARCHAR(1000) = CONCAT(N'Merged into asset #', @survivor, N' (merge #', @event_id, N').');
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'Asset', @entity_id = @duplicate, @from_status_code = @from, @to_status_code = N'ARCHIVED',
         @actor_employee_id = @actor_employee_id, @actor_role_code = N'ASSET_MERGE', @reason_code = N'MERGED', @reason_text = @reason_text,
         @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
    DECLARE @inactive_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                                 WHERE status_code = N'Inactive' OR status_name = N'Inactive' ORDER BY record_status_id);
    UPDATE grac_practice.organization_dependency_asset
       SET current_status_id = @to_id, status = N'Inactive', record_status_id = ISNULL(@inactive_rs, record_status_id),
           lifecycle_status = ISNULL((SELECT legacy_lifecycle_status FROM grac_practice.asset_lifecycle_status_phase WHERE status_code = N'ARCHIVED'),
                                     lifecycle_status),
           merged_into_asset_id = @survivor, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE asset_id = @duplicate;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @duplicate, N'MERGED', (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @survivor AS mergedIntoAssetId, @event_id AS mergeEventId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor),
           (N'asset-register', @survivor, N'MERGE_SURVIVOR', NULL,
            (SELECT @duplicate AS mergedAssetId, @event_id AS mergeEventId,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object o WHERE o.event_id = @event_id AND o.from_asset_id = @duplicate) AS outcomes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
END
GO
PRINT '444: merge save and execution created.';
GO

-- =====================================================================
-- 6. Recovery (19.4 "restorative event where technically possible";
--    D121). Newest outcome first; a row is restored only when the object is
--    still as the merge left it, otherwise its recovery note says why.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_recover
    @organization_id   BIGINT,
    @event_id          BIGINT,
    @note              NVARCHAR(1000),
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @row BIGINT, @kind NVARCHAR(20), @oid BIGINT, @okey NVARCHAR(200), @from_asset BIGINT, @to_asset BIGINT, @outcome NVARCHAR(12),
            @before NVARCHAR(MAX), @after NVARCHAR(MAX), @done BIT, @why NVARCHAR(400);
    DECLARE @msg NVARCHAR(400) = CONCAT(N'Merge #', @event_id, N' recovered: ', LEFT(@note, 300));
    DECLARE @prev NVARCHAR(60), @to_id INT, @log BIGINT, @rtext NVARCHAR(1000) = CONCAT(N'Merge #', @event_id, N' recovered.'),
            @bs BIGINT, @bt BIGINT;
    DECLARE obj_cur CURSOR LOCAL STATIC FOR
        SELECT object_row_id, object_kind, object_id, object_key, from_asset_id, to_asset_id, outcome, before_value, after_value
          FROM grac_practice.asset_merge_split_object
         WHERE event_id = @event_id AND recovered = 0
         ORDER BY object_row_id DESC;
    OPEN obj_cur;
    FETCH NEXT FROM obj_cur INTO @row, @kind, @oid, @okey, @from_asset, @to_asset, @outcome, @before, @after;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @done = 0, @why = NULL;
        IF @outcome = N'KEPT'
        BEGIN
            SET @done = 1;
        END
        ELSE IF @kind = N'ASSET_RECORD'
        BEGIN
            SET @prev = JSON_VALUE(@before, '$.statusCode');
            IF EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                        WHERE a.asset_id = @oid AND s.status_code = N'ARCHIVED' AND a.merged_into_asset_id = @to_asset)
               AND @prev IS NOT NULL
            BEGIN
                EXEC grac_practice.sp_pm_state_transition
                     @entity_type = N'Asset', @entity_id = @oid, @from_status_code = N'ARCHIVED', @to_status_code = @prev,
                     @actor_employee_id = @actor_employee_id, @actor_role_code = N'ASSET_MERGE', @reason_code = N'MERGE_RECOVERED',
                     @reason_text = @rtext, @to_status_id = @to_id OUTPUT, @transition_log_id = @log OUTPUT;
                UPDATE grac_practice.organization_dependency_asset
                   SET current_status_id = @to_id, status = ISNULL(JSON_VALUE(@before, '$.status'), N'Active'),
                       record_status_id = ISNULL(TRY_CONVERT(INT, JSON_VALUE(@before, '$.recordStatusId')), record_status_id),
                       lifecycle_status = JSON_VALUE(@before, '$.lifecycleStatus'),
                       merged_into_asset_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE asset_id = @oid;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The merged record is no longer archived into the survivor.'; END
        END
        ELSE IF @kind = N'ALIAS'
        BEGIN
            UPDATE grac_practice.asset_alias SET is_active = 0 WHERE alias_id = @oid;
            SET @done = 1;
        END
        ELSE IF @kind = N'FIELD'
        BEGIN
            IF EXISTS (SELECT 1 FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid AND value_text = @after)
            BEGIN
                IF @before IS NULL
                BEGIN
                    DELETE FROM grac_practice.asset_field_value WHERE asset_id = @to_asset AND field_definition_id = @oid;
                END
                ELSE
                    UPDATE v
                       SET value_text = @before,
                           value_number = TRY_CONVERT(DECIMAL(38, 6), CASE WHEN f.data_type_code = N'QUANTITY_UNIT'
                                                                         THEN LEFT(@before, CHARINDEX(N' ', @before + N' ') - 1) ELSE @before END),
                           value_date = CASE WHEN f.data_type_code = N'DATE' THEN TRY_CONVERT(DATE, @before, 23) END,
                           value_ref = CASE WHEN f.lookup_source LIKE N'MASTER:%' AND f.data_type_code NOT IN (N'MULTI_SELECT', N'MULTI_USER')
                                            THEN TRY_CONVERT(BIGINT, @before) END,
                           updated_by = @actor, updated_dt = SYSUTCDATETIME()
                      FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                     WHERE v.asset_id = @to_asset AND v.field_definition_id = @oid;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The survivor value was changed after the merge.'; END
        END
        ELSE IF @kind = N'RELATIONSHIP' AND @outcome = N'MOVED'
        BEGIN
            SELECT @bs = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.sourceId')), @bt = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.targetId'));
            IF EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                        WHERE r.relationship_id = @oid AND r.source_id = TRY_CONVERT(BIGINT, JSON_VALUE(@after, '$.sourceId'))
                          AND r.target_id = TRY_CONVERT(BIGINT, JSON_VALUE(@after, '$.targetId')))
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                                 JOIN grac_practice.asset_relationship q ON q.organization_id = r.organization_id
                                  AND q.relationship_type_code = r.relationship_type_code AND q.relationship_id <> r.relationship_id
                                  AND q.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                                  AND q.source_kind = r.source_kind AND q.source_id = @bs AND q.target_kind = r.target_kind AND q.target_id = @bt
                                WHERE r.relationship_id = @oid AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED'))
            BEGIN
                UPDATE grac_practice.asset_relationship
                   SET source_id = @bs, target_id = @bt, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE relationship_id = @oid;
                EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @oid, @action_code = N'MERGE_RECOVER', @note = @msg,
                     @actor = @actor, @actor_employee_id = @actor_employee_id;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The relationship changed after the merge, or restoring it would duplicate a current one.'; END
        END
        ELSE IF @kind = N'RELATIONSHIP' AND @outcome = N'ENDED'
        BEGIN
            IF EXISTS (SELECT 1 FROM grac_practice.asset_relationship WHERE relationship_id = @oid AND status = N'RETIRED')
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship r
                                 JOIN grac_practice.asset_relationship q ON q.organization_id = r.organization_id
                                  AND q.relationship_type_code = r.relationship_type_code AND q.relationship_id <> r.relationship_id
                                  AND q.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')
                                  AND q.source_kind = r.source_kind AND q.source_id = r.source_id AND q.target_kind = r.target_kind
                                  AND q.target_id = r.target_id
                                WHERE r.relationship_id = @oid)
            BEGIN
                UPDATE grac_practice.asset_relationship
                   SET status = JSON_VALUE(@before, '$.status'), effective_to = TRY_CONVERT(DATE, JSON_VALUE(@before, '$.effectiveTo')),
                       status_note = @msg, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE relationship_id = @oid;
                EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @oid, @action_code = N'MERGE_RECOVER', @note = @msg,
                     @actor = @actor, @actor_employee_id = @actor_employee_id;
                SET @done = 1;
            END
            ELSE BEGIN SET @why = N'The relationship is no longer retired, or restoring it would duplicate a current one.'; END
        END
        ELSE IF @kind = N'DISCOVERY_LINK'
        BEGIN
            UPDATE grac_practice.asset_discovery_link SET asset_id = @from_asset WHERE link_id = @oid AND asset_id = @to_asset;
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The source record is linked elsewhere now.'; END
        END
        ELSE IF @kind = N'ATTRIBUTE_SOURCE'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_attribute_source WHERE asset_id = @from_asset AND field_key = @okey AND source_id = @oid)
            BEGIN
                UPDATE grac_practice.asset_attribute_source SET asset_id = @from_asset
                 WHERE asset_id = @to_asset AND field_key = @okey AND source_id = @oid;
                IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The value is no longer on the survivor.'; END
            END
            ELSE BEGIN SET @why = N'The merged record already holds a value from this source.'; END
        END
        ELSE IF @kind = N'RECON_EXCEPTION' AND @outcome = N'RESOLVED'
        BEGIN
            UPDATE grac_practice.asset_reconciliation_exception
               SET status = N'OPEN', resolution = NULL, resolution_note = NULL, resolved_by = NULL, resolved_dt = NULL, updated_dt = SYSUTCDATETIME()
             WHERE exception_id = @oid AND status = N'RESOLVED' AND resolution = N'MERGED';
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The exception was handled again after the merge.'; END
        END
        ELSE IF @kind = N'RECON_EXCEPTION'
        BEGIN
            UPDATE grac_practice.asset_reconciliation_exception
               SET asset_id = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.assetId')),
                   other_asset_id = TRY_CONVERT(BIGINT, JSON_VALUE(@before, '$.otherAssetId')), updated_dt = SYSUTCDATETIME()
             WHERE exception_id = @oid AND status = N'OPEN' AND (asset_id = @to_asset OR other_asset_id = @to_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The exception was resolved or changed after the merge.'; END
        END
        ELSE IF @kind = N'COVERAGE'
        BEGIN
            UPDATE c SET asset_id = @from_asset
              FROM grac_practice.asset_contract_coverage c
             WHERE c.coverage_id = @oid AND c.asset_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage c2
                                WHERE c2.version_id = c.version_id AND c2.asset_id = @from_asset AND c2.coverage_type = c.coverage_type);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The coverage line changed after the merge.'; END
        END
        ELSE IF @kind = N'OCCURRENCE'
        BEGIN
            UPDATE o SET asset_id = @from_asset, updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.asset_activity_occurrence o
             WHERE o.occurrence_id = @oid AND o.asset_id = @to_asset
               AND (o.status <> N'OPEN' OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o2
                                                        WHERE o2.asset_id = @from_asset AND o2.template_code = o.template_code AND o2.status = N'OPEN'));
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The activity changed after the merge.'; END
        END
        ELSE IF @kind = N'RESTRICTIVE_REVIEW'
        BEGIN
            UPDATE r SET asset_id = @from_asset
              FROM grac_practice.asset_restrictive_review r
             WHERE r.review_id = @oid AND r.asset_id = @to_asset
               AND (r.status NOT IN (N'OPEN', N'DECIDED') OR NOT EXISTS (
                        SELECT 1 FROM grac_practice.asset_restrictive_review r2
                         WHERE r2.asset_id = @from_asset AND r2.status IN (N'OPEN', N'DECIDED') AND r2.source_kind = r.source_kind
                           AND r2.source_code = r.source_code AND r2.trigger_code = r.trigger_code));
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The review changed after the merge.'; END
        END
        ELSE IF @kind = N'RISK_MAP'
        BEGIN
            UPDATE m SET dependency_object_id = @from_asset, dependency_object_name = @before, updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.risk_dependency_map m
             WHERE m.risk_dependency_map_id = @oid AND m.dependency_object_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map m2
                                WHERE m2.risk_register_id = m.risk_register_id AND m2.dependency_type_id = m.dependency_type_id
                                  AND m2.dependency_object_id = @from_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The risk mapping changed after the merge.'; END
        END
        ELSE IF @kind = N'RISK_LINK'
        BEGIN
            UPDATE grac_practice.risk_register SET linked_asset_id = @from_asset WHERE risk_register_id = @oid AND linked_asset_id = @to_asset;
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The risk was linked elsewhere after the merge.'; END
        END
        ELSE IF @kind = N'PRACTICE_RESOLUTION'
        BEGIN
            UPDATE d SET resolved_dependency_id = @from_asset, resolved_dependency_name = ISNULL(@before, d.resolved_dependency_name),
                         updated_by = @actor, updated_dt = SYSUTCDATETIME()
              FROM grac_practice.practice_dependency_resolution d
             WHERE d.resolution_id = @oid AND d.resolved_dependency_id = @to_asset
               AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_dependency_resolution d2
                                WHERE d2.organization_id = d.organization_id AND d2.practice_instance_id = d.practice_instance_id
                                  AND d2.dependency_type_id = d.dependency_type_id AND d2.resolved_dependency_id = @from_asset);
            IF @@ROWCOUNT = 1 BEGIN SET @done = 1; END ELSE BEGIN SET @why = N'The practice resolution changed after the merge.'; END
        END
        UPDATE grac_practice.asset_merge_split_object SET recovered = @done, recovery_note = @why WHERE object_row_id = @row;
        FETCH NEXT FROM obj_cur INTO @row, @kind, @oid, @okey, @from_asset, @to_asset, @outcome, @before, @after;
    END
    CLOSE obj_cur;
    DEALLOCATE obj_cur;
END
GO

-- =====================================================================
-- 7. Merge actions (D115, D120)
--   SUBMIT   Draft -> Pending approval (reason, no blockers; plan counts kept)
--   CANCEL   Draft / Pending approval / Approved -> Cancelled (note)
--   APPROVE  Pending approval: another person than the requester; a critical
--            merge needs two different approvers -> Approved
--   REJECT   Pending approval -> Rejected (note; not the requester)
--   EXECUTE  Approved -> Executed (blockers checked again; per duplicate)
--   RECOVER  Executed -> Recovered (note)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_action
    @organization_id         BIGINT,
    @event_id                BIGINT,
    @action                  NVARCHAR(10),
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
    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @survivor BIGINT, @reason NVARCHAR(1000), @choices NVARCHAR(MAX),
            @requested_by NVARCHAR(100), @requested_emp BIGINT, @required INT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @survivor = survivor_asset_id, @reason = reason,
           @choices = field_choices_json, @requested_by = requested_by, @requested_emp = requested_by_employee_id,
           @required = approvals_required
      FROM grac_practice.asset_merge_split_event
     WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'MERGE';
    IF @found = 0 THROW 52902, 'Merge not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 52903, 'The merge was changed by someone else; reload it and try again.', 1;
    IF @action NOT IN (N'SUBMIT', N'CANCEL', N'APPROVE', N'REJECT', N'EXECUTE', N'RECOVER')
        THROW 52911, 'That action is not available for a merge.', 1;
    IF NOT ((@action = N'SUBMIT' AND @status = N'DRAFT')
         OR (@action = N'CANCEL' AND @status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED'))
         OR (@action IN (N'APPROVE', N'REJECT') AND @status = N'PENDING_APPROVAL')
         OR (@action = N'EXECUTE' AND @status = N'APPROVED')
         OR (@action = N'RECOVER' AND @status = N'EXECUTED'))
        THROW 52907, 'The merge status does not allow this action.', 1;
    IF @action IN (N'CANCEL', N'REJECT', N'RECOVER') AND @note IS NULL
        THROW 52910, 'Record the reason in the note.', 1;
    IF @action IN (N'APPROVE', N'REJECT')
       AND ((@actor_employee_id IS NOT NULL AND @actor_employee_id = @requested_emp) OR @actor = @requested_by)
        THROW 52909, 'The requester cannot approve or reject the merge; another person decides.', 1;
    IF @action = N'APPROVE'
       AND EXISTS (SELECT 1 FROM grac_practice.asset_merge_split_approval
                    WHERE event_id = @event_id AND decision = N'APPROVE'
                      AND ((@actor_employee_id IS NOT NULL AND approver_employee_id = @actor_employee_id) OR approver = @actor))
        THROW 52909, 'You already approved this merge; a critical merge needs a second, different approver.', 1;
    IF @action IN (N'SUBMIT', N'EXECUTE')
    BEGIN
        IF @action = N'SUBMIT' AND @reason IS NULL THROW 52906, 'Record the reason for the merge first.', 1;
        DECLARE @blk NVARCHAR(1500) = (
            SELECT LEFT(STRING_AGG(CAST(CONCAT(a.asset_name, N': ', b.Detail) AS NVARCHAR(MAX)), N' | '), 1400)
              FROM grac_practice.asset_merge_split_member m
              JOIN grac_practice.organization_dependency_asset a ON a.asset_id = m.asset_id
             CROSS APPLY grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, m.asset_id) b
             WHERE m.event_id = @event_id);
        IF @blk IS NOT NULL
        BEGIN
            DECLARE @blk_msg NVARCHAR(1600) = CONCAT(N'Resolve these first: ', @blk);
            THROW 52908, @blk_msg, 1;
        END
    END

    DECLARE @result NVARCHAR(20) = @status, @approvals INT;
    BEGIN TRAN;
    IF @action = N'SUBMIT'
    BEGIN
        UPDATE e
           SET status = N'PENDING_APPROVAL', submitted_dt = SYSUTCDATETIME(), is_critical = c.IsCritical,
               approvals_required = CASE WHEN c.IsCritical = 1 THEN 2 ELSE 1 END,
               preview_json = (SELECT p.ObjectKind AS kind, p.Outcome AS outcome, COUNT(*) AS items
                                 FROM grac_practice.asset_merge_split_member m
                                CROSS APPLY grac_practice.fn_asset_merge_plan(@organization_id, @survivor, m.asset_id) p
                                WHERE m.event_id = @event_id
                                GROUP BY p.ObjectKind, p.Outcome FOR JSON PATH)
          FROM grac_practice.asset_merge_split_event e
         CROSS APPLY grac_practice.fn_asset_merge_critical(@organization_id, @event_id) c
         WHERE e.event_id = @event_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE IF @action = N'CANCEL'
    BEGIN
        UPDATE grac_practice.asset_merge_split_event SET status = N'CANCELLED', decided_note = @note, closed_dt = SYSUTCDATETIME()
         WHERE event_id = @event_id;
        SET @result = N'CANCELLED';
    END
    ELSE IF @action IN (N'APPROVE', N'REJECT')
    BEGIN
        INSERT grac_practice.asset_merge_split_approval (event_id, decision, note, approver, approver_employee_id)
        VALUES (@event_id, @action, @note, @actor, @actor_employee_id);
        SET @approvals = (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval WHERE event_id = @event_id AND decision = N'APPROVE');
        IF @action = N'REJECT'
        BEGIN
            UPDATE grac_practice.asset_merge_split_event SET status = N'REJECTED', decided_note = @note, closed_dt = SYSUTCDATETIME()
             WHERE event_id = @event_id;
            SET @result = N'REJECTED';
        END
        ELSE IF @approvals >= @required
        BEGIN
            UPDATE grac_practice.asset_merge_split_event SET status = N'APPROVED' WHERE event_id = @event_id;
            SET @result = N'APPROVED';
        END
        ELSE
            SET @result = N'FIRST_APPROVAL';
    END
    ELSE IF @action = N'EXECUTE'
    BEGIN
        DECLARE @dup BIGINT;
        DECLARE dup_cur CURSOR LOCAL STATIC FOR
            SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id ORDER BY sequence_no;
        OPEN dup_cur;
        FETCH NEXT FROM dup_cur INTO @dup;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC grac_practice.sp_asset_merge_execute_one
                 @organization_id = @organization_id, @event_id = @event_id, @survivor = @survivor, @duplicate = @dup,
                 @field_choices_json = @choices, @actor_employee_id = @actor_employee_id, @actor = @actor;
            FETCH NEXT FROM dup_cur INTO @dup;
        END
        CLOSE dup_cur;
        DEALLOCATE dup_cur;
        UPDATE grac_practice.asset_merge_split_event
           SET status = N'EXECUTED', executed_by = @actor, executed_dt = SYSUTCDATETIME(), closed_dt = SYSUTCDATETIME()
         WHERE event_id = @event_id;
        SET @result = N'EXECUTED';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_merge_recover
             @organization_id = @organization_id, @event_id = @event_id, @note = @note,
             @actor_employee_id = @actor_employee_id, @actor = @actor;
        UPDATE grac_practice.asset_merge_split_event
           SET status = N'RECOVERED', recovered_by = @actor, recovered_dt = SYSUTCDATETIME(), recovery_reason = @note
         WHERE event_id = @event_id;
        SET @result = N'RECOVERED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-merge', @event_id, @action, (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @result AS result, @note AS note,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object WHERE event_id = @event_id) AS outcomes,
                    (SELECT COUNT(*) FROM grac_practice.asset_merge_split_object WHERE event_id = @event_id AND recovered = 1) AS recovered
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @event_id AS EventId, @result AS Result;
END
GO
PRINT '444: merge recovery and actions created.';
GO

-- =====================================================================
-- 8. Readers
-- =====================================================================
-- Merge list. @status: NULL = open (Draft, Pending approval, Approved),
-- ALL, or one status.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_events
    @organization_id BIGINT,
    @status          NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT e.event_id AS EventId, e.status AS Status, e.survivor_asset_id AS SurvivorAssetId, s.asset_name AS SurvivorName,
           d.names AS DuplicateNames, d.cnt AS DuplicateCount, e.is_critical AS IsCritical, e.approvals_required AS ApprovalsRequired,
           (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval p WHERE p.event_id = e.event_id AND p.decision = N'APPROVE') AS Approvals,
           e.reason AS Reason, e.requested_by AS RequestedBy, e.requested_dt AS RequestedDt, e.executed_dt AS ExecutedDt,
           e.recovered_dt AS RecoveredDt, e.closed_dt AS ClosedDt, CONVERT(BIGINT, e.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_merge_split_event e
      JOIN grac_practice.organization_dependency_asset s ON s.asset_id = e.survivor_asset_id
     CROSS APPLY (SELECT COUNT(*) AS cnt, LEFT(STRING_AGG(CAST(a.asset_name AS NVARCHAR(MAX)), N', '), 600) AS names
                    FROM grac_practice.asset_merge_split_member m
                    JOIN grac_practice.organization_dependency_asset a ON a.asset_id = m.asset_id
                   WHERE m.event_id = e.event_id) d
     WHERE e.organization_id = @organization_id AND e.event_kind = N'MERGE'
       AND ((@status IS NULL AND e.status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED')) OR @status = N'ALL' OR e.status = @status)
       AND (@search IS NULL OR s.asset_name LIKE N'%' + @search + N'%' OR d.names LIKE N'%' + @search + N'%')
     ORDER BY e.event_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One merge: 1. event  2. assets (survivor first)  3. approvals
-- 4. blockers  5. plan (open merges)  6. outcomes (executed / recovered)
-- 7. field comparison (open merges)  8. impact per asset.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_merge_get
    @organization_id BIGINT,
    @event_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @survivor BIGINT, @status NVARCHAR(20), @choices NVARCHAR(MAX);
    SELECT @survivor = survivor_asset_id, @status = status, @choices = field_choices_json
      FROM grac_practice.asset_merge_split_event
     WHERE event_id = @event_id AND organization_id = @organization_id AND event_kind = N'MERGE';
    IF @survivor IS NULL THROW 52902, 'Merge not found for this organization.', 1;
    DECLARE @open BIT = CASE WHEN @status IN (N'DRAFT', N'PENDING_APPROVAL', N'APPROVED') THEN 1 ELSE 0 END;
    SELECT e.event_id AS EventId, e.status AS Status, e.survivor_asset_id AS SurvivorAssetId, s.asset_name AS SurvivorName,
           e.reason AS Reason, e.field_choices_json AS FieldChoicesJson, e.is_critical AS IsCritical, e.approvals_required AS ApprovalsRequired,
           (SELECT COUNT(*) FROM grac_practice.asset_merge_split_approval p WHERE p.event_id = e.event_id AND p.decision = N'APPROVE') AS Approvals,
           e.requested_by AS RequestedBy, e.requested_by_employee_id AS RequestedByEmployeeId, e.requested_dt AS RequestedDt,
           e.submitted_dt AS SubmittedDt, e.decided_note AS DecidedNote, e.executed_by AS ExecutedBy, e.executed_dt AS ExecutedDt,
           e.recovered_by AS RecoveredBy, e.recovered_dt AS RecoveredDt, e.recovery_reason AS RecoveryReason, e.closed_dt AS ClosedDt,
           CONVERT(BIGINT, e.record_version) AS RecordVersion
      FROM grac_practice.asset_merge_split_event e
      JOIN grac_practice.organization_dependency_asset s ON s.asset_id = e.survivor_asset_id
     WHERE e.event_id = @event_id;
    SELECT x.asset_id AS AssetId, x.role_code AS MemberRole, x.seq AS SequenceNo, a.asset_name AS AssetName,
           ty.asset_type_name AS AssetTypeName, ISNULL(st.status_name, N'Active') AS StatusName, c.criticality_name AS CriticalityName,
           ow.employee_name AS OwnerName, a.merged_into_asset_id AS MergedIntoAssetId
      FROM (SELECT @survivor AS asset_id, N'SURVIVOR' AS role_code, 0 AS seq
            UNION ALL SELECT asset_id, member_role, sequence_no FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id) x
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.entity_status_master st ON st.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = a.owner_id
     ORDER BY x.seq;
    SELECT approval_id AS ApprovalId, decision AS Decision, note AS Note, approver AS Approver, decided_dt AS DecidedDt
      FROM grac_practice.asset_merge_split_approval WHERE event_id = @event_id ORDER BY approval_id;
    SELECT m.asset_id AS AssetId, b.BlockerCode, b.Detail
      FROM grac_practice.asset_merge_split_member m
     CROSS APPLY grac_practice.fn_asset_merge_blockers(@organization_id, @survivor, m.asset_id) b
     WHERE m.event_id = @event_id AND @open = 1
     ORDER BY m.sequence_no;
    SELECT m.asset_id AS DuplicateAssetId, p.ObjectKind, p.ObjectId, p.ObjectLabel, p.Outcome, p.Detail, p.Domain
      FROM grac_practice.asset_merge_split_member m
     CROSS APPLY grac_practice.fn_asset_merge_plan(@organization_id, @survivor, m.asset_id) p
     WHERE m.event_id = @event_id AND @open = 1
     ORDER BY m.sequence_no, p.Domain, p.ObjectKind, p.ObjectLabel;
    SELECT o.object_row_id AS ObjectRowId, o.from_asset_id AS DuplicateAssetId, o.object_kind AS ObjectKind, o.object_id AS ObjectId,
           o.object_label AS ObjectLabel, o.outcome AS Outcome, LEFT(o.before_value, 400) AS BeforeValue, LEFT(o.after_value, 400) AS AfterValue,
           o.detail AS Detail, o.recovered AS Recovered, o.recovery_note AS RecoveryNote
      FROM grac_practice.asset_merge_split_object o
     WHERE o.event_id = @event_id
     ORDER BY o.object_row_id;
    SELECT m.asset_id AS DuplicateAssetId, f.FieldKey, f.FieldLabel, f.SurvivorDisplay, f.DuplicateDisplay, f.IsMergeable, f.IsDifferent,
           CAST(CASE WHEN ch.chosen = m.asset_id THEN 1 ELSE 0 END AS BIT) AS IsChosen
      FROM grac_practice.asset_merge_split_member m
     CROSS APPLY grac_practice.fn_asset_merge_fields(@survivor, m.asset_id) f
     OUTER APPLY (SELECT TOP 1 TRY_CONVERT(BIGINT, j.[value]) AS chosen FROM OPENJSON(ISNULL(@choices, N'{}')) j
                   WHERE j.[key] COLLATE DATABASE_DEFAULT = f.FieldKey) ch
     WHERE m.event_id = @event_id AND @open = 1 AND f.DuplicateValue IS NOT NULL
     ORDER BY f.FieldLabel, m.sequence_no;
    SELECT x.asset_id AS AssetId, i.ImpactItem, i.ItemCount, i.SortOrder
      FROM (SELECT @survivor AS asset_id UNION SELECT asset_id FROM grac_practice.asset_merge_split_member WHERE event_id = @event_id) x
     CROSS APPLY grac_practice.fn_asset_merge_impact(@organization_id, x.asset_id) i
     ORDER BY x.asset_id, i.SortOrder;
END
GO
PRINT '444: merge readers created.';
GO

-- =====================================================================
-- 9. sp_asset_register_list (429) re-issued: the search also finds the
--    aliases a merge kept on the survivor (19.4 "aliases and external
--    identifiers remain searchable"). Otherwise unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @pending_only    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    SET @pending_only = ISNULL(@pending_only, 0);

    ;WITH rows_ AS (
        SELECT a.asset_id, a.asset_name, a.asset_type_id, a.template_id, a.owner_id, a.location_id, a.criticality_id,
               a.asset_category_id, a.asset_subcategory_id, a.updated_dt, a.entered_dt,
               COALESCE(cs.status_code, ls.status_code) AS status_code
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
         WHERE a.organization_id = @organization_id
           AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(a.asset_id AS NVARCHAR(30)) = @search   -- 444
                OR EXISTS (SELECT 1 FROM grac_practice.asset_alias al   -- 444
                            WHERE al.asset_id = a.asset_id AND al.is_active = 1 AND al.alias_value LIKE N'%' + @search + N'%'))   -- 444
    )
    SELECT r.asset_id AS AssetId, r.asset_name AS AssetName,
           c.asset_category_name AS CategoryName, s.subcategory_name AS SubcategoryName,
           r.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           r.status_code AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           r.template_id AS TemplateId, tpl.version_no AS TemplateVersion,
           e.employee_name AS OwnerName, l.location_name AS LocationName, cr.criticality_name AS CriticalityName,
           ISNULL(r.updated_dt, r.entered_dt) AS LastChanged,
           pc.change_id AS PendingChangeId, pcs.status_name AS PendingToStatusName,
           COUNT(*) OVER () AS TotalRows
      FROM rows_ r
      LEFT JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = r.asset_category_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = r.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = r.asset_type_id
      LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = r.status_code
      LEFT JOIN grac_practice.asset_lifecycle_status_phase ph ON ph.status_code = r.status_code
      LEFT JOIN grac_practice.asset_form_template tpl ON tpl.template_id = r.template_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = r.location_id
      LEFT JOIN grac_practice.criticality_master cr ON cr.criticality_id = r.criticality_id
      LEFT JOIN grac_practice.asset_lifecycle_change pc ON pc.asset_id = r.asset_id AND pc.change_status = N'PENDING_APPROVAL'
      LEFT JOIN grac_practice.entity_status_master pcs ON pcs.entity_type = N'Asset' AND pcs.status_code = pc.to_status_code
     WHERE (@status_code IS NULL OR r.status_code = @status_code)
       AND (@pending_only = 0 OR pc.change_id IS NOT NULL)
     ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.asset_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '444: sp_asset_register_list re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '444-a tables and merged pointer' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_merge_split_event','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_merge_split_member','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_merge_split_approval','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_merge_split_object','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_alias','U') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '444-b functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_merge_blockers') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_merge_plan') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_merge_fields') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_merge_impact') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_merge_critical') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_merge_save', 'sp_asset_merge_execute_one', 'sp_asset_merge_recover', 'sp_asset_merge_action',
                                'sp_asset_merge_events', 'sp_asset_merge_get')) = 6
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '444-c merge rules: every status to Archived and back, role ASSET_MERGE, no gate',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule r
                   WHERE r.entity_type = N'Asset' AND r.actor_role_code = N'ASSET_MERGE'
                     AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_transition_gate g WHERE g.transition_rule_id = r.transition_rule_id))
                 = 2 * ((SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'Asset') - 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '444-d user lifecycle rules unchanged (no way back from Disposed / Archived)',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_rule
                              WHERE entity_type = N'Asset' AND is_active = 1 AND actor_role_code IS NULL
                                AND from_status_code IN (N'DISPOSED', N'ARCHIVED') AND to_status_code <> N'ARCHIVED')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '444-e register search finds aliases',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_list')) LIKE '%asset_alias%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_list')) LIKE '%pending_only%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '444-f plan and blockers run',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.fn_asset_merge_plan(-1, -1, -2)) = 0
             AND (SELECT COUNT(*) FROM grac_practice.fn_asset_merge_blockers(-1, -1, -2)) = 2
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs: assets S (survivor) and D (duplicate) of one organization, D with
--   a discovery link, a relationship to a business service, contract
--   coverage on an active version, a risk mapping, an asset tag and a value
--   S lacks; users R (asset-discovery EDIT + asset-register EDIT), A1 and
--   A2 (asset-discovery APPROVE).
--   1. Asset Discovery -> Reconciliation queue: a Potential duplicate of S
--      and D -> Merge (or Merges -> New merge, survivor S, duplicate D).
--      The window shows both assets, impact per asset, the field
--      comparison (choose D for a field), the plan (moves, ends, kept) and
--      blockers. Give the reason, save, submit.
--   2. D with an open workflow case -> Submit refused, the case named.
--   3. A non-critical merge: R cannot approve (requester); A1 approves ->
--      Approved. Critical (S criticality Critical): A1 approves -> first
--      approval; A1 again refused; A2 approves -> Approved.
--   4. R executes -> Executed: outcomes per object (relationships moved or
--      ended, discovery link, coverage, risk mapping moved, fields filled /
--      replaced, aliases, D archived and inactive); S shows the values of D; the
--      Asset Register search for the name or asset tag of D finds S; the
--      Potential duplicate exception is closed as Merged; the history of D
--      (lifecycle, custody, completed activities) stays on D.
--   5. A1 recovers (note) -> Recovered: D is back in its earlier status, the
--      objects are on D again; a value changed on S after the merge is kept
--      and its row shows why; the event and its rows remain.
--   6. Reject (A1, note) and Cancel (R, note) close a merge without changes.
-- =====================================================================
