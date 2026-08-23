-- =====================================================================
-- 156 Gap Centre v1 -- lifecycle + analysis + downstream link schema
--
-- Delivers the schema portion of AES Gap Centre v1.0. Purely ADDITIVE:
-- no existing column / table / proc is dropped or renamed. Backward
-- compatibility of every existing gap flow is preserved.
--
-- WHAT THIS ADDS
-- --------------
--   1. grac_practice.gap_lifecycle_state_master
--        The 9 canonical states from AES section 4:
--        New / Validation / Analysis / ResolutionPlanning / Execution /
--        Verification / Closed  and terminals  Invalid / Duplicate.
--
--   2. grac_practice.gap_lifecycle_transition_master
--        Allowed (from_state, action_code, to_state) triples. Config-
--        driven so ops can extend the workflow (spec section 5, 13.6)
--        by inserting rows without a code change.
--
--   3. grac_practice.custom_gap  -- three new columns (guarded):
--        lifecycle_state_id INT NULL FK to state_master
--        duplicate_of_gap_id BIGINT NULL FK to custom_gap (self)
--        invalid_reason NVARCHAR(1000) NULL
--        The existing status column is UNCHANGED -- every current query,
--        proc and report keeps working. status will be kept in sync by
--        the transition proc in 157 (Open<->New/Validation/Analysis /
--        InProgress<->ResolutionPlanning/Execution / Closed<->Closed /
--        Cancelled<->Invalid/Duplicate).
--
--   4. grac_practice.custom_gap_analysis  (1:1 with custom_gap)
--        The Gap Analysis Engine payload (AES section 5).
--
--   5. grac_practice.custom_gap_downstream_link  (many:many gap -> artefact)
--        Task / Exception / Risk Candidate linkage (AES section 6, 7, 8).
--        Ownership stays with the artefact's own module -- this table
--        only carries the LINK. External artefacts referenced by
--        (artefact_type_code, artefact_id) plus a free external_ref
--        string for callers that live outside this database.
--
-- BACKWARD COMPATIBILITY
-- ----------------------
--   * custom_gap.status keeps its CHECK constraint and existing values.
--   * All lifecycle_state_id backfill happens in 158 -- 156 leaves the
--     column NULL so 156+157 can be deployed in isolation without
--     changing runtime behaviour until callers opt in.
--   * All new tables are independent -- rolling 156 back does not
--     touch legacy gap data.
--
-- DEPENDS ON: 054 (custom_gap), 109 (extend), 110 (supporting tables).
-- Rollback: 156_gap_centre_v1_schema_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    RAISERROR('156: prerequisites missing. Run 054/109/110 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. gap_lifecycle_state_master
-- =====================================================================
IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.gap_lifecycle_state_master(
        lifecycle_state_id  INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_gap_lifecycle_state PRIMARY KEY,
        state_code          NVARCHAR(60)  NOT NULL,
        state_name          NVARCHAR(200) NOT NULL,
        description         NVARCHAR(500) NULL,
        sort_order          INT NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_sort DEFAULT 100,
        is_terminal         BIT NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_terminal DEFAULT 0,
        is_valid_terminal   BIT NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_valid_terminal DEFAULT 0,
        status              NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_status DEFAULT N'Active',
        record_status_id    INT NOT NULL
            CONSTRAINT fk_pm_gap_lifecycle_state_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_state_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL,
        CONSTRAINT uq_pm_gap_lifecycle_state_code UNIQUE(state_code)
    );
END
GO

-- =====================================================================
-- 2. gap_lifecycle_transition_master
--    Config-driven allowed transitions. action_code is what the caller
--    passes to sp_custom_gap_lifecycle_transition. reason_required /
--    comment_required flags let ops mandate a remark for specific
--    actions (e.g. Invalid must carry an explanation).
-- =====================================================================
IF OBJECT_ID('grac_practice.gap_lifecycle_transition_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.gap_lifecycle_transition_master(
        transition_id       INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_gap_lifecycle_transition PRIMARY KEY,
        from_state_id       INT NOT NULL
            CONSTRAINT fk_pm_gap_lifecycle_transition_from
                REFERENCES grac_practice.gap_lifecycle_state_master(lifecycle_state_id),
        to_state_id         INT NOT NULL
            CONSTRAINT fk_pm_gap_lifecycle_transition_to
                REFERENCES grac_practice.gap_lifecycle_state_master(lifecycle_state_id),
        action_code         NVARCHAR(60)  NOT NULL,
        action_name         NVARCHAR(200) NOT NULL,
        description         NVARCHAR(500) NULL,
        remark_required     BIT NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_transition_remark DEFAULT 0,
        record_status_id    INT NOT NULL
            CONSTRAINT fk_pm_gap_lifecycle_transition_record_status
                REFERENCES grac_practice.record_status_master(record_status_id),
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_transition_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_gap_lifecycle_transition_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_gap_lifecycle_transition UNIQUE(from_state_id, action_code)
    );
END
GO

-- =====================================================================
-- 3. custom_gap  -- add three columns (guarded, additive)
-- =====================================================================
IF COL_LENGTH('grac_practice.custom_gap','lifecycle_state_id') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD lifecycle_state_id INT NULL
            CONSTRAINT fk_pm_custom_gap_lifecycle_state
                REFERENCES grac_practice.gap_lifecycle_state_master(lifecycle_state_id);
GO

IF COL_LENGTH('grac_practice.custom_gap','duplicate_of_gap_id') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD duplicate_of_gap_id BIGINT NULL
            CONSTRAINT fk_pm_custom_gap_duplicate_of
                REFERENCES grac_practice.custom_gap(custom_gap_id);
GO

IF COL_LENGTH('grac_practice.custom_gap','invalid_reason') IS NULL
    ALTER TABLE grac_practice.custom_gap
        ADD invalid_reason NVARCHAR(1000) NULL;
GO

IF OBJECT_ID('grac_practice.custom_gap','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_custom_gap_lifecycle_state'
                     AND object_id=OBJECT_ID('grac_practice.custom_gap'))
    CREATE INDEX ix_pm_custom_gap_lifecycle_state
        ON grac_practice.custom_gap(lifecycle_state_id, organization_id)
        INCLUDE(title, priority);
GO

-- =====================================================================
-- 4. custom_gap_analysis (1:1)
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap_analysis','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.custom_gap_analysis(
        custom_gap_id           BIGINT NOT NULL
            CONSTRAINT pk_pm_custom_gap_analysis PRIMARY KEY
            CONSTRAINT fk_pm_custom_gap_analysis_gap
                REFERENCES grac_practice.custom_gap(custom_gap_id),
        detection_method_code   NVARCHAR(60)  NULL,   -- Manual/Assurance/Audit/AutoScan/etc.
        detection_method_name   NVARCHAR(200) NULL,
        severity_code           NVARCHAR(30)  NULL,   -- mirrored from gap for analysis-time snapshot
        severity_name           NVARCHAR(120) NULL,
        business_impact_code    NVARCHAR(30)  NULL,   -- None/Low/Medium/High/Critical
        business_impact_summary NVARCHAR(MAX) NULL,
        regulatory_impact_code  NVARCHAR(30)  NULL,   -- None/Low/Medium/High/Critical
        regulatory_impact_summary NVARCHAR(MAX) NULL,
        rca_required            BIT NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_rca_required DEFAULT 0,
        rca_method_code         NVARCHAR(60)  NULL,   -- 5Whys/Fishbone/Freeform/etc.
        rca_summary             NVARCHAR(MAX) NULL,
        recommended_action_summary NVARCHAR(MAX) NULL,
        recommend_task          BIT NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_recommend_task DEFAULT 0,
        recommend_exception     BIT NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_recommend_exception DEFAULT 0,
        recommend_risk          BIT NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_recommend_risk DEFAULT 0,
        analysed_by_employee_id BIGINT NULL,
        analysed_on             DATETIME2 NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_custom_gap_analysis_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by NVARCHAR(100) NULL,
        updated_dt DATETIME2 NULL
    );
END
GO

-- =====================================================================
-- 5. custom_gap_downstream_link (many:many gap -> artefact)
--
-- artefact_type_code is soft (not FK'd to an artefact-type master)
-- because Task, Exception and Risk are separate modules; each may live
-- in a different DB / service. artefact_id is BIGINT for in-DB
-- artefacts (e.g. Task row id). external_ref carries an out-of-DB
-- reference (e.g. "RSK-2026-01452" for a risk ticket in Archer).
--
-- link_status_code lets a link be soft-cancelled without deleting the
-- audit trail. `initiated_by_employee_id` records who created the link
-- so the Decision Gateway audit reads cleanly.
-- =====================================================================
IF OBJECT_ID('grac_practice.custom_gap_downstream_link','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.custom_gap_downstream_link(
        link_id             BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_custom_gap_downstream_link PRIMARY KEY,
        custom_gap_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_custom_gap_downstream_link_gap
                REFERENCES grac_practice.custom_gap(custom_gap_id),
        artefact_type_code  NVARCHAR(30) NOT NULL,        -- Task | Exception | RiskCandidate
        artefact_id         BIGINT NULL,
        external_ref        NVARCHAR(200) NULL,
        title               NVARCHAR(300) NULL,
        link_status_code    NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_custom_gap_downstream_link_status DEFAULT N'Active',
        initiated_by_employee_id BIGINT NULL,
        initiated_dt        DATETIME2 NOT NULL
            CONSTRAINT df_pm_custom_gap_downstream_link_initiated_dt DEFAULT SYSUTCDATETIME(),
        cancelled_by_employee_id BIGINT NULL,
        cancelled_dt        DATETIME2 NULL,
        cancellation_reason NVARCHAR(1000) NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_custom_gap_downstream_link_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_custom_gap_downstream_link_entered_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_custom_gap_downstream_link_type
            CHECK (artefact_type_code IN (N'Task', N'Exception', N'RiskCandidate')),
        CONSTRAINT ck_pm_custom_gap_downstream_link_ref
            CHECK (artefact_id IS NOT NULL OR external_ref IS NOT NULL)
    );
END
GO

IF OBJECT_ID('grac_practice.custom_gap_downstream_link','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_custom_gap_downstream_link_gap'
                     AND object_id=OBJECT_ID('grac_practice.custom_gap_downstream_link'))
    CREATE INDEX ix_pm_custom_gap_downstream_link_gap
        ON grac_practice.custom_gap_downstream_link(custom_gap_id, link_status_code)
        INCLUDE(artefact_type_code, artefact_id);
GO

IF OBJECT_ID('grac_practice.custom_gap_downstream_link','U') IS NOT NULL
   AND NOT EXISTS(SELECT 1 FROM sys.indexes
                   WHERE name='ix_pm_custom_gap_downstream_link_artefact'
                     AND object_id=OBJECT_ID('grac_practice.custom_gap_downstream_link'))
    CREATE INDEX ix_pm_custom_gap_downstream_link_artefact
        ON grac_practice.custom_gap_downstream_link(artefact_type_code, artefact_id);
GO

-- End 156 =============================================================
