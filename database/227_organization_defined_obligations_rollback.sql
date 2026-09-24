-- =====================================================================
-- 227 Organisation-defined obligations -- ROLLBACK
--
-- Undoes database/227_organization_defined_obligations.sql:
--   1. Restores grac_practice.sp_resolve_obligation_list to the 226 body
--      (published obligations only -- no RowKey, no local half).
--   2. Drops sp_resolve_local_obligation_save and
--      sp_resolve_obligation_type_fields.
--   3. Puts the schema back ONLY IF no organisation-defined obligation
--      exists. See below.
--
-- THE SCHEMA IS NOT FORCED BACK
-- -----------------------------
-- obligation_id can only return to NOT NULL, and the unfiltered UNIQUE
-- constraint can only return, if there is no row with obligation_id
-- IS NULL. Every organisation-defined obligation is such a row.
--
-- So section 3 checks first. If any exist it stops, says how many, and
-- leaves the column NULLable and the filtered index in place -- because
-- the alternative is deleting an organisation's own compliance
-- obligations to satisfy a constraint, which no rollback should do on
-- its own initiative.
--
-- With the procedures gone those rows are simply invisible: the restored
-- list procedure reads only the published side. They are still there,
-- and re-running 227 brings them back.
--
-- To go all the way back, decide about them explicitly first:
--
--     SELECT practice_instance_id, practice_instance_obligation_id,
--            obligation_name, obligation_type_code, entered_by, entered_dt
--     FROM   grac_practice.practice_instance_obligation
--     WHERE  obligation_id IS NULL;
--
-- then retire or delete them, and re-run this script.
--
-- The two added columns (obligation_description, typed_detail_json) are
-- kept either way -- they are nullable, nothing reads them once the
-- procedures are gone, and dropping them would throw away the rule
-- detail those rows carry.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN
    PRINT 'ABORT (227 rollback): vw_pm_obligation_typed_detail missing -- the restored list procedure reads it. Re-run 224/225 first, or roll those back instead.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_obligation_list -- back to the 226 body.
-- =====================================================================
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
        LEFT   JOIN GRAC_New.requirement repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   GRAC_New.obligation_requirement_release_map orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    -- One row per obligation. Where the same obligation rides several
    -- subscribed releases, the lowest release_id is the representative --
    -- an arbitrary but stable choice, so the card does not reshuffle
    -- between loads.
    picked AS (
        SELECT obligation_id,
               MIN(release_id)      AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT
        o.obligation_id                 AS ObligationId,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        -- Same value as ObligationText. Named separately because the card
        -- shows it under a "Description" heading, and a caller reading
        -- ObligationText for the title fallback should not have to know
        -- that the two uses are the same column today.
        o.obligation_text               AS ObligationDescription,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        -- As published. Kept for the pre-taxonomy obligations that still
        -- carry only these, and as the fallback when a typed obligation
        -- has no detail rows yet.
        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        -- Typed detail (224). Whichever array matches TypeCode is what
        -- the admin module actually captured for this obligation.
        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS PublishedEvidenceJson,

        -- As adopted here. NULL until the organization adopts it.
        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        -- What adopting will create, and what already exists.
        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount
    FROM   picked pk
    JOIN   GRAC_New.requirement_obligation o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
           ON td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT roe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   GRAC_New.requirement_obligation_evidence roe
        WHERE  roe.obligation_id = pk.obligation_id
    ) ev
    ORDER  BY ISNULL(t.display_order, 999),
              COALESCE(o.obligation_name, o.obligation_text);
END
GO

PRINT '227 rollback: sp_resolve_obligation_list restored to the 226 body.';
GO

-- =====================================================================
-- 2. Drop the procedures 227 added.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_local_obligation_save;
    PRINT '227 rollback: sp_resolve_local_obligation_save dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_obligation_type_fields;
    PRINT '227 rollback: sp_resolve_obligation_type_fields dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_obligation_type_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_obligation_type_list;
    PRINT '227 rollback: sp_resolve_obligation_type_list dropped.';
END
GO

-- =====================================================================
-- 3. Schema -- only when nothing depends on it staying.
-- =====================================================================
DECLARE @local_rows INT = (
    SELECT COUNT(*) FROM grac_practice.practice_instance_obligation
    WHERE obligation_id IS NULL);

IF @local_rows > 0
BEGIN
    PRINT '227 rollback: ' + CAST(@local_rows AS NVARCHAR(20))
        + ' organisation-defined obligation(s) exist. The column stays NULLable and the';
    PRINT '              filtered index stays in place -- see the header for how to proceed.';
END
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_pio_instance_obligation'
                  AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
    BEGIN
        DROP INDEX ux_pm_pio_instance_obligation
            ON grac_practice.practice_instance_obligation;
        PRINT '227 rollback: ux_pm_pio_instance_obligation dropped.';
    END

    IF EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('grac_practice.practice_instance_obligation')
                  AND name = 'obligation_id' AND is_nullable = 1)
    BEGIN
        ALTER TABLE grac_practice.practice_instance_obligation
            ALTER COLUMN obligation_id BIGINT NOT NULL;
        PRINT '227 rollback: obligation_id is NOT NULL again.';
    END

    IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
                    WHERE name = 'uq_pm_practice_instance_obligation')
    BEGIN
        ALTER TABLE grac_practice.practice_instance_obligation
            ADD CONSTRAINT uq_pm_practice_instance_obligation
            UNIQUE(practice_instance_id, obligation_id);
        PRINT '227 rollback: uq_pm_practice_instance_obligation restored.';
    END
END
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 227 rollback verification ===';

SELECT 'list procedure has no RowKey' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P')) LIKE '%RowKey%'
            THEN 'FAIL' ELSE 'PASS' END AS Result
UNION ALL
SELECT 'procedures dropped',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_obligation_type_list','P')   IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'organisation-defined obligations remaining',
       CAST((SELECT COUNT(*) FROM grac_practice.practice_instance_obligation
              WHERE obligation_id IS NULL) AS NVARCHAR(20))
UNION ALL
SELECT 'schema fully reverted',
       CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints
                          WHERE name = 'uq_pm_practice_instance_obligation')
            THEN 'YES' ELSE 'NO -- local rows still present, see the PRINT above' END;

PRINT '';
PRINT '227 rollback complete.';
GO

SET NOEXEC OFF;
GO
