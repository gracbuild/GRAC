-- =====================================================================
-- 354 Risk register resolves its own linked practice -- ROLLBACK
--
-- Restores sp_risk_register_insert and sp_risk_mapping_sync_primary to
-- their exact 216 / 266 bodies -- the derivation steps removed, nothing
-- else changed.
--
-- Does NOT undo:
--   * Part 1's backfill UPDATE (354's migration).
--   * Any UPDATE sp_risk_mapping_sync_primary's derive-and-persist step
--     already made to risk_register.linked_practice_id while 354 was
--     live -- those rows now hold a correctly-derived value indistin-
--     guishable from one 261's backfill would have set, and unwinding
--     them would need a second, unrelated data migration.
--
-- Roll back only if the derivation logic itself turns out to be wrong
-- (e.g. mis-scoping across organisations) -- this reintroduces the
-- exact "no existing practice mapped" symptom 354 was written to fix
-- for every risk registered from now on, though rows 354 already
-- populated keep their value since this file only touches the two
-- procedures.
--
-- Re-runnable: yes.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_risk_register_insert','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P') IS NULL
BEGIN
    PRINT 'ABORT (354 rollback): one or both procedures missing. Nothing to undo.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- sp_risk_register_insert -- 216's body, verbatim.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_register_insert
    @risk_analysis_id     BIGINT,
    @risk_title           NVARCHAR(300),
    @source_type_code     NVARCHAR(40),
    @source_record_id     BIGINT        = NULL,
    @source_reference     NVARCHAR(200) = NULL,
    @source_description   NVARCHAR(MAX) = NULL,
    @source_centre_code   NVARCHAR(60)  = NULL,
    @risk_candidate_id    BIGINT        = NULL,
    @linked_asset_id      BIGINT        = NULL,
    @linked_vendor_id     BIGINT        = NULL,
    @linked_practice_id   BIGINT        = NULL,
    @linked_obligation_id BIGINT        = NULL,
    @linked_control_id    BIGINT        = NULL,
    @registered_by_employee_id BIGINT   = NULL,
    @caller_display_name  NVARCHAR(100) = N'system',
    @risk_register_id     BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @risk_register_id = NULL;

    IF @risk_analysis_id IS NULL
        THROW 56110, 'sp_risk_register_insert: risk_analysis_id is required — a risk cannot be registered without its assessment (BRD 24.1).', 1;
    IF @risk_title IS NULL OR LEN(LTRIM(RTRIM(@risk_title))) = 0
        THROW 56111, 'sp_risk_register_insert: risk_title is required.', 1;
    IF @source_type_code IS NULL OR LEN(LTRIM(RTRIM(@source_type_code))) = 0
        THROW 56112, 'sp_risk_register_insert: source_type_code is required — every registered risk shall have a defined source (BRD 24.7).', 1;

    DECLARE
        @org_id BIGINT, @scope NVARCHAR(20),
        @statement NVARCHAR(1000), @cat_code NVARCHAR(60), @cat_name NVARCHAR(200),
        @description NVARCHAR(MAX), @cause NVARCHAR(MAX),
        @consequence NVARCHAR(MAX), @controls NVARCHAR(MAX),
        @lk_code NVARCHAR(60), @lk_name NVARCHAR(200), @lk_value INT,
        @im_code NVARCHAR(60), @im_name NVARCHAR(200), @im_value INT,
        @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT,
        @owner_id BIGINT, @bu NVARCHAR(200), @proc_name NVARCHAR(200),
        @threat_id INT, @threat_name NVARCHAR(400), @threat_desc NVARCHAR(MAX),
        @vuln_id INT, @vuln_name NVARCHAR(400), @vuln_desc NVARCHAR(MAX),
        @bf_id BIGINT, @bf_name NVARCHAR(200),
        @already_registered BIGINT;

    SELECT @org_id      = organization_id,
           @scope       = analysis_scope_code,
           @statement   = risk_statement,
           @cat_code    = risk_category_code,
           @cat_name    = risk_category_name,
           @description = risk_description,
           @cause       = risk_cause,
           @consequence = potential_consequence,
           @controls    = existing_controls,
           @lk_code     = likelihood_code,
           @lk_name     = likelihood_name,
           @lk_value    = likelihood_value,
           @im_code     = impact_code,
           @im_name     = impact_name,
           @im_value    = impact_value,
           @rt_code     = inherent_rating_code,
           @rt_name     = inherent_rating_name,
           @rt_score    = inherent_rating_score,
           @owner_id    = risk_owner_employee_id,
           @bu          = business_unit,
           @proc_name   = process_name,
           @threat_id   = threat_id,
           @threat_name = threat_name,
           @threat_desc = threat_description,
           @vuln_id     = vulnerability_id,
           @vuln_name   = vulnerability_name,
           @vuln_desc   = vulnerability_description,
           @bf_id       = business_function_id,
           @bf_name     = business_function_name,
           @already_registered = risk_register_id
      FROM grac_practice.risk_analysis
     WHERE risk_analysis_id = @risk_analysis_id;

    IF @org_id IS NULL
        THROW 56113, 'sp_risk_register_insert: assessment not found.', 1;
    IF @already_registered IS NOT NULL
        THROW 56114, 'sp_risk_register_insert: this assessment has already been registered.', 1;

    -- ---- The mandatory-field gate (the five stage-1 fields) ---------
    -- 56116 (category), 56117 (likelihood), 56118 (impact) and 56119
    -- (rating) are RETIRED by 216: those belong to stage 2 now. The
    -- numbers are not reused, so an old log line still means what it
    -- said.
    IF @statement IS NULL OR LEN(LTRIM(RTRIM(@statement))) = 0
        THROW 56115, 'sp_risk_register_insert: assessment is incomplete — risk statement is required.', 1;
    IF @threat_id IS NULL
        THROW 56410, 'sp_risk_register_insert: assessment is incomplete — a threat is required.', 1;
    IF @vuln_id IS NULL
        THROW 56411, 'sp_risk_register_insert: assessment is incomplete — a vulnerability is required.', 1;
    IF @owner_id IS NULL
        THROW 56120, 'sp_risk_register_insert: assessment is incomplete — risk owner is required.', 1;

    IF @source_type_code = N'Custom' AND @risk_candidate_id IS NOT NULL
        THROW 56121, 'sp_risk_register_insert: a Custom risk cannot carry a candidate (BRD 24.8).', 1;
    IF @source_type_code <> N'Custom' AND @scope = N'Custom'
        THROW 56122, 'sp_risk_register_insert: a custom-scoped assessment must register with source type Custom (BRD 24.8).', 1;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    INSERT INTO grac_practice.risk_register
        (organization_id,
         risk_title, risk_statement, risk_description,
         risk_category_code, risk_category_name,
         source_type_code, source_record_id, source_reference,
         source_description, source_centre_code,
         risk_candidate_id, risk_analysis_id,
         risk_owner_employee_id, business_unit, process_name,
         risk_cause, potential_consequence, existing_controls,
         likelihood_code, likelihood_name, likelihood_value,
         impact_code, impact_name, impact_value,
         inherent_rating_code, inherent_rating_name, inherent_rating_score,
         threat_id, threat_name, threat_description,
         vulnerability_id, vulnerability_name, vulnerability_description,
         business_function_id, business_function_name, analysis_pending,
         linked_asset_id, linked_vendor_id, linked_practice_id,
         linked_obligation_id, linked_control_id,
         status_code, registered_dt, registered_by_employee_id,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@org_id,
         @risk_title, @statement, @description,
         @cat_code, @cat_name,
         @source_type_code, @source_record_id, @source_reference,
         @source_description, @source_centre_code,
         @risk_candidate_id, @risk_analysis_id,
         @owner_id, @bu, @proc_name,
         @cause, @consequence, @controls,
         @lk_code, @lk_name, @lk_value,
         @im_code, @im_name, @im_value,
         @rt_code, @rt_name, @rt_score,
         @threat_id, @threat_name, @threat_desc,
         @vuln_id, @vuln_name, @vuln_desc,
         @bf_id, @bf_name,
         CASE WHEN @rt_code IS NULL THEN 1 ELSE 0 END,
         @linked_asset_id, @linked_vendor_id, @linked_practice_id,
         @linked_obligation_id, @linked_control_id,
         N'Active', SYSUTCDATETIME(), @registered_by_employee_id,
         @active_rs, @caller_display_name, SYSUTCDATETIME());

    SET @risk_register_id = SCOPE_IDENTITY();

    UPDATE grac_practice.risk_analysis
       SET risk_register_id = @risk_register_id,
           decision_code    = N'Register',
           decision_dt      = COALESCE(decision_dt, SYSUTCDATETIME()),
           decision_by_employee_id = COALESCE(decision_by_employee_id, @registered_by_employee_id),
           updated_by       = @caller_display_name,
           updated_dt       = SYSUTCDATETIME()
     WHERE risk_analysis_id = @risk_analysis_id;

    INSERT INTO grac_practice.risk_register_history
        (risk_register_id, action_code, from_status_code, to_status_code,
         remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
    VALUES
        (@risk_register_id, N'Register', NULL, N'Active',
         CONCAT(N'Registered from ', @source_type_code,
                CASE WHEN @source_reference IS NULL THEN N''
                     ELSE CONCAT(N' ', @source_reference) END,
                N'; assessment #', CAST(@risk_analysis_id AS NVARCHAR(20)),
                CASE WHEN @rt_code IS NULL
                     THEN N'; rating pending analysis'
                     ELSE CONCAT(N'; inherent rating ', @rt_code) END),
         @registered_by_employee_id, @caller_display_name,
         @caller_display_name, SYSUTCDATETIME());
END;
GO
PRINT '354 rollback: sp_risk_register_insert restored to its 216 body.';
GO

-- ---------------------------------------------------------------------
-- sp_risk_mapping_sync_primary -- 266's body, verbatim.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_sync_primary
    @risk_register_id    BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56660, 'sp_risk_mapping_sync_primary: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @practice_id BIGINT;
    SELECT @org_id = organization_id, @practice_id = linked_practice_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56661, 'sp_risk_mapping_sync_primary: risk not found.', 1;

    IF @practice_id IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, CAST(NULL AS BIGINT) AS PracticeId;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id
                  AND map_source_code  = N'Primary')
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    UPDATE grac_practice.risk_practice_map
       SET map_source_code = N'Additional',
           updated_by      = @caller_display_name,
           updated_dt      = SYSUTCDATETIME()
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary'
       AND practice_id     <> @practice_id;

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id)
    BEGIN
        UPDATE grac_practice.risk_practice_map
           SET map_source_code = N'Primary',
               updated_by      = @caller_display_name,
               updated_dt      = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND practice_id      = @practice_id;

        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    EXEC grac_practice.sp_risk_practice_map
         @risk_register_id    = @risk_register_id,
         @practice_id         = @practice_id,
         @map_source_code     = N'Primary',
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;
END;
GO
PRINT '354 rollback: sp_risk_mapping_sync_primary restored to its 266 body.';
GO

SELECT '354r-a sp_risk_register_insert no longer derives' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_register_insert','P'))
                 NOT LIKE '%354:%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '354r-b sp_risk_mapping_sync_primary no longer derives',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P'))
                 NOT LIKE '%354:%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '354 rollback complete. Risk registrations from now on will again';
PRINT 'carry linked_practice_id = NULL unless a caller supplies it, and';
PRINT '/mapping reads will again show no practice the moment that column';
PRINT 'is NULL. Rows already populated by 354 (the backfill, or an earlier';
PRINT 'self-heal read) keep their value -- this file changes procedures,';
PRINT 'not data.';
GO

SET NOEXEC OFF;
GO
