-- =====================================================================
-- 438  Recurring asset activities: templates, schedules, occurrences,
--      contract-versus-asset task generation, campaigns
--      (Asset & Contract Management, Phase 6 increment 2)
--
-- REQUEST
-- -------
--   BRD v1.7 7.1 "Explicit Task-Generation Rules for Calibration,
--   Maintenance and Licence Renewal": 7.1.1 due event -> activity type ->
--   active matching contract -> evidence granularity -> contract activity,
--   asset task or both; 7.1.2 calibration (one task per due asset whether
--   or not a calibration contract exists, contract reference linked);
--   7.1.3 licence renewal (no separate task for an asset covered by the
--   licence contract; standalone licence -> individual task; a contract
--   mapped after the task was generated requests reconciliation); 7.1.4
--   contract-versus-asset matrix; 7.1.5 duplicate prevention (no second
--   open task for the same asset, template and due occurrence; occurrence
--   key = asset + template + due date + recurrence sequence; closing a
--   contract renewal does not close asset tasks and the other way round;
--   one parent campaign with one item per asset); 7.1.6 due-date updates
--   (next date from the configured basis); 7.1.7 examples; 5.1.7 fields
--   (frequency, basis, last / next date, calibration / maintenance
--   status); 5.2.16 recurrence and task mapping; 9.1.4 calibration
--   notification rules (reminders from the next calibration date, the
--   contract owner also told). Plan: docs/asset-contract-management.md
--   (Phase 6.2, D60-D68).
--
-- WHAT THIS DOES
-- --------------
--   1. Activity templates (global catalogue, BRD 7.1.4 rows that have
--      register fields): Calibration, Preventive maintenance, Statutory
--      inspection (execution -- always one task per asset) and Equipment
--      licence renewal (renewal -- covered by a licence contract or an
--      individual task). Per organization: active, task lead days, due-soon
--      days, individual tasks or a monthly campaign, campaign owner.
--   2. asset_activity_schedule -- per asset and template, recalculated by
--      the scheduler: applicable (the "... required" field), frequency
--      (the "12 months" field), basis, last date, next due date, status
--      (Valid / Due Soon / Overdue / Covered / Not scheduled + reason /
--      Not applicable) and the matching contract coverage.
--   3. asset_activity_occurrence -- one per asset, template, due date and
--      sequence (occurrence key), with the decision (asset task or covered
--      by contract), the linked contract version, the Task Centre task
--      (source "Asset", task type "Asset Activity"), campaign, completion
--      and the reconciliation flag. One open occurrence per asset and
--      template (unique index).
--   4. asset_activity_campaign -- one per organization, template and due
--      month for templates set to campaigns; each asset keeps its own task.
--   5. sp_asset_activity_run (in the 437 scheduler pass): task results ->
--      occurrences (completed: the last date field is written; cancelled),
--      schedules recalculated, occurrences opened and tasks created when the
--      due date is within the lead days.
--   6. Calculated register fields: next calibration / maintenance /
--      inspection date, calibration / maintenance status
--      (fn_asset_stored_values re-issued).
--   7. Notifications: open occurrences raise the Calibration / Preventive
--      maintenance or inspection / Standalone licence profiles (437 sweep
--      and parties re-issued; the activity owner and the linked contract
--      owner are recipients).
--   8. Task Centre: source "Asset" (check constraint widened as 215 did,
--      source counts re-issued) and task type "Asset Activity".
--   9. Readers / writers for the Asset Activities screen; menu row.
--
-- NOT DONE HERE: task results, certificate, pass / fail, reviewer approval
--   and the failed / restricted-use follow-ups (6.3 -- completing the task
--   is taken as the approved result); reschedule / waive / not applicable
--   with approver (6.3); usage, meter, run-hour and manufacturer bases
--   (no meter history exists -- shown as Not scheduled); manual / bulk
--   campaigns with preview and approval (BRD 8); enterprise licence
--   allocations to users.
--
-- ERROR NUMBERS: 54650-54669
--   54650 organization not found           54651 unknown template
--   54652 lead / due-soon days             54653 grouping
--   54654 campaign owner                   54655 occurrence not found
--   54656 nothing to reconcile             54657 note required
--   54658 occurrence changed by someone else
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   PracticeScreen + Manage.cshtml + appsettings (new screen),
--   asset-activities.cshtml / .js (new), asset-notifications.js (run log
--   column), tasks.cshtml (Asset source), 274 (menu), docs.
-- DEPENDS ON: 192, 196, 215, 256, 428-437.
-- Rollback: 438_asset_activities_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_scheduler_run','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_notification_occurrence','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_centre_source_counts','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_line_view') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_field_value_set','P') IS NULL
BEGIN
    RAISERROR('ABORT (438): run 192, 196, 215, 256 and 428-437 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Task Centre: task type and source "Asset"
-- =====================================================================
MERGE grac_practice.task_type_master AS t
USING (VALUES (N'AssetActivity', N'Asset Activity', N'Recurring asset activity: calibration, maintenance, inspection, licence renewal', 168, N'Medium', 1, 90))
   AS s(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
ON t.type_code = s.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (s.type_code, s.type_name, s.description, s.default_sla_hours, s.default_priority, s.is_system_only, s.display_order, N'seed-438');
PRINT CONCAT('438: task type inserted: ', @@ROWCOUNT);
GO

-- Widen the source vocabulary by one value (215 pattern; additive only).
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_practice_task_source_type'
                  AND definition LIKE '%Asset''%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type')
        ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
    ALTER TABLE grac_practice.practice_task WITH NOCHECK
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'RiskRegister',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom',
                                        N'Asset'));                       -- NEW in 438
    PRINT '438: practice_task source vocabulary widened (Asset).';
END
GO

-- 437 notification occurrences may now point at an activity occurrence.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%ACTIVITY%')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj')
        ALTER TABLE grac_practice.asset_notification_occurrence DROP CONSTRAINT ck_pm_asset_ntf_occ_obj;
    ALTER TABLE grac_practice.asset_notification_occurrence WITH NOCHECK
        ADD CONSTRAINT ck_pm_asset_ntf_occ_obj
            CHECK (object_type IN (N'CONTRACT_VERSION', N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE',
                                   N'TECH_EXCEPTION', N'ATTESTATION', N'ACTIVITY'));
    PRINT '438: notification object types widened (ACTIVITY).';
END
GO

UPDATE grac_practice.asset_notification_activity
   SET source_available = 1, source_note = N'Raised by the activity scheduler (438).'
 WHERE activity_code IN (N'CALIBRATION', N'PREVENTIVE_MAINTENANCE', N'STANDALONE_LICENCE') AND source_available = 0;
PRINT CONCAT('438: notification activities with a source now: ', @@ROWCOUNT);
GO

IF COL_LENGTH('grac_practice.asset_scheduler_run', 'tasks_created') IS NULL
    ALTER TABLE grac_practice.asset_scheduler_run
        ADD tasks_created INT NOT NULL CONSTRAINT df_pm_asset_sched_run_tasks DEFAULT 0;
GO

-- =====================================================================
-- 2. Activity templates (global) and organization settings
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_activity_template','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_template (
        template_code         NVARCHAR(40)  NOT NULL CONSTRAINT pk_pm_asset_act_tpl PRIMARY KEY,
        template_name         NVARCHAR(160) NOT NULL,
        activity_kind         NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_act_tpl_kind CHECK (activity_kind IN (N'EXECUTION', N'RENEWAL')),
        description           NVARCHAR(600) NOT NULL,
        required_field_key    NVARCHAR(100) NOT NULL,   -- YES_NO field that makes the activity applicable
        frequency_field_key   NVARCHAR(100) NULL,       -- QUANTITY_UNIT field ("12 months")
        basis_field_key       NVARCHAR(100) NULL,
        last_date_field_key   NVARCHAR(100) NULL,       -- written when a task completes
        expiry_field_key      NVARCHAR(100) NULL,       -- RENEWAL: the date that falls due
        next_date_field_key   NVARCHAR(100) NULL,       -- calculated field published by fn_asset_stored_values
        status_field_key      NVARCHAR(100) NULL,
        owner_field_key       NVARCHAR(100) NULL,       -- task owner (person), else the asset owner
        coverage_types        NVARCHAR(200) NULL,       -- comma list of contract coverage types that match
        notification_activity_code NVARCHAR(40) NOT NULL
            CONSTRAINT fk_pm_asset_act_tpl_ntf REFERENCES grac_practice.asset_notification_activity(activity_code),
        default_lead_days     INT           NOT NULL,
        default_due_soon_days INT           NOT NULL,
        display_order         INT           NOT NULL,
        entered_by            NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_act_tpl_eby DEFAULT N'system',
        entered_dt            DATETIME2     NOT NULL CONSTRAINT df_pm_asset_act_tpl_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '438: asset_activity_template created.';
END
GO

MERGE grac_practice.asset_activity_template AS t
USING (VALUES
    (N'CALIBRATION', N'Calibration', N'EXECUTION',
     N'One calibration task per due asset, also when a calibration contract exists (the contract is linked to the task) -- BRD 7.1.2.',
     N'calibration_required', N'calibration_frequency', N'calibration_basis', N'last_calibration_date', NULL,
     N'next_calibration_date', N'calibration_status', N'calibration_owner', N'CALIBRATION', N'CALIBRATION', 30, 30, 10),
    (N'PREVENTIVE_MAINTENANCE', N'Preventive maintenance', N'EXECUTION',
     N'One maintenance task per due asset; an AMC / CMC contract covering the asset is linked to the task -- BRD 7.1.4.',
     N'preventive_maintenance_required', N'maintenance_frequency', N'maintenance_basis', N'last_maintenance_date', NULL,
     N'next_maintenance_date', N'maintenance_status', N'maintenance_owner', N'AMC,CMC', N'PREVENTIVE_MAINTENANCE', 15, 30, 20),
    (N'STATUTORY_INSPECTION', N'Statutory inspection', N'EXECUTION',
     N'One inspection task per due asset, always -- BRD 7.1.4 (safety / electrical inspection).',
     N'statutory_inspection_required', N'inspection_frequency', NULL, N'last_inspection_date', NULL,
     N'next_inspection_date', NULL, N'compliance_owner', NULL, N'PREVENTIVE_MAINTENANCE', 30, 30, 30),
    (N'EQUIPMENT_LICENCE', N'Equipment licence renewal', N'RENEWAL',
     N'Renewal of the equipment licence by its expiry date: no task while a licence contract covers the asset through the expiry (contract-level renewal); otherwise an individual task -- BRD 7.1.3.',
     N'licence_required', NULL, NULL, NULL, N'equipment_licence_expiry',
     NULL, NULL, N'technical_owner', N'LICENCE', N'STANDALONE_LICENCE', 30, 30, 40)
) AS s(template_code, template_name, activity_kind, description, required_field_key, frequency_field_key, basis_field_key,
       last_date_field_key, expiry_field_key, next_date_field_key, status_field_key, owner_field_key, coverage_types,
       notification_activity_code, default_lead_days, default_due_soon_days, display_order)
ON t.template_code = s.template_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (template_code, template_name, activity_kind, description, required_field_key, frequency_field_key, basis_field_key,
            last_date_field_key, expiry_field_key, next_date_field_key, status_field_key, owner_field_key, coverage_types,
            notification_activity_code, default_lead_days, default_due_soon_days, display_order, entered_by)
    VALUES (s.template_code, s.template_name, s.activity_kind, s.description, s.required_field_key, s.frequency_field_key, s.basis_field_key,
            s.last_date_field_key, s.expiry_field_key, s.next_date_field_key, s.status_field_key, s.owner_field_key, s.coverage_types,
            s.notification_activity_code, s.default_lead_days, s.default_due_soon_days, s.display_order, N'seed-438');
PRINT CONCAT('438: activity templates inserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_activity_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_setting (
        organization_id            BIGINT        NOT NULL,
        template_code              NVARCHAR(40)  NOT NULL
            CONSTRAINT fk_pm_asset_act_set_tpl REFERENCES grac_practice.asset_activity_template(template_code),
        is_active                  BIT           NOT NULL,
        lead_days                  INT           NOT NULL CONSTRAINT ck_pm_asset_act_set_lead CHECK (lead_days BETWEEN 0 AND 365),
        due_soon_days              INT           NOT NULL CONSTRAINT ck_pm_asset_act_set_soon CHECK (due_soon_days BETWEEN 0 AND 365),
        grouping_mode              NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_act_set_group CHECK (grouping_mode IN (N'INDIVIDUAL', N'CAMPAIGN')),
        campaign_owner_employee_id BIGINT        NULL
            CONSTRAINT fk_pm_asset_act_set_owner REFERENCES grac_practice.organization_employee(employee_id),
        entered_by                 NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_act_set_eby DEFAULT N'system',
        entered_dt                 DATETIME2     NOT NULL CONSTRAINT df_pm_asset_act_set_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100) NULL,
        updated_dt                 DATETIME2     NULL,
        CONSTRAINT pk_pm_asset_act_set PRIMARY KEY (organization_id, template_code)
    );
    PRINT '438: asset_activity_setting created.';
END
GO

-- =====================================================================
-- 3. Schedules, campaigns, occurrences
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_activity_schedule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_schedule (
        organization_id       BIGINT         NOT NULL,
        asset_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_act_sch_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        template_code         NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_asset_act_sch_tpl REFERENCES grac_practice.asset_activity_template(template_code),
        schedule_state        NVARCHAR(16)   NOT NULL
            CONSTRAINT ck_pm_asset_act_sch_state CHECK (schedule_state IN (N'SCHEDULED', N'NOT_SCHEDULED', N'NOT_APPLICABLE')),
        not_scheduled_reason  NVARCHAR(300)  NULL,
        frequency_text        NVARCHAR(100)  NULL,
        interval_value        INT            NULL,
        interval_unit         NVARCHAR(10)   NULL,      -- DAY | MONTH | YEAR
        basis                 NVARCHAR(40)   NULL,
        last_done_date        DATE           NULL,
        next_due_date         DATE           NULL,
        due_source            NVARCHAR(30)   NULL,      -- LAST_DATE_FIELD | COMPLETED_OCCURRENCE | NO_HISTORY | EXPIRY_FIELD
        status_code           NVARCHAR(16)   NOT NULL,  -- VALID | DUE_SOON | OVERDUE | COVERED | NOT_SCHEDULED | NOT_APPLICABLE
        contract_version_id   BIGINT         NULL,
        coverage_end          DATE           NULL,
        refreshed_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_asset_act_sch_rdt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_asset_act_sch PRIMARY KEY (asset_id, template_code)
    );
    CREATE INDEX ix_pm_asset_act_sch_org ON grac_practice.asset_activity_schedule(organization_id, template_code, status_code);
    PRINT '438: asset_activity_schedule created.';
END
GO

IF OBJECT_ID('grac_practice.asset_activity_campaign','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_campaign (
        campaign_id       BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_act_cmp PRIMARY KEY,
        organization_id   BIGINT        NOT NULL,
        template_code     NVARCHAR(40)  NOT NULL
            CONSTRAINT fk_pm_asset_act_cmp_tpl REFERENCES grac_practice.asset_activity_template(template_code),
        period_key        CHAR(6)       NOT NULL,     -- yyyymm of the due dates grouped
        campaign_key      NVARCHAR(120) NOT NULL,
        campaign_name     NVARCHAR(200) NOT NULL,
        owner_employee_id BIGINT        NULL
            CONSTRAINT fk_pm_asset_act_cmp_owner REFERENCES grac_practice.organization_employee(employee_id),
        entered_by        NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_act_cmp_eby DEFAULT N'scheduler',
        entered_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_asset_act_cmp_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_asset_act_cmp_key UNIQUE (organization_id, campaign_key)
    );
    PRINT '438: asset_activity_campaign created.';
END
GO

IF OBJECT_ID('grac_practice.asset_activity_occurrence','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_activity_occurrence (
        occurrence_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_act_occ PRIMARY KEY,
        organization_id        BIGINT         NOT NULL,
        asset_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_act_occ_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        template_code          NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_asset_act_occ_tpl REFERENCES grac_practice.asset_activity_template(template_code),
        due_date               DATE           NOT NULL,
        sequence_no            INT            NOT NULL,
        occurrence_key         NVARCHAR(200)  NOT NULL,
        decision               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_act_occ_dec CHECK (decision IN (N'ASSET_TASK', N'CONTRACT_COVERED')),
        decision_reason        NVARCHAR(400)  NULL,
        contract_version_id    BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_occ_ver REFERENCES grac_practice.asset_contract_version(version_id),
        campaign_id            BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_occ_cmp REFERENCES grac_practice.asset_activity_campaign(campaign_id),
        task_id                BIGINT         NULL
            CONSTRAINT fk_pm_asset_act_occ_task REFERENCES grac_practice.practice_task(task_id),
        task_error             NVARCHAR(1000) NULL,
        status                 NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_act_occ_status CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED', N'COVERED')),
        needs_reconciliation   BIT            NOT NULL CONSTRAINT df_pm_asset_act_occ_rec DEFAULT 0,
        reconciliation_reason  NVARCHAR(400)  NULL,
        reconciled_note        NVARCHAR(1000) NULL,
        reconciled_by          NVARCHAR(100)  NULL,
        reconciled_dt          DATETIME2      NULL,
        completed_dt           DATETIME2      NULL,
        completed_by_employee_id BIGINT       NULL,
        closed_dt              DATETIME2      NULL,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_act_occ_eby DEFAULT N'scheduler',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_act_occ_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        record_version         ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_asset_act_occ_key UNIQUE (organization_id, occurrence_key)
    );
    -- 7.1.5: never a second open occurrence (task) for the same asset and template.
    CREATE UNIQUE INDEX ux_pm_asset_act_occ_open ON grac_practice.asset_activity_occurrence(asset_id, template_code) WHERE status = N'OPEN';
    CREATE INDEX ix_pm_asset_act_occ_org ON grac_practice.asset_activity_occurrence(organization_id, status, due_date);
    CREATE INDEX ix_pm_asset_act_occ_task ON grac_practice.asset_activity_occurrence(task_id) WHERE task_id IS NOT NULL;
    PRINT '438: asset_activity_occurrence created.';
END
GO

-- =====================================================================
-- 4. Helpers
-- =====================================================================
-- "12 months" -> 12 MONTH. Units: day(s), week(s), month(s), quarter(s),
-- half-year(s), year(s) / annual. Anything else -> NULL (not scheduled).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_interval (@frequency_text NVARCHAR(400))
RETURNS TABLE
AS
RETURN
    WITH p AS (SELECT LTRIM(RTRIM(ISNULL(@frequency_text, N''))) AS t),
    q AS (SELECT TRY_CONVERT(DECIMAL(38, 6), LEFT(p.t, CHARINDEX(N' ', p.t + N' ') - 1)) AS n,
                 LOWER(LTRIM(SUBSTRING(p.t, CHARINDEX(N' ', p.t + N' ') + 1, 100))) AS u
            FROM p)
    SELECT CASE WHEN q.n IS NULL OR q.n <= 0 OR q.n <> FLOOR(q.n) OR q.n > 10000 THEN NULL
                WHEN q.u LIKE N'day%' THEN CAST(q.n AS INT)
                WHEN q.u LIKE N'week%' THEN CAST(q.n * 7 AS INT)
                WHEN q.u LIKE N'month%' THEN CAST(q.n AS INT)
                WHEN q.u LIKE N'quarter%' THEN CAST(q.n * 3 AS INT)
                WHEN q.u LIKE N'half%' THEN CAST(q.n * 6 AS INT)
                WHEN q.u LIKE N'year%' OR q.u LIKE N'annual%' THEN CAST(q.n AS INT) END AS IntervalValue,
           CASE WHEN q.n IS NULL OR q.n <= 0 OR q.n <> FLOOR(q.n) OR q.n > 10000 THEN NULL
                WHEN q.u LIKE N'day%' OR q.u LIKE N'week%' THEN N'DAY'
                WHEN q.u LIKE N'month%' OR q.u LIKE N'quarter%' OR q.u LIKE N'half%' THEN N'MONTH'
                WHEN q.u LIKE N'year%' OR q.u LIKE N'annual%' THEN N'YEAR' END AS IntervalUnit
      FROM q;
GO

CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_add (@d DATE, @value INT, @unit NVARCHAR(10))
RETURNS DATE
AS
BEGIN
    RETURN CASE WHEN @d IS NULL OR @value IS NULL THEN NULL
                WHEN @unit = N'DAY' THEN DATEADD(DAY, @value, @d)
                WHEN @unit = N'MONTH' THEN DATEADD(MONTH, @value, @d)
                WHEN @unit = N'YEAR' THEN DATEADD(YEAR, @value, @d) END;
END
GO

-- Effective settings of every template for an organization (defaults when
-- the organization saved none).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_settings (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind,
           CAST(ISNULL(s.is_active, 1) AS BIT) AS IsActive, ISNULL(s.lead_days, t.default_lead_days) AS LeadDays,
           ISNULL(s.due_soon_days, t.default_due_soon_days) AS DueSoonDays, ISNULL(s.grouping_mode, N'INDIVIDUAL') AS GroupingMode,
           s.campaign_owner_employee_id AS CampaignOwnerEmployeeId
      FROM grac_practice.asset_activity_template t
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code;
GO

-- A person-or-team field value resolved to one active employee of the
-- organization (E:<id> or <id>); a team gives nobody.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_person (@organization_id BIGINT, @value NVARCHAR(100))
RETURNS BIGINT
AS
BEGIN
    DECLARE @id BIGINT = CASE WHEN @value LIKE N'T:%' THEN NULL
                              WHEN @value LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(@value, 3, 40))
                              ELSE TRY_CONVERT(BIGINT, @value) END;
    RETURN (SELECT employee_id FROM grac_practice.organization_employee
             WHERE employee_id = @id AND organization_id = @organization_id AND status = N'Active');
END
GO
PRINT '438: helpers created.';
GO

-- =====================================================================
-- 5. Task results -> occurrences (7.1.6)
-- =====================================================================
-- A Closed task completes its occurrence (completing the task is the
-- approved result until 6.3 adds results / certificates -- D63); the last
-- date field of an execution template is set to the completion date when
-- that is later than the recorded one. A Cancelled task cancels the
-- occurrence; the next pass opens a new one for the same due date (D64).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_task_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @completed       INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @completed = 0;
    DECLARE @done TABLE (occurrence_id BIGINT NOT NULL, asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL,
                         status NVARCHAR(12) NOT NULL, completed_dt DATETIME2 NULL);
    BEGIN TRAN;
    UPDATE o
       SET status = CASE WHEN s.status_code = N'Cancelled' THEN N'CANCELLED' ELSE N'COMPLETED' END,
           completed_dt = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE COALESCE(t.completed_dt, t.closed_at, SYSUTCDATETIME()) END,
           completed_by_employee_id = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE t.completed_by_employee_id END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.occurrence_id, inserted.asset_id, inserted.template_code, inserted.status, inserted.completed_dt
      INTO @done (occurrence_id, asset_id, template_code, status, completed_dt)
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.practice_task t ON t.task_id = o.task_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN'
       AND (s.status_code IN (N'Closed', N'Cancelled') OR t.completed_dt IS NOT NULL);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', d.occurrence_id, d.status, N'{"status":"OPEN"}',
           (SELECT d.status AS status, d.completed_dt AS completedDt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor
      FROM @done d;
    COMMIT;
    SET @completed = (SELECT COUNT(*) FROM @done WHERE status = N'COMPLETED');

    -- The last date field follows the completion (never moves back).
    DECLARE @asset BIGINT, @key NVARCHAR(100), @dt DATE, @cur DATE, @val NVARCHAR(400);
    DECLARE last_cur CURSOR LOCAL STATIC FOR
        SELECT d.asset_id, t.last_date_field_key, CAST(d.completed_dt AS DATE)
          FROM @done d
          JOIN grac_practice.asset_activity_template t ON t.template_code = d.template_code
         WHERE d.status = N'COMPLETED' AND t.last_date_field_key IS NOT NULL;
    OPEN last_cur;
    FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cur = (SELECT v.value_date FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @key
                     WHERE v.asset_id = @asset);
        IF @cur IS NULL OR @cur < @dt
        BEGIN
            SET @val = CONVERT(NVARCHAR(10), @dt, 23);
            EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @key, @value = @val, @actor = @actor;
        END
        FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    END
    CLOSE last_cur;
    DEALLOCATE last_cur;
END
GO

-- =====================================================================
-- 6. Schedules (5.1.7, 7.1.6; D60-D62)
-- =====================================================================
-- Recalculated for every asset in use (431 D24) and every template:
--   Not applicable  the "... required" field is not Yes
--   Not scheduled   no / unreadable frequency, a usage / run-hour /
--                   manufacturer basis (no meter history), no expiry date
--   next due        execution: the later of the last completed occurrence
--                   (its due date + interval, or its completion date +
--                   interval for a completion basis) and the last date
--                   field + interval; no history -> today. Renewal: the
--                   expiry date field.
--   Covered         renewal template, a matching contract line covers the
--                   asset through the due date (7.1.3)
--   Overdue / Due soon / Valid against today and the due-soon days.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedule_sync
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #cov (asset_id BIGINT NOT NULL, coverage_type NVARCHAR(160) NOT NULL, version_id BIGINT NOT NULL, eff_end DATE NULL);
    INSERT #cov (asset_id, coverage_type, version_id, eff_end)
    SELECT AssetId, CoverageType, VersionId, EffectiveEnd
      FROM grac_practice.fn_asset_coverage_line_view(@organization_id)
     WHERE LineStatus IN (N'COVERED', N'EXPIRING');

    CREATE TABLE #in (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, activity_kind NVARCHAR(12) NOT NULL,
        due_soon_days INT NOT NULL, coverage_types NVARCHAR(200) NULL,
        required_val NVARCHAR(400) NULL, frequency_text NVARCHAR(400) NULL, basis NVARCHAR(400) NULL,
        field_last DATE NULL, expiry DATE NULL, occ_due DATE NULL, occ_done DATE NULL, open_due DATE NULL,
        PRIMARY KEY (asset_id, template_code));
    INSERT #in (asset_id, template_code, activity_kind, due_soon_days, coverage_types, required_val, frequency_text, basis,
                field_last, expiry, occ_due, occ_done, open_due)
    SELECT a.asset_id, t.template_code, t.activity_kind, st.DueSoonDays, t.coverage_types,
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.required_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.frequency_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.basis_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.last_date_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.expiry_field_key
             WHERE v.asset_id = a.asset_id),
           lo.due_date, CAST(lo.completed_dt AS DATE),
           (SELECT o.due_date FROM grac_practice.asset_activity_occurrence o
             WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'OPEN')
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     CROSS JOIN grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code AND st.IsActive = 1
     OUTER APPLY (SELECT TOP 1 o.due_date, o.completed_dt
                    FROM grac_practice.asset_activity_occurrence o
                   WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'COMPLETED'
                   ORDER BY o.due_date DESC, o.occurrence_id DESC) lo
     WHERE a.organization_id = @organization_id
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    CREATE TABLE #out (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, schedule_state NVARCHAR(16) NOT NULL,
        not_scheduled_reason NVARCHAR(300) NULL, frequency_text NVARCHAR(100) NULL, interval_value INT NULL, interval_unit NVARCHAR(10) NULL,
        basis NVARCHAR(40) NULL, last_done_date DATE NULL, next_due_date DATE NULL, due_source NVARCHAR(30) NULL,
        status_code NVARCHAR(16) NOT NULL, contract_version_id BIGINT NULL, coverage_end DATE NULL);
    INSERT #out (asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit, basis,
                 last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end)
    SELECT i.asset_id, i.template_code, z.state, z.reason, LEFT(i.frequency_text, 100), iv.IntervalValue, iv.IntervalUnit,
           LEFT(i.basis, 40), CASE WHEN z.state = N'SCHEDULED' THEN n.last_done END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.next_due END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.source END,
           CASE WHEN z.state = N'NOT_APPLICABLE' THEN N'NOT_APPLICABLE'
                WHEN z.state = N'NOT_SCHEDULED' THEN N'NOT_SCHEDULED'
                WHEN i.activity_kind = N'RENEWAL' AND cv.version_id IS NOT NULL
                     AND ISNULL(cv.eff_end, CAST('9999-12-31' AS DATE)) >= n.next_due THEN N'COVERED'
                WHEN n.next_due < @today THEN N'OVERDUE'
                WHEN n.next_due <= DATEADD(DAY, i.due_soon_days, @today) THEN N'DUE_SOON'
                ELSE N'VALID' END,
           cv.version_id, cv.eff_end
      FROM #in i
     OUTER APPLY grac_practice.fn_asset_activity_interval(i.frequency_text) iv
     CROSS APPLY (SELECT CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'APPROVED_COMPLETION_DATE', N'COMPLETION_DATE') THEN N'COMPLETION'
                              WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'USAGE', N'RUN_HOURS', N'MANUFACTURER') THEN N'UNSUPPORTED'
                              ELSE N'SCHEDULED' END AS basis_class) b
     CROSS APPLY (SELECT
            CASE WHEN i.activity_kind = N'RENEWAL' THEN i.expiry
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last)
                     THEN grac_practice.fn_asset_activity_add(CASE WHEN b.basis_class = N'COMPLETION' THEN i.occ_done ELSE i.occ_due END,
                                                              iv.IntervalValue, iv.IntervalUnit)
                 WHEN i.field_last IS NOT NULL THEN grac_practice.fn_asset_activity_add(i.field_last, iv.IntervalValue, iv.IntervalUnit)
                 ELSE ISNULL(i.open_due, @today) END AS next_due,      -- no history: due now (D61), kept while it is open
            CASE WHEN i.activity_kind = N'RENEWAL' THEN NULL
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN i.occ_done
                 ELSE i.field_last END AS last_done,
            CASE WHEN i.activity_kind = N'RENEWAL' THEN N'EXPIRY_FIELD'
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN N'COMPLETED_OCCURRENCE'
                 WHEN i.field_last IS NOT NULL THEN N'LAST_DATE_FIELD'
                 ELSE N'NO_HISTORY' END AS source) n
     CROSS APPLY (SELECT
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN N'NOT_APPLICABLE'
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED' THEN N'NOT_SCHEDULED'
                 ELSE N'SCHEDULED' END AS state,
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN NULL
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'No expiry date is recorded on the asset.'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL
                     THEN N'The frequency is missing or not understood (for example "12 months").'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED'
                     THEN CONCAT(N'The ', LOWER(REPLACE(i.basis, N'_', N' ')), N' basis needs meter readings; it is not scheduled yet.') END AS reason) z
     OUTER APPLY (SELECT TOP 1 c.version_id, c.eff_end
                    FROM #cov c
                   WHERE c.asset_id = i.asset_id AND i.coverage_types IS NOT NULL
                     AND CHARINDEX(N',' + c.coverage_type + N',', N',' + i.coverage_types + N',') > 0
                   ORDER BY ISNULL(c.eff_end, CAST('9999-12-31' AS DATE)) DESC, c.version_id DESC) cv;

    BEGIN TRAN;
    DELETE grac_practice.asset_activity_schedule WHERE organization_id = @organization_id;
    INSERT grac_practice.asset_activity_schedule
        (organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
         basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end)
    SELECT @organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
           basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end
      FROM #out;
    COMMIT;
END
GO
PRINT '438: task sync and schedule procedures created.';
GO

-- =====================================================================
-- 7. Occurrences and tasks (7.1.1-7.1.5; D63-D66)
-- =====================================================================
--   a. Reconciliation, never silent deletion (7.1.5): an open occurrence is
--      flagged when a matching contract now covers a renewal, when the due
--      date moved, or when the activity no longer applies.
--   b. A covered renewal whose coverage no longer reaches the due date
--      becomes an asset task (7.1.3).
--   c. New occurrences for scheduled assets whose due date is within the
--      lead days and that have no open / completed / covered occurrence
--      for that due date; one open occurrence per asset and template.
--      Execution templates -> asset task with the matching contract linked
--      (7.1.2); renewal templates -> covered by the contract (no task) or
--      an individual task (7.1.3). Sequence = earlier occurrences of the
--      same due date + 1 (a cancelled task is replaced).
--   d. Tasks for open asset-task occurrences that have none: Task Centre
--      task (type Asset Activity, source Asset, owner from the template
--      owner field, else the asset owner; priority from criticality; due =
--      the due date). Campaign templates group the month in one campaign;
--      each asset keeps its own task (BRD 8 / 7.1.5).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_generate
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @tasks           INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @tasks = 0, @errors = 0, @error_text = NULL;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- a. Reconciliation flags (a reason already reconciled is not raised again).
    UPDATE o
       SET needs_reconciliation = 1, reconciliation_reason = r.reason, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      LEFT JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     CROSS APPLY (SELECT CASE
               WHEN s.schedule_state IS NULL OR s.schedule_state <> N'SCHEDULED'
                   THEN N'The activity no longer applies or is no longer scheduled for this asset.'
               WHEN s.status_code = N'COVERED'
                   THEN N'A contract now covers this renewal; complete or cancel the task after reconciling (BRD 7.1.5).'
               WHEN s.next_due_date <> o.due_date
                   THEN CONCAT(N'The due date is now ', CONVERT(NVARCHAR(10), s.next_due_date, 23), N'.') END AS reason) r
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.needs_reconciliation = 0
       AND r.reason IS NOT NULL AND r.reason <> ISNULL(o.reconciliation_reason, N'');

    -- b. Coverage no longer reaches a covered renewal: it becomes an asset task.
    UPDATE o
       SET status = N'OPEN', decision = N'ASSET_TASK',
           decision_reason = N'The matching contract no longer covers the asset through the due date (BRD 7.1.3).',
           contract_version_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     WHERE o.organization_id = @organization_id AND o.status = N'COVERED' AND s.schedule_state = N'SCHEDULED'
       AND s.next_due_date = o.due_date AND s.status_code <> N'COVERED'
       AND DATEADD(DAY, -(SELECT LeadDays FROM grac_practice.fn_asset_activity_settings(@organization_id) x
                           WHERE x.TemplateCode = o.template_code), o.due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = o.asset_id AND z.template_code = o.template_code AND z.status = N'OPEN');

    -- c. New occurrences.
    DECLARE @new TABLE (occurrence_id BIGINT NOT NULL);
    INSERT grac_practice.asset_activity_occurrence
        (organization_id, asset_id, template_code, due_date, sequence_no, occurrence_key, decision, decision_reason,
         contract_version_id, status, entered_by)
    OUTPUT inserted.occurrence_id INTO @new (occurrence_id)
    SELECT @organization_id, s.asset_id, s.template_code, s.next_due_date, q.seq,
           CONCAT(N'AA-', s.template_code, N'-', s.asset_id, N'-', CONVERT(NVARCHAR(8), s.next_due_date, 112), N'-', q.seq),
           CASE WHEN s.status_code = N'COVERED' THEN N'CONTRACT_COVERED' ELSE N'ASSET_TASK' END,
           CASE WHEN s.status_code = N'COVERED'
                    THEN N'A matching contract covers the asset through the due date: contract-level renewal, no separate task (BRD 7.1.3).'
                WHEN t.activity_kind = N'EXECUTION' AND s.contract_version_id IS NOT NULL
                    THEN N'Asset-specific result: one task per asset; the covering contract is linked (BRD 7.1.2).'
                WHEN t.activity_kind = N'EXECUTION' THEN N'Asset-specific result: one task per asset (BRD 7.1.4).'
                ELSE N'No matching contract covers the asset: individual renewal task (BRD 7.1.3).' END
           + CASE WHEN q.seq > 1 THEN N' The previous task for this due date was cancelled.' ELSE N'' END,
           s.contract_version_id,
           CASE WHEN s.status_code = N'COVERED' THEN N'COVERED' ELSE N'OPEN' END, @actor
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = s.template_code AND st.IsActive = 1
     CROSS APPLY (SELECT 1 + COUNT(*) AS seq FROM grac_practice.asset_activity_occurrence z
                   WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code AND z.due_date = s.next_due_date) q
     WHERE s.organization_id = @organization_id AND s.schedule_state = N'SCHEDULED'
       AND DATEADD(DAY, -st.LeadDays, s.next_due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code
                          AND (z.status = N'OPEN' OR (z.due_date = s.next_due_date AND z.status IN (N'COMPLETED', N'COVERED'))));
    SET @opened = @@ROWCOUNT;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', o.occurrence_id, N'CREATE', NULL,
           (SELECT o.occurrence_key AS occurrenceKey, o.asset_id AS assetId, o.template_code AS templateCode, o.due_date AS dueDate,
                   o.decision AS decision, o.contract_version_id AS contractVersionId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor
      FROM @new n JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = n.occurrence_id;

    -- d. Tasks.
    DECLARE @occ BIGINT, @asset BIGINT, @tpl NVARCHAR(40), @due DATE, @key NVARCHAR(200), @ver BIGINT,
            @tpl_name NVARCHAR(160), @owner_key NVARCHAR(100), @grouping NVARCHAR(12), @cmp_owner BIGINT,
            @asset_name NVARCHAR(400), @asset_owner BIGINT, @crit NVARCHAR(40), @reason NVARCHAR(400),
            @assignee BIGINT, @prio NVARCHAR(30), @title NVARCHAR(250), @descr NVARCHAR(MAX), @ref NVARCHAR(200),
            @cmp BIGINT, @cmp_key NVARCHAR(120), @period CHAR(6), @tid BIGINT, @contract_text NVARCHAR(400), @target DATETIME2;
    DECLARE task_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.asset_id, o.template_code, o.due_date, o.occurrence_key, o.contract_version_id, o.decision_reason,
               t.template_name, t.owner_field_key, st.GroupingMode, st.CampaignOwnerEmployeeId,
               a.asset_name, a.owner_id, c.criticality_code
          FROM grac_practice.asset_activity_occurrence o
          JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
          JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = o.template_code
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
          LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
         WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.decision = N'ASSET_TASK' AND o.task_id IS NULL
         ORDER BY o.due_date, o.occurrence_id;
    OPEN task_cur;
    FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                  @asset_name, @asset_owner, @crit;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @assignee = NULL, @cmp = NULL, @cmp_key = NULL, @tid = NULL, @contract_text = NULL;
            -- Owner: the template owner field (a person), else the asset owner (D65).
            IF @owner_key IS NOT NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id,
                    (SELECT LEFT(v.value_text, 100) FROM grac_practice.asset_field_value v
                       JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @owner_key
                      WHERE v.asset_id = @asset));
            IF @assignee IS NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id, CAST(@asset_owner AS NVARCHAR(30)));
            SET @prio = CASE @crit WHEN N'Critical' THEN N'Critical' WHEN N'High' THEN N'High' WHEN N'Low' THEN N'Low' ELSE N'Medium' END;
            IF @ver IS NOT NULL
                SELECT @contract_text = CONCAT(c.contract_number, N' version ', v.version_no, N' (', c.contract_name, N')')
                  FROM grac_practice.asset_contract_version v
                  JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
                 WHERE v.version_id = @ver;

            IF @grouping = N'CAMPAIGN'
            BEGIN
                SET @period = CONVERT(CHAR(6), @due, 112);
                SET @cmp_key = CONCAT(N'AC-', @tpl, N'-', @period);
                SELECT @cmp = campaign_id FROM grac_practice.asset_activity_campaign
                 WHERE organization_id = @organization_id AND campaign_key = @cmp_key;
                IF @cmp IS NULL
                BEGIN
                    INSERT grac_practice.asset_activity_campaign
                        (organization_id, template_code, period_key, campaign_key, campaign_name, owner_employee_id, entered_by)
                    VALUES (@organization_id, @tpl, @period, @cmp_key,
                            CONCAT(@tpl_name, N' campaign ', LEFT(@period, 4), N'-', RIGHT(@period, 2)), @cmp_owner, @actor);
                    SET @cmp = SCOPE_IDENTITY();
                END
            END

            SET @title = LEFT(CONCAT(@tpl_name, N' - ', @asset_name, N' (due ', CONVERT(NVARCHAR(10), @due, 23), N')'), 250);
            SET @descr = CONCAT(@tpl_name, N' of ', @asset_name, N', due ', CONVERT(NVARCHAR(10), @due, 23), N'.', CHAR(13), CHAR(10),
                                N'Occurrence: ', @key, CHAR(13), CHAR(10),
                                CASE WHEN @cmp_key IS NULL THEN N'' ELSE CONCAT(N'Campaign: ', @cmp_key, CHAR(13), CHAR(10)) END,
                                CASE WHEN @contract_text IS NULL THEN N'' ELSE CONCAT(N'Contract: ', @contract_text, CHAR(13), CHAR(10)) END,
                                @reason);
            SET @ref = ISNULL(@cmp_key, @key);
            SET @target = CAST(@due AS DATETIME2);
            EXEC grac_practice.sp_task_open
                 @organization_id         = @organization_id,
                 @task_type_code          = N'AssetActivity',
                 @subject_entity_type     = N'AssetActivityOccurrence',
                 @subject_entity_id       = @occ,
                 @subject_title           = @title,
                 @subject_description     = @descr,
                 @priority                = @prio,
                 @criticality             = @crit,
                 @origin_code             = N'GRAC',
                 @assigned_to_employee_id = @assignee,
                 @target_date             = @target,
                 @source_type_code        = N'Asset',
                 @source_record_id        = @occ,
                 @source_reference        = @ref,
                 @resolve_owner           = 0,
                 @task_id                 = @tid OUTPUT;
            UPDATE grac_practice.asset_activity_occurrence
               SET task_id = @tid, campaign_id = @cmp, task_error = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
            SET @tasks = @tasks + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Activity occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
            UPDATE grac_practice.asset_activity_occurrence
               SET task_error = LEFT(ERROR_MESSAGE(), 1000), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
        END CATCH
        FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                      @asset_name, @asset_owner, @crit;
    END
    CLOSE task_cur;
    DEALLOCATE task_cur;
END
GO

-- The activity step of the scheduler pass: task results, schedules,
-- occurrences and tasks.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_run
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @tasks           INT           = NULL OUTPUT,
    @opened          INT           = NULL OUTPUT,
    @completed       INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SELECT @tasks = 0, @opened = 0, @completed = 0, @errors = 0, @error_text = NULL;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @completed OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    EXEC grac_practice.sp_asset_activity_generate @organization_id = @organization_id, @actor = @actor,
         @opened = @opened OUTPUT, @tasks = @tasks OUTPUT, @errors = @errors OUTPUT, @error_text = @error_text OUTPUT;
END
GO
PRINT '438: occurrence and task generation created.';
GO

-- =====================================================================
-- 8. Re-issued (438 lines marked; the rest is verbatim)
-- =====================================================================
-- 435 body + calculated next dates / statuses.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stored_values (@asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, c.val AS Value
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY (VALUES
        (N'asset_id',             CAST(a.asset_id AS NVARCHAR(MAX))),
        (N'asset_name',           CAST(a.asset_name AS NVARCHAR(MAX))),
        (N'asset_category_id',    CAST(a.asset_category_id AS NVARCHAR(MAX))),
        (N'asset_subcategory_id', CAST(a.asset_subcategory_id AS NVARCHAR(MAX))),
        (N'asset_type_id',        CAST(a.asset_type_id AS NVARCHAR(MAX))),
        (N'organization_id',      CAST(a.organization_id AS NVARCHAR(MAX))),
        (N'location_id',          CAST(a.location_id AS NVARCHAR(MAX))),
        (N'owner_id',             CAST(a.owner_id AS NVARCHAR(MAX))),
        (N'purchase_dt',          CONVERT(NVARCHAR(MAX), a.purchase_dt, 23)),
        (N'warranty_expiry_dt',   CONVERT(NVARCHAR(MAX), a.warranty_expiry_dt, 23)),
        (N'amc_expiry_dt',        CONVERT(NVARCHAR(MAX), a.amc_expiry_dt, 23)),
        (N'criticality_id',       CAST(a.criticality_id AS NVARCHAR(MAX))),
        (N'remarks',              CAST(a.remarks AS NVARCHAR(MAX))),
        (N'entered_by',           CAST(a.entered_by AS NVARCHAR(MAX))),
        (N'entered_dt',           CONVERT(NVARCHAR(MAX), a.entered_dt, 126)),
        (N'updated_by',           CAST(a.updated_by AS NVARCHAR(MAX))),
        (N'updated_dt',           CONVERT(NVARCHAR(MAX), a.updated_dt, 126))
     ) AS c(column_name, val)
      JOIN grac_practice.asset_field_definition d ON d.storage_kind = N'COLUMN' AND d.column_name = c.column_name
     WHERE a.asset_id = @asset_id AND c.val IS NOT NULL
    UNION ALL
    SELECT v.field_definition_id, d.field_key, v.value_text
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
     WHERE v.asset_id = @asset_id
    UNION ALL
    SELECT d.field_definition_id, d.field_key, s.status_code
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'asset_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 435: the calculated coverage status (5.1.11).
    SELECT d.field_definition_id, d.field_key, cs.CoverageStatusLabel
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY grac_practice.fn_asset_coverage_summary(a.organization_id, a.asset_id) cs
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'coverage_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 438: next calibration / maintenance / inspection date and calibration /
    -- maintenance status from the activity schedule (5.1.7), unless a value
    -- is stored for the field.
    SELECT d.field_definition_id, d.field_key, x.val
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
     CROSS APPLY (VALUES
        (t.next_date_field_key, CONVERT(NVARCHAR(MAX), s.next_due_date, 23)),
        (t.status_field_key,
         CASE WHEN t.status_field_key = N'maintenance_status'
                   AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o
                                WHERE o.asset_id = s.asset_id AND o.template_code = s.template_code
                                  AND o.status = N'OPEN' AND o.task_id IS NOT NULL) THEN N'In Progress'
              WHEN t.status_field_key = N'maintenance_status' THEN
                   CASE s.status_code WHEN N'VALID' THEN N'Not Due' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue' END
              ELSE CASE s.status_code WHEN N'VALID' THEN N'Valid' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'NOT_APPLICABLE' THEN N'N/A' END END)
     ) AS x(field_key, val)
      JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key
     WHERE s.asset_id = @asset_id AND x.val IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                        WHERE v.asset_id = @asset_id AND v.field_definition_id = d.field_definition_id);
GO
PRINT '438: fn_asset_stored_values re-issued.';
GO

-- 437 body + the ACTIVITY branch.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_parties
    @occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT;
    SELECT @org = organization_id, @otype = object_type, @oid = object_id, @asset = asset_id
      FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id;
    IF @org IS NULL RETURN;

    DECLARE @raw TABLE (party_code NVARCHAR(30) NOT NULL, val NVARCHAR(100) NOT NULL);

    IF @asset IS NOT NULL
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ASSET_OWNER', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset AND a.owner_id IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT CASE v.FieldKey WHEN N'business_owner' THEN N'BUSINESS_OWNER' WHEN N'technical_owner' THEN N'TECHNICAL_OWNER'
                               WHEN N'custodian' THEN N'CUSTODIAN' WHEN N'maintenance_owner' THEN N'MAINTENANCE_OWNER'
                               WHEN N'compliance_owner' THEN N'COMPLIANCE_OWNER' WHEN N'privacy_owner' THEN N'PRIVACY_OWNER'
                               ELSE N'SECURITY_OWNER' END,
               LEFT(LTRIM(RTRIM(v.Value)), 100)
          FROM grac_practice.fn_asset_stored_values(@asset) v
         WHERE v.FieldKey IN (N'business_owner', N'technical_owner', N'custodian', N'maintenance_owner', N'compliance_owner',
                              N'privacy_owner', N'information_security_owner')
           AND NULLIF(LTRIM(RTRIM(v.Value)), N'') IS NOT NULL;
    END

    IF @otype = N'CONTRACT_VERSION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_contract_version cv
         CROSS APPLY (VALUES (N'CONTRACT_OWNER', cv.contract_owner_id), (N'PROCUREMENT_OWNER', cv.procurement_owner_id),
                             (N'ACTIVITY_OWNER', COALESCE(cv.contract_owner_id, cv.procurement_owner_id))) x(code, emp)
         WHERE cv.version_id = @oid AND x.emp IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT DISTINCT N'AFFECTED_ASSET_OWNERS', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_contract_coverage cc
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = cc.asset_id
         WHERE cc.version_id = @oid AND cc.coverage_state <> N'EXCLUDED' AND a.owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'TECH_EXCEPTION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_technology_exception t
         CROSS APPLY (VALUES (N'ACTIVITY_OWNER', t.owner_employee_id), (N'EXCEPTION_APPROVER', t.decided_by_employee_id)) x(code, emp)
         WHERE t.exception_id = @oid AND x.emp IS NOT NULL;
    END
    ELSE IF @otype = N'ATTESTATION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ACTIVITY_OWNER', CASE WHEN t.assignee_employee_id IS NOT NULL THEN CAST(t.assignee_employee_id AS NVARCHAR(30))
                                       ELSE N'T:' + CAST(t.assignee_team_id AS NVARCHAR(30)) END
          FROM grac_practice.asset_attestation t
         WHERE t.attestation_id = @oid AND (t.assignee_employee_id IS NOT NULL OR t.assignee_team_id IS NOT NULL);
    END
    ELSE IF @otype = N'ACTIVITY'                                                       -- 438
    BEGIN
        -- Activity owner: the task owner, else the template owner field, else
        -- the asset owner; the owner of the linked contract version too (9.1.4).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, CAST(t.assigned_to_employee_id AS NVARCHAR(100)) AS val
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.practice_task t ON t.task_id = ao.task_id
                 WHERE ao.occurrence_id = @oid AND t.assigned_to_employee_id IS NOT NULL
                UNION ALL
                SELECT 1, LEFT(v.value_text, 100)
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
                  JOIN grac_practice.asset_field_value v ON v.asset_id = ao.asset_id
                  JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                             AND f.field_key = tp.owner_field_key
                 WHERE ao.occurrence_id = @oid
                UNION ALL
                SELECT 2, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
        INSERT @raw (party_code, val)
        SELECT N'CONTRACT_OWNER', CAST(cv.contract_owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_activity_occurrence ao
          JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
         WHERE ao.occurrence_id = @oid AND cv.contract_owner_id IS NOT NULL;
    END
    ELSE IF @otype IN (N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE')
    BEGIN
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', val
          FROM @raw WHERE party_code IN (N'TECHNICAL_OWNER', N'ASSET_OWNER')
         ORDER BY CASE party_code WHEN N'TECHNICAL_OWNER' THEN 0 ELSE 1 END;
    END

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT r.party_code, e.employee_id
      FROM @raw r
     CROSS APPLY (SELECT CASE WHEN r.val LIKE N'T:%' THEN NULL
                              WHEN r.val LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40))
                              ELSE TRY_CONVERT(BIGINT, r.val) END AS emp,
                         CASE WHEN r.val LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40)) END AS team) x
      JOIN grac_practice.organization_employee e
        ON e.organization_id = @org AND e.status = N'Active'
       AND (e.employee_id = x.emp
            OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                        WHERE m.team_id = x.team AND m.employee_id = e.employee_id AND m.status = N'Active'));

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'MANAGER', m.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_employee m ON m.employee_id = e.reporting_officer_id AND m.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'DEPARTMENT_HEAD', h.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_department d ON d.department_id = e.department_id
      JOIN grac_practice.organization_employee h ON h.employee_id = d.head_employee_id AND h.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';
END
GO
PRINT '438: sp_asset_notification_parties re-issued.';
GO

-- 437 body + the activity source.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_sweep
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @closed          INT           = NULL OUTPUT,
    @queued          INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @closed = 0, @queued = 0, @errors = 0, @error_text = NULL;
    DECLARE @org BIGINT = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #due (
        occurrence_key NVARCHAR(200) NOT NULL PRIMARY KEY,
        activity_code  NVARCHAR(40)  NOT NULL,
        object_type    NVARCHAR(30)  NOT NULL,
        object_id      BIGINT        NOT NULL,
        ref_id         BIGINT        NULL,
        asset_id       BIGINT        NULL,
        contract_id    BIGINT        NULL,
        trigger_date   DATE          NOT NULL,
        object_ref     NVARCHAR(200) NULL,
        object_title   NVARCHAR(400) NULL,
        severity_code  NVARCHAR(10)  NOT NULL
    );

    -- Contract renewal (9.1.5): earliest of notice, decision and end date of
    -- the version in force; stops once a renewal of that version completes.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), t.d, 112)), x.act, N'CONTRACT_VERSION', cv.version_id,
           NULL, NULL, c.contract_id, t.d, c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N')'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_contract_activity(c.contract_type) AS act) x
     WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
       AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
                        WHERE r.prior_version_id = cv.version_id AND s.status_code = N'COMPLETED');

    -- Contract expiry (9.1.5): the version in force expired without a successor.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CONTRACT_EXPIRY:CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), DATEADD(DAY, 1, cv.effective_end), 112)),
           N'CONTRACT_EXPIRY', N'CONTRACT_VERSION', cv.version_id, NULL, NULL, c.contract_id, DATEADD(DAY, 1, cv.effective_end),
           c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N') expired'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = cv.current_status_id
     WHERE c.organization_id = @org AND s.status_code = N'EXPIRED' AND cv.effective_end IS NOT NULL;

    -- Assets that are in use for the technology sources (as 431 D24: not in
    -- acquisition, not lost / stolen, not disposed / archived).
    DECLARE @in_use TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, asset_name NVARCHAR(400) NULL, severity_code NVARCHAR(10) NOT NULL);
    INSERT @in_use (asset_id, asset_name, severity_code)
    SELECT a.asset_id, a.asset_name, grac_practice.fn_asset_ntf_asset_severity(a.asset_id)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @org
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    -- Model support end (9.1.3 "Model or OS support end"; D50).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT DISTINCT CONCAT(N'TECH_SUPPORT_END:MODEL:', u.asset_id, N':', m.model_id, N':', CONVERT(NVARCHAR(8), x.d, 112)),
           N'TECH_SUPPORT_END', N'ASSET_MODEL', u.asset_id, m.model_id, u.asset_id, NULL, x.d,
           u.asset_name, CONCAT(N'Model ', m.model_name, N' support ends'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id AND fd.field_key = N'model'
      JOIN grac_practice.asset_model m ON m.model_id = v.value_ref
     CROSS APPLY (SELECT COALESCE(m.end_extended_support_date, m.end_security_support_date, m.end_standard_support_date) AS d) x
     WHERE x.d IS NOT NULL;

    -- Installed OS / firmware release support end (the 430 technology status).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':', t.Kind, N':', u.asset_id, N':', t.CurrentReleaseId, N':', CONVERT(NVARCHAR(8), t.SupportEndDate, 112)),
           x.act, CASE t.Kind WHEN N'OS' THEN N'ASSET_OS' ELSE N'ASSET_FIRMWARE' END, u.asset_id, t.CurrentReleaseId, u.asset_id, NULL,
           t.SupportEndDate, u.asset_name, CONCAT(t.CurrentLabel, N' support ends'), u.severity_code
      FROM grac_practice.fn_asset_technology_status(@org, NULL) t
      JOIN @in_use u ON u.asset_id = t.AssetId
     CROSS APPLY (SELECT CASE t.Kind WHEN N'OS' THEN N'TECH_SUPPORT_END' ELSE N'FIRMWARE_SUPPORT_END' END AS act) x
     WHERE t.CurrentReleaseId IS NOT NULL AND t.SupportEndDate IS NOT NULL;

    -- Technology exception expiry (430).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EXCEPTION_EXPIRY:EXC:', x.exception_id, N':', CONVERT(NVARCHAR(8), x.expiry_date, 112)),
           N'EXCEPTION_EXPIRY', N'TECH_EXCEPTION', x.exception_id, NULL, x.asset_id, NULL, x.expiry_date,
           CONCAT(N'Exception #', x.exception_id),
           CONCAT(CASE x.technology_kind WHEN N'OS' THEN N'OS' ELSE N'Firmware' END, N' exception for ',
                  COALESCE(a.asset_name, N'model ' + m.model_name, N'-')),
           CASE WHEN x.asset_id IS NULL THEN N'MEDIUM' ELSE grac_practice.fn_asset_ntf_asset_severity(x.asset_id) END
      FROM grac_practice.asset_technology_exception x
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.asset_model m ON m.model_id = x.model_id
     WHERE x.organization_id = @org AND x.status = N'APPROVED';

    -- Custodian attestation (431): open attestations by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CUSTODIAN_ATTESTATION:ATT:', t.attestation_id, N':', CONVERT(NVARCHAR(8), t.due_date, 112)),
           N'CUSTODIAN_ATTESTATION', N'ATTESTATION', t.attestation_id, NULL, t.asset_id, NULL, t.due_date,
           a.asset_name, CONCAT(N'Attestation of ', a.asset_name, N' (', LOWER(t.assignee_role), N')'),
           grac_practice.fn_asset_ntf_asset_severity(t.asset_id)
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
     WHERE t.organization_id = @org AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE', N'ESCALATED');

    -- 438: recurring asset activities -- open asset-task occurrences by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(tp.notification_activity_code, N':ACT:', ao.occurrence_id, N':', CONVERT(NVARCHAR(8), ao.due_date, 112)),
           tp.notification_activity_code, N'ACTIVITY', ao.occurrence_id, NULL, ao.asset_id, cv.contract_id, ao.due_date,
           a.asset_name, CONCAT(tp.template_name, N' of ', a.asset_name),
           grac_practice.fn_asset_ntf_asset_severity(ao.asset_id)
      FROM grac_practice.asset_activity_occurrence ao
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = ao.asset_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
     WHERE ao.organization_id = @org AND ao.status = N'OPEN' AND ao.decision = N'ASSET_TASK';

    -- 2. Close / reopen.
    UPDATE o
       SET status = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                AND d.object_id = o.object_id)
                         THEN N'SUPERSEDED' ELSE N'COMPLETED' END,
           close_reason = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                      AND d.object_id = o.object_id)
                               THEN N'The trigger date or reference changed; a new occurrence replaces it.'
                               ELSE N'No longer due (completed, renewed, changed or withdrawn).' END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
     WHERE o.organization_id = @org AND o.status = N'OPEN'
       AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.occurrence_key = o.occurrence_key);
    SET @closed = @@ROWCOUNT;

    UPDATE o
       SET status = N'OPEN', closed_dt = NULL, close_reason = NULL, object_ref = d.object_ref, object_title = d.object_title,
           severity_code = d.severity_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
      JOIN #due d ON d.occurrence_key = o.occurrence_key
     WHERE o.organization_id = @org
       AND (o.status <> N'OPEN' OR ISNULL(o.object_title, N'') <> ISNULL(d.object_title, N'') OR o.severity_code <> d.severity_code
            OR ISNULL(o.object_ref, N'') <> ISNULL(d.object_ref, N''));

    -- 3. Open.
    INSERT grac_practice.asset_notification_occurrence
        (organization_id, occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
         object_ref, object_title, severity_code, status, entered_by)
    SELECT @org, d.occurrence_key, d.activity_code, d.object_type, d.object_id, d.ref_id, d.asset_id, d.contract_id, d.trigger_date,
           d.object_ref, d.object_title, d.severity_code, N'OPEN', @actor
      FROM #due d
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence o
                        WHERE o.organization_id = @org AND o.occurrence_key = d.occurrence_key);
    SET @opened = @@ROWCOUNT;

    -- 4. Fire.
    CREATE TABLE #np (party_code NVARCHAR(30) NOT NULL, employee_id BIGINT NOT NULL);
    CREATE TABLE #rcp (employee_id BIGINT NULL, role_id BIGINT NULL, role_name NVARCHAR(200) NULL, reason_code NVARCHAR(30) NOT NULL);
    CREATE TABLE #holders (
        EmployeeId BIGINT, EmployeeCode NVARCHAR(100), EmployeeName NVARCHAR(240),
        Email NVARCHAR(250), Designation NVARCHAR(200), Department NVARCHAR(200),
        RoleId BIGINT, RoleName NVARCHAR(200)
    );

    DECLARE @occ BIGINT, @act NVARCHAR(40), @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @contract BIGINT, @trigger DATE,
            @ref NVARCHAR(200), @title NVARCHAR(400), @sev NVARCHAR(10), @last_date DATE,
            @p BIGINT, @pver INT, @ack NVARCHAR(10), @wdays BIT, @channels NVARCHAR(60),
            @stage BIGINT, @sdate DATE, @kind NVARCHAR(12), @offset INT, @level TINYINT, @class NVARCHAR(20),
            @act_name NVARCHAR(160), @basis NVARCHAR(30), @subject NVARCHAR(400), @body NVARCHAR(MAX), @n INT,
            @role BIGINT, @role_name NVARCHAR(200);

    DECLARE occ_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.activity_code, o.object_type, o.object_id, o.asset_id, o.contract_id, o.trigger_date,
               o.object_ref, o.object_title, o.severity_code, o.last_stage_date
          FROM grac_practice.asset_notification_occurrence o
         WHERE o.organization_id = @org AND o.status = N'OPEN'
           AND (o.snoozed_until IS NULL OR o.snoozed_until <= @today)
         ORDER BY o.trigger_date, o.occurrence_id;
    OPEN occ_cur;
    FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @p = NULL, @pver = NULL, @ack = NULL, @wdays = NULL, @channels = NULL,
                   @stage = NULL, @sdate = NULL, @kind = NULL, @offset = NULL, @level = NULL, @class = NULL;
            SELECT @p = ProfileId, @pver = VersionNo, @ack = AckMode, @wdays = WorkingDaysOnly, @channels = Channels
              FROM grac_practice.fn_asset_ntf_profile_for(@org, @act, @sev, @today);

            IF @p IS NOT NULL
                SELECT TOP 1 @stage = s.stage_id, @sdate = x.d, @kind = s.stage_kind, @offset = s.offset_days,
                       @level = s.escalation_level, @class = s.notification_class
                  FROM grac_practice.asset_notification_stage s
                 CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(@trigger, s.stage_kind, s.offset_days, @wdays) AS d) x
                 WHERE s.profile_id = @p AND s.is_active = 1 AND x.d <= @today
                 ORDER BY x.d DESC, s.escalation_level DESC, s.stage_id DESC;

            IF @stage IS NOT NULL AND @sdate > ISNULL(@last_date, CONVERT(DATE, '19000101', 112))
            BEGIN
                -- 9.1.2: an escalation on a critical object is a Critical notification (D53).
                IF @sev = N'CRITICAL' AND @kind = N'ESCALATION' SET @class = N'CRITICAL';

                DELETE FROM #np;
                DELETE FROM #rcp;
                EXEC grac_practice.sp_asset_notification_parties @occurrence_id = @occ;

                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, sr.recipient_code
                  FROM grac_practice.asset_notification_stage_recipient sr
                  JOIN #np np ON np.party_code = sr.recipient_code
                 WHERE sr.stage_id = @stage AND sr.recipient_code <> N'ROLE';
                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, m.recipient_code
                  FROM grac_practice.asset_escalation_matrix m
                  JOIN #np np ON np.party_code = m.recipient_code
                 WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                   AND m.recipient_code <> N'ROLE';

                DECLARE role_cur CURSOR LOCAL STATIC FOR
                    SELECT DISTINCT r.role_id, r.role_name
                      FROM (SELECT sr.role_id FROM grac_practice.asset_notification_stage_recipient sr
                             WHERE sr.stage_id = @stage AND sr.recipient_code = N'ROLE'
                            UNION
                            SELECT m.role_id FROM grac_practice.asset_escalation_matrix m
                             WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                               AND m.recipient_code = N'ROLE') x
                      JOIN grac_practice.organization_role r ON r.role_id = x.role_id;
                OPEN role_cur;
                FETCH NEXT FROM role_cur INTO @role, @role_name;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DELETE FROM #holders;
                    INSERT INTO #holders
                        EXEC grac_practice.sp_org_role_holders_list @organization_id = @org, @role_id = @role;
                    IF EXISTS (SELECT 1 FROM #holders)
                    BEGIN
                        INSERT #rcp (employee_id, role_id, role_name, reason_code)
                        SELECT EmployeeId, RoleId, RoleName, N'ROLE' FROM #holders;
                    END
                    ELSE
                    BEGIN
                        -- An empty role still records the obligation (213 precedent).
                        INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, @role, @role_name, N'ROLE');
                    END
                    FETCH NEXT FROM role_cur INTO @role, @role_name;
                END
                CLOSE role_cur;
                DEALLOCATE role_cur;

                IF NOT EXISTS (SELECT 1 FROM #rcp)
                    INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, NULL, NULL, N'UNRESOLVED');

                SELECT @act_name = activity_name, @basis = trigger_basis
                  FROM grac_practice.asset_notification_activity WHERE activity_code = @act;
                SET @subject = LEFT(CONCAT(N'[GRAC] ',
                    CASE @class WHEN N'INFORMATIONAL' THEN N'Information' WHEN N'REMINDER' THEN N'Reminder'
                                WHEN N'ESCALATION' THEN N'Escalation' ELSE N'Critical' END,
                    N': ', @act_name, N' - ', ISNULL(@ref, N'-'),
                    CASE @kind WHEN N'REMINDER' THEN CONCAT(N' due in ', @offset, N' day(s)')
                               WHEN N'DUE' THEN N' due today'
                               ELSE CASE WHEN @offset = 0 THEN N' reached its date' ELSE CONCAT(N' ', @offset, N' day(s) overdue') END END), 400);
                SET @body = CONCAT(
                    @act_name, CHAR(13), CHAR(10), CHAR(13), CHAR(10),
                    N'Reference: ', ISNULL(@ref, N'-'), CHAR(13), CHAR(10),
                    N'Subject:   ', ISNULL(@title, N'-'), CHAR(13), CHAR(10),
                    N'Date:      ', CONVERT(NVARCHAR(10), @trigger, 23), N' (', LOWER(REPLACE(@basis, N'_', N' ')), N')', CHAR(13), CHAR(10),
                    N'Stage:     ', CASE @kind WHEN N'REMINDER' THEN CONCAT(@offset, N' day(s) before')
                                               WHEN N'DUE' THEN N'due date'
                                               ELSE CONCAT(N'escalation level ', @level, N', ', @offset, N' day(s) after') END, CHAR(13), CHAR(10),
                    N'Severity:  ', @sev, CHAR(13), CHAR(10),
                    CASE @ack WHEN N'ACTION' THEN N'Acknowledge with the action taken.'
                              WHEN N'MANAGER' THEN N'Acknowledge with the action taken; your manager confirms the acknowledgement.'
                              WHEN N'READ' THEN N'Mark as read once seen.' ELSE N'' END);

                BEGIN TRAN;
                INSERT grac_practice.asset_notification_outbox
                    (organization_id, occurrence_id, profile_id, profile_version, stage_id, stage_kind, stage_offset_days, stage_date,
                     escalation_level, notification_class, activity_code, object_type, object_id, asset_id, contract_id, object_ref,
                     object_title, trigger_date, severity_code, recipient_employee_id, recipient_name, recipient_email,
                     recipient_manager_id, role_id, role_name, recipient_reason_code, channels, ack_mode, subject, body_text,
                     status_code, failure_reason, entered_by)
                SELECT @org, @occ, @p, @pver, @stage, @kind, @offset, @sdate, @level, @class, @act, @otype, @oid, @asset, @contract, @ref,
                       @title, @trigger, @sev, r.employee_id, e.employee_name, e.email, e.reporting_officer_id, r.role_id, r.role_name,
                       r.reason_code, @channels, @ack, @subject, @body,
                       CASE WHEN r.employee_id IS NULL THEN N'Suppressed' ELSE N'Pending' END,
                       CASE WHEN r.employee_id IS NULL AND r.reason_code = N'ROLE' THEN N'The role has no active holder.'
                            WHEN r.employee_id IS NULL THEN N'No recipient could be resolved for this stage.' END,
                       @actor
                  FROM (SELECT employee_id, role_id, role_name, reason_code,
                               ROW_NUMBER() OVER (PARTITION BY ISNULL(employee_id, -1)
                                                  ORDER BY CASE WHEN role_id IS NULL THEN 0 ELSE 1 END, reason_code) AS rn
                          FROM #rcp) r
                  LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                 WHERE r.rn = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_outbox x
                                    WHERE x.occurrence_id = @occ AND x.stage_id = @stage
                                      AND ((x.recipient_employee_id IS NULL AND r.employee_id IS NULL)
                                           OR x.recipient_employee_id = r.employee_id));
                SET @n = @@ROWCOUNT;
                UPDATE grac_practice.asset_notification_occurrence
                   SET last_stage_id = @stage, last_stage_date = @sdate,
                       escalation_level = CASE WHEN @level > escalation_level THEN @level ELSE escalation_level END,
                       last_notified_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_id = @occ;
                COMMIT;
                SET @queued = @queued + @n;
            END
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            IF CURSOR_STATUS('local', 'role_cur') >= -1
            BEGIN
                IF CURSOR_STATUS('local', 'role_cur') >= 0 CLOSE role_cur;
                DEALLOCATE role_cur;
            END
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
        END CATCH
        FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    END
    CLOSE occ_cur;
    DEALLOCATE occ_cur;
END
GO
PRINT '438: sp_asset_notification_sweep re-issued.';
GO

-- 437 body + the activity step and the tasks counter.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_scheduler_run
    @organization_id BIGINT        = NULL,
    @trigger_code    NVARCHAR(12)  = N'SCHEDULED',
    @actor           NVARCHAR(100) = N'scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @trigger_code = CASE WHEN UPPER(ISNULL(@trigger_code, N'')) = N'MANUAL' THEN N'MANUAL' ELSE N'SCHEDULED' END;
    IF @organization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.asset_scheduler', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS RunId, N'SKIPPED' AS Result, 0 AS Organizations, 0 AS RenewalsStarted,
               0 AS AttestationsGenerated, 0 AS OccurrencesOpened, 0 AS OccurrencesClosed, 0 AS NotificationsQueued,
               0 AS ErrorCount, N'Another scheduler run is in progress.' AS ErrorText, 0 AS TasksCreated;
        RETURN;
    END

    DECLARE @run BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    BEGIN TRY
    INSERT grac_practice.asset_scheduler_run (organization_id, trigger_code, entered_by) VALUES (@organization_id, @trigger_code, @actor);
    SET @run = SCOPE_IDENTITY();

    DECLARE @orgs INT = 0, @ren INT = 0, @att INT = 0, @opened INT = 0, @closed INT = 0, @queued INT = 0, @errors INT = 0,
            @err NVARCHAR(MAX) = NULL,
            @o INT, @c INT, @q INT, @e INT, @et NVARCHAR(MAX), @gen INT, @rid BIGINT,
            @tasks INT = 0, @t INT, @ao INT, @ac INT;                                      -- 438

    DECLARE @org_list TABLE (organization_id BIGINT NOT NULL PRIMARY KEY);
    INSERT @org_list (organization_id)
    SELECT o.organization_id
      FROM grac_practice.organization o
     WHERE (@organization_id IS NOT NULL AND o.organization_id = @organization_id)
        OR (@organization_id IS NULL
            AND (EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a WHERE a.organization_id = o.organization_id)
                 OR EXISTS (SELECT 1 FROM grac_practice.asset_contract c WHERE c.organization_id = o.organization_id)));

    DECLARE @org BIGINT, @contract BIGINT;
    DECLARE org_cur CURSOR LOCAL STATIC FOR SELECT organization_id FROM @org_list ORDER BY organization_id;
    OPEN org_cur;
    FETCH NEXT FROM org_cur INTO @org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @orgs = @orgs + 1;

        BEGIN TRY
            EXEC grac_practice.sp_asset_notification_defaults_ensure @organization_id = @org, @actor = @actor;
            EXEC grac_practice.sp_asset_contract_sync @organization_id = @org, @actor = @actor;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (defaults / contract dates): ', ERROR_MESSAGE()), 8000);
        END CATCH

        IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation_profile WHERE organization_id = @org AND is_active = 1)
        BEGIN
        BEGIN TRY
            SET @gen = 0;
            EXEC grac_practice.sp_asset_attestation_generate @organization_id = @org, @campaign_type = N'PERIODIC', @actor = @actor,
                 @scheduled = 1, @suppress_result = 1, @out_generated = @gen OUTPUT;
            SET @att = @att + ISNULL(@gen, 0);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (periodic attestation): ', ERROR_MESSAGE()), 8000);
        END CATCH
        END

        -- d. Renewal occurrences whose reminder window has opened.
        DECLARE ren_cur CURSOR LOCAL STATIC FOR
            SELECT c.contract_id
              FROM grac_practice.asset_contract c
              JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
             CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
             OUTER APPLY (SELECT ProfileId FROM grac_practice.fn_asset_ntf_profile_for(
                              c.organization_id, grac_practice.fn_asset_ntf_contract_activity(c.contract_type),
                              grac_practice.fn_asset_ntf_version_severity(cv.version_id), @today)) p
             OUTER APPLY (SELECT MAX(s.offset_days) AS lead_days FROM grac_practice.asset_notification_stage s
                           WHERE s.profile_id = p.ProfileId AND s.is_active = 1 AND s.stage_kind = N'REMINDER') w
             WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
               AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
               AND DATEADD(DAY, -ISNULL(w.lead_days, 0), t.d) <= @today
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                                WHERE r.contract_id = c.contract_id
                                  AND (r.is_open = 1 OR (r.prior_version_id = cv.version_id AND ISNULL(r.outcome, N'') <> N'CANCELLED')));
        OPEN ren_cur;
        FETCH NEXT FROM ren_cur INTO @contract;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @rid = NULL;
                EXEC grac_practice.sp_asset_contract_renewal_start @organization_id = @org, @contract_id = @contract,
                     @renewal_type = N'RENEWAL', @notes = N'Started by the scheduler: the renewal reminder window opened.',
                     @actor_employee_id = NULL, @actor = @actor, @suppress_result = 1, @out_renewal_id = @rid OUTPUT;
                IF @rid IS NOT NULL SET @ren = @ren + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @errors = @errors + 1;
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                       N'Contract ', @contract, N' (renewal start): ', ERROR_MESSAGE()), 8000);
            END CATCH
            FETCH NEXT FROM ren_cur INTO @contract;
        END
        CLOSE ren_cur;
        DEALLOCATE ren_cur;

        -- 438: recurring asset activities (before the sweep, so new occurrences notify).
        BEGIN TRY
            SELECT @t = 0, @ao = 0, @ac = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_activity_run @organization_id = @org, @actor = @actor,
                 @tasks = @t OUTPUT, @opened = @ao OUTPUT, @completed = @ac OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @tasks = @tasks + ISNULL(@t, 0), @errors = @errors + ISNULL(@e, 0);
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (activities): ', ERROR_MESSAGE()), 8000);
        END CATCH

        BEGIN TRY
            SELECT @o = 0, @c = 0, @q = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_notification_sweep @organization_id = @org, @actor = @actor,
                 @opened = @o OUTPUT, @closed = @c OUTPUT, @queued = @q OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @opened = @opened + @o, @closed = @closed + @c, @queued = @queued + @q, @errors = @errors + @e;
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (notifications): ', ERROR_MESSAGE()), 8000);
        END CATCH

        FETCH NEXT FROM org_cur INTO @org;
    END
    CLOSE org_cur;
    DEALLOCATE org_cur;

    UPDATE grac_practice.asset_scheduler_run
       SET finished_dt = SYSUTCDATETIME(), result = CASE WHEN @errors > 0 THEN N'COMPLETED_WITH_ERRORS' ELSE N'COMPLETED' END,
           organizations = @orgs, renewals_started = @ren, attestations_generated = @att, occurrences_opened = @opened,
           occurrences_closed = @closed, notifications_queued = @queued, error_count = @errors, error_text = @err,
           tasks_created = @tasks                                                          -- 438
     WHERE run_id = @run;
    END TRY
    BEGIN CATCH
        -- Never leave the lock behind on a pooled connection.
        IF XACT_STATE() <> 0 ROLLBACK;
        IF CURSOR_STATUS('local', 'org_cur') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'org_cur') >= 0 CLOSE org_cur;
            DEALLOCATE org_cur;
        END
        EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';
        IF @run IS NOT NULL
            UPDATE grac_practice.asset_scheduler_run
               SET finished_dt = SYSUTCDATETIME(), result = N'FAILED', error_count = @errors + 1,
                   error_text = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, ERROR_MESSAGE()), 8000)
             WHERE run_id = @run;
        THROW;
    END CATCH
    EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';

    SELECT run_id AS RunId, result AS Result, organizations AS Organizations, renewals_started AS RenewalsStarted,
           attestations_generated AS AttestationsGenerated, occurrences_opened AS OccurrencesOpened,
           occurrences_closed AS OccurrencesClosed, notifications_queued AS NotificationsQueued,
           error_count AS ErrorCount, error_text AS ErrorText, tasks_created AS TasksCreated   -- 438
      FROM grac_practice.asset_scheduler_run WHERE run_id = @run;
END
GO
PRINT '438: sp_asset_scheduler_run re-issued.';
GO

-- 437 body + TasksCreated.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_scheduler_runs
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 50 r.run_id AS RunId, r.trigger_code AS TriggerCode, r.started_dt AS StartedDt, r.finished_dt AS FinishedDt,
           r.result AS Result, CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END AS AllOrganizations,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.renewals_started END AS RenewalsStarted,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.attestations_generated END AS AttestationsGenerated,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.occurrences_opened END AS OccurrencesOpened,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.occurrences_closed END AS OccurrencesClosed,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.notifications_queued END AS NotificationsQueued,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.tasks_created END AS TasksCreated,          -- 438
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.error_count END AS ErrorCount,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.error_text END AS ErrorText,
           r.entered_by AS EnteredBy
      FROM grac_practice.asset_scheduler_run r
     WHERE r.organization_id IS NULL OR r.organization_id = @organization_id
     ORDER BY r.started_dt DESC, r.run_id DESC;
END
GO
PRINT '438: sp_asset_scheduler_runs re-issued.';
GO

-- 256 body + the Asset source (Task Centre filter).
CREATE OR ALTER PROCEDURE grac_practice.sp_task_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1 -- the filterable vocabulary, in dropdown order.
    ;WITH vocab(SourceTypeCode, DisplayOrder) AS (
        SELECT N'Gap',                 1 UNION ALL
        SELECT N'Exception',           2 UNION ALL
        SELECT N'Risk',                3 UNION ALL
        SELECT N'RiskRegister',        4 UNION ALL
        SELECT N'ContinuousAssurance', 5 UNION ALL
        SELECT N'EventAssurance',      6 UNION ALL
        SELECT N'Custom',              7 UNION ALL
        SELECT N'Asset',               8                                               -- 438
    )
    SELECT v.SourceTypeCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.practice_task t
             WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
               AND t.parent_task_id IS NULL
               AND t.source_type_code = v.SourceTypeCode) AS TaskCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;

    -- Result set 2 -- totals, so the dropdown can label "All sources"
    -- and the caller can see how many rows carry no source at all.
    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL) AS TotalCount,
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.source_type_code IS NULL) AS UnsourcedCount;
END
GO
PRINT '438: sp_task_centre_source_counts re-issued.';
GO

-- 9.1.4: the contract / vendor coordinator is told about calibration too.
MERGE grac_practice.asset_notification_default_recipient AS t
USING (VALUES (N'CALIBRATION', N'REMINDER'), (N'CALIBRATION', N'DUE'), (N'CALIBRATION', N'ESCALATION')) AS s(activity_code, stage_kind)
ON t.activity_code = s.activity_code AND t.stage_kind = s.stage_kind AND t.recipient_code = N'CONTRACT_OWNER'
WHEN NOT MATCHED BY TARGET THEN
    INSERT (activity_code, stage_kind, recipient_code, entered_by) VALUES (s.activity_code, s.stage_kind, N'CONTRACT_OWNER', N'seed-438');
PRINT CONCAT('438: calibration default recipients added: ', @@ROWCOUNT);
GO
-- Default calibration profiles nobody has changed yet (version 1) get it too.
INSERT grac_practice.asset_notification_stage_recipient (stage_id, recipient_code, entered_by)
SELECT s.stage_id, N'CONTRACT_OWNER', N'seed-438'
  FROM grac_practice.asset_notification_profile p
  JOIN grac_practice.asset_notification_stage s ON s.profile_id = p.profile_id AND s.is_active = 1
 WHERE p.activity_code = N'CALIBRATION' AND p.entered_by = N'seed-437' AND p.version_no = 1
   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_stage_recipient r
                    WHERE r.stage_id = s.stage_id AND r.recipient_code = N'CONTRACT_OWNER');
PRINT CONCAT('438: contract owner added to unchanged calibration profiles: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 9. Readers / writers (Asset Activities screen)
-- =====================================================================
-- 1. templates with the organization settings  2. active employees.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind, t.description AS Description,
           t.required_field_key AS RequiredFieldKey, t.frequency_field_key AS FrequencyFieldKey, t.basis_field_key AS BasisFieldKey,
           t.last_date_field_key AS LastDateFieldKey, t.expiry_field_key AS ExpiryFieldKey, t.owner_field_key AS OwnerFieldKey,
           t.coverage_types AS CoverageTypes, t.notification_activity_code AS NotificationActivityCode, na.activity_name AS NotificationActivityName,
           st.IsActive, st.LeadDays, st.DueSoonDays, st.GroupingMode, st.CampaignOwnerEmployeeId, ow.employee_name AS CampaignOwnerName,
           t.default_lead_days AS DefaultLeadDays, t.default_due_soon_days AS DefaultDueSoonDays,
           CASE WHEN s.organization_id IS NULL THEN 0 ELSE 1 END AS IsCustomized
      FROM grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code
      JOIN grac_practice.asset_notification_activity na ON na.activity_code = t.notification_activity_code
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = st.CampaignOwnerEmployeeId
     ORDER BY t.display_order;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_setting_save
    @organization_id            BIGINT,
    @template_code              NVARCHAR(40),
    @is_active                  BIT           = 1,
    @lead_days                  INT           = NULL,
    @due_soon_days              INT           = NULL,
    @grouping_mode              NVARCHAR(12)  = N'INDIVIDUAL',
    @campaign_owner_employee_id BIGINT        = NULL,
    @actor                      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @grouping_mode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@grouping_mode)), N''), N'INDIVIDUAL'));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_template WHERE template_code = @template_code)
        THROW 54651, 'Unknown activity template.', 1;
    IF @lead_days IS NULL OR @lead_days NOT BETWEEN 0 AND 365 OR @due_soon_days IS NULL OR @due_soon_days NOT BETWEEN 0 AND 365
        THROW 54652, 'Task lead days and due-soon days must be between 0 and 365.', 1;
    IF @grouping_mode NOT IN (N'INDIVIDUAL', N'CAMPAIGN')
        THROW 54653, 'Tasks are created individually or grouped in a monthly campaign.', 1;
    IF @campaign_owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                                WHERE employee_id = @campaign_owner_employee_id
                                                                  AND organization_id = @organization_id AND status = N'Active')
        THROW 54654, 'The campaign owner must be an active employee of the organization.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT is_active AS isActive, lead_days AS leadDays, due_soon_days AS dueSoonDays,
                                            grouping_mode AS groupingMode, campaign_owner_employee_id AS campaignOwnerEmployeeId
                                       FROM grac_practice.asset_activity_setting
                                      WHERE organization_id = @organization_id AND template_code = @template_code
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    MERGE grac_practice.asset_activity_setting AS t
    USING (SELECT @organization_id AS organization_id, @template_code AS template_code) AS s
    ON t.organization_id = s.organization_id AND t.template_code = s.template_code
    WHEN MATCHED THEN UPDATE SET
        is_active = ISNULL(@is_active, 1), lead_days = @lead_days, due_soon_days = @due_soon_days, grouping_mode = @grouping_mode,
        campaign_owner_employee_id = @campaign_owner_employee_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (organization_id, template_code, is_active, lead_days, due_soon_days, grouping_mode, campaign_owner_employee_id, entered_by)
        VALUES (@organization_id, @template_code, ISNULL(@is_active, 1), @lead_days, @due_soon_days, @grouping_mode,
                @campaign_owner_employee_id, @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-setting', @organization_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @template_code AS templateCode, ISNULL(@is_active, 1) AS isActive, @lead_days AS leadDays, @due_soon_days AS dueSoonDays,
                    @grouping_mode AS groupingMode, @campaign_owner_employee_id AS campaignOwnerEmployeeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO

-- Schedules (recalculated first: task results and register changes show at
-- once). @status: NULL = every applicable schedule, ALL, or one status code.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedules
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(16)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @done INT;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @done OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT s.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName, s.template_code AS TemplateCode,
           t.template_name AS TemplateName, t.activity_kind AS ActivityKind, s.schedule_state AS ScheduleState,
           s.not_scheduled_reason AS NotScheduledReason, s.frequency_text AS FrequencyText, s.basis AS Basis,
           s.last_done_date AS LastDoneDate, s.next_due_date AS NextDueDate, DATEDIFF(DAY, @today, s.next_due_date) AS DaysToDue,
           s.due_source AS DueSource, s.status_code AS StatusCode,
           c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo, s.coverage_end AS CoverageEnd,
           o.occurrence_id AS OpenOccurrenceId, o.occurrence_key AS OpenOccurrenceKey, o.task_id AS OpenTaskId,
           o.needs_reconciliation AS NeedsReconciliation,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = s.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = s.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_occurrence o ON o.asset_id = s.asset_id AND o.template_code = s.template_code AND o.status = N'OPEN'
     WHERE s.organization_id = @organization_id
       AND (@template_code IS NULL OR s.template_code = @template_code)
       AND ((@status IS NULL AND s.status_code <> N'NOT_APPLICABLE') OR @status = N'ALL' OR s.status_code = @status)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR ty.asset_type_name LIKE N'%' + @search + N'%')
     ORDER BY CASE s.status_code WHEN N'OVERDUE' THEN 0 WHEN N'DUE_SOON' THEN 1 WHEN N'VALID' THEN 2 WHEN N'COVERED' THEN 3
                                 WHEN N'NOT_SCHEDULED' THEN 4 ELSE 5 END,
              s.next_due_date, a.asset_name, t.display_order
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Occurrences. @status: OPEN (default), COMPLETED, CANCELLED, COVERED, ALL;
-- @reconcile_only = 1 lists the ones flagged for reconciliation.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_occurrences
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(12)  = N'OPEN',
    @reconcile_only  BIT           = 0,
    @campaign_id     BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'OPEN'));
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.asset_id AS AssetId, a.asset_name AS AssetName,
           o.template_code AS TemplateCode, t.template_name AS TemplateName, o.due_date AS DueDate,
           DATEDIFF(DAY, @today, o.due_date) AS DaysToDue, o.sequence_no AS SequenceNo, o.decision AS Decision,
           o.decision_reason AS DecisionReason, c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo,
           cm.campaign_key AS CampaignKey, cm.campaign_name AS CampaignName, o.task_id AS TaskId, pt.task_number AS TaskNumber,
           ts.status_name AS TaskStatusName, ae.employee_name AS TaskOwnerName, o.task_error AS TaskError, o.status AS Status,
           o.needs_reconciliation AS NeedsReconciliation, o.reconciliation_reason AS ReconciliationReason,
           o.reconciled_note AS ReconciledNote, o.reconciled_by AS ReconciledBy, o.reconciled_dt AS ReconciledDt,
           o.completed_dt AS CompletedDt, cb.employee_name AS CompletedByName, o.entered_dt AS OpenedDt,
           CONVERT(BIGINT, o.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = o.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_campaign cm ON cm.campaign_id = o.campaign_id
      LEFT JOIN grac_practice.practice_task pt ON pt.task_id = o.task_id
      LEFT JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = pt.current_status_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = pt.assigned_to_employee_id
      LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = o.completed_by_employee_id
     WHERE o.organization_id = @organization_id
       AND (@template_code IS NULL OR o.template_code = @template_code)
       AND (@status = N'ALL' OR o.status = @status)
       AND (ISNULL(@reconcile_only, 0) = 0 OR o.needs_reconciliation = 1)
       AND (@campaign_id IS NULL OR o.campaign_id = @campaign_id)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR o.occurrence_key LIKE N'%' + @search + N'%')
     ORDER BY o.due_date, o.occurrence_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Campaigns with item counts and the derived BRD 8 status: Generated (no
-- item finished), In Progress, Partially Completed (finished, some items
-- cancelled), Completed.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_campaigns
    @organization_id BIGINT,
    @page_number     INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT c.campaign_id AS CampaignId, c.campaign_key AS CampaignKey, c.campaign_name AS CampaignName, c.template_code AS TemplateCode,
           t.template_name AS TemplateName, c.period_key AS PeriodKey, ow.employee_name AS OwnerName, c.entered_dt AS CreatedDt,
           n.items AS ItemCount, n.open_items AS OpenCount, n.done_items AS CompletedCount, n.cancelled_items AS CancelledCount,
           CASE WHEN n.open_items = 0 AND n.cancelled_items = 0 THEN N'COMPLETED'
                WHEN n.open_items = 0 THEN N'PARTIALLY_COMPLETED'
                WHEN n.done_items > 0 OR n.cancelled_items > 0 THEN N'IN_PROGRESS'
                ELSE N'GENERATED' END AS CampaignStatus,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_campaign c
      JOIN grac_practice.asset_activity_template t ON t.template_code = c.template_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = c.owner_employee_id
     CROSS APPLY (SELECT COUNT(*) AS items,
                         SUM(CASE WHEN o.status = N'OPEN' THEN 1 ELSE 0 END) AS open_items,
                         SUM(CASE WHEN o.status = N'COMPLETED' THEN 1 ELSE 0 END) AS done_items,
                         SUM(CASE WHEN o.status = N'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_items
                    FROM grac_practice.asset_activity_occurrence o WHERE o.campaign_id = c.campaign_id) n
     WHERE c.organization_id = @organization_id
     ORDER BY c.period_key DESC, c.campaign_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Record the reconciliation of a flagged open occurrence (7.1.5): the note
-- says what was decided (complete, cancel, or keep the task); the flag is
-- cleared and audited. The task itself is completed / cancelled in Task Centre.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_reconcile
    @organization_id         BIGINT,
    @occurrence_id           BIGINT,
    @note                    NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @flag BIT, @reason NVARCHAR(400);
    SELECT @flag = needs_reconciliation, @reason = reconciliation_reason
      FROM grac_practice.asset_activity_occurrence WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id;
    IF @flag IS NULL THROW 54655, 'Activity occurrence not found for this organization.', 1;
    IF @flag = 0 THROW 54656, 'This occurrence is not waiting for reconciliation.', 1;
    IF @note IS NULL THROW 54657, 'Enter the reconciliation note.', 1;
    IF @expected_record_version IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence
                                                             WHERE occurrence_id = @occurrence_id
                                                               AND CONVERT(BIGINT, record_version) = @expected_record_version)
        THROW 54658, 'The occurrence was changed by someone else; reload it and try again.', 1;
    BEGIN TRAN;
    UPDATE grac_practice.asset_activity_occurrence
       SET needs_reconciliation = 0, reconciled_note = @note, reconciled_by = @actor, reconciled_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE occurrence_id = @occurrence_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-occurrence', @occurrence_id, N'RECONCILE',
            (SELECT @reason AS reconciliationReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @occurrence_id AS OccurrenceId, N'RECONCILED' AS Result;
END
GO
PRINT '438: readers and writers created.';
GO

-- =====================================================================
-- 10. Menu: Asset & Contract -> Asset Activities (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-activities', N'Asset Activities', N'Practice/Index/asset-activities', 360, N'calendar-check', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-438', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-438');
PRINT CONCAT('438: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-438', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-activities' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-438', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-activities'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('438: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '438-a templates, task type and Asset source' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_activity_template) >= 4
             AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'AssetActivity')
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%Asset''%')
             AND EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj' AND definition LIKE '%ACTIVITY%')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '438-b tables and the one-open-occurrence index',
       CASE WHEN OBJECT_ID('grac_practice.asset_activity_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_activity_schedule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_activity_campaign','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_activity_occurrence','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_act_occ_open' AND is_unique = 1)
             AND COL_LENGTH('grac_practice.asset_scheduler_run', 'tasks_created') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '438-c procedures and functions present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_activity_task_sync', 'sp_asset_activity_schedule_sync', 'sp_asset_activity_generate',
                                'sp_asset_activity_run', 'sp_asset_activity_config_get', 'sp_asset_activity_setting_save',
                                'sp_asset_activity_schedules', 'sp_asset_activity_occurrences', 'sp_asset_activity_campaigns',
                                'sp_asset_activity_reconcile')) = 10
             AND OBJECT_ID('grac_practice.fn_asset_activity_interval') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_activity_add') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_activity_settings') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_activity_person') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '438-d re-issues carry the 438 additions',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) LIKE '%asset_activity_schedule%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) LIKE '%coverage_status%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_parties')) LIKE '%ACTIVITY%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) LIKE '%asset_activity_occurrence%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_activity_run%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_runs')) LIKE '%tasks_created%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_centre_source_counts')) LIKE '%Asset''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '438-e frequency parsing ("12 months", "2 weeks", "1 year", "monthly" not understood)',
       CASE WHEN (SELECT IntervalValue FROM grac_practice.fn_asset_activity_interval(N'12 months')) = 12
             AND (SELECT IntervalUnit FROM grac_practice.fn_asset_activity_interval(N'12 months')) = N'MONTH'
             AND (SELECT IntervalValue FROM grac_practice.fn_asset_activity_interval(N'2 weeks')) = 14
             AND (SELECT IntervalUnit FROM grac_practice.fn_asset_activity_interval(N'1 year')) = N'YEAR'
             AND (SELECT IntervalValue FROM grac_practice.fn_asset_activity_interval(N'monthly')) IS NULL
             AND grac_practice.fn_asset_activity_add('20260131', 1, N'MONTH') = '20260228'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '438-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-activities' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: asset A with Calibration required = Yes, frequency "12 months",
--   basis Scheduled Date, last calibration 11 months ago, calibration owner
--   P; asset B the same but covered by an Active Calibration contract;
--   asset C with Licence required = Yes and an equipment licence expiring in
--   20 days, no licence contract; asset D the same, covered by a Licence
--   contract running past the expiry.
--   1. Asset Activities -> Schedules: A and B Due Soon (next = last + 12
--      months), B shows the contract; C Due Soon; D Covered.
--   2. Asset Notifications -> Scheduler -> Run now (or wait for the worker):
--      run log shows tasks created. Occurrences: A and B have their own
--      task (B's decision names the linked contract -- 7.1.2); C has an
--      individual renewal task; D is Covered with no task (7.1.3).
--      Run now again: nothing new (one open occurrence per asset/template).
--   3. Task Centre -> Source: Asset lists the tasks (owner P for A / B).
--      Complete A's task: Run now -> A's occurrence Completed, last
--      calibration date = today, next = due + 12 months (scheduled basis).
--      Asset Register shows Next calibration date and Calibration status.
--   4. Map C to a Licence contract covering it past the expiry: Run now ->
--      C's open occurrence is flagged for reconciliation, its task stays.
--      Reconcile with a note -> flag cleared (and not raised again).
--   5. Templates: Calibration -> Campaign; a new due month groups its tasks
--      in one campaign (Campaigns tab), each asset keeping its own task.
--   6. My Notifications: P receives the Calibration reminder for A; the
--      contract owner of B's contract too (9.1.4).
-- =====================================================================
