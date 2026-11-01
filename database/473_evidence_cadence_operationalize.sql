-- =====================================================================
-- 473_evidence_cadence_operationalize.sql
--
-- REQUEST (2026-10-18)
-- --------------------
--   Control Management 077 added an evidence cadence to every evidence
--   spec of an obligation (Recurring / OneTime). Practice Management must
--   now:
--     1. show that cadence on Operationalize;
--     2. let a ONE-TIME evidence be attached (a file) on Operationalize,
--        at implementation;
--     3. make an attachment MANDATORY on the scheduled task only when the
--        evidence is RECURRING (one-time evidence is not asked for again);
--     4. let the organisation edit the obligation description and the
--        evidence description on Operationalize. Both edits are for THIS
--        practice instance (decided 2026-10-18); the published text stays
--        visible beside the edit and is the way back.
--
-- WHAT THIS FILE DOES
-- -------------------
--   1. Copy model. evidence_cadence reaches the organisation's copy
--      (organization_obligation_evidence) the 391 way: the source view
--      vw_repo_src_obligation_evidence is rebuilt from the live
--      GRAC_New table and sp_repo_clone_ensure_table adds the column.
--      Rows whose copy was IN STEP with Control Management before the
--      rebuild get the cadence (and any other column the rebuilt view
--      newly carries) and the new content hash directly, so the
--      new column alone does not raise a "Changed" approval (395) for
--      every evidence spec of every subscribed organisation. Rows that
--      were already behind keep their old hash and arrive through the
--      normal approval, cadence included.
--   2. grac_practice.practice_instance_evidence_attachment -- files
--      attached to an evidence row at implementation. Same shape as
--      task_attachment (192), plus organisation / instance keys and a
--      soft remove (status, removed_by, removed_dt).
--   3. vw_pm_instance_evidence_cadence -- the cadence of every
--      practice_instance_evidence row, read from the organisation's copy:
--      the row is one per (obligation, evidence type) (304/400), so when
--      several published specs of the same type merge into it, ANY
--      recurring spec makes the row Recurring (077's rule: the error
--      should fall on the side of asking for proof). Evidence of an
--      organisation-defined obligation has no published cadence and is
--      Recurring ('Default').
--   4. Re-issued (body from the file named, only the listed change):
--        sp_resolve_obligation_list (457)  ObligationDescription = the
--            instance's edited text when there is one; new
--            PublishedObligationDescription / IsDescriptionOverridden;
--            PublishedEvidenceJson elements carry EvidenceCadence /
--            EvidenceCadenceLabel
--        sp_resolve_evidence_list   (394)  EvidenceCadence,
--            EvidenceCadenceLabel, EvidenceCadenceSource, AttachmentCount
--        sp_resolve_evidence_save   (254)  @clear_evidence_description
--        sp_task_completion_eligibility (194)  the recurring-evidence
--            gate. Same seven result columns, so sp_task_complete's
--            INSERT ... EXEC (200) is untouched; the em dash in two
--            reason texts is spelled '-' (ASCII-only convention).
--   5. New procedures:
--        sp_resolve_obligation_description_save
--        sp_resolve_evidence_attachment_add / _list / _get / _remove
--
-- WHERE THE OBLIGATION DESCRIPTION EDIT IS STORED
-- -----------------------------------------------
--   practice_instance_obligation.obligation_description (227). It is the
--   column an organisation-defined obligation already keeps its text in,
--   and it was never written for an adopted (published) row -- the adopt
--   and fan-out paths do not touch it there. Re-using it means the
--   scheduled task description (459) follows the edit with no change:
--   459 already reads COALESCE(pio.obligation_description,
--   published obligation_text). NULL = as published.
--
-- WHAT THIS DOES NOT DO
-- ---------------------
--   * A one-time attachment does not make the evidence "resolved".
--     Resolved stays location AND locator (353), the same test assurance
--     eligibility applies.
--   * The scheduled-task gate needs at least one file on the task; it does
--     not match files to evidence types (task_attachment has no evidence
--     type). The reason text names the recurring evidence expected.
--   * Close Task (close without completing) is not gated -- it is not a
--     completion.
--   * Evidence of an organisation-defined obligation cannot be marked
--     one-time yet (the shared obligation form has no cadence field).
--
-- ERROR NUMBERS: 52760-52779.
-- DEPENDS ON: Control Management 077; PM 194, 200, 254, 391-395, 449,
--   457, 459. Deploy with the API / Web changes of the same date (the API
--   reads every new column defensively, so either tier can go first).
-- Rollback: database/473_evidence_cadence_operationalize_rollback.sql
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================
-- 0. Prerequisites
-- =====================================================================
IF COL_LENGTH('GRAC_New.requirement_obligation_evidence','evidence_cadence') IS NULL
BEGIN
    PRINT 'ABORT (473): GRAC_New.requirement_obligation_evidence.evidence_cadence is missing.';
    PRINT '             Run Control Management 077_evidence_cadence.sql first.';
    SET NOEXEC ON;
END
GO
IF OBJECT_ID('grac_practice.repository_copy_config','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.repository_copy_config WHERE copy_code = N'ObligationEvidence')
   OR OBJECT_ID('grac_practice.organization_obligation_evidence','U') IS NULL
   OR OBJECT_ID('grac_practice.vw_repo_src_obligation_evidence','V') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_build_source_view','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_repo_clone_ensure_table','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation_evidence') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_obligation_evidence','V') IS NULL
   OR OBJECT_ID('grac_practice.vw_pm_org_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (473): the repository copy model is missing -- run 391-395 first.';
    SET NOEXEC ON;
END
GO
-- Every column the re-issued bodies read (reissued_proc_needs_column_guard).
IF COL_LENGTH('grac_practice.practice_instance_obligation','obligation_description') IS NULL   -- 227
   OR COL_LENGTH('grac_practice.practice_instance_obligation','first_occurrence_date') IS NULL  -- 338 / 457
   OR COL_LENGTH('grac_practice.practice_instance_obligation','owner_employee_id') IS NULL      -- 412
   OR COL_LENGTH('grac_practice.practice_instance_obligation','connection_type_id') IS NULL     -- 244
   OR COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL -- 242
   OR COL_LENGTH('grac_practice.practice_instance_obligation','updated_by') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','updated_dt') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL            -- 254
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NULL     -- 140
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL -- 140
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL -- 231/232
   OR OBJECT_ID('grac_practice.sp_resolve_obligation_list','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_resolve_evidence_save','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_completion_eligibility','P') IS NULL
   OR OBJECT_ID('grac_practice.task_attachment','U') IS NULL
   OR OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_record_id') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
   OR OBJECT_ID('GRAC_New.reference_option','U') IS NULL
   OR OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (473): a prerequisite is missing -- run 194, 200, 227-254, 338, 412, 449 and 457 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. evidence_cadence into the organisation's copy
-- =====================================================================
-- One batch: the temp table must outlive the view rebuild, and the
-- UPDATE is dynamic because the column is added inside this batch.
IF OBJECT_ID('tempdb..#pm473_in_step') IS NOT NULL DROP TABLE #pm473_in_step;
CREATE TABLE #pm473_in_step (org_obligation_evidence_id BIGINT NOT NULL PRIMARY KEY);

-- Rows whose copy matches Control Management as the view sees it NOW,
-- i.e. before the view learns about the new column.
INSERT #pm473_in_step(org_obligation_evidence_id)
SELECT c.org_obligation_evidence_id
FROM   grac_practice.organization_obligation_evidence c
JOIN   grac_practice.vw_repo_src_obligation_evidence s
       ON s.obligation_evidence_id = c.obligation_evidence_id
WHERE  c.source_version_hash = s.content_hash;
PRINT '473: evidence copy rows in step before the rebuild = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

EXEC grac_practice.sp_repo_build_source_view
     @source_table = N'grac_new.requirement_obligation_evidence',
     @view_name    = N'vw_repo_src_obligation_evidence';

DECLARE @v SYSNAME, @t SYSNAME, @pk SYSNAME, @k SYSNAME;
SELECT @v = source_view, @t = target_table, @pk = org_pk_column, @k = key_column
FROM   grac_practice.repository_copy_config
WHERE  copy_code = N'ObligationEvidence';
EXEC grac_practice.sp_repo_clone_ensure_table
     @source_view = @v, @target_table = @t, @org_pk_column = @pk, @key_column = @k;

-- Every column the copy shares with the rebuilt view is set, not only the
-- cadence: if Control Management added any other column since 391, the
-- view now carries it too, and stamping the new hash on a row that still
-- lacked that value would hide the difference from 395 for good. The
-- column list is read from the catalogue the sp_repo_clone_sync (395) way.
DECLARE @n INT = 0, @set_cols NVARCHAR(MAX);
SELECT @set_cols = STRING_AGG(CAST(N'c.' + QUOTENAME(tc.name) + N' = s.' + QUOTENAME(tc.name) AS NVARCHAR(MAX)), N', ')
                   WITHIN GROUP (ORDER BY tc.column_id)
FROM   sys.columns tc
JOIN   sys.columns vc
       ON vc.object_id = OBJECT_ID(N'grac_practice.' + QUOTENAME(@v), 'V')
      AND vc.name = tc.name
WHERE  tc.object_id = OBJECT_ID(N'grac_practice.' + QUOTENAME(@t), 'U')
  AND  tc.name <> @pk
  AND  tc.name NOT IN (SELECT r.column_name FROM grac_practice.fn_repo_clone_reserved_columns() r);

DECLARE @sql NVARCHAR(MAX) = N'
UPDATE c
   SET ' + ISNULL(@set_cols + N',', N'') + N'
       c.source_version_hash = s.content_hash
FROM   grac_practice.organization_obligation_evidence c
JOIN   #pm473_in_step i ON i.org_obligation_evidence_id = c.org_obligation_evidence_id
JOIN   grac_practice.vw_repo_src_obligation_evidence s
       ON s.obligation_evidence_id = c.obligation_evidence_id;
SET @n = @@ROWCOUNT;';
IF COL_LENGTH('grac_practice.organization_obligation_evidence','evidence_cadence') IS NOT NULL
   AND @set_cols LIKE N'%evidence_cadence%'
    EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @n OUTPUT;
PRINT '473: evidence copy rows given their cadence (kept in step) = ' + CAST(@n AS NVARCHAR(20));

-- fn_org_requirement_obligation_evidence is SELECT t.* (392); refresh it
-- so the new column is part of its metadata.
IF OBJECT_ID('grac_practice.fn_org_requirement_obligation_evidence') IS NOT NULL
    EXEC sys.sp_refreshsqlmodule N'grac_practice.fn_org_requirement_obligation_evidence';

DROP TABLE #pm473_in_step;
GO

IF COL_LENGTH('grac_practice.organization_obligation_evidence','evidence_cadence') IS NULL
BEGIN
    PRINT 'ABORT (473): organization_obligation_evidence.evidence_cadence was not added -- see the messages above.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 2. practice_instance_evidence_attachment
-- =====================================================================
-- The fat VARBINARY column lives in its own table so list queries never
-- read it -- the 192 / 161 / document_upload_file shape.
IF OBJECT_ID('grac_practice.practice_instance_evidence_attachment','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_instance_evidence_attachment(
        evidence_attachment_id  BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_pi_evidence_attachment PRIMARY KEY,
        organization_id         BIGINT NOT NULL
            CONSTRAINT fk_pm_pi_evidence_attachment_org
                REFERENCES grac_practice.organization(organization_id),
        practice_instance_id    BIGINT NOT NULL
            CONSTRAINT fk_pm_pi_evidence_attachment_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id),
        evidence_id             BIGINT NOT NULL
            CONSTRAINT fk_pm_pi_evidence_attachment_evidence
                REFERENCES grac_practice.practice_instance_evidence(evidence_id),
        file_name               NVARCHAR(500)  NOT NULL,
        content_type            NVARCHAR(200)  NULL,
        file_size_bytes         BIGINT         NOT NULL
            CONSTRAINT df_pm_pi_evidence_attachment_size DEFAULT 0,
        file_data               VARBINARY(MAX) NOT NULL,
        attachment_description  NVARCHAR(1000) NULL,
        status                  NVARCHAR(30)   NOT NULL
            CONSTRAINT df_pm_pi_evidence_attachment_status DEFAULT N'Active',   -- Active / Removed
        uploaded_by_employee_id BIGINT NULL
            CONSTRAINT fk_pm_pi_evidence_attachment_uploader
                REFERENCES grac_practice.organization_employee(employee_id),
        uploaded_by             NVARCHAR(100)  NOT NULL,
        uploaded_dt             DATETIME2      NOT NULL
            CONSTRAINT df_pm_pi_evidence_attachment_dt DEFAULT SYSUTCDATETIME(),
        removed_by              NVARCHAR(100)  NULL,
        removed_dt              DATETIME2      NULL
    );
    CREATE INDEX ix_pm_pi_evidence_attachment_instance
        ON grac_practice.practice_instance_evidence_attachment(practice_instance_id, evidence_id, status)
        INCLUDE (file_name, file_size_bytes, uploaded_dt);
    PRINT '473: practice_instance_evidence_attachment created.';
END
GO

-- =====================================================================
-- 3. vw_pm_instance_evidence_cadence
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_evidence_cadence
AS
    -- 473: the cadence of every practice_instance_evidence row.
    --   Published = read from the organisation's copy of the specs of
    --               this obligation + evidence type (any Recurring spec
    --               makes the row Recurring), or, failing that, of the
    --               exact spec the row was created from;
    --   Default   = nothing published (organisation-defined evidence)
    --               -> Recurring, the 077 default.
    -- A copied spec with no cadence (a copy still waiting for approval of
    -- the 077 change) reads as Recurring, the same as 077's backfill.
    SELECT e.evidence_id,
           e.organization_id,
           e.practice_instance_id,
           c.EvidenceCadence,
           COALESCE(ro.option_label, c.EvidenceCadence) AS EvidenceCadenceLabel,
           c.CadenceSource
    FROM   grac_practice.practice_instance_evidence e
    OUTER  APPLY (
        SELECT COUNT(*) AS spec_count,
               MAX(CASE WHEN ISNULL(ooe.evidence_cadence, N'Recurring') = N'OneTime' THEN 0 ELSE 1 END) AS any_recurring
        FROM   grac_practice.vw_pm_obligation_evidence oe
        JOIN   grac_practice.organization_obligation_evidence ooe
               ON ooe.organization_id = oe.organization_id
              AND ooe.obligation_evidence_id = oe.obligation_evidence_id
        WHERE  e.source_obligation_id IS NOT NULL
          AND  oe.organization_id  = e.organization_id
          AND  oe.obligation_id    = e.source_obligation_id
          AND  oe.evidence_type_id = e.evidence_type_id
    ) bytype
    OUTER  APPLY (
        SELECT TOP 1 ISNULL(ooe2.evidence_cadence, N'Recurring') AS cadence
        FROM   grac_practice.organization_obligation_evidence ooe2
        WHERE  e.source_obligation_evidence_id IS NOT NULL
          AND  ooe2.organization_id = e.organization_id
          AND  ooe2.obligation_evidence_id = e.source_obligation_evidence_id
    ) exact
    CROSS  APPLY (
        SELECT CASE WHEN bytype.spec_count > 0
                    THEN CASE WHEN bytype.any_recurring = 1 THEN N'Recurring' ELSE N'OneTime' END
                    WHEN exact.cadence IS NOT NULL THEN exact.cadence
                    ELSE N'Recurring' END AS EvidenceCadence,
               CASE WHEN bytype.spec_count > 0 OR exact.cadence IS NOT NULL
                    THEN N'Published' ELSE N'Default' END AS CadenceSource
    ) c
    LEFT   JOIN GRAC_New.reference_option ro
           ON ro.option_group = N'evidence-cadence'
          AND ro.option_value = c.EvidenceCadence;
GO

-- =====================================================================
-- 4. Re-issued procedures
-- =====================================================================
-- ---------------------------------------------------------------------
-- 4a. sp_resolve_obligation_list (from 457)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_list
    @practice_instance_id BIGINT,
    @include_unsubscribed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52604, 'sp_resolve_obligation_list: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @practice_id BIGINT;
    SELECT @organization_id = organization_id, @practice_id = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52605, 'sp_resolve_obligation_list: instance not found.', 1;

    ;WITH reachable AS (
        SELECT orm.obligation_id,
               orm.release_id,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                       WHERE s.organization_id = @organization_id
                                         AND s.release_id = orm.release_id
                                         AND s.status = N'Active')
                         THEN 1 ELSE 0 END AS BIT) AS is_subscribed
        FROM   grac_practice.practice pp
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = pp.organization_requirement_id
        LEFT   JOIN grac_practice.fn_org_requirement(@organization_id) repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    picked AS (
        SELECT obligation_id,
               MIN(release_id)                 AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT * FROM (
    SELECT
        o.obligation_id                 AS ObligationId,
        CAST(0 AS BIT)                  AS IsOrganizationDefined,
        N'p' + CAST(o.obligation_id AS NVARCHAR(20)) AS RowKey,
        ISNULL(t.display_order, 999)    AS SortOrder,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        -- 473: the description this instance works to -- the organisation's
        -- own wording when it has edited it on Operationalize (stored on
        -- practice_instance_obligation.obligation_description, the same
        -- column an organisation-defined obligation keeps its text in),
        -- otherwise the published text.
        COALESCE(NULLIF(LTRIM(RTRIM(adopt.obligation_description)), N''),
                 o.obligation_text)     AS ObligationDescription,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        -- 473: each published evidence spec also carries its cadence
        -- (Recurring / OneTime) from the organisation's copy, so the card
        -- can say it before the obligation is adopted.
        COALESCE(evj.EvidenceJson, td.EvidenceJson, N'[]') AS PublishedEvidenceJson,

        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.event_type_id             AS EventTypeId,
        adopt.sla_value                 AS SlaValue,
        adopt.sla_unit                  AS SlaUnit,
        adopt.implementation_status_id  AS ImplementationStatusId,
        -- Migration 244: connection payload for Automated assurance.
        -- Null on any obligation that has not been configured yet.
        adopt.connection_type_id        AS ConnectionTypeId,
        adopt.connection_url            AS ConnectionUrl,
        adopt.responsibility            AS Responsibility,
        -- 412: the owner employee behind Responsibility (NULL on a row
        -- still carrying a legacy role name, or not yet set).
        adopt.owner_employee_id         AS OwnerEmployeeId,
        -- 457: the first-occurrence anchor (338), read back so the
        -- Operationalize date input shows what was saved.
        adopt.first_occurrence_date     AS FirstOccurrenceDate,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount,
        -- 396: 'Retired' once a repository retirement of this obligation
        -- has been approved (flag only -- the card stays, with a badge).
        o.lifecycle_status              AS RepositoryLifecycleStatus,
        -- 473: what was published, kept beside the edited text so the card
        -- can show both and offer the way back.
        o.obligation_text               AS PublishedObligationDescription,
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(adopt.obligation_description)), N'') IS NULL
                  THEN 0 ELSE 1 END AS BIT) AS IsDescriptionOverridden
    FROM   picked pk
    JOIN   grac_practice.fn_org_requirement_obligation(@organization_id) o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.vw_pm_org_obligation_typed_detail td
           ON td.OrganizationId = @organization_id
          AND td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT oe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active'
                   -- 353: an evidence row counts as RESOLVED only once its
                   -- location AND locator are both filled (same test as
                   -- sp_resolve_evidence_list.IsResolved). Before this it
                   -- counted every row that merely EXISTS, so an empty
                   -- evidence row created by the single obligation+evidence
                   -- save turned the obligation green with no details entered.
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedEvidenceCount
        FROM   grac_practice.vw_pm_obligation_evidence oe
        WHERE  oe.organization_id = @organization_id
          AND  oe.obligation_id = pk.obligation_id
    ) ev
    -- 473: cadence onto every element of the copied EvidenceJson. The
    -- element is kept whole (JSON_MODIFY adds two keys), so nothing the
    -- renderer already reads changes. No rows (an empty array) gives NULL
    -- and the COALESCE above falls back to the stored JSON.
    OUTER  APPLY (
        SELECT N'[' + STRING_AGG(CAST(
                   JSON_MODIFY(JSON_MODIFY(j.[value],
                       '$.EvidenceCadence', COALESCE(ooe.evidence_cadence, N'Recurring')),
                       '$.EvidenceCadenceLabel', COALESCE(cad.option_label, ooe.evidence_cadence, N'Recurring'))
                   AS NVARCHAR(MAX)), N',') WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) + N']' AS EvidenceJson
        FROM   OPENJSON(td.EvidenceJson) j
        LEFT   JOIN grac_practice.organization_obligation_evidence ooe
               ON ooe.organization_id = @organization_id
              AND ooe.obligation_evidence_id = TRY_CAST(JSON_VALUE(j.[value], '$.ObligationEvidenceId') AS BIGINT)
        LEFT   JOIN GRAC_New.reference_option cad
               ON cad.option_group = N'evidence-cadence'
              AND cad.option_value = COALESCE(ooe.evidence_cadence, N'Recurring')
        WHERE  ISJSON(td.EvidenceJson) = 1
          AND  j.[type] = 5
    ) evj

    UNION ALL
    SELECT
        CAST(NULL AS BIGINT)            AS ObligationId,
        CAST(1 AS BIT)                  AS IsOrganizationDefined,
        N'l' + CAST(pio.practice_instance_obligation_id AS NVARCHAR(20)) AS RowKey,
        1000 + CAST(pio.practice_instance_obligation_id % 1000 AS INT) AS SortOrder,
        pio.obligation_name             AS ObligationName,
        pio.obligation_description      AS ObligationText,
        pio.obligation_description      AS ObligationDescription,
        pio.obligation_type_code        AS TypeCode,
        lt.type_name                    AS TypeName,
        CAST(NULL AS BIGINT)            AS ReleaseId,
        CAST(NULL AS NVARCHAR(400))     AS FrameworkRelease,
        CAST(1 AS BIT)                  AS IsSubscribed,

        CAST(NULL AS NVARCHAR(200))     AS PublishedExecutionFrequency,
        CAST(NULL AS NVARCHAR(300))     AS PublishedResponsibility,
        CAST(NULL AS NVARCHAR(300))     AS PublishedApprovalAuthority,
        CAST(NULL AS NVARCHAR(200))     AS PublishedRetention,

        CASE WHEN pio.obligation_type_code = N'State'         THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS StateRulesJson,
        CASE WHEN pio.obligation_type_code = N'Execution'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ExecutionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Assurance'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS AssuranceSpecsJson,
        CASE WHEN pio.obligation_type_code = N'EventResponse' THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS EventResponsesJson,
        CASE WHEN pio.obligation_type_code = N'Constraint'    THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ConstraintRulesJson,
        CASE WHEN pio.obligation_type_code = N'Retention'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS RetentionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Evidence'      THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS PublishedEvidenceJson,

        pio.practice_instance_obligation_id AS AdoptionId,
        CAST(1 AS BIT)                  AS IsAdopted,
        CAST(1 AS BIT)                  AS OrganizationModified,
        pio.execution_frequency_id      AS ExecutionFrequencyId,
        pio.execution_frequency         AS ExecutionFrequency,
        pio.assurance_frequency_id      AS AssuranceFrequencyId,
        pio.assurance_frequency         AS AssuranceFrequency,
        pio.event_type_id               AS EventTypeId,
        pio.sla_value                   AS SlaValue,
        pio.sla_unit                    AS SlaUnit,
        pio.implementation_status_id    AS ImplementationStatusId,
        -- Migration 244: mirrors the top half.
        pio.connection_type_id          AS ConnectionTypeId,
        pio.connection_url              AS ConnectionUrl,
        pio.responsibility              AS Responsibility,
        pio.owner_employee_id           AS OwnerEmployeeId,
        pio.first_occurrence_date       AS FirstOccurrenceDate,
        pio.approval_authority          AS ApprovalAuthority,
        pio.retention_period            AS RetentionPeriod,
        pio.assurance_type              AS AdoptedAssuranceType,
        pio.remarks                     AS Remarks,
        pio.adopted_by                  AS AdoptedBy,
        pio.adopted_dt                  AS AdoptedDt,

        0                               AS PublishedEvidenceCount,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie2
          WHERE pie2.practice_instance_id = @practice_instance_id
            AND pie2.source_practice_instance_obligation_id = pio.practice_instance_obligation_id
            AND pie2.status = N'Active'
            -- 353: resolved = location AND locator both filled (see fix above).
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_location, N''))), N'') IS NOT NULL
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_locator,  N''))), N'') IS NOT NULL)  AS ResolvedEvidenceCount,
        CAST(NULL AS NVARCHAR(20))      AS RepositoryLifecycleStatus,
        -- 473: nothing is published for an organisation-defined obligation;
        -- its text is edited with Edit obligation, not overridden here.
        CAST(NULL AS NVARCHAR(MAX))     AS PublishedObligationDescription,
        CAST(0 AS BIT)                  AS IsDescriptionOverridden
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN GRAC_New.obligation_type_master lt
           ON lt.type_code = pio.obligation_type_code
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.obligation_id IS NULL
      AND  pio.status = N'Active'
    ) x
    ORDER  BY x.SortOrder, x.ObligationName;
END
GO

-- ---------------------------------------------------------------------
-- 4b. sp_resolve_evidence_list (from 394)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL,
    -- 232. Filters to one organisation-defined obligation. Separate from
    -- @obligation_id rather than overloading it: they index different
    -- tables, and a NULL @obligation_id already means "every row".
    @practice_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    -- 394: repository evidence text comes from the organization's copy.
    DECLARE @copy_organization_id BIGINT = (
        SELECT organization_id FROM grac_practice.practice_instance
        WHERE practice_instance_id = @practice_instance_id);

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
        -- 231/232. A locally added obligation has no GRAC_New id, so this
        -- is what says which one an evidence row belongs to.
        e.source_practice_instance_obligation_id AS SourcePracticeInstanceObligationId,
        -- Migration 254: the organisation's own label for this row.
        e.evidence_name           AS EvidenceName,
        e.evidence_type_id        AS EvidenceTypeId,
        et.evidence_type_name     AS EvidenceType,

        -- Migration 306: what the authority published as the instruction
        -- for this evidence. Exact source row first, then the
        -- obligation + type fallback for a row that has no
        -- source_obligation_evidence_id.
        -- CAST before LTRIM/RTRIM: the column is repository-owned, and
        -- LTRIM on an ntext argument is Msg 8116, not a NULL. Casting
        -- costs nothing when it is already NVARCHAR(MAX) and removes the
        -- guess about which it is.
        COALESCE(
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe
             WHERE  roe.obligation_evidence_id = e.source_obligation_evidence_id
               AND  roe.status = N'Active'),
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.vw_pm_obligation_evidence oe
             JOIN   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe2
                    ON roe2.obligation_evidence_id = oe.obligation_evidence_id
             JOIN   GRAC_New.evidence_type_master get
                    ON get.evidence_type_id = oe.evidence_type_id
             JOIN   grac_practice.evidence_type_master pet
                    ON pet.evidence_type_name = get.evidence_type_name
                   AND pet.is_active = 1
             WHERE  oe.organization_id    = @copy_organization_id
               AND  oe.obligation_id      = e.source_obligation_id
               AND  pet.evidence_type_id  = e.evidence_type_id
               AND  roe2.status = N'Active'
               AND  NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'') IS NOT NULL
             ORDER  BY oe.obligation_evidence_id)
        )                         AS EvidenceRemarks,

        e.is_mandatory            AS IsMandatory,
        e.collection_method_id    AS CollectionMethodId,
        cm.collection_method_name AS CollectionMethod,
        e.collection_frequency_id AS CollectionFrequencyId,
        f.frequency_name          AS CollectionFrequency,
        e.assurance_type_id       AS AssuranceTypeId,
        at2.assurance_type_name   AS AssuranceType,
        e.retention_period        AS RetentionPeriod,
        e.evidence_owner          AS EvidenceOwner,
        e.evidence_description    AS EvidenceDescription,
        e.evidence_location       AS EvidenceLocation,
        e.evidence_locator        AS EvidenceLocator,
        e.alignment_status_id     AS AlignmentStatusId,
        al.alignment_status_name  AS AlignmentStatus,
        e.inherited_from_repository AS InheritedFromRepository,
        e.organization_modified     AS OrganizationModified,

        -- The same two-field test assurance eligibility applies, so the
        -- workspace cannot report ready on a row assurance would reject.
        -- Migration 254 deliberately does NOT add the name here, and 306
        -- does not add the remark: a published instruction is not an
        -- organisation answer, so it cannot move a row towards resolved.
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved,

        -- 473: is this proof produced once (attached here, at
        -- implementation) or again for every scheduled occurrence?
        -- Read from the organisation's copy of the published spec through
        -- vw_pm_instance_evidence_cadence; 'Default' = nothing published
        -- (organisation-defined evidence), which is treated as Recurring.
        cad.EvidenceCadence       AS EvidenceCadence,
        cad.EvidenceCadenceLabel  AS EvidenceCadenceLabel,
        cad.CadenceSource         AS EvidenceCadenceSource,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence_attachment ea
          WHERE ea.evidence_id = e.evidence_id AND ea.status = N'Active') AS AttachmentCount
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence cad
           ON cad.evidence_id = e.evidence_id
    LEFT   JOIN grac_practice.evidence_type_master et
           ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.collection_method_master cm
           ON cm.collection_method_id = e.collection_method_id
    LEFT   JOIN grac_practice.frequency_master f
           ON f.frequency_id = e.collection_frequency_id
    LEFT   JOIN grac_practice.assurance_type_master at2
           ON at2.assurance_type_id = e.assurance_type_id
    LEFT   JOIN grac_practice.evidence_alignment_status_master al
           ON al.alignment_status_id = e.alignment_status_id
    WHERE  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND (@obligation_id IS NULL OR e.source_obligation_id = @obligation_id)
      AND (@practice_instance_obligation_id IS NULL
           OR e.source_practice_instance_obligation_id = @practice_instance_obligation_id)
    ORDER  BY CASE WHEN e.source_obligation_id IS NULL THEN 1 ELSE 0 END,
              e.source_obligation_id,
              -- Migration 254: a named row sorts by its name, an unnamed
              -- one keeps sorting by type, so adding a name never scatters
              -- the list into a new order the operator did not ask for.
              COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name);
END
GO

-- ---------------------------------------------------------------------
-- 4c. sp_resolve_evidence_save (from 254)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_save
    @practice_instance_id   BIGINT,
    @evidence_id            BIGINT,
    @is_mandatory           BIT           = NULL,
    @collection_method_id   INT           = NULL,
    @collection_frequency_id INT          = NULL,
    @assurance_type_id      INT           = NULL,
    @retention_period       NVARCHAR(120) = NULL,
    @owner_employee_id      BIGINT        = NULL,
    @clear_owner            BIT           = 0,
    @evidence_description   NVARCHAR(MAX) = NULL,
    @evidence_location      NVARCHAR(500) = NULL,
    @evidence_locator       NVARCHAR(500) = NULL,
    -- Migration 254. NULL means "unchanged", same contract as every other
    -- optional field here.
    @evidence_name          NVARCHAR(300) = NULL,
    @actor                  NVARCHAR(100) = N'system',
    -- Migration 473. The Description box now opens on the published
    -- evidence description, so "back to what was published" has to be
    -- sayable: 1 stores NULL, and the screen shows the published text
    -- again. NULL @evidence_description alone still means "unchanged".
    @clear_evidence_description BIT       = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52641, 'sp_resolve_evidence_save: practice instance and evidence row are both required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = e.organization_id
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active';

    -- Scoped to the instance the caller already opened, so an evidence id
    -- from somewhere else matches nothing rather than being editable by
    -- guessing the number.
    IF @organization_id IS NULL
        THROW 52642, 'sp_resolve_evidence_save: that evidence row was not found on this practice instance.', 1;

    -- The owner picker is filled from the shared lookups feed, which is
    -- not scoped to one organization. Verify before writing the name.
    DECLARE @owner_name NVARCHAR(200) = NULL;
    IF @owner_employee_id IS NOT NULL
    BEGIN
        SELECT @owner_name = e.employee_name
        FROM   grac_practice.organization_employee e
        WHERE  e.employee_id     = @owner_employee_id
          AND  e.organization_id = @organization_id
          AND  e.status          = N'Active';

        IF @owner_name IS NULL
            THROW 52643, 'sp_resolve_evidence_save: the evidence owner must be an active employee of this organization.', 1;
    END

    IF @collection_method_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.collection_method_master
                        WHERE collection_method_id = @collection_method_id AND is_active = 1)
        THROW 52644, 'sp_resolve_evidence_save: that collection method does not exist.', 1;

    IF @collection_frequency_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                        WHERE frequency_id = @collection_frequency_id AND is_active = 1)
        THROW 52645, 'sp_resolve_evidence_save: that collection frequency does not exist.', 1;

    -- Alignment: once the organization sets any of its own parameters the
    -- row is no longer what the repository published. Worked out from the
    -- values after the update rather than taken from the caller.
    DECLARE @org_defined_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Organization Defined'
        ORDER BY alignment_status_id);
    DECLARE @inherited_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);

    UPDATE e
       SET is_mandatory            = COALESCE(@is_mandatory, e.is_mandatory),
           collection_method_id    = COALESCE(@collection_method_id, e.collection_method_id),
           collection_frequency_id = COALESCE(@collection_frequency_id, e.collection_frequency_id),
           assurance_type_id       = COALESCE(@assurance_type_id, e.assurance_type_id),
           retention_period        = COALESCE(@retention_period, e.retention_period),
           evidence_owner          = CASE WHEN @clear_owner = 1 THEN NULL
                                          ELSE COALESCE(@owner_name, e.evidence_owner) END,
           evidence_name           = COALESCE(@evidence_name, e.evidence_name),
           evidence_description    = CASE WHEN @clear_evidence_description = 1 THEN NULL
                                          ELSE COALESCE(@evidence_description, e.evidence_description) END,
           evidence_location       = COALESCE(@evidence_location, e.evidence_location),
           evidence_locator        = COALESCE(@evidence_locator, e.evidence_locator),
           organization_modified   = 1,
           alignment_status_id     = COALESCE(@org_defined_id, e.alignment_status_id),
           updated_by              = @actor,
           updated_dt              = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id;

    -- A row that was only ever touched to blank things back out is
    -- inherited again; saying otherwise would overstate what the
    -- organization has decided. Migration 254 adds the name to this test
    -- for the same reason evidence_description is already in it.
    UPDATE e
       SET organization_modified = 0,
           alignment_status_id   = COALESCE(@inherited_id, e.alignment_status_id)
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.inherited_from_repository = 1
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location,    N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,     N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_owner,       N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_name,        N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_description, N''))), N'') IS NULL;

    SELECT CAST(1 AS BIT) AS Success,
           e.evidence_id  AS EvidenceId,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                     THEN 1 ELSE 0 END AS BIT) AS IsResolved,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence x
             WHERE x.practice_instance_id = @practice_instance_id
               AND x.status = N'Active'
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_location, N''))), N'') IS NOT NULL
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedOnInstance,
           N'Evidence saved.' AS Message
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id = @evidence_id;
END
GO

-- ---------------------------------------------------------------------
-- 4d. sp_task_completion_eligibility (from 194)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_completion_eligibility
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55680, 'sp_task_completion_eligibility: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @exists BIT = 0,
            @source_type NVARCHAR(40), @source_record_id BIGINT;   -- 473
    SELECT @closed_at        = closed_at,
           @source_type      = source_type_code,
           @source_record_id = source_record_id,
           @exists           = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @exists = 0
        THROW 55681, 'sp_task_completion_eligibility: task not found.', 1;

    DECLARE @child_total     INT = 0,
            @mand_total      INT = 0,
            @mand_completed  INT = 0;

    SELECT @child_total    = COUNT(*),
           @mand_total     = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1 THEN 1 ELSE 0 END),
           @mand_completed = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1
                                       AND c.closed_at IS NOT NULL THEN 1 ELSE 0 END)
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = @task_id;

    SET @mand_total     = ISNULL(@mand_total, 0);
    SET @mand_completed = ISNULL(@mand_completed, 0);

    -- 473: a task raised for a scheduled occurrence (449, source
    -- 'Schedule') whose obligation expects RECURRING evidence cannot be
    -- completed until evidence is attached to the task. One-time evidence
    -- is attached once, on Operationalize, and is not asked for again.
    DECLARE @recurring_count INT = 0, @recurring_names NVARCHAR(MAX) = NULL,
            @attachment_count INT = 0;
    IF @source_type = N'Schedule' AND @source_record_id IS NOT NULL
    BEGIN
        SELECT @recurring_count = COUNT(*),
               @recurring_names = STRING_AGG(CAST(COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''),
                                                           get.evidence_type_name, N'Evidence')
                                                  AS NVARCHAR(MAX)), N', ')
          FROM grac_practice.schedule_occurrence_task x
          JOIN grac_practice.practice_instance_obligation pio
            ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
          JOIN grac_practice.practice_instance_evidence pie
            ON pie.practice_instance_id = x.practice_instance_id
           AND pie.status = N'Active'
           AND (   (pio.obligation_id IS NOT NULL AND pie.source_obligation_id = pio.obligation_id)
                OR pie.source_practice_instance_obligation_id = pio.practice_instance_obligation_id)
          JOIN grac_practice.vw_pm_instance_evidence_cadence c
            ON c.evidence_id = pie.evidence_id
          LEFT JOIN GRAC_New.evidence_type_master get
            ON get.evidence_type_id = pie.evidence_type_id
         WHERE x.occurrence_task_id = @source_record_id
           AND c.EvidenceCadence = N'Recurring';

        SELECT @attachment_count = COUNT(*)
          FROM grac_practice.task_attachment ta
         WHERE ta.task_id = @task_id;
    END

    DECLARE @eligible BIT, @reason NVARCHAR(300);

    IF @closed_at IS NOT NULL
    BEGIN
        SET @eligible = 0;
        SET @reason   = N'Task is already completed.';
    END
    ELSE IF @mand_total > @mand_completed
    BEGIN
        SET @eligible = 0;
        SET @reason   = CONCAT(N'Waiting on ', @mand_total - @mand_completed,
                               N' of ', @mand_total, N' mandatory child task(s).');
    END
    ELSE IF @recurring_count > 0 AND @attachment_count = 0
    BEGIN
        SET @eligible = 0;
        SET @reason   = LEFT(CONCAT(N'Attach the evidence for this occurrence before completing it (recurring evidence: ',
                                    @recurring_names, N').'), 300);
    END
    ELSE
    BEGIN
        SET @eligible = 1;
        SET @reason   = CASE WHEN @child_total = 0
                             THEN N'No child tasks - ready to complete.'
                             ELSE N'All mandatory child tasks are complete - ready for owner confirmation.'
                        END;
    END

    SELECT @task_id        AS TaskId,
           @eligible       AS IsEligible,
           @reason         AS Reason,
           @child_total    AS ChildCount,
           @mand_total     AS MandatoryChildCount,
           @mand_completed AS MandatoryChildCompletedCount,
           @mand_total - @mand_completed AS MandatoryChildOpenCount;
END;
GO

-- =====================================================================
-- 5. New procedures
-- =====================================================================

-- ---------------------------------------------------------------------
-- 5a. sp_resolve_obligation_description_save
--
--   The Operationalize card's Description box for a PUBLISHED obligation.
--   @payload_json = [{ "obligationId": n, "description": "..." }, ...]
--   For each element, on the instance's ACTIVE adoption of that obligation:
--     empty / blank, or the same text as published -> NULL (as published)
--     anything else                                -> stored as written
--   An obligation that is not adopted on this instance is skipped (the
--   caller adopts first, in the same request). Organisation-defined
--   obligations are not touched -- their text is edited with Edit
--   obligation (sp_resolve_local_obligation_save).
--   Comparisons are binary (a change of case or punctuation is kept) and
--   ignore CRLF vs LF.
--   Every change is written to practice_audit_trace.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_description_save
    @practice_instance_id BIGINT,
    @payload_json         NVARCHAR(MAX),
    @actor                NVARCHAR(100) = N'system',
    @saved                INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @saved = 0;

    IF @practice_instance_id IS NULL
        THROW 52770, 'sp_resolve_obligation_description_save: practice_instance_id is required.', 1;
    IF @payload_json IS NULL RETURN;
    IF ISJSON(@payload_json) <> 1
        THROW 52771, 'sp_resolve_obligation_description_save: the payload must be a JSON array.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;
    IF @organization_id IS NULL
        THROW 52772, 'sp_resolve_obligation_description_save: instance not found.', 1;

    DECLARE @rows TABLE (obligation_id BIGINT NOT NULL PRIMARY KEY, description NVARCHAR(MAX) NULL);
    INSERT @rows(obligation_id, description)
    SELECT j.obligationId, MAX(j.description)
    FROM   OPENJSON(@payload_json)
           WITH (obligationId BIGINT        '$.obligationId',
                 description  NVARCHAR(MAX) '$.description') j
    WHERE  j.obligationId > 0
    GROUP  BY j.obligationId;

    DECLARE @changes TABLE (
        practice_instance_obligation_id BIGINT,
        obligation_id BIGINT,
        before_text   NVARCHAR(MAX),
        after_text    NVARCHAR(MAX));

    BEGIN TRAN;

    UPDATE pio
       SET obligation_description = n.new_text,
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
    OUTPUT inserted.practice_instance_obligation_id, inserted.obligation_id,
           deleted.obligation_description, inserted.obligation_description
      INTO @changes(practice_instance_obligation_id, obligation_id, before_text, after_text)
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   @rows r ON r.obligation_id = pio.obligation_id
    OUTER  APPLY (SELECT TOP 1 CAST(o.obligation_text AS NVARCHAR(MAX)) AS obligation_text
                  FROM   grac_practice.fn_org_requirement_obligation(@organization_id) o
                  WHERE  o.obligation_id = r.obligation_id
                  ORDER  BY CASE WHEN o.status = N'Active' THEN 0 ELSE 1 END) pub
    CROSS  APPLY (SELECT CASE
                    WHEN NULLIF(LTRIM(RTRIM(r.description)), N'') IS NULL THEN NULL
                    -- A browser textarea returns LF line breaks; the
                    -- published text may hold CRLF. Compared without that
                    -- difference, so re-saving the published text is
                    -- recognised as "as published".
                    WHEN REPLACE(LTRIM(RTRIM(r.description)), NCHAR(13) + NCHAR(10), NCHAR(10)) COLLATE Latin1_General_BIN2
                       = REPLACE(LTRIM(RTRIM(ISNULL(pub.obligation_text, N''))), NCHAR(13) + NCHAR(10), NCHAR(10))
                         COLLATE Latin1_General_BIN2 THEN NULL
                    ELSE r.description END AS new_text) n
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.obligation_id IS NOT NULL
      AND  pio.status = N'Active'
      AND  ISNULL(pio.obligation_description, N'') COLLATE Latin1_General_BIN2
        <> ISNULL(n.new_text, N'') COLLATE Latin1_General_BIN2;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'practice-instance-obligation', c.practice_instance_obligation_id, N'UPDATE_DESCRIPTION',
           (SELECT c.obligation_id AS obligationId, c.before_text AS [description]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           (SELECT c.obligation_id AS obligationId, c.after_text AS [description]
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           N'Active', @actor
    FROM   @changes c;

    SET @saved = (SELECT COUNT(*) FROM @changes);
    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- 5b. sp_resolve_evidence_attachment_add
--
--   A file attached to an evidence row at implementation. Only ONE-TIME
--   evidence takes one here: recurring evidence is produced again for
--   every occurrence and is attached to that occurrence's task (see
--   sp_task_completion_eligibility).
--   Result: EvidenceAttachmentId, FileSizeBytes.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_add
    @practice_instance_id    BIGINT,
    @evidence_id             BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @attachment_description  NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    -- The organisation the Web tier checked the caller against. NULL = no
    -- check (a call from SQL); when given, the instance must belong to it.
    @organization_id         BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52760, 'sp_resolve_evidence_attachment_add: practice instance and evidence row are both required.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 52761, 'sp_resolve_evidence_attachment_add: a file name is required.', 1;
    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 52762, 'sp_resolve_evidence_attachment_add: the file is empty.', 1;

    DECLARE @row_organization_id BIGINT, @cadence NVARCHAR(30);
    SELECT @row_organization_id = e.organization_id,
           @cadence             = c.EvidenceCadence
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND  (@organization_id IS NULL OR e.organization_id = @organization_id);
    SET @organization_id = @row_organization_id;

    -- Scoped to the instance the caller opened, the sp_resolve_evidence_save way.
    IF @organization_id IS NULL
        THROW 52763, 'sp_resolve_evidence_attachment_add: that evidence row was not found on this practice instance.', 1;
    IF ISNULL(@cadence, N'Recurring') <> N'OneTime'
        THROW 52764, 'Only one-time evidence is attached on Operationalize. Recurring evidence is attached to each scheduled task when it is completed.', 1;

    -- The uploader comes from the session (Web tier). Kept only when it is
    -- an employee of this organisation; the name stamp is kept either way.
    IF @uploaded_by_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @uploaded_by_employee_id
                          AND oe.organization_id = @organization_id)
        SET @uploaded_by_employee_id = NULL;

    DECLARE @size BIGINT = DATALENGTH(@file_data), @attachment_id BIGINT;

    BEGIN TRAN;

    INSERT grac_practice.practice_instance_evidence_attachment
        (organization_id, practice_instance_id, evidence_id, file_name, content_type,
         file_size_bytes, file_data, attachment_description, status,
         uploaded_by_employee_id, uploaded_by, uploaded_dt)
    VALUES
        (@organization_id, @practice_instance_id, @evidence_id, LTRIM(RTRIM(@file_name)), @content_type,
         @size, @file_data, NULLIF(LTRIM(RTRIM(@attachment_description)), N''), N'Active',
         @uploaded_by_employee_id, ISNULL(@actor, N'system'), SYSUTCDATETIME());

    SET @attachment_id = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'practice-instance-evidence-attachment', @attachment_id, N'CREATE', NULL,
           (SELECT @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   LTRIM(RTRIM(@file_name)) AS fileName, @size AS fileSizeBytes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', ISNULL(@actor, N'system');

    COMMIT;

    SELECT @attachment_id AS EvidenceAttachmentId, @size AS FileSizeBytes;
END
GO

-- ---------------------------------------------------------------------
-- 5c. sp_resolve_evidence_attachment_list -- metadata only (no file_data)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_list
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52765, 'sp_resolve_evidence_attachment_list: practice_instance_id is required.', 1;

    SELECT a.evidence_attachment_id  AS EvidenceAttachmentId,
           a.evidence_id             AS EvidenceId,
           a.file_name               AS FileName,
           a.content_type            AS ContentType,
           a.file_size_bytes         AS FileSizeBytes,
           a.attachment_description  AS AttachmentDescription,
           a.uploaded_by_employee_id AS UploadedByEmployeeId,
           COALESCE(emp.employee_name, a.uploaded_by) AS UploadedByName,
           a.uploaded_dt             AS UploadedDt
    FROM   grac_practice.practice_instance_evidence_attachment a
    LEFT   JOIN grac_practice.organization_employee emp
           ON emp.employee_id = a.uploaded_by_employee_id
    WHERE  a.practice_instance_id = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id)
    ORDER  BY a.evidence_id, a.uploaded_dt DESC, a.evidence_attachment_id DESC;
END
GO

-- ---------------------------------------------------------------------
-- 5d. sp_resolve_evidence_attachment_get -- one file, for download.
--     Scoped to the instance: an id from another instance returns nothing.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_get
    @practice_instance_id   BIGINT,
    @evidence_attachment_id BIGINT,
    @organization_id        BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.evidence_attachment_id AS EvidenceAttachmentId,
           a.evidence_id            AS EvidenceId,
           a.file_name              AS FileName,
           a.content_type           AS ContentType,
           a.file_size_bytes        AS FileSizeBytes,
           a.file_data              AS FileData
    FROM   grac_practice.practice_instance_evidence_attachment a
    WHERE  a.evidence_attachment_id = @evidence_attachment_id
      AND  a.practice_instance_id   = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id);
END
GO

-- ---------------------------------------------------------------------
-- 5e. sp_resolve_evidence_attachment_remove -- soft remove, audited.
--     The bytes stay (status = Removed) so the audit trail can still
--     say what was there.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_remove
    @practice_instance_id   BIGINT,
    @evidence_attachment_id BIGINT,
    @actor                  NVARCHAR(100) = N'system',
    @organization_id        BIGINT        = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_attachment_id IS NULL
        THROW 52766, 'sp_resolve_evidence_attachment_remove: practice instance and attachment are both required.', 1;

    DECLARE @file_name NVARCHAR(500), @evidence_id BIGINT;
    SELECT @file_name = a.file_name, @evidence_id = a.evidence_id
    FROM   grac_practice.practice_instance_evidence_attachment a
    WHERE  a.evidence_attachment_id = @evidence_attachment_id
      AND  a.practice_instance_id   = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id);

    IF @evidence_id IS NULL
        THROW 52767, 'sp_resolve_evidence_attachment_remove: that attachment was not found on this practice instance.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.practice_instance_evidence_attachment
       SET status     = N'Removed',
           removed_by = ISNULL(@actor, N'system'),
           removed_dt = SYSUTCDATETIME()
     WHERE evidence_attachment_id = @evidence_attachment_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'practice-instance-evidence-attachment', @evidence_attachment_id, N'REMOVE',
           (SELECT @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   @file_name AS fileName, N'Active' AS status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT N'Removed' AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', ISNULL(@actor, N'system');

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Attachment removed.' AS Message;
END
GO

-- =====================================================================
-- 6. Verification
-- =====================================================================
SELECT '473 copy carries evidence_cadence' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.organization_obligation_evidence','evidence_cadence') IS NOT NULL
             AND COL_LENGTH('grac_practice.vw_repo_src_obligation_evidence','evidence_cadence') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '473 sp_resolve_obligation_list returns PublishedObligationDescription',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list')) LIKE '%AS PublishedObligationDescription%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '473 sp_resolve_evidence_list returns EvidenceCadence',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list')) LIKE '%AS EvidenceCadence%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '473 sp_resolve_evidence_save takes @clear_evidence_description',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_evidence_save')
                            AND name = '@clear_evidence_description')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '473 completion gate reads the evidence cadence',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) LIKE '%vw_pm_instance_evidence_cadence%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '473 attachment procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_list','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_get','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_remove','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_resolve_obligation_description_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- What the organisation copies hold now (NULL = copy still behind 077,
-- waiting in Repository Updates; it reads as Recurring meanwhile).
SELECT organization_id,
       Recurring    = SUM(CASE WHEN evidence_cadence = N'Recurring' THEN 1 ELSE 0 END),
       OneTime      = SUM(CASE WHEN evidence_cadence = N'OneTime'   THEN 1 ELSE 0 END),
       NotYetCopied = SUM(CASE WHEN evidence_cadence IS NULL        THEN 1 ELSE 0 END)
FROM   grac_practice.organization_obligation_evidence
GROUP  BY organization_id
ORDER  BY organization_id;
GO

PRINT '473 complete.';
GO
