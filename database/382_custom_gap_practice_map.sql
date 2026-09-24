-- =====================================================================
-- 382_custom_gap_practice_map.sql
--
-- FEATURE: Add Custom Gap -> map relevant Practice(s), reusing the same
-- Practice selection control Risk Analysis already uses (the cascading
-- Practice Picker, migration 282). This migration adds only the storage
-- and the create/read plumbing; the picker UI is reused as-is.
--
-- WHAT THIS ADDS
--   1. custom_gap_practice_map -- one row per practice mapped to a
--      Custom Gap. Deliberately mirrors risk_practice_map (261): frozen
--      practice_name/code so a later practice rename does not rewrite the
--      audit trail, org + record-status columns, mapper + timestamp.
--   2. sp_custom_gap_open re-issued (368's live body, kept verbatim) with
--      one new OPTIONAL trailing parameter @practice_ids_json. When it is
--      a non-empty JSON array of practice ids, the proc inserts one map
--      row per id after the gap row exists. NULL/empty -> no rows, so
--      every existing caller keeps working unchanged.
--   3. sp_custom_gap_practice_map_list -- read the practices mapped to a
--      gap, for the read-only display on the Gap view / detail.
--
-- The "at least one practice required" rule is enforced at the API and
-- UI (like every other required field in this module); the proc stays
-- tolerant so it never breaks a non-UI caller.
--
-- Idempotent / SAFE TO RE-RUN. ASCII-only.
-- Depends on 054 (custom_gap), 001 (practice), 261 pattern.
-- Rollback: 382_custom_gap_practice_map_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN
    PRINT 'ABORT (382): grac_practice.custom_gap is missing (run 054 first).';
    SET NOEXEC ON;
END
GO

-- 1. Mapping table -------------------------------------------------------
IF OBJECT_ID('grac_practice.custom_gap_practice_map','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.custom_gap_practice_map(
        custom_gap_practice_map_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_custom_gap_practice_map PRIMARY KEY,
        organization_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_org
                REFERENCES grac_practice.organization(organization_id),
        custom_gap_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_gap
                REFERENCES grac_practice.custom_gap(custom_gap_id),
        practice_id          BIGINT NOT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_practice
                REFERENCES grac_practice.practice(practice_id),
        -- Frozen at map time (same reasoning as risk_practice_map).
        practice_name        NVARCHAR(300) NULL,
        practice_code        NVARCHAR(100) NULL,
        mapped_dt            DATETIME2 NOT NULL
            CONSTRAINT df_pm_custom_gap_practice_map_dt DEFAULT SYSUTCDATETIME(),
        mapped_by_employee_id BIGINT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_mapper
                REFERENCES grac_practice.organization_employee(employee_id),
        remarks              NVARCHAR(1000) NULL,
        record_status_id     INT NOT NULL
            CONSTRAINT fk_pm_custom_gap_practice_map_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        CONSTRAINT uq_pm_custom_gap_practice UNIQUE(custom_gap_id, practice_id)
    );
    CREATE INDEX ix_pm_custom_gap_practice_map_gap
        ON grac_practice.custom_gap_practice_map(custom_gap_id, record_status_id);
    PRINT '382: custom_gap_practice_map created.';
END
ELSE
    PRINT '382: custom_gap_practice_map already exists.';
GO

-- 2. sp_custom_gap_open (368 body + @practice_ids_json map insert) --------
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    -- Migration 382: optional JSON array of practice ids to map to this
    -- gap, e.g. '[12,15]'. NULL/empty leaves the gap with no mappings, so
    -- every pre-382 caller is unaffected.
    @practice_ids_json      NVARCHAR(MAX) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    DECLARE @owner_display_name NVARCHAR(240) = NULL;
    IF @owner_employee_id IS NOT NULL
        SELECT @owner_display_name = employee_name
          FROM grac_practice.organization_employee
         WHERE employee_id = @owner_employee_id;

    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, owner_display_name, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         lifecycle_state_id,
         opened_dt,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @owner_display_name, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         @new_state_id,
         SYSUTCDATETIME(),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();

    -- Migration 382: map the selected practices. Only practices that
    -- belong to the same organization are mapped; name/code are frozen
    -- from grac_practice.practice at map time.
    IF @practice_ids_json IS NOT NULL AND LTRIM(RTRIM(@practice_ids_json)) <> N''
       AND ISJSON(@practice_ids_json) = 1
    BEGIN
        DECLARE @active_rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

        INSERT INTO grac_practice.custom_gap_practice_map
            (organization_id, custom_gap_id, practice_id, practice_name, practice_code,
             mapped_by_employee_id, record_status_id, mapped_dt)
        SELECT DISTINCT
            @organization_id, @custom_gap_id, p.practice_id, p.practice_name, p.practice_code,
            @actor_employee_id, @active_rs, SYSUTCDATETIME()
        FROM OPENJSON(@practice_ids_json) WITH (practice_id BIGINT N'$') j
        JOIN grac_practice.practice p
              ON p.practice_id = j.practice_id
             AND p.organization_id = @organization_id;
    END
END
GO
PRINT '382: sp_custom_gap_open accepts @practice_ids_json and stores practice mappings.';
GO

-- 3. Read the practices mapped to a gap ---------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_practice_map_list
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.custom_gap_practice_map_id CustomGapPracticeMapId,
           m.custom_gap_id              CustomGapId,
           m.practice_id                PracticeId,
           COALESCE(p.practice_name, m.practice_name) PracticeName,
           COALESCE(p.practice_code, m.practice_code) PracticeCode,
           m.mapped_dt                  MappedDt
      FROM grac_practice.custom_gap_practice_map m
      LEFT JOIN grac_practice.practice p ON p.practice_id = m.practice_id
      JOIN grac_practice.record_status_master rs ON rs.record_status_id = m.record_status_id
     WHERE m.custom_gap_id = @custom_gap_id
       AND rs.status_code = N'Active'
     ORDER BY COALESCE(p.practice_name, m.practice_name);
END
GO
PRINT '382: sp_custom_gap_practice_map_list created.';
GO
SET NOEXEC OFF;
GO
