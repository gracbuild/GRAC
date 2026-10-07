-- =====================================================================
-- 431  Custody -- ownership / location history, custodian
--      acknowledgement and periodic attestation
--      (Asset & Contract Management, Phase 4 increment 4)
--
-- REQUEST
-- -------
--   BRD v1.7 5.3 "Asset Custodian Acknowledgement and Attestation
--   Framework": 5.3.1 configuration (required by category / subcategory /
--   asset type, participant, frequency, due window, evidence, manager
--   approval), 5.3.2 initial acknowledgement ("assignment or custody
--   change generates exactly one open acknowledgement occurrence for the
--   asset, assignee and assignment event"; "disagreement does not change
--   ownership automatically"; no submission on behalf of another
--   custodian), 5.3.3 periodic attestation (occurrences from the schedule
--   and current custodian; campaign grouping; Verified + next due date;
--   Overdue; reassignment on custody change), 5.3.4 fields, 5.3.5 outcomes,
--   5.3.6 disagreement categories, 5.3.12 occurrence key / immutability;
--   1 "effective-dated history for ownership, location". Plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_assignment_history -- effective-dated snapshots of asset
--      owner, custodian (employee or team), department, site, building,
--      floor and room; one current row per asset. Written by
--      sp_asset_assignment_snapshot whenever a save changes any of them
--      (sp_asset_register_save re-issued: one call added); existing assets
--      get a starting row.
--   2. asset_attestation_profile -- 5.3.1 per organization and scope
--      (asset type, else subcategory -- its level-1 parent included --,
--      else category; most specific wins): required, participant
--      (Custodian / Asset Owner / Both), frequency (Monthly / Quarterly /
--      Half-Yearly / Annual / custom days), due window (calendar days --
--      no business calendar exists, D23), evidence (None / Optional /
--      Mandatory), manager approval; version number kept on every
--      occurrence.
--   3. asset_attestation -- one row per occurrence with the 5.3.4 fields
--      (occurrence key, type, campaign, profile version, assignment
--      snapshot, timing, the 11 statuses, verification checks, condition,
--      response, disagreement category, comments, evidence, attested by /
--      channel, outcome, approval). A unique key per open occurrence makes
--      generation idempotent. asset_attestation_campaign groups a
--      generation run or an ad-hoc campaign; asset_attestation_state keeps
--      the asset's last attested date, verification status and next
--      attestation date.
--   4. Initial acknowledgement: a custodian / owner change opens one
--      INITIAL occurrence for the new assignee (cancels the superseded
--      open acknowledgement, reassigns open periodic / campaign ones).
--      Periodic / campaign: sp_asset_attestation_generate marks overdue
--      occurrences and creates the due ones (the Phase 6 scheduler will call
--      it; until then it is run from the screen).
--   5. Response (sp_asset_attestation_respond): only the assignee (or an
--      active member of the assignee team) may respond; Confirm needs the
--      asset to exist and custody confirmed, a Lost / Not Found condition
--      must be a disagreement, comments are required for disagreements and
--      conditional confirmations, evidence when the profile says so.
--      Confirm -> Closed (or Confirmed awaiting the manager's approval) and
--      the asset becomes Verified with its next date; Disagree -> Disputed
--      and the asset Disputed -- no ownership change. Decisions
--      (sp_asset_attestation_decide): manager Approve / Return, Cancel with
--      a reason.
--   6. Readers: profiles, campaigns, occurrence list (all / mine / my
--      approvals), asset custody view (state, history, occurrences).
--   7. Menu "Asset Attestation" (asset-attestation) under Asset & Contract;
--      Admin VIEW / ADD / EDIT / APPROVE.
--
-- NOT DONE HERE: Asset Verification Exception records, category tasks and
--   SLA (5.3.7-5.3.9 -> 4.5 / Phase 6); reminders and escalations
--   (5.3.11, Phase 6 notifications -- blocked on the worker decision);
--   delegated authority (not configured, so not allowed); Transfer /
--   Return / Event-driven occurrence types (allowed values, raised by the
--   4.5 workflows); business-day due windows.
--
-- ERROR NUMBERS: 54350-54389
--   54350 organization not found          54351 asset not found
--   54352 profile not found               54353 profile changed by someone else
--   54354 profile scope                   54355 profile values
--   54356 profile exists for the scope    54357 attestation not found
--   54358 attestation changed             54359 not open for a response
--   54360 not the assignee                54361 response Confirm / Disagree
--   54362 condition                       54363 disagreement category
--   54364 comments required               54365 evidence required
--   54366 confirm needs existence + custody 54367 unknown decision
--   54368 wrong state for the decision    54369 not the approving manager
--   54370 note / reason required          54371 campaign name / due date
--   54372 campaign type
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml, both
--   appsettings.json, new partial + script asset-attestation, asset-register
--   (Custody tab), docs.
-- DEPENDS ON: 428-430.
-- Rollback: 431_asset_custody_attestation_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_tech_install_apply','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_tech_exception_active') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_stored_values') IS NULL
   OR OBJECT_ID('grac_practice.organization_team_member','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_employee','reporting_officer_id') IS NULL
   OR COL_LENGTH('grac_practice.dependency_asset_subcategory_master','parent_subcategory_id') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'custodian')
BEGIN
    RAISERROR('ABORT (431): run 428 to 430 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_assignment_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_assignment_history (
        assignment_id   BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_assignment PRIMARY KEY,
        organization_id BIGINT         NOT NULL,
        asset_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_assignment_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        asset_owner_id  BIGINT         NULL,
        custodian       NVARCHAR(40)   NULL,      -- E:<employee_id> | T:<team_id> (MASTER:EMPLOYEE_OR_TEAM)
        department_id   BIGINT         NULL,
        location_id     BIGINT         NULL,      -- site
        building        NVARCHAR(160)  NULL,
        floor           NVARCHAR(160)  NULL,
        room            NVARCHAR(160)  NULL,
        effective_from  DATE           NOT NULL,
        effective_to    DATE           NULL,
        is_current      BIT            NOT NULL CONSTRAINT df_pm_asset_assignment_current DEFAULT 0,
        change_source   NVARCHAR(100)  NOT NULL,
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_assignment_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_asset_assignment_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_assignment_asset ON grac_practice.asset_assignment_history(asset_id, effective_from DESC);
    CREATE UNIQUE INDEX ux_pm_asset_assignment_current ON grac_practice.asset_assignment_history(asset_id) WHERE is_current = 1;
    PRINT '431: asset_assignment_history created.';
END
GO

IF OBJECT_ID('grac_practice.asset_attestation_profile','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_attestation_profile (
        profile_id                BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_att_profile PRIMARY KEY,
        organization_id           BIGINT        NOT NULL,
        scope_kind                NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_att_profile_scope CHECK (scope_kind IN (N'CATEGORY', N'SUBCATEGORY', N'ASSET_TYPE')),
        asset_category_id         INT           NULL,
        asset_subcategory_id      INT           NULL,
        asset_type_id             INT           NULL,
        attestation_required      BIT           NOT NULL CONSTRAINT df_pm_asset_att_profile_req DEFAULT 1,
        participant               NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_att_profile_part CHECK (participant IN (N'CUSTODIAN', N'OWNER', N'BOTH')),
        frequency                 NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_att_profile_freq CHECK (frequency IN (N'MONTHLY', N'QUARTERLY', N'HALF_YEARLY', N'ANNUAL', N'CUSTOM')),
        custom_interval_days      INT           NULL,
        due_window_days           INT           NOT NULL,
        evidence_requirement      NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_att_profile_ev CHECK (evidence_requirement IN (N'NONE', N'OPTIONAL', N'MANDATORY')),
        manager_approval_required BIT           NOT NULL CONSTRAINT df_pm_asset_att_profile_mgr DEFAULT 0,
        is_active                 BIT           NOT NULL CONSTRAINT df_pm_asset_att_profile_active DEFAULT 1,
        version_no                INT           NOT NULL CONSTRAINT df_pm_asset_att_profile_ver DEFAULT 1,
        entered_by                NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_att_profile_eby DEFAULT N'system',
        entered_dt                DATETIME2     NOT NULL CONSTRAINT df_pm_asset_att_profile_edt DEFAULT SYSUTCDATETIME(),
        updated_by                NVARCHAR(100) NULL,
        updated_dt                DATETIME2     NULL,
        record_version            ROWVERSION    NOT NULL,
        CONSTRAINT ck_pm_asset_att_profile_target CHECK (
            (scope_kind = N'CATEGORY' AND asset_category_id IS NOT NULL AND asset_subcategory_id IS NULL AND asset_type_id IS NULL) OR
            (scope_kind = N'SUBCATEGORY' AND asset_subcategory_id IS NOT NULL AND asset_category_id IS NULL AND asset_type_id IS NULL) OR
            (scope_kind = N'ASSET_TYPE' AND asset_type_id IS NOT NULL AND asset_category_id IS NULL AND asset_subcategory_id IS NULL)),
        CONSTRAINT ck_pm_asset_att_profile_days CHECK (
            due_window_days BETWEEN 1 AND 365
            AND ((frequency = N'CUSTOM' AND custom_interval_days BETWEEN 1 AND 3660) OR (frequency <> N'CUSTOM' AND custom_interval_days IS NULL)))
    );
    CREATE UNIQUE INDEX ux_pm_asset_att_profile_scope ON grac_practice.asset_attestation_profile
        (organization_id, scope_kind, asset_category_id, asset_subcategory_id, asset_type_id);
    PRINT '431: asset_attestation_profile created.';
END
GO

IF OBJECT_ID('grac_practice.asset_attestation_campaign','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_attestation_campaign (
        campaign_id     BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_att_campaign PRIMARY KEY,
        organization_id BIGINT         NOT NULL,
        campaign_type   NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_att_campaign_type CHECK (campaign_type IN (N'PERIODIC', N'CAMPAIGN')),
        campaign_name   NVARCHAR(200)  NOT NULL,
        asset_type_id   INT            NULL,
        due_date        DATE           NULL,
        generated_count INT            NOT NULL CONSTRAINT df_pm_asset_att_campaign_gen DEFAULT 0,
        skipped_count   INT            NOT NULL CONSTRAINT df_pm_asset_att_campaign_skip DEFAULT 0,
        overdue_marked  INT            NOT NULL CONSTRAINT df_pm_asset_att_campaign_od DEFAULT 0,
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_att_campaign_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_asset_att_campaign_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '431: asset_attestation_campaign created.';
END
GO

IF OBJECT_ID('grac_practice.asset_attestation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_attestation (
        attestation_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_attestation PRIMARY KEY,
        organization_id           BIGINT         NOT NULL,
        occurrence_key            NVARCHAR(200)  NOT NULL,
        attestation_type          NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_att_type CHECK (attestation_type IN
                (N'INITIAL', N'PERIODIC', N'TRANSFER', N'RETURN', N'EVENT', N'CAMPAIGN')),
        asset_id                  BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_att_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        asset_type_id             INT            NULL,
        campaign_id               BIGINT         NULL
            CONSTRAINT fk_pm_asset_att_campaign REFERENCES grac_practice.asset_attestation_campaign(campaign_id),
        profile_id                BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_att_profile REFERENCES grac_practice.asset_attestation_profile(profile_id),
        profile_version           INT            NOT NULL,
        evidence_requirement      NVARCHAR(20)   NOT NULL,
        manager_approval_required BIT            NOT NULL,
        assignee_role             NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_att_role CHECK (assignee_role IN (N'CUSTODIAN', N'OWNER')),
        assignee_employee_id      BIGINT         NULL,
        assignee_team_id          BIGINT         NULL,
        assignment_id             BIGINT         NULL
            CONSTRAINT fk_pm_asset_att_assignment REFERENCES grac_practice.asset_assignment_history(assignment_id),
        -- assignment snapshot (5.3.4)
        snap_custodian            NVARCHAR(40)   NULL,
        snap_owner_id             BIGINT         NULL,
        snap_manager_id           BIGINT         NULL,
        snap_department_id        BIGINT         NULL,
        snap_location_id          BIGINT         NULL,
        snap_assignment_start     DATE           NULL,
        -- timing
        generated_dt              DATETIME2      NOT NULL CONSTRAINT df_pm_asset_att_gen DEFAULT SYSUTCDATETIME(),
        due_date                  DATE           NOT NULL,
        response_dt               DATETIME2      NULL,
        closed_dt                 DATETIME2      NULL,
        next_attestation_date     DATE           NULL,
        status                    NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_att_status CHECK (status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'CONFIRMED', N'DISPUTED',
                N'OVERDUE', N'ESCALATED', N'EXCEPTION', N'RESOLVED', N'CLOSED', N'CANCELLED')),
        -- response
        response                  NVARCHAR(10)   NULL CONSTRAINT ck_pm_asset_att_response CHECK (response IN (N'CONFIRM', N'DISAGREE')),
        asset_exists              BIT            NULL,
        custody_confirmed         BIT            NULL,
        location_verified         BIT            NULL,
        tag_verified              BIT            NULL,
        serial_verified           BIT            NULL,
        assigned_user_verified    BIT            NULL,
        information_correct       BIT            NULL,
        business_use_confirmed    BIT            NULL,
        condition_code            NVARCHAR(30)   NULL,
        disagreement_category     NVARCHAR(40)   NULL,
        comments                  NVARCHAR(2000) NULL,
        evidence_text             NVARCHAR(1000) NULL,
        attested_by               NVARCHAR(100)  NULL,
        attested_by_employee_id   BIGINT         NULL,
        channel                   NVARCHAR(30)   NULL,
        verification_status       NVARCHAR(20)   NULL,
        -- decision
        decided_by                NVARCHAR(100)  NULL,
        decided_by_employee_id    BIGINT         NULL,
        decided_dt                DATETIME2      NULL,
        decision_note             NVARCHAR(1000) NULL,
        entered_by                NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_att_eby DEFAULT N'system',
        updated_by                NVARCHAR(100)  NULL,
        updated_dt                DATETIME2      NULL,
        record_version            ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_asset_att_org_status ON grac_practice.asset_attestation(organization_id, status, due_date);
    CREATE INDEX ix_pm_asset_att_asset ON grac_practice.asset_attestation(asset_id, generated_dt DESC);
    CREATE INDEX ix_pm_asset_att_assignee ON grac_practice.asset_attestation(assignee_employee_id, status);
    -- 5.3.12: one occurrence per key unless cancelled.
    CREATE UNIQUE INDEX ux_pm_asset_att_key ON grac_practice.asset_attestation(occurrence_key) WHERE status <> N'CANCELLED';
    PRINT '431: asset_attestation created.';
END
GO

IF OBJECT_ID('grac_practice.asset_attestation_state','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_attestation_state (
        asset_id              BIGINT         NOT NULL CONSTRAINT pk_pm_asset_att_state PRIMARY KEY
            CONSTRAINT fk_pm_asset_att_state_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        organization_id       BIGINT         NOT NULL,
        last_attested_date    DATE           NULL,
        verification_status   NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_att_state_ver CHECK (verification_status IN (N'NOT_VERIFIED', N'VERIFIED', N'DISPUTED')),
        next_attestation_date DATE           NULL,
        last_attestation_id   BIGINT         NULL,
        updated_by            NVARCHAR(100)  NULL,
        updated_dt            DATETIME2      NULL
    );
    PRINT '431: asset_attestation_state created.';
END
GO

-- =====================================================================
-- 2. Functions
-- =====================================================================
-- The profile that applies to an asset: asset type, else subcategory (the
-- asset's subcategory, then its level-1 parent), else category.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_attestation_profile_for (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 p.profile_id AS ProfileId, p.version_no AS VersionNo, p.attestation_required AS AttestationRequired,
           p.participant AS Participant, p.frequency AS Frequency, p.custom_interval_days AS CustomIntervalDays,
           p.due_window_days AS DueWindowDays, p.evidence_requirement AS EvidenceRequirement,
           p.manager_approval_required AS ManagerApprovalRequired
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = a.asset_subcategory_id
      JOIN grac_practice.asset_attestation_profile p
        ON p.organization_id = a.organization_id AND p.is_active = 1
       AND (   (p.scope_kind = N'ASSET_TYPE' AND p.asset_type_id = a.asset_type_id)
            OR (p.scope_kind = N'SUBCATEGORY' AND p.asset_subcategory_id IN (a.asset_subcategory_id, s.parent_subcategory_id))
            OR (p.scope_kind = N'CATEGORY' AND p.asset_category_id = a.asset_category_id))
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id
     ORDER BY CASE p.scope_kind WHEN N'ASSET_TYPE' THEN 0 WHEN N'SUBCATEGORY' THEN 1 ELSE 2 END,
              CASE WHEN p.asset_subcategory_id = a.asset_subcategory_id THEN 0 ELSE 1 END;
GO

-- Next attestation date after @from for a frequency (5.3.1).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_attestation_next_date (@from DATE, @frequency NVARCHAR(20), @custom_days INT)
RETURNS DATE
AS
BEGIN
    RETURN CASE @frequency
             WHEN N'MONTHLY'     THEN DATEADD(MONTH, 1, @from)
             WHEN N'QUARTERLY'   THEN DATEADD(MONTH, 3, @from)
             WHEN N'HALF_YEARLY' THEN DATEADD(MONTH, 6, @from)
             WHEN N'ANNUAL'      THEN DATEADD(YEAR, 1, @from)
             ELSE DATEADD(DAY, ISNULL(@custom_days, 365), @from) END;
END
GO
PRINT '431: functions created.';
GO

-- =====================================================================
-- 3. Internal procedures
-- =====================================================================
-- Creates one occurrence from the current assignment and profile of the asset.
-- @out_attestation_id stays NULL (with @out_skip_reason) when there is no
-- assignee, no profile requiring attestation, or the key already exists.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_create
    @organization_id    BIGINT,
    @asset_id           BIGINT,
    @attestation_type   NVARCHAR(20),
    @assignee_role      NVARCHAR(20),
    @occurrence_key     NVARCHAR(200),
    @due_date           DATE,
    @campaign_id        BIGINT        = NULL,
    @actor              NVARCHAR(100) = N'system',
    @out_attestation_id BIGINT        = NULL OUTPUT,
    @out_skip_reason    NVARCHAR(100) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @out_attestation_id = NULL;
    SET @out_skip_reason = NULL;

    DECLARE @profile_id BIGINT, @profile_version INT, @required BIT, @evidence NVARCHAR(20), @mgr BIT;
    SELECT @profile_id = ProfileId, @profile_version = VersionNo, @required = AttestationRequired,
           @evidence = EvidenceRequirement, @mgr = ManagerApprovalRequired
      FROM grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset_id);
    IF @profile_id IS NULL OR @required = 0 BEGIN SET @out_skip_reason = N'No attestation profile applies'; RETURN; END
    IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation WHERE occurrence_key = @occurrence_key AND status <> N'CANCELLED')
    BEGIN SET @out_skip_reason = N'Already generated'; RETURN; END

    DECLARE @assignment_id BIGINT, @owner BIGINT, @custodian NVARCHAR(40), @dept BIGINT, @loc BIGINT, @start DATE;
    SELECT @assignment_id = assignment_id, @owner = asset_owner_id, @custodian = custodian, @dept = department_id,
           @loc = location_id, @start = effective_from
      FROM grac_practice.asset_assignment_history WHERE asset_id = @asset_id AND is_current = 1;
    DECLARE @emp BIGINT, @team BIGINT;
    IF @assignee_role = N'OWNER' SET @emp = @owner;
    ELSE IF @custodian LIKE N'E:%' SET @emp = TRY_CONVERT(BIGINT, SUBSTRING(@custodian, 3, 38));
    ELSE IF @custodian LIKE N'T:%' SET @team = TRY_CONVERT(BIGINT, SUBSTRING(@custodian, 3, 38));
    IF @emp IS NULL AND @team IS NULL BEGIN SET @out_skip_reason = N'No assignee'; RETURN; END
    DECLARE @manager BIGINT = (SELECT reporting_officer_id FROM grac_practice.organization_employee WHERE employee_id = @emp);

    INSERT grac_practice.asset_attestation
        (organization_id, occurrence_key, attestation_type, asset_id, asset_type_id, campaign_id, profile_id, profile_version,
         evidence_requirement, manager_approval_required, assignee_role, assignee_employee_id, assignee_team_id, assignment_id,
         snap_custodian, snap_owner_id, snap_manager_id, snap_department_id, snap_location_id, snap_assignment_start,
         due_date, status, entered_by)
    SELECT @organization_id, @occurrence_key, @attestation_type, @asset_id, a.asset_type_id, @campaign_id, @profile_id, @profile_version,
           @evidence, @mgr, @assignee_role, @emp, @team, @assignment_id,
           @custodian, @owner, @manager, @dept, @loc, @start,
           @due_date, N'PENDING', @actor
      FROM grac_practice.organization_dependency_asset a WHERE a.asset_id = @asset_id;
    SET @out_attestation_id = SCOPE_IDENTITY();
END
GO

-- Snapshot of owner / custodian / department / location after a change
-- (history row only when something differs). With
-- @raise_acknowledgement = 1 a custodian / owner change opens the INITIAL
-- acknowledgement for the new assignee (5.3.2), cancels the superseded open
-- acknowledgement and reassigns open periodic / campaign occurrences (5.3.3).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_assignment_snapshot
    @organization_id       BIGINT,
    @asset_id              BIGINT,
    @source                NVARCHAR(100),
    @raise_acknowledgement BIT           = 1,
    @actor                 NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @v TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @v (field_key, val)
    SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id)
     WHERE FieldKey IN (N'asset_owner', N'custodian', N'department', N'site', N'building', N'floor', N'room', N'assignment_start_date');
    DECLARE @owner BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @v WHERE field_key = N'asset_owner')),
            @custodian NVARCHAR(40) = LEFT((SELECT val FROM @v WHERE field_key = N'custodian'), 40),
            @dept BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @v WHERE field_key = N'department')),
            @loc BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @v WHERE field_key = N'site')),
            @building NVARCHAR(160) = LEFT((SELECT val FROM @v WHERE field_key = N'building'), 160),
            @floor NVARCHAR(160) = LEFT((SELECT val FROM @v WHERE field_key = N'floor'), 160),
            @room NVARCHAR(160) = LEFT((SELECT val FROM @v WHERE field_key = N'room'), 160),
            @start DATE = TRY_CONVERT(DATE, (SELECT val FROM @v WHERE field_key = N'assignment_start_date'), 23);

    DECLARE @cur_id BIGINT, @c_owner BIGINT, @c_cust NVARCHAR(40), @c_dept BIGINT, @c_loc BIGINT,
            @c_building NVARCHAR(160), @c_floor NVARCHAR(160), @c_room NVARCHAR(160), @c_from DATE;
    SELECT @cur_id = assignment_id, @c_owner = asset_owner_id, @c_cust = custodian, @c_dept = department_id, @c_loc = location_id,
           @c_building = building, @c_floor = floor, @c_room = room, @c_from = effective_from
      FROM grac_practice.asset_assignment_history WHERE asset_id = @asset_id AND is_current = 1;

    IF @cur_id IS NOT NULL
       AND ISNULL(@c_owner, -1) = ISNULL(@owner, -1) AND ISNULL(@c_cust, N'') = ISNULL(@custodian, N'')
       AND ISNULL(@c_dept, -1) = ISNULL(@dept, -1) AND ISNULL(@c_loc, -1) = ISNULL(@loc, -1)
       AND ISNULL(@c_building, N'') = ISNULL(@building, N'') AND ISNULL(@c_floor, N'') = ISNULL(@floor, N'')
       AND ISNULL(@c_room, N'') = ISNULL(@room, N'')
        RETURN;   -- nothing tracked changed

    -- Effective from: the assignment start date when it is newer than the current row, else today.
    DECLARE @from DATE = CASE WHEN @start IS NOT NULL AND (@c_from IS NULL OR @start > @c_from) AND @start <= @today THEN @start
                              WHEN @cur_id IS NULL THEN ISNULL(@start, @today) ELSE @today END;
    DECLARE @custodian_changed BIT = CASE WHEN ISNULL(@c_cust, N'') <> ISNULL(@custodian, N'') THEN 1 ELSE 0 END,
            @owner_changed BIT = CASE WHEN ISNULL(@c_owner, -1) <> ISNULL(@owner, -1) THEN 1 ELSE 0 END;
    DECLARE @new_id BIGINT;

    BEGIN TRAN;
    UPDATE grac_practice.asset_assignment_history
       SET is_current = 0, effective_to = @from
     WHERE assignment_id = @cur_id;
    INSERT grac_practice.asset_assignment_history
        (organization_id, asset_id, asset_owner_id, custodian, department_id, location_id, building, floor, room,
         effective_from, is_current, change_source, entered_by)
    VALUES (@organization_id, @asset_id, @owner, @custodian, @dept, @loc, @building, @floor, @room,
            @from, 1, @source, @actor);
    SET @new_id = SCOPE_IDENTITY();

    IF @raise_acknowledgement = 1 AND (@custodian_changed = 1 OR @owner_changed = 1)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                        WHERE a.asset_id = @asset_id AND s.status_code IN (N'DISPOSED', N'ARCHIVED'))
    BEGIN
        DECLARE @participant NVARCHAR(20), @window INT;
        SELECT @participant = CASE WHEN AttestationRequired = 1 THEN Participant END, @window = DueWindowDays
          FROM grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset_id);
        DECLARE @roles TABLE (role_code NVARCHAR(20) PRIMARY KEY);
        IF @custodian_changed = 1 AND @participant IN (N'CUSTODIAN', N'BOTH') INSERT @roles VALUES (N'CUSTODIAN');
        IF @owner_changed = 1 AND @participant IN (N'OWNER', N'BOTH') INSERT @roles VALUES (N'OWNER');

        -- Superseded open acknowledgements are cancelled (history kept).
        UPDATE t
           SET status = N'CANCELLED', decision_note = N'Superseded by a new assignment.', decided_by = @actor,
               decided_dt = SYSUTCDATETIME(), closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.asset_attestation t JOIN @roles r ON r.role_code = t.assignee_role
         WHERE t.asset_id = @asset_id AND t.attestation_type = N'INITIAL'
           AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE');
        -- Open periodic / campaign occurrences move to the new assignee (5.3.3).
        UPDATE t
           SET assignee_employee_id = CASE WHEN t.assignee_role = N'OWNER' THEN @owner
                                           WHEN @custodian LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@custodian, 3, 38)) END,
               assignee_team_id = CASE WHEN t.assignee_role = N'CUSTODIAN' AND @custodian LIKE N'T:%'
                                       THEN TRY_CONVERT(BIGINT, SUBSTRING(@custodian, 3, 38)) END,
               assignment_id = @new_id, snap_custodian = @custodian, snap_owner_id = @owner,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.asset_attestation t JOIN @roles r ON r.role_code = t.assignee_role
         WHERE t.asset_id = @asset_id AND t.attestation_type <> N'INITIAL'
           AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE');

        DECLARE @role NVARCHAR(20), @key NVARCHAR(200), @due DATE = DATEADD(DAY, ISNULL(@window, 7), @today), @att BIGINT, @skip NVARCHAR(100);
        DECLARE role_cur CURSOR LOCAL FAST_FORWARD FOR SELECT role_code FROM @roles;
        OPEN role_cur;
        FETCH NEXT FROM role_cur INTO @role;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @key = CONCAT(N'INITIAL:', @asset_id, N':', @role, N':', @new_id);
            EXEC grac_practice.sp_asset_attestation_create
                 @organization_id = @organization_id, @asset_id = @asset_id, @attestation_type = N'INITIAL',
                 @assignee_role = @role, @occurrence_key = @key, @due_date = @due, @actor = @actor,
                 @out_attestation_id = @att OUTPUT, @out_skip_reason = @skip OUTPUT;
            FETCH NEXT FROM role_cur INTO @role;
        END
        CLOSE role_cur;
        DEALLOCATE role_cur;
    END
    COMMIT;
END
GO

-- Starting assignment row for every existing asset (no acknowledgement raised).
DECLARE @aid BIGINT, @oid BIGINT, @n INT = 0;
DECLARE asset_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.asset_id, a.organization_id FROM grac_practice.organization_dependency_asset a
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_assignment_history h WHERE h.asset_id = a.asset_id);
OPEN asset_cur;
FETCH NEXT FROM asset_cur INTO @aid, @oid;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC grac_practice.sp_asset_assignment_snapshot
         @organization_id = @oid, @asset_id = @aid, @source = N'Existing value (431)', @raise_acknowledgement = 0, @actor = N'seed-431';
    SET @n = @n + 1;
    FETCH NEXT FROM asset_cur INTO @aid, @oid;
END
CLOSE asset_cur;
DEALLOCATE asset_cur;
PRINT CONCAT('431: starting assignment rows: ', @n);
GO

-- =====================================================================
-- 4. sp_asset_register_save (430) re-issued -- one call added, marked 431
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_save
    @organization_id         BIGINT,
    @asset_id                BIGINT         = NULL,
    @asset_type_id           INT            = NULL,
    @values_json             NVARCHAR(MAX)  = N'{}',
    @hidden_decisions_json   NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_asset_id            BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';
    IF ISJSON(ISNULL(@hidden_decisions_json, N'')) <> 1 SET @hidden_decisions_json = N'{}';
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54950, 'Organization not found.', 1;

    -- ---------------------------------------------------------- the record
    DECLARE @found BIT = 0, @rv BIGINT, @old_type INT, @template_id BIGINT;
    IF @asset_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_type = asset_type_id, @template_id = template_id
          FROM grac_practice.organization_dependency_asset
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54951, 'Asset not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54952, 'This asset was changed by someone else. Reload it and try again.', 1;
        IF @old_type IS NOT NULL AND @asset_type_id IS NOT NULL AND @asset_type_id <> @old_type
            THROW 54953, 'The asset type of a registered asset cannot change.', 1;
        SET @asset_type_id = ISNULL(@old_type, @asset_type_id);
    END
    IF @asset_type_id IS NULL
       OR (ISNULL(@old_type, -1) <> @asset_type_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id))
        THROW 54954, 'Select an asset type that is active and in effect.', 1;

    -- Template: the version the asset was registered with, else the Active one (5.2.1).
    IF @template_id IS NULL
        SELECT @template_id = template_id FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_active_version = 1;
    IF @template_id IS NULL
        THROW 54955, 'This asset type has no Active form template. Activate one on Asset Form Templates first.', 1;

    DECLARE @sub_id INT, @cat_id INT;
    SELECT @sub_id = t.subcategory_id, @cat_id = s.asset_category_id
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
     WHERE t.asset_type_id = @asset_type_id;

    -- ---------------------------------------------------------- template fields
    DECLARE @tf TABLE (
        field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL UNIQUE, label NVARCHAR(200) NOT NULL,
        data_type NVARCHAR(30) NOT NULL, lookup_source NVARCHAR(100) NULL, storage_kind NVARCHAR(10) NOT NULL,
        column_name NVARCHAR(128) NULL, editable BIT NOT NULL, default_value NVARCHAR(400) NULL,
        hidden_behavior NVARCHAR(10) NOT NULL, is_multi BIT NOT NULL);
    INSERT @tf
    SELECT d.field_definition_id, d.field_key, d.display_label, d.data_type_code, d.lookup_source, d.storage_kind, d.column_name,
           CASE WHEN dt.is_user_entered = 1 AND f.is_read_only = 0 AND d.storage_kind <> N'SYSTEM' AND d.is_system_field = 0
                 AND ISNULL(d.column_name, N'') NOT IN (N'organization_id', N'asset_type_id', N'asset_subcategory_id', N'asset_category_id')
                THEN 1 ELSE 0 END,
           f.default_value, f.hidden_value_behavior,
           CASE WHEN d.data_type_code IN (N'MULTI_SELECT', N'MULTI_USER') THEN 1 ELSE 0 END
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id;

    -- ---------------------------------------------------------- stored, submitted, effective
    DECLARE @stored TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    IF @asset_id IS NOT NULL
        INSERT @stored (field_key, val) SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id);

    DECLARE @sub TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @sub (field_key, val)
    SELECT j.[key],
           CASE WHEN j.[type] = 4 THEN CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(j.[value])) THEN j.[value] END
                WHEN j.[type] = 0 THEN NULL
                ELSE NULLIF(LTRIM(RTRIM(j.[value])), N'') END
      FROM OPENJSON(@values_json) j
      -- OPENJSON's [key] is Latin1_General_BIN2; compare in the database collation (Msg 468).
      JOIN @tf t ON t.field_key = j.[key] COLLATE DATABASE_DEFAULT AND t.editable = 1;
    -- New asset: template defaults for fields not supplied.
    IF @asset_id IS NULL
        INSERT @sub (field_key, val)
        SELECT t.field_key, t.default_value FROM @tf t
         WHERE t.editable = 1 AND t.default_value IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @sub s WHERE s.field_key = t.field_key);

    DECLARE @eff TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL, submitted BIT NOT NULL);
    INSERT @eff (field_key, val, submitted)
    SELECT t.field_key,
           CASE WHEN s.field_key IS NOT NULL THEN s.val ELSE st.val END,
           CASE WHEN s.field_key IS NOT NULL AND ISNULL(s.val, N'') <> ISNULL(st.val, N'') THEN 1 ELSE 0 END
      FROM @tf t
      LEFT JOIN @sub s ON s.field_key = t.field_key
      LEFT JOIN @stored st ON st.field_key = t.field_key;
    -- Taxonomy and legal entity follow the asset type and the organization.
    UPDATE e SET val = CASE t.column_name WHEN N'asset_type_id' THEN CAST(@asset_type_id AS NVARCHAR(40))
                                          WHEN N'asset_subcategory_id' THEN CAST(@sub_id AS NVARCHAR(40))
                                          WHEN N'asset_category_id' THEN CAST(@cat_id AS NVARCHAR(40))
                                          ELSE CAST(@organization_id AS NVARCHAR(40)) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     WHERE t.column_name IN (N'asset_type_id', N'asset_subcategory_id', N'asset_category_id', N'organization_id');

    -- ---------------------------------------------------------- rules (5.1.14)
    DECLARE @eval_json NVARCHAR(MAX) = N'{' + ISNULL((
        SELECT STRING_AGG(CAST(CONCAT(N'"', STRING_ESCAPE(e.field_key, 'json'), N'":',
                    CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                         ELSE N'"' + STRING_ESCAPE(e.val, 'json') + N'"' END) AS NVARCHAR(MAX)), N',')
          FROM @eff e JOIN @tf t ON t.field_key = e.field_key
         WHERE e.val IS NOT NULL), N'') + N'}';
    DECLARE @ev TABLE (field_key NVARCHAR(100) PRIMARY KEY, is_visible INT NOT NULL, is_mandatory INT NOT NULL);
    INSERT @ev (field_key, is_visible, is_mandatory)
    SELECT FieldKey, IsVisible, IsMandatory FROM grac_practice.fn_asset_form_evaluate(@template_id, @eval_json);

    DECLARE @issues TABLE (severity NVARCHAR(10) NOT NULL, field_key NVARCHAR(100) NULL, message NVARCHAR(500) NOT NULL);

    -- Hidden fields holding a value (5.1.14): RETAIN keeps it; CLEAR / MIGRATE need a decision.
    DECLARE @decisions TABLE (field_key NVARCHAR(100) PRIMARY KEY, decision NVARCHAR(10) NOT NULL);
    INSERT @decisions (field_key, decision)
    SELECT j.[key], UPPER(j.[value]) FROM OPENJSON(@hidden_decisions_json) j WHERE UPPER(j.[value]) IN (N'RETAIN', N'CLEAR');
    INSERT @issues (severity, field_key, message)
    SELECT N'DECISION', t.field_key,
           CONCAT(N'"', t.label, N'" is hidden by the form rules but holds a value. Choose whether to keep it or clear it.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 0
      JOIN @stored st ON st.field_key = t.field_key AND st.val IS NOT NULL
     WHERE t.editable = 1 AND t.hidden_behavior IN (N'CLEAR', N'MIGRATE')
       AND NOT EXISTS (SELECT 1 FROM @decisions d WHERE d.field_key = t.field_key);
    -- Hidden fields: never take a newly typed value; keep or clear the stored one.
    UPDATE e
       SET val = CASE WHEN ISNULL(d.decision, CASE WHEN t.hidden_behavior = N'RETAIN' THEN N'RETAIN' END) = N'CLEAR' THEN NULL ELSE st.val END,
           submitted = CASE WHEN ISNULL(d.decision, N'') = N'CLEAR' AND st.val IS NOT NULL THEN 1 ELSE 0 END
      FROM @eff e
      JOIN @tf t ON t.field_key = e.field_key AND t.editable = 1
      JOIN @ev v ON v.field_key = e.field_key AND v.is_visible = 0
      LEFT JOIN @stored st ON st.field_key = e.field_key
      LEFT JOIN @decisions d ON d.field_key = e.field_key;

    -- ---------------------------------------------------------- mandatory
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key, CONCAT(N'"', t.label, N'" is required.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 1 AND v.is_mandatory = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.val IS NULL;

    -- ---------------------------------------------------------- data types (changed values)
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key,
           CONCAT(N'"', t.label, N'" ', CASE
               WHEN t.data_type IN (N'DECIMAL', N'CURRENCY') THEN N'must be a number.'
               WHEN t.data_type = N'PERCENT' THEN N'must be a number from 0 to 100.'
               WHEN t.data_type = N'QUANTITY_UNIT' THEN N'must start with a number (for example "12 months").'
               WHEN t.data_type = N'DATE' THEN N'must be a date (yyyy-mm-dd).'
               WHEN t.data_type = N'YES_NO' THEN N'must be Yes or No.'
               ELSE N'is not valid.' END)
      FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL
       AND (   (t.data_type IN (N'DECIMAL', N'CURRENCY') AND TRY_CONVERT(DECIMAL(38, 6), e.val) IS NULL)
            OR (t.data_type = N'PERCENT' AND ISNULL(TRY_CONVERT(DECIMAL(38, 6), e.val), -1) NOT BETWEEN 0 AND 100)
            OR (t.data_type = N'QUANTITY_UNIT' AND TRY_CONVERT(DECIMAL(38, 6), LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1)) IS NULL)
            OR (t.data_type = N'DATE' AND TRY_CONVERT(DATE, e.val, 23) IS NULL)
            OR (t.data_type = N'YES_NO' AND e.val NOT IN (N'Yes', N'No')));

    -- ---------------------------------------------------------- lookup values (changed values)
    DECLARE @elems TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elems (field_key, elem)
    SELECT e.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     CROSS APPLY OPENJSON(CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                               ELSE N'["' + STRING_ESCAPE(e.val, 'json') + N'"]' END) a
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL AND t.lookup_source IS NOT NULL
       AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';

    INSERT @issues (severity, field_key, message)
    SELECT DISTINCT N'ERROR', t.field_key,
           CASE WHEN t.lookup_source = N'MASTER:CONTRACT'
                THEN CONCAT(N'"', t.label, N'" is linked once contracts are available (Phase 5); leave it empty for now.')
                ELSE CONCAT(N'"', t.label, N'" has a value that is not in its list: ', x.elem, N'.') END
      FROM @elems x JOIN @tf t ON t.field_key = x.field_key
     WHERE t.lookup_source NOT IN (N'MASTER:COUNTRY', N'MASTER:CURRENCY')
       AND t.lookup_source NOT LIKE N'STATE:%'
       AND NOT (t.lookup_source LIKE N'OPTION:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) o
                 WHERE o.OptionGroup = N'asset_field.' + SUBSTRING(t.lookup_source, 8, 100) AND o.OptionValue = x.elem))
       AND NOT (t.lookup_source LIKE N'MASTER:%' AND t.lookup_source <> N'MASTER:CONTRACT' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_master_lookup(@organization_id) m
                 WHERE m.Source = t.lookup_source AND m.Value = x.elem))
       -- CIA ratings: the levels of the Active valuation configuration (same mapping as 422 / 423 template get).
       AND NOT (t.lookup_source = N'CONFIG:CIA_SCALE' AND EXISTS (
                SELECT 1 FROM grac_practice.asset_valuation_config c
                  JOIN grac_practice.asset_cia_scale_level l ON l.config_id = c.config_id
                 WHERE c.organization_id = @organization_id AND c.is_active_version = 1
                   AND CAST(l.score AS NVARCHAR(160)) = x.elem
                   AND l.dimension_code = CASE t.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                           WHEN N'integrity_rating' THEN N'I'
                                                           WHEN N'availability_rating' THEN N'A' END));

    -- ---------------------------------------------------------- cross-field rules (5.1 / 5.1.16)
    DECLARE @num TABLE (field_key NVARCHAR(100) PRIMARY KEY, n DECIMAL(38, 6) NULL, d DATE NULL);
    INSERT @num (field_key, n, d)
    SELECT e.field_key,
           TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END),
           CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key WHERE e.val IS NOT NULL;

    INSERT @issues (severity, field_key, message)
    SELECT r.severity, r.field_key, r.message
      FROM grac_practice.asset_field_validation_rule r
      JOIN @eff e ON e.field_key = r.field_key
      JOIN @num a ON a.field_key = r.field_key
      LEFT JOIN @eff eo ON eo.field_key = r.other_field_key
      LEFT JOIN @num b ON b.field_key = r.other_field_key
      LEFT JOIN @stored st ON st.field_key = r.field_key
     WHERE r.is_active = 1
       AND (e.submitted = 1 OR ISNULL(eo.submitted, 0) = 1)
       AND (   (r.rule_code = N'NOT_FUTURE'       AND a.d > @today)
            OR (r.rule_code = N'ON_OR_AFTER'      AND a.d < b.d)
            OR (r.rule_code = N'AFTER'            AND a.d <= b.d)
            OR (r.rule_code = N'NON_NEGATIVE'     AND a.n < 0)
            OR (r.rule_code = N'POSITIVE'         AND a.n <= 0)
            OR (r.rule_code = N'NOT_GREATER_THAN' AND a.n > b.n)
            OR (r.rule_code = N'NOT_BELOW_STORED' AND a.n < TRY_CONVERT(DECIMAL(38, 6), st.val)));

    -- Model must belong to the selected make and asset type (5.1.16).
    DECLARE @model_val NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'model'),
            @make_val  NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'manufacturer_make');
    DECLARE @model_id BIGINT = TRY_CONVERT(BIGINT, @model_val), @m_make INT, @m_type INT;
    IF @model_id IS NOT NULL
    BEGIN
        SELECT @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model WHERE model_id = @model_id;
        IF @m_type IS NOT NULL AND @m_type <> @asset_type_id
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model belongs to a different asset type.');
        IF @m_make IS NOT NULL AND (@make_val IS NULL OR TRY_CONVERT(INT, @make_val) <> @m_make)
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model does not belong to the selected make.');
    END

    -- Serial uniqueness within make / model: warning (no blocking policy configured).
    DECLARE @serial NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'serial_number' AND submitted = 1);
    IF @serial IS NOT NULL AND EXISTS (
        SELECT 1 FROM grac_practice.asset_field_value sv
          JOIN grac_practice.asset_field_definition sd ON sd.field_definition_id = sv.field_definition_id AND sd.field_key = N'serial_number'
          JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = sv.asset_id AND a2.organization_id = @organization_id
          LEFT JOIN grac_practice.asset_field_value mv ON mv.asset_id = sv.asset_id
               AND mv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'model')
          LEFT JOIN grac_practice.asset_field_value kv ON kv.asset_id = sv.asset_id
               AND kv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'manufacturer_make')
         WHERE sv.value_text = @serial AND sv.asset_id <> ISNULL(@asset_id, -1)
           AND ISNULL(mv.value_text, N'') = ISNULL(@model_val, N'') AND ISNULL(kv.value_text, N'') = ISNULL(@make_val, N''))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'serial_number', N'Another asset of this make and model already has this serial number.');

    -- 430: installed firmware / OS (5.1.16 "approved mapping or explicit exception", 4.8)
    -- An ERROR unless an active technology exception covers the asset (or its
    -- model) and the version; it was a warning in 428 until exceptions existed (D14, D19).
    DECLARE @fw BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version' AND submitted = 1)),
            @os BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system' AND submitted = 1));
    DECLARE @hw_rev NVARCHAR(400) = LEFT((SELECT val FROM @eff WHERE field_key = N'hardware_revision'), 400);
    IF @fw IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'FIRMWARE', @fw, @asset_type_id, @model_id, @hw_rev) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'FIRMWARE', @fw))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'firmware_version', N'This firmware has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');
    IF @os IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'OS', @os, @asset_type_id, @model_id, NULL) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'OS', @os))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'operating_system', N'This operating system has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');

    -- Asset name is unique in the organization (existing constraint uq_pm_org_asset_name).
    DECLARE @name NVARCHAR(220) = LEFT((SELECT val FROM @eff WHERE field_key = N'asset_name'), 220);
    IF @name IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                                      WHERE organization_id = @organization_id AND asset_name = @name AND asset_id <> ISNULL(@asset_id, -1))
        INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'asset_name', N'Another asset in this organization already has this name.');

    -- ---------------------------------------------------------- stop or write
    IF EXISTS (SELECT 1 FROM @issues WHERE severity IN (N'ERROR', N'DECISION'))
    BEGIN
        SET @out_result = CASE WHEN EXISTS (SELECT 1 FROM @issues WHERE severity = N'ERROR') THEN N'INVALID' ELSE N'NEEDS_DECISION' END;
        SET @out_asset_id = @asset_id;
        SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues
         ORDER BY CASE severity WHEN N'ERROR' THEN 0 WHEN N'DECISION' THEN 1 ELSE 2 END, field_key;
        RETURN;
    END

    DECLARE @col TABLE (column_name NVARCHAR(128) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @col (column_name, val)
    SELECT t.column_name, e.val FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.storage_kind = N'COLUMN' AND t.editable = 1;
    DECLARE @in_tpl TABLE (column_name NVARCHAR(128) PRIMARY KEY);
    INSERT @in_tpl (column_name) SELECT column_name FROM @col;

    DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                               WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'Asset', N'DRAFT');
    DECLARE @before NVARCHAR(MAX) = (SELECT field_key AS fieldKey, val AS value FROM @stored FOR JSON PATH);
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @asset_id IS NULL
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id, owner_id, location_id,
             purchase_dt, warranty_expiry_dt, amc_expiry_dt, criticality_id, remarks, status, record_status_id,
             lifecycle_status, template_id, current_status_id, entered_by)
        SELECT @organization_id, @name, @cat_id, @sub_id, @asset_type_id,
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')),
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23),
               TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')),
               (SELECT val FROM @col WHERE column_name = N'remarks'),
               N'Active', ISNULL(@active_rs, 1), p.legacy_lifecycle_status, @template_id, @draft_id, @actor
          FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = N'DRAFT';
        SET @out_asset_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'Asset', @entity_id = @out_asset_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'REGISTERED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        -- Only columns whose field is on the template change.
        UPDATE a
           SET asset_name = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'asset_name') THEN @name ELSE a.asset_name END,
               asset_category_id = @cat_id, asset_subcategory_id = @sub_id, asset_type_id = @asset_type_id,
               owner_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'owner_id')
                               THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')) ELSE a.owner_id END,
               location_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'location_id')
                                  THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')) ELSE a.location_id END,
               purchase_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'purchase_dt')
                                  THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23) ELSE a.purchase_dt END,
               warranty_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'warranty_expiry_dt')
                                         THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23) ELSE a.warranty_expiry_dt END,
               amc_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'amc_expiry_dt')
                                    THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23) ELSE a.amc_expiry_dt END,
               criticality_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'criticality_id')
                                     THEN TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')) ELSE a.criticality_id END,
               remarks = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'remarks')
                              THEN (SELECT val FROM @col WHERE column_name = N'remarks') ELSE a.remarks END,
               template_id = @template_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset_id;
        SET @out_asset_id = @asset_id;
    END

    -- VALUE fields on the template: clear the empty ones, upsert the rest.
    DELETE v
      FROM grac_practice.asset_field_value v
      JOIN @tf t ON t.field_definition_id = v.field_definition_id AND t.storage_kind = N'VALUE' AND t.editable = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE v.asset_id = @out_asset_id AND e.val IS NULL;
    MERGE grac_practice.asset_field_value AS tgt
    USING (
        SELECT t.field_definition_id, e.val,
               TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END) AS n,
               CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END AS d,
               CASE WHEN t.lookup_source LIKE N'MASTER:%' AND t.is_multi = 0 THEN TRY_CONVERT(BIGINT, e.val) END AS r
          FROM @tf t JOIN @eff e ON e.field_key = t.field_key
         WHERE t.storage_kind = N'VALUE' AND t.editable = 1 AND e.val IS NOT NULL
    ) AS src
    ON tgt.asset_id = @out_asset_id AND tgt.field_definition_id = src.field_definition_id
    WHEN MATCHED AND tgt.value_text <> src.val THEN
        UPDATE SET value_text = src.val, value_number = src.n, value_date = src.d, value_ref = src.r,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
        VALUES (@out_asset_id, src.field_definition_id, src.val, src.n, src.d, src.r, @actor);

    -- 430: installed firmware / OS history (BRD 4.6) when the form changes them.
    DECLARE @fw_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'firmware_version')),
            @fw_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version')),
            @os_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'operating_system')),
            @os_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system'));
    DECLARE @patch_old NVARCHAR(100) = LEFT((SELECT val FROM @stored WHERE field_key = N'os_build_patch_level'), 100),
            @patch_new NVARCHAR(100) = LEFT((SELECT val FROM @eff WHERE field_key = N'os_build_patch_level'), 100);
    DECLARE @fw_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'firmware_version' AND editable = 1) THEN 1 ELSE 0 END,
            @os_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'operating_system' AND editable = 1) THEN 1 ELSE 0 END;
    DECLARE @inst_id BIGINT, @form_source NVARCHAR(100) = N'Asset form';
    IF @fw_on_tpl = 1 AND @fw_new IS NOT NULL AND ISNULL(@fw_old, -1) <> @fw_new
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'FIRMWARE', @release_id = @fw_new,
             @installed_date = @today, @source = @form_source, @update_value = 0, @actor = @actor,
             @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @fw_on_tpl = 1 AND @fw_new IS NULL AND @fw_old IS NOT NULL
        UPDATE grac_practice.asset_firmware_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;
    IF @os_on_tpl = 1 AND @os_new IS NOT NULL AND (ISNULL(@os_old, -1) <> @os_new OR ISNULL(@patch_old, N'') <> ISNULL(@patch_new, N''))
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'OS', @release_id = @os_new,
             @build_patch_level = @patch_new, @installed_date = @today, @source = @form_source, @update_value = 0,
             @actor = @actor, @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @os_on_tpl = 1 AND @os_new IS NULL AND @os_old IS NOT NULL
        UPDATE grac_practice.asset_os_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;

    -- 431: ownership / custody / location history and the acknowledgement it raises (5.3.2).
    DECLARE @assign_source NVARCHAR(100) = N'Asset form';
    EXEC grac_practice.sp_asset_assignment_snapshot
         @organization_id = @organization_id, @asset_id = @out_asset_id, @source = @assign_source,
         @raise_acknowledgement = 1, @actor = @actor;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @out_asset_id, CASE WHEN @asset_id IS NULL THEN N'ADD' ELSE N'SAVE' END,
            CASE WHEN @asset_id IS NULL THEN NULL ELSE @before END,
            (SELECT @template_id AS templateId,
                    (SELECT e.field_key AS fieldKey, e.val AS value FROM @eff e WHERE e.submitted = 1 FOR JSON PATH) AS changedValues
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SET @out_result = N'SAVED';
    SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues ORDER BY field_key;
END
GO
PRINT '431: sp_asset_register_save re-issued.';
GO

-- =====================================================================
-- 5. Attestation procedures
-- =====================================================================
-- Internal: writes one VALUE field of an asset (used for the dictionary fields
-- last_verified_date / verified_by after a confirmed attestation).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_field_value_set
    @asset_id  BIGINT,
    @field_key NVARCHAR(100),
    @value     NVARCHAR(400),
    @value_ref BIGINT        = NULL,
    @actor     NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @def INT = (SELECT field_definition_id FROM grac_practice.asset_field_definition
                         WHERE field_key = @field_key AND storage_kind = N'VALUE');
    IF @def IS NULL RETURN;
    IF @value IS NULL
    BEGIN
        DELETE FROM grac_practice.asset_field_value WHERE asset_id = @asset_id AND field_definition_id = @def;
        RETURN;
    END
    MERGE grac_practice.asset_field_value AS tgt
    USING (SELECT @def AS field_definition_id) AS src
    ON tgt.asset_id = @asset_id AND tgt.field_definition_id = src.field_definition_id
    WHEN MATCHED AND tgt.value_text <> @value THEN
        UPDATE SET value_text = @value, value_number = TRY_CONVERT(DECIMAL(38, 6), @value),
                   value_date = TRY_CONVERT(DATE, @value, 23), value_ref = @value_ref,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
        VALUES (@asset_id, src.field_definition_id, @value, TRY_CONVERT(DECIMAL(38, 6), @value),
                TRY_CONVERT(DATE, @value, 23), @value_ref, @actor);
END
GO

-- Internal: a confirmed occurrence closes; the asset becomes Verified with
-- its next attestation date (5.3.5 Confirm).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_close_verified
    @attestation_id BIGINT,
    @actor          NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @asset_id BIGINT, @org BIGINT, @profile_id BIGINT, @attester BIGINT;
    SELECT @asset_id = asset_id, @org = organization_id, @profile_id = profile_id, @attester = attested_by_employee_id
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id;
    DECLARE @next DATE = (SELECT grac_practice.fn_asset_attestation_next_date(@today, frequency, custom_interval_days)
                            FROM grac_practice.asset_attestation_profile WHERE profile_id = @profile_id);
    DECLARE @today_text NVARCHAR(400) = CONVERT(NVARCHAR(10), @today, 23),
            @attester_text NVARCHAR(400) = CAST(@attester AS NVARCHAR(40));

    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET status = N'CLOSED', closed_dt = SYSUTCDATETIME(), verification_status = N'VERIFIED',
           next_attestation_date = @next, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    MERGE grac_practice.asset_attestation_state AS t
    USING (SELECT @asset_id AS asset_id) AS s ON t.asset_id = s.asset_id
    WHEN MATCHED THEN UPDATE SET last_attested_date = @today, verification_status = N'VERIFIED', next_attestation_date = @next,
                                 last_attestation_id = @attestation_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (asset_id, organization_id, last_attested_date, verification_status, next_attestation_date,
                                  last_attestation_id, updated_by, updated_dt)
                          VALUES (@asset_id, @org, @today, N'VERIFIED', @next, @attestation_id, @actor, SYSUTCDATETIME());
    EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset_id, @field_key = N'last_verified_date',
         @value = @today_text, @actor = @actor;
    EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset_id, @field_key = N'verified_by',
         @value = @attester_text, @value_ref = @attester, @actor = @actor;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_profile_save
    @organization_id           BIGINT,
    @profile_id                BIGINT        = NULL,
    @scope_kind                NVARCHAR(20),
    @scope_id                  INT,
    @attestation_required      BIT           = 1,
    @participant               NVARCHAR(20),
    @frequency                 NVARCHAR(20),
    @custom_interval_days      INT           = NULL,
    @due_window_days           INT,
    @evidence_requirement      NVARCHAR(20),
    @manager_approval_required BIT           = 0,
    @is_active                 BIT           = 1,
    @expected_record_version   BIGINT        = NULL,
    @actor                     NVARCHAR(100) = N'system',
    @out_profile_id            BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @scope_kind = UPPER(LTRIM(RTRIM(ISNULL(@scope_kind, N''))));
    SET @participant = UPPER(LTRIM(RTRIM(ISNULL(@participant, N''))));
    SET @frequency = UPPER(LTRIM(RTRIM(ISNULL(@frequency, N''))));
    SET @evidence_requirement = UPPER(LTRIM(RTRIM(ISNULL(@evidence_requirement, N''))));
    SET @attestation_required = ISNULL(@attestation_required, 1);
    SET @manager_approval_required = ISNULL(@manager_approval_required, 0);
    SET @is_active = ISNULL(@is_active, 1);
    IF @frequency <> N'CUSTOM' SET @custom_interval_days = NULL;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54350, 'Organization not found.', 1;
    DECLARE @found BIT = 0, @rv BIGINT, @old_kind NVARCHAR(20), @old_scope INT, @before NVARCHAR(MAX);
    IF @profile_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_kind = scope_kind,
               @old_scope = COALESCE(asset_type_id, asset_subcategory_id, asset_category_id)
          FROM grac_practice.asset_attestation_profile WHERE profile_id = @profile_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54352, 'Attestation profile not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54353, 'This profile was changed by someone else. Reload and try again.', 1;
        IF @old_kind <> @scope_kind OR @old_scope <> @scope_id
            THROW 54354, 'The scope of a profile cannot change; add a profile for the other scope.', 1;
        SET @before = (SELECT * FROM grac_practice.asset_attestation_profile WHERE profile_id = @profile_id
                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    END
    IF NOT ((@scope_kind = N'CATEGORY' AND EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master WHERE asset_category_id = @scope_id))
         OR (@scope_kind = N'SUBCATEGORY' AND EXISTS (SELECT 1 FROM grac_practice.dependency_asset_subcategory_master WHERE subcategory_id = @scope_id))
         OR (@scope_kind = N'ASSET_TYPE' AND EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @scope_id)))
        THROW 54354, 'Select a category, subcategory or asset type for the profile.', 1;
    IF @participant NOT IN (N'CUSTODIAN', N'OWNER', N'BOTH')
       OR @frequency NOT IN (N'MONTHLY', N'QUARTERLY', N'HALF_YEARLY', N'ANNUAL', N'CUSTOM')
       OR (@frequency = N'CUSTOM' AND ISNULL(@custom_interval_days, 0) NOT BETWEEN 1 AND 3660)
       OR ISNULL(@due_window_days, 0) NOT BETWEEN 1 AND 365
       OR @evidence_requirement NOT IN (N'NONE', N'OPTIONAL', N'MANDATORY')
        THROW 54355, 'Check the participant, frequency (custom: 1-3660 days), due window (1-365 days) and evidence requirement.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation_profile
                WHERE organization_id = @organization_id AND scope_kind = @scope_kind
                  AND COALESCE(asset_type_id, asset_subcategory_id, asset_category_id) = @scope_id
                  AND profile_id <> ISNULL(@profile_id, -1))
        THROW 54356, 'A profile already exists for this scope; edit it instead.', 1;

    BEGIN TRAN;
    IF @profile_id IS NULL
    BEGIN
        INSERT grac_practice.asset_attestation_profile
            (organization_id, scope_kind, asset_category_id, asset_subcategory_id, asset_type_id, attestation_required, participant,
             frequency, custom_interval_days, due_window_days, evidence_requirement, manager_approval_required, is_active, entered_by)
        VALUES (@organization_id, @scope_kind,
                CASE WHEN @scope_kind = N'CATEGORY' THEN @scope_id END,
                CASE WHEN @scope_kind = N'SUBCATEGORY' THEN @scope_id END,
                CASE WHEN @scope_kind = N'ASSET_TYPE' THEN @scope_id END,
                @attestation_required, @participant, @frequency, @custom_interval_days, @due_window_days, @evidence_requirement,
                @manager_approval_required, @is_active, @actor);
        SET @out_profile_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_attestation_profile
           SET attestation_required = @attestation_required, participant = @participant, frequency = @frequency,
               custom_interval_days = @custom_interval_days, due_window_days = @due_window_days,
               evidence_requirement = @evidence_requirement, manager_approval_required = @manager_approval_required,
               is_active = @is_active, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE profile_id = @profile_id;
        SET @out_profile_id = @profile_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation-profile', @out_profile_id, CASE WHEN @profile_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT * FROM grac_practice.asset_attestation_profile WHERE profile_id = @out_profile_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- Periodic run or ad-hoc campaign (5.3.3). Marks overdue occurrences
-- first; then one occurrence per applicable asset, participant and due
-- period. Idempotent through the occurrence key.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_generate
    @organization_id BIGINT,
    @campaign_type   NVARCHAR(20)  = N'PERIODIC',
    @campaign_name   NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @due_date        DATE          = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @campaign_type = UPPER(LTRIM(RTRIM(ISNULL(@campaign_type, N''))));
    SET @campaign_name = NULLIF(LTRIM(RTRIM(@campaign_name)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54350, 'Organization not found.', 1;
    IF @campaign_type NOT IN (N'PERIODIC', N'CAMPAIGN')
        THROW 54372, 'The run must be PERIODIC or CAMPAIGN.', 1;
    IF @campaign_type = N'CAMPAIGN' AND (@campaign_name IS NULL OR @due_date IS NULL OR @due_date < @today)
        THROW 54371, 'A campaign needs a name and a due date that is not in the past.', 1;
    IF @campaign_name IS NULL SET @campaign_name = CONCAT(N'Periodic attestation run ', CONVERT(NVARCHAR(10), @today, 23));

    DECLARE @overdue INT, @campaign_id BIGINT, @generated INT = 0, @skipped INT = 0;
    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET status = N'OVERDUE', updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id AND status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND due_date < @today;
    SET @overdue = @@ROWCOUNT;
    INSERT grac_practice.asset_attestation_campaign (organization_id, campaign_type, campaign_name, asset_type_id, due_date, overdue_marked, entered_by)
    VALUES (@organization_id, @campaign_type, @campaign_name, @asset_type_id, @due_date, @overdue, @actor);
    SET @campaign_id = SCOPE_IDENTITY();

    -- Applicable assets: a profile requiring attestation; not in acquisition, not lost / stolen, not retired (D24).
    DECLARE @work TABLE (asset_id BIGINT NOT NULL, role_code NVARCHAR(20) NOT NULL, due DATE NOT NULL, occ_key NVARCHAR(200) NOT NULL);
    INSERT @work (asset_id, role_code, due, occ_key)
    SELECT a.asset_id, r.role_code,
           CASE WHEN @campaign_type = N'CAMPAIGN' THEN @due_date
                WHEN st.next_attestation_date IS NULL THEN DATEADD(DAY, p.DueWindowDays, @today)
                WHEN st.next_attestation_date < @today THEN @today ELSE st.next_attestation_date END,
           CASE WHEN @campaign_type = N'CAMPAIGN' THEN CONCAT(N'CAMPAIGN:', @campaign_id, N':', a.asset_id, N':', r.role_code)
                ELSE CONCAT(N'PERIODIC:', a.asset_id, N':', r.role_code, N':',
                            ISNULL(CONVERT(NVARCHAR(10), st.next_attestation_date, 112), N'FIRST')) END
      FROM grac_practice.organization_dependency_asset a
      CROSS APPLY grac_practice.fn_asset_attestation_profile_for(@organization_id, a.asset_id) p
      JOIN (VALUES (N'CUSTODIAN'), (N'OWNER')) r(role_code)
        ON (r.role_code = N'CUSTODIAN' AND p.Participant IN (N'CUSTODIAN', N'BOTH'))
        OR (r.role_code = N'OWNER' AND p.Participant IN (N'OWNER', N'BOTH'))
      LEFT JOIN grac_practice.asset_attestation_state st ON st.asset_id = a.asset_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @organization_id AND p.AttestationRequired = 1
       AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED')
       AND (@campaign_type = N'CAMPAIGN' OR st.next_attestation_date IS NULL
            OR st.next_attestation_date <= DATEADD(DAY, p.DueWindowDays, @today));

    DECLARE @w_asset BIGINT, @w_role NVARCHAR(20), @w_due DATE, @w_key NVARCHAR(200), @att BIGINT, @skip NVARCHAR(100),
            @type NVARCHAR(20) = CASE WHEN @campaign_type = N'CAMPAIGN' THEN N'CAMPAIGN' ELSE N'PERIODIC' END;
    DECLARE work_cur CURSOR LOCAL FAST_FORWARD FOR SELECT asset_id, role_code, due, occ_key FROM @work;
    OPEN work_cur;
    FETCH NEXT FROM work_cur INTO @w_asset, @w_role, @w_due, @w_key;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_asset_attestation_create
             @organization_id = @organization_id, @asset_id = @w_asset, @attestation_type = @type,
             @assignee_role = @w_role, @occurrence_key = @w_key, @due_date = @w_due, @campaign_id = @campaign_id,
             @actor = @actor, @out_attestation_id = @att OUTPUT, @out_skip_reason = @skip OUTPUT;
        IF @att IS NULL SET @skipped = @skipped + 1; ELSE SET @generated = @generated + 1;
        FETCH NEXT FROM work_cur INTO @w_asset, @w_role, @w_due, @w_key;
    END
    CLOSE work_cur;
    DEALLOCATE work_cur;

    UPDATE grac_practice.asset_attestation_campaign
       SET generated_count = @generated, skipped_count = @skipped
     WHERE campaign_id = @campaign_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation-campaign', @campaign_id, N'GENERATE', NULL,
            (SELECT @campaign_type AS campaignType, @campaign_name AS campaignName, @asset_type_id AS assetTypeId, @due_date AS dueDate,
                    @generated AS generated, @skipped AS skipped, @overdue AS overdueMarked FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @campaign_id AS CampaignId, @generated AS Generated, @skipped AS Skipped, @overdue AS OverdueMarked;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_respond
    @organization_id         BIGINT,
    @attestation_id          BIGINT,
    @response                NVARCHAR(10),
    @asset_exists            BIT            = NULL,
    @custody_confirmed       BIT            = NULL,
    @location_verified       BIT            = NULL,
    @tag_verified            BIT            = NULL,
    @serial_verified         BIT            = NULL,
    @assigned_user_verified  BIT            = NULL,
    @information_correct     BIT            = NULL,
    @business_use_confirmed  BIT            = NULL,
    @condition_code          NVARCHAR(30)   = NULL,
    @disagreement_category   NVARCHAR(40)   = NULL,
    @comments                NVARCHAR(2000) = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @channel                 NVARCHAR(30)   = N'Web',
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @response = UPPER(LTRIM(RTRIM(ISNULL(@response, N''))));
    SET @condition_code = UPPER(NULLIF(LTRIM(RTRIM(@condition_code)), N''));
    SET @disagreement_category = UPPER(NULLIF(LTRIM(RTRIM(@disagreement_category)), N''));
    SET @comments = NULLIF(LTRIM(RTRIM(@comments)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');
    SET @channel = ISNULL(NULLIF(LTRIM(RTRIM(@channel)), N''), N'Web');

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @emp BIGINT, @team BIGINT, @evidence_req NVARCHAR(20), @mgr BIT, @asset_id BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @emp = assignee_employee_id, @team = assignee_team_id,
           @evidence_req = evidence_requirement, @mgr = manager_approval_required, @asset_id = asset_id
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54357, 'Attestation not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54358, 'This attestation was changed by someone else. Reload and try again.', 1;
    IF @status NOT IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE')
        THROW 54359, 'This attestation is not open for a response.', 1;
    -- 5.3.2: no response on behalf of another custodian (no delegated authority is configured).
    IF @actor_employee_id IS NULL
       OR NOT (@actor_employee_id = @emp
               OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                           WHERE m.team_id = @team AND m.employee_id = @actor_employee_id AND m.status = N'Active'))
        THROW 54360, 'Only the assigned custodian or owner (or a member of the assigned team) can respond to this attestation.', 1;
    IF @response NOT IN (N'CONFIRM', N'DISAGREE')
        THROW 54361, 'The response must be Confirm or Disagree.', 1;
    IF @condition_code IS NULL OR @condition_code NOT IN
        (N'GOOD', N'FAIR', N'POOR', N'DAMAGED', N'LOST', N'NOT_FOUND', N'RETURNED', N'REPLACED', N'RETIRED')
        THROW 54362, 'Select the condition of the asset.', 1;
    IF @response = N'CONFIRM'
    BEGIN
        IF ISNULL(@asset_exists, 0) = 0 OR ISNULL(@custody_confirmed, 0) = 0 OR @condition_code IN (N'LOST', N'NOT_FOUND')
            THROW 54366, 'A confirmation needs the asset to exist and custody confirmed; a lost or missing asset is a disagreement.', 1;
        -- Conditional confirmation: a check left open or a condition other than Good needs a comment.
        IF @comments IS NULL AND (@condition_code <> N'GOOD' OR ISNULL(@location_verified, 0) = 0 OR ISNULL(@tag_verified, 0) = 0
               OR ISNULL(@serial_verified, 0) = 0 OR ISNULL(@assigned_user_verified, 0) = 0 OR ISNULL(@information_correct, 0) = 0
               OR ISNULL(@business_use_confirmed, 0) = 0)
            THROW 54364, 'Add a comment explaining the checks not confirmed or the condition.', 1;
        SET @disagreement_category = NULL;
    END
    ELSE
    BEGIN
        IF @disagreement_category IS NULL OR @disagreement_category NOT IN
            (N'ASSET_NOT_FOUND', N'WRONG_CUSTODIAN', N'ASSET_RETURNED', N'ASSET_REPLACED', N'ASSET_DAMAGED', N'ASSET_LOST',
             N'LOCATION_INCORRECT', N'INFORMATION_INCORRECT', N'DUPLICATE_RECORD', N'ASSET_RETIRED', N'OTHER')
            THROW 54363, 'Select the disagreement category.', 1;
        IF @comments IS NULL
            THROW 54364, 'Explain the disagreement in the comments.', 1;
    END
    IF @evidence_req = N'MANDATORY' AND @evidence_text IS NULL
        THROW 54365, 'Evidence is required for this attestation (photo, scan, document or other reference).', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT status, response, condition_code, disagreement_category, comments
                                       FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @new_status NVARCHAR(20) = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED'
                                            WHEN @mgr = 1 THEN N'CONFIRMED' ELSE N'CLOSED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET response = @response, asset_exists = @asset_exists, custody_confirmed = @custody_confirmed,
           location_verified = @location_verified, tag_verified = @tag_verified, serial_verified = @serial_verified,
           assigned_user_verified = @assigned_user_verified, information_correct = @information_correct,
           business_use_confirmed = @business_use_confirmed, condition_code = @condition_code,
           disagreement_category = @disagreement_category, comments = @comments, evidence_text = @evidence_text,
           attested_by = @actor, attested_by_employee_id = @actor_employee_id, channel = @channel, response_dt = SYSUTCDATETIME(),
           status = CASE WHEN @new_status = N'CLOSED' THEN N'CONFIRMED' ELSE @new_status END,
           verification_status = CASE WHEN @response = N'DISAGREE' THEN N'DISPUTED' END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    IF @new_status = N'CLOSED'
        EXEC grac_practice.sp_asset_attestation_close_verified @attestation_id = @attestation_id, @actor = @actor;
    IF @response = N'DISAGREE'
        MERGE grac_practice.asset_attestation_state AS t
        USING (SELECT @asset_id AS asset_id) AS s ON t.asset_id = s.asset_id
        WHEN MATCHED THEN UPDATE SET verification_status = N'DISPUTED', last_attestation_id = @attestation_id,
                                     updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (asset_id, organization_id, verification_status, last_attestation_id, updated_by, updated_dt)
                              VALUES (@asset_id, @organization_id, N'DISPUTED', @attestation_id, @actor, SYSUTCDATETIME());
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation', @attestation_id, @response, @before,
            (SELECT @response AS response, @new_status AS status, @condition_code AS conditionCode,
                    @disagreement_category AS disagreementCategory, @comments AS comments, @evidence_text AS evidence,
                    @asset_exists AS assetExists, @custody_confirmed AS custodyConfirmed, @location_verified AS locationVerified,
                    @tag_verified AS tagVerified, @serial_verified AS serialVerified, @assigned_user_verified AS assignedUserVerified,
                    @information_correct AS informationCorrect, @business_use_confirmed AS businessUseConfirmed, @channel AS channel
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @attestation_id AS AttestationId, @new_status AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_decide
    @organization_id         BIGINT,
    @attestation_id          BIGINT,
    @decision                NVARCHAR(10),       -- APPROVE | RETURN (manager) | CANCEL
    @decision_note           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @decision = UPPER(LTRIM(RTRIM(ISNULL(@decision, N''))));
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @attester BIGINT, @owner BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @attester = attested_by_employee_id, @owner = snap_owner_id
      FROM grac_practice.asset_attestation WHERE attestation_id = @attestation_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54357, 'Attestation not found for this organization.', 1;
    IF @decision NOT IN (N'APPROVE', N'RETURN', N'CANCEL')
        THROW 54367, 'The decision must be Approve, Return or Cancel.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54358, 'This attestation was changed by someone else. Reload and try again.', 1;
    IF (@decision IN (N'APPROVE', N'RETURN') AND @status <> N'CONFIRMED')
       OR (@decision = N'CANCEL' AND @status IN (N'CLOSED', N'CANCELLED', N'RESOLVED'))
        THROW 54368, 'This attestation is not in a state that allows that decision.', 1;
    IF @decision IN (N'APPROVE', N'RETURN')
    BEGIN
        -- Manager approval (5.3.1): the reporting officer of the attester, else the asset owner; never the attester.
        DECLARE @approver BIGINT = (SELECT reporting_officer_id FROM grac_practice.organization_employee WHERE employee_id = @attester);
        IF @approver IS NULL OR @approver = @attester SET @approver = CASE WHEN @owner <> @attester THEN @owner END;
        IF @actor_employee_id IS NULL OR @approver IS NULL OR @actor_employee_id <> @approver
            THROW 54369, 'Only the attester''s manager (or, without one, the asset owner) can approve or return this attestation.', 1;
    END
    IF @decision IN (N'RETURN', N'CANCEL') AND @decision_note IS NULL
        THROW 54370, 'Give the reason for this decision.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_attestation
       SET decided_by = @actor, decided_by_employee_id = @actor_employee_id, decided_dt = SYSUTCDATETIME(),
           decision_note = @decision_note,
           status = CASE @decision WHEN N'RETURN' THEN N'IN_PROGRESS' WHEN N'CANCEL' THEN N'CANCELLED' ELSE status END,
           closed_dt = CASE WHEN @decision = N'CANCEL' THEN SYSUTCDATETIME() ELSE closed_dt END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE attestation_id = @attestation_id;
    IF @decision = N'APPROVE'
        EXEC grac_practice.sp_asset_attestation_close_verified @attestation_id = @attestation_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation', @attestation_id, @decision,
            (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @decision AS decision, @decision_note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @attestation_id AS AttestationId,
           CASE @decision WHEN N'APPROVE' THEN N'CLOSED' WHEN N'RETURN' THEN N'IN_PROGRESS' ELSE N'CANCELLED' END AS Result;
END
GO
PRINT '431: attestation procedures created.';
GO

-- =====================================================================
-- 6. Readers
-- =====================================================================
-- Profiles + the taxonomy for the scope picker.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_profiles
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.profile_id AS ProfileId, p.scope_kind AS ScopeKind,
           COALESCE(p.asset_type_id, p.asset_subcategory_id, p.asset_category_id) AS ScopeId,
           COALESCE(t.asset_type_name, s.subcategory_name, c.asset_category_name) AS ScopeName,
           p.attestation_required AS AttestationRequired, p.participant AS Participant, p.frequency AS Frequency,
           p.custom_interval_days AS CustomIntervalDays, p.due_window_days AS DueWindowDays,
           p.evidence_requirement AS EvidenceRequirement, p.manager_approval_required AS ManagerApprovalRequired,
           p.is_active AS IsActive, p.version_no AS VersionNo, CONVERT(BIGINT, p.record_version) AS RecordVersion,
           ISNULL(p.updated_dt, p.entered_dt) AS LastChanged
      FROM grac_practice.asset_attestation_profile p
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = p.asset_type_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = p.asset_subcategory_id
      LEFT JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = p.asset_category_id
     WHERE p.organization_id = @organization_id
     ORDER BY CASE p.scope_kind WHEN N'CATEGORY' THEN 0 WHEN N'SUBCATEGORY' THEN 1 ELSE 2 END, ScopeName;

    SELECT N'CATEGORY' AS ScopeKind, c.asset_category_id AS ScopeId, c.asset_category_name AS ScopeName
      FROM grac_practice.dependency_asset_category_master c WHERE c.is_active = 1
    UNION ALL
    SELECT N'SUBCATEGORY', s.subcategory_id, CONCAT(c.asset_category_name, N' / ', s.subcategory_name)
      FROM grac_practice.dependency_asset_subcategory_master s
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = s.asset_category_id
     WHERE s.is_active = 1
    UNION ALL
    SELECT N'ASSET_TYPE', t.asset_type_id, CONCAT(c.asset_category_name, N' / ', s.subcategory_name, N' / ', t.asset_type_name)
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = s.asset_category_id
     WHERE t.is_active = 1
     ORDER BY ScopeKind, ScopeName;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_campaigns
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 50 c.campaign_id AS CampaignId, c.campaign_type AS CampaignType, c.campaign_name AS CampaignName,
           t.asset_type_name AS AssetTypeName, c.due_date AS DueDate, c.generated_count AS GeneratedCount,
           c.skipped_count AS SkippedCount, c.overdue_marked AS OverdueMarked, c.entered_by AS EnteredBy, c.entered_dt AS EnteredDt,
           (SELECT COUNT(*) FROM grac_practice.asset_attestation a WHERE a.campaign_id = c.campaign_id AND a.status = N'CLOSED') AS ClosedCount
      FROM grac_practice.asset_attestation_campaign c
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = c.asset_type_id
     WHERE c.organization_id = @organization_id
     ORDER BY c.entered_dt DESC, c.campaign_id DESC;
END
GO

-- Occurrences: ALL, MINE (assigned to the caller or a team of the caller) or
-- APPROVALS (confirmed, waiting for the caller as manager).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_list
    @organization_id   BIGINT,
    @scope             NVARCHAR(20)  = N'ALL',
    @status            NVARCHAR(20)  = NULL,
    @campaign_id       BIGINT        = NULL,
    @search            NVARCHAR(200) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @page_number       INT           = 1,
    @page_size         INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @scope = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@scope)), N''), N'ALL'));
    SET @status = NULLIF(LTRIM(RTRIM(@status)), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    ;WITH rows_ AS (
        SELECT t.*,
               CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < @today THEN N'OVERDUE' ELSE t.status END AS display_status,
               CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE')
                     AND (t.assignee_employee_id = @actor_employee_id
                          OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                                      WHERE m.team_id = t.assignee_team_id AND m.employee_id = @actor_employee_id AND m.status = N'Active'))
                    THEN 1 ELSE 0 END AS can_respond,
               CASE WHEN t.status = N'CONFIRMED' AND @actor_employee_id IS NOT NULL
                     AND @actor_employee_id = COALESCE(NULLIF(ae.reporting_officer_id, t.attested_by_employee_id),
                                                       NULLIF(t.snap_owner_id, t.attested_by_employee_id))
                    THEN 1 ELSE 0 END AS can_approve
          FROM grac_practice.asset_attestation t
          LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = t.attested_by_employee_id
         WHERE t.organization_id = @organization_id
           AND (@campaign_id IS NULL OR t.campaign_id = @campaign_id)
    )
    SELECT r.attestation_id AS AttestationId, r.occurrence_key AS OccurrenceKey, r.attestation_type AS AttestationType,
           r.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
           r.campaign_id AS CampaignId, c.campaign_name AS CampaignName, r.profile_version AS ProfileVersion,
           r.evidence_requirement AS EvidenceRequirement, r.manager_approval_required AS ManagerApprovalRequired,
           r.assignee_role AS AssigneeRole, COALESCE(e.employee_name, tm.team_name + N' (team)') AS AssigneeName,
           mg.employee_name AS ManagerName, ow.employee_name AS OwnerName, l.location_name AS LocationName,
           d.department_name AS DepartmentName, r.snap_assignment_start AS AssignmentStart,
           r.generated_dt AS GeneratedDt, r.due_date AS DueDate, r.response_dt AS ResponseDt, r.closed_dt AS ClosedDt,
           r.next_attestation_date AS NextAttestationDate, r.status AS Status, r.display_status AS DisplayStatus,
           r.response AS Response, r.asset_exists AS AssetExists, r.custody_confirmed AS CustodyConfirmed,
           r.location_verified AS LocationVerified, r.tag_verified AS TagVerified, r.serial_verified AS SerialVerified,
           r.assigned_user_verified AS AssignedUserVerified, r.information_correct AS InformationCorrect,
           r.business_use_confirmed AS BusinessUseConfirmed, r.condition_code AS ConditionCode,
           r.disagreement_category AS DisagreementCategory, r.comments AS Comments, r.evidence_text AS EvidenceText,
           r.attested_by AS AttestedBy, at.employee_name AS AttestedByName, r.channel AS Channel,
           r.verification_status AS VerificationStatus, r.decided_by AS DecidedBy, de.employee_name AS DecidedByName,
           r.decided_dt AS DecidedDt, r.decision_note AS DecisionNote,
           r.can_respond AS CanRespond, r.can_approve AS CanApprove, CONVERT(BIGINT, r.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM rows_ r
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = r.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = r.asset_type_id
      LEFT JOIN grac_practice.asset_attestation_campaign c ON c.campaign_id = r.campaign_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.assignee_employee_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = r.assignee_team_id
      LEFT JOIN grac_practice.organization_employee mg ON mg.employee_id = r.snap_manager_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.snap_owner_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = r.snap_location_id
      LEFT JOIN grac_practice.organization_department d ON d.department_id = r.snap_department_id
      LEFT JOIN grac_practice.organization_employee at ON at.employee_id = r.attested_by_employee_id
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = r.decided_by_employee_id
     WHERE (@status IS NULL OR r.display_status = @status)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(r.asset_id AS NVARCHAR(30)) = @search)
       AND (   @scope = N'ALL'
            OR (@scope = N'MINE' AND (r.assignee_employee_id = @actor_employee_id
                                      OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                                                  WHERE m.team_id = r.assignee_team_id AND m.employee_id = @actor_employee_id AND m.status = N'Active')))
            OR (@scope = N'APPROVALS' AND r.can_approve = 1))
     ORDER BY CASE WHEN r.display_status IN (N'OVERDUE', N'PENDING', N'IN_PROGRESS', N'GENERATED', N'CONFIRMED') THEN 0 ELSE 1 END,
              r.due_date, r.attestation_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Asset Register Custody tab: 1. verification state + profile
-- 2. assignment history  3. occurrences of the asset
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_custody_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54351, 'Asset not found for this organization.', 1;

    SELECT @asset_id AS AssetId, ISNULL(st.verification_status, N'NOT_VERIFIED') AS VerificationStatus,
           st.last_attested_date AS LastAttestedDate, st.next_attestation_date AS NextAttestationDate,
           p.ProfileId, p.AttestationRequired, p.Participant, p.Frequency, p.CustomIntervalDays, p.DueWindowDays,
           p.EvidenceRequirement, p.ManagerApprovalRequired, p.VersionNo AS ProfileVersion
      FROM (SELECT 1 AS x) one
      LEFT JOIN grac_practice.asset_attestation_state st ON st.asset_id = @asset_id
      OUTER APPLY grac_practice.fn_asset_attestation_profile_for(@organization_id, @asset_id) p;

    SELECT h.assignment_id AS AssignmentId, ow.employee_name AS OwnerName,
           COALESCE(ce.employee_name, ct.team_name + N' (team)') AS CustodianName,
           d.department_name AS DepartmentName, l.location_name AS LocationName,
           h.building AS Building, h.floor AS Floor, h.room AS Room,
           h.effective_from AS EffectiveFrom, h.effective_to AS EffectiveTo, h.is_current AS IsCurrent,
           h.change_source AS ChangeSource, h.entered_by AS EnteredBy, h.entered_dt AS EnteredDt
      FROM grac_practice.asset_assignment_history h
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = h.asset_owner_id
      LEFT JOIN grac_practice.organization_employee ce ON h.custodian LIKE N'E:%' AND ce.employee_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_team ct ON h.custodian LIKE N'T:%' AND ct.team_id = TRY_CONVERT(BIGINT, SUBSTRING(h.custodian, 3, 38))
      LEFT JOIN grac_practice.organization_department d ON d.department_id = h.department_id
      LEFT JOIN grac_practice.organization_location l ON l.location_id = h.location_id
     WHERE h.asset_id = @asset_id
     ORDER BY h.effective_from DESC, h.assignment_id DESC;

    SELECT t.attestation_id AS AttestationId, t.attestation_type AS AttestationType, t.assignee_role AS AssigneeRole,
           COALESCE(e.employee_name, tm.team_name + N' (team)') AS AssigneeName, t.due_date AS DueDate,
           CASE WHEN t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS') AND t.due_date < CAST(SYSUTCDATETIME() AS DATE)
                THEN N'OVERDUE' ELSE t.status END AS DisplayStatus,
           t.response AS Response, t.condition_code AS ConditionCode, t.disagreement_category AS DisagreementCategory,
           t.comments AS Comments, at.employee_name AS AttestedByName, t.response_dt AS ResponseDt, t.closed_dt AS ClosedDt,
           t.decision_note AS DecisionNote
      FROM grac_practice.asset_attestation t
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = t.assignee_employee_id
      LEFT JOIN grac_practice.organization_team tm ON tm.team_id = t.assignee_team_id
      LEFT JOIN grac_practice.organization_employee at ON at.employee_id = t.attested_by_employee_id
     WHERE t.asset_id = @asset_id
     ORDER BY t.generated_dt DESC, t.attestation_id DESC;
END
GO
PRINT '431: attestation readers created.';
GO

-- =====================================================================
-- 7. Menu: Asset & Contract -> Asset Attestation (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-attestation', N'Asset Attestation', N'Practice/Index/asset-attestation', 357, N'clipboard-check', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-431', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-431');
PRINT CONCAT('431: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-431', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-attestation' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-431', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-attestation'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('431: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '431-a tables and unique indexes present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_assignment_history','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_attestation_profile','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_attestation','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_attestation_campaign','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_attestation_state','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.indexes WHERE name IN ('ux_pm_asset_assignment_current', 'ux_pm_asset_att_profile_scope',
                                                                   'ux_pm_asset_att_key')) = 3
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '431-b every asset has one current assignment row',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                              WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_assignment_history h
                                                 WHERE h.asset_id = a.asset_id AND h.is_current = 1))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '431-c save re-issued with the assignment snapshot',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_assignment_snapshot%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_tech_install_apply%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '431-d procedures and functions present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_attestation_create', 'sp_asset_assignment_snapshot', 'sp_asset_field_value_set',
                                'sp_asset_attestation_close_verified', 'sp_asset_attestation_profile_save', 'sp_asset_attestation_generate',
                                'sp_asset_attestation_respond', 'sp_asset_attestation_decide', 'sp_asset_attestation_profiles',
                                'sp_asset_attestation_campaigns', 'sp_asset_attestation_list', 'sp_asset_custody_get')) = 12
             AND OBJECT_ID('grac_practice.fn_asset_attestation_profile_for') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_attestation_next_date') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '431-e menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-attestation' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs two users with logins in the organization (custodian, manager:
--   the custodian's reporting officer) and an asset form with Custodian.
--   1. Asset Attestation -> Profiles: add a profile for an asset type --
--      Custodian, Quarterly, 7 days, evidence Optional, manager approval on.
--   2. Asset Register: set the custodian of an Active asset of that type
--      and save -> Custody tab shows a new assignment row and one Initial
--      acknowledgement for the custodian. Save again without a change --
--      no new row, no second acknowledgement. Change the site -> a new
--      assignment row, no acknowledgement.
--   3. Sign in as the custodian -> Asset Attestation -> My attestations:
--      Confirm with every check and condition Good -> Confirmed (awaiting
--      approval). As another user, responding is refused.
--   4. Sign in as the manager -> My approvals -> Approve -> Closed; the
--      asset is Verified, Last verified date set, next date in 3 months.
--   5. Generate periodic attestations twice -> the second run creates
--      nothing new (occurrence key). Campaign with a due date -> one
--      occurrence per applicable asset.
--   6. Disagree without a category / comment -> refused; with category
--      Asset Not Found -> Disputed, the asset Disputed, custodian unchanged.
--   7. Cancel an occurrence (reason required) -> Cancelled, history kept.
-- =====================================================================
