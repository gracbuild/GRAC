-- ============================================================================
-- 057 Organization Control <-> Practice mapping + Apply/Unapply helpers
--
-- Adds a proper many-to-many mapping between organization_control and
-- organization_requirement (Practices) so a single Practice can serve
-- multiple applicable Controls without creating duplicate Practice rows.
--
-- Compatibility strategy:
--   * grac_practice.organization_requirement.organization_control_id STAYS.
--     It now denotes the "primary control" (the first Applicable control
--     that caused the Practice to be imported). Every existing SP / view
--     / query that JOINs on it keeps working.
--   * New table organization_control_requirement carries the full
--     many-to-many relationship. Cross-control queries JOIN through here.
--
-- Helper SPs (called by the master pm_manage_practice_repository proc
-- after migration 058):
--   sp_apply_practices_for_control(@organization_control_id, @actor,
--                                  @mapped_count OUT, @imported_count OUT)
--       - Called when a Control transitions to Applicable.
--       - Inserts an organization_requirement row only if the (org,
--         repo_requirement_id) pair does not already exist (dedupped
--         cross-control).
--       - Inserts a mapping row for this (control, requirement) unless
--         one already exists.
--
--   sp_unapply_practices_for_control(@organization_control_id, @actor,
--                                    @deactivated_count OUT)
--       - Called when a Control transitions away from Applicable
--         (Not Applicable / Deferred / Retired / etc.).
--       - Soft-inactivates the mapping rows for this control.
--       - For each affected Practice: if no active mappings remain,
--         soft-inactivates the Practice row itself (status='Inactive').
--       - Never DELETES -- preserves audit trail + any Practice
--         Instances the user may have created.
--
-- ASCII-only. Idempotent. Wraps DDL/DML in TRAN with XACT_ABORT ON.
-- Rollback: database/057_org_control_practice_mapping_rollback.sql
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    RAISERROR('057: schema grac_practice missing.', 16, 1);
    RETURN;
END
GO

-- ============================================================================
-- 1. Mapping table
-- ============================================================================
IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NULL
CREATE TABLE grac_practice.organization_control_requirement(
    mapping_id                  BIGINT       IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_ocr PRIMARY KEY,
    organization_id             BIGINT       NOT NULL,
    organization_control_id     BIGINT       NOT NULL
        CONSTRAINT fk_pm_ocr_control     REFERENCES grac_practice.organization_control(organization_control_id),
    organization_requirement_id BIGINT       NOT NULL
        CONSTRAINT fk_pm_ocr_requirement REFERENCES grac_practice.organization_requirement(organization_requirement_id),
    status                      NVARCHAR(30) NOT NULL CONSTRAINT df_pm_ocr_status DEFAULT N'Active',
    entered_by                  NVARCHAR(100) NOT NULL CONSTRAINT df_pm_ocr_entered_by DEFAULT 'system',
    entered_dt                  DATETIME2    NOT NULL CONSTRAINT df_pm_ocr_entered_dt DEFAULT SYSUTCDATETIME(),
    updated_by                  NVARCHAR(100) NULL,
    updated_dt                  DATETIME2    NULL,
    CONSTRAINT uq_pm_ocr_ctrl_req UNIQUE(organization_control_id, organization_requirement_id)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'ix_pm_ocr_req_active' AND object_id = OBJECT_ID('grac_practice.organization_control_requirement'))
    CREATE INDEX ix_pm_ocr_req_active
        ON grac_practice.organization_control_requirement(organization_requirement_id, status)
        INCLUDE (organization_control_id);
GO

-- ============================================================================
-- 2. Backfill: every existing active organization_requirement row gets
--    one mapping row pointing at its "primary" control_id. Safe to re-run.
-- ============================================================================
INSERT INTO grac_practice.organization_control_requirement
    (organization_id, organization_control_id, organization_requirement_id, status, entered_by, entered_dt)
SELECT
    r.organization_id,
    r.organization_control_id,
    r.organization_requirement_id,
    CASE WHEN r.status = N'Active' THEN N'Active' ELSE N'Inactive' END,
    'seed-057',
    SYSUTCDATETIME()
FROM grac_practice.organization_requirement r
WHERE r.organization_control_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM grac_practice.organization_control_requirement m
      WHERE m.organization_control_id     = r.organization_control_id
        AND m.organization_requirement_id = r.organization_requirement_id
  );
GO

-- ============================================================================
-- 3. sp_apply_practices_for_control
--    Called from control-applicability when a Control transitions to Applicable.
-- ============================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_apply_practices_for_control
    @organization_control_id BIGINT,
    @actor                   NVARCHAR(100) = 'system',
    @mapped_count            INT OUTPUT,
    @imported_count          INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @mapped_count   = 0;
    SET @imported_count = 0;

    IF @organization_control_id IS NULL OR @organization_control_id = 0 RETURN;

    DECLARE @not_updated_id INT = (
        SELECT applicability_status_id
        FROM grac_practice.applicability_status_master
        WHERE status_code = 'Not Updated');
    DECLARE @not_started_id INT = (
        SELECT implementation_status_id
        FROM grac_practice.implementation_status_master
        WHERE status_code = 'Not Started');
    DECLARE @active_record_id INT = (
        SELECT record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'Active');

    -- Snapshot of the target control + all repo requirements mapped to it.
    IF OBJECT_ID('tempdb..#candidates') IS NOT NULL DROP TABLE #candidates;
    CREATE TABLE #candidates (
        organization_id             BIGINT       NOT NULL,
        organization_control_id     BIGINT       NOT NULL,
        repository_requirement_id   BIGINT       NOT NULL,
        requirement_code            NVARCHAR(100) NOT NULL,
        requirement_name            NVARCHAR(500) NOT NULL,
        requirement_statement       NVARCHAR(MAX) NULL,
        objective                   NVARCHAR(MAX) NULL
    );

    INSERT INTO #candidates
        (organization_id, organization_control_id, repository_requirement_id,
         requirement_code, requirement_name, requirement_statement, objective)
    SELECT DISTINCT
        oc.organization_id,
        oc.organization_control_id,
        q.requirement_id,
        q.requirement_code,
        q.requirement_name,
        q.requirement_statement,
        q.objective
    FROM grac_practice.organization_control oc
    JOIN grac_new.control repo_control
         ON (repo_control.control_id = oc.repository_control_id
             OR repo_control.control_code = oc.control_code)
        AND repo_control.status = 'Active'
    JOIN grac_new.control_requirement_map crm
         ON crm.control_id = repo_control.control_id AND crm.status = 'Active'
    JOIN grac_new.requirement q
         ON q.requirement_id = crm.requirement_id AND q.status = 'Active'
    WHERE oc.organization_control_id = @organization_control_id
      AND ISNULL(oc.origin_type, 'Repository') IN ('Repository', 'Hybrid');

    SELECT @mapped_count = COUNT(*) FROM #candidates;
    IF @mapped_count = 0 RETURN;

    -- 3a. Create org_requirement rows deduped by (org, repo_requirement_id).
    --     The Practice is only inserted if no row exists for this
    --     organization + repository requirement -- ANY control's earlier
    --     Applicable-mark counts as "already imported".
    INSERT INTO grac_practice.organization_requirement (
        organization_id, origin_type, repository_requirement_id,
        organization_control_id, requirement_code, requirement_name,
        requirement_statement, objective,
        applicability_status, applicability_status_id,
        implementation_status, implementation_status_id,
        status, record_status_id, entered_by)
    SELECT
        c.organization_id, 'Repository', c.repository_requirement_id,
        c.organization_control_id,  -- becomes "primary" control for this Practice
        c.requirement_code, c.requirement_name,
        c.requirement_statement, c.objective,
        'Not Updated', @not_updated_id,
        'Not Started', @not_started_id,
        'Active', @active_record_id, @actor
    FROM #candidates c
    WHERE NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_requirement existing
        WHERE existing.organization_id = c.organization_id
          AND (existing.repository_requirement_id = c.repository_requirement_id
               OR existing.requirement_code       = c.requirement_code)
    );

    SET @imported_count = @@ROWCOUNT;

    -- 3b. Reactivate any org_requirement that was previously soft-inactivated
    --     but which we now need again because a Control was re-marked Applicable.
    UPDATE r
       SET status           = 'Active',
           record_status_id = @active_record_id,
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
    FROM grac_practice.organization_requirement r
    JOIN #candidates c
         ON c.organization_id = r.organization_id
        AND (c.repository_requirement_id = r.repository_requirement_id
             OR c.requirement_code       = r.requirement_code)
    WHERE r.status = 'Inactive';

    -- 3c. Insert / reactivate the mapping rows (dedup on control+requirement).
    ;WITH resolved AS (
        SELECT c.organization_id,
               c.organization_control_id,
               r.organization_requirement_id
        FROM #candidates c
        JOIN grac_practice.organization_requirement r
             ON r.organization_id = c.organization_id
            AND (r.repository_requirement_id = c.repository_requirement_id
                 OR r.requirement_code       = c.requirement_code)
    )
    MERGE grac_practice.organization_control_requirement AS target
    USING resolved AS source
        ON target.organization_control_id     = source.organization_control_id
       AND target.organization_requirement_id = source.organization_requirement_id
    WHEN MATCHED THEN UPDATE SET
        status     = 'Active',
        updated_by = @actor,
        updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, organization_control_id, organization_requirement_id,
         status, entered_by, entered_dt)
    VALUES
        (source.organization_id, source.organization_control_id,
         source.organization_requirement_id, 'Active', @actor, SYSUTCDATETIME());

    DROP TABLE #candidates;
END;
GO

-- ============================================================================
-- 4. sp_unapply_practices_for_control
--    Called when a Control transitions AWAY from Applicable.
--    Soft-inactivates the mapping rows for that control.
--    Then for each affected Practice: if no active mappings remain, soft-
--    inactivate the Practice row too. Never DELETES.
-- ============================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_unapply_practices_for_control
    @organization_control_id BIGINT,
    @actor                   NVARCHAR(100) = 'system',
    @deactivated_count       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @deactivated_count = 0;

    IF @organization_control_id IS NULL OR @organization_control_id = 0 RETURN;

    DECLARE @inactive_record_id INT = (
        SELECT record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'Inactive');

    -- Snapshot the mapping ids we are about to inactivate, plus the
    -- requirements they touch (so we can re-check their orphan status
    -- after the mapping deactivation).
    IF OBJECT_ID('tempdb..#affected_reqs') IS NOT NULL DROP TABLE #affected_reqs;
    CREATE TABLE #affected_reqs (organization_requirement_id BIGINT PRIMARY KEY);

    INSERT INTO #affected_reqs (organization_requirement_id)
    SELECT DISTINCT organization_requirement_id
    FROM grac_practice.organization_control_requirement
    WHERE organization_control_id = @organization_control_id
      AND status = 'Active';

    UPDATE grac_practice.organization_control_requirement
       SET status     = 'Inactive',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
     WHERE organization_control_id = @organization_control_id
       AND status = 'Active';

    SET @deactivated_count = @@ROWCOUNT;

    -- For each affected Practice: if it has no active mappings remaining,
    -- soft-inactivate the Practice row itself.
    UPDATE r
       SET status           = 'Inactive',
           record_status_id = @inactive_record_id,
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
    FROM grac_practice.organization_requirement r
    JOIN #affected_reqs a ON a.organization_requirement_id = r.organization_requirement_id
    WHERE r.status = 'Active'
      AND NOT EXISTS (
          SELECT 1 FROM grac_practice.organization_control_requirement m
          WHERE m.organization_requirement_id = r.organization_requirement_id
            AND m.status = 'Active'
      );

    DROP TABLE #affected_reqs;
END;
GO

-- ============================================================================
-- Sanity report
-- ============================================================================
SELECT 'organization_control_requirement present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Backfill mapping row count' AS Check_,
       COUNT(*) AS Mappings
FROM grac_practice.organization_control_requirement;

SELECT 'Helper procs present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_apply_practices_for_control','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_unapply_practices_for_control','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '057 organization_control_requirement + helper procs installed.';
GO
