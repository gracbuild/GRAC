-- =====================================================================
-- 437  Notification profiles, reminders and escalation; scheduler pass
--      (Asset & Contract Management, Phase 6 increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 9.1 "Due-Date Notifications and Escalation Framework":
--   configurable reminders, acknowledgements, escalations and restrictive-
--   action reviews for time-bound asset and contract activities, defined by
--   activity and overridable by criticality; 9.1.1 profile fields (identity,
--   trigger basis, reminder stages, escalation stages with severity and
--   recipient rules, recipients, channels, acknowledgement, snooze /
--   reschedule by configured roles with reason, revised date and audit,
--   calendar rules, completion behaviour); 9.1.2 classes (Informational,
--   Reminder, Escalation, Critical); 9.1.3 default profiles; 9.1.5 licence
--   and contract rules (earliest of notice / decision / end date; contract
--   expiry notifies contract owner, procurement, compliance and affected
--   asset owners); 9.1.8 escalation matrix; 9.1.10 audit and reliability
--   (profile / version, trigger, recipient, channel, sent time, delivery
--   result, acknowledgement, escalation level, related object; no duplicate
--   for the same profile stage and occurrence; retry transient failures and
--   expose permanent ones; due-date / ownership changes recalculate future
--   notices and keep the sent records); 7.1.1 step 24 (one contract-level
--   renewal workflow for a contract-driven due event); 7.1.5 (unique
--   occurrence key, no second open occurrence). The user decided that the
--   scheduler runs in the EXISTING background worker (TaskNotificationWorker).
--   Plan in docs/asset-contract-management.md (Phase 6 split, D49).
--
-- WHAT THIS DOES
-- --------------
--   1. Catalogues (global, seeded): notification activities (the 9.1.3 rows
--      plus Contract expiry from 9.1.5) with their trigger basis and whether
--      a source is wired yet; recipient types; default stages, default
--      recipients and the default 9.1.8 escalation matrix.
--   2. Per organization: notification profiles (one active default per
--      activity, optional overrides by severity), stages (reminder days
--      before, due, escalation days after with level 1-3 and class),
--      recipients per stage (parties of the object or organization roles),
--      escalation matrix (severity x level -> recipients). Defaults are
--      copied in for an organization the first time it is configured or
--      swept (D52).
--   3. Notification occurrences: one per activity, object and trigger date
--      (7.1.5 occurrence key); a changed trigger date or object reference
--      supersedes the occurrence and keeps what was sent (9.1.10); snooze /
--      reschedule with reason and revised date (D55).
--   4. asset_notification_outbox: one row per occurrence, stage and
--      recipient (9.1.10 idempotency) with the profile version, class,
--      escalation level, channels, delivery status / attempts, read and
--      acknowledgement (read / action / manager -- D54).
--   5. sp_asset_scheduler_run -- the daily pass, run by the existing
--      TaskNotificationWorker (at most hourly) or by "Run now": contract
--      effective dates (434 sync), renewal occurrences started when the
--      reminder window opens (D58), periodic attestation runs (D59), then
--      the notification sources wired today (D50): contract renewal (major
--      contract / warranty-AMC), contract expiry, model / OS support end,
--      firmware support end, technology exception expiry, custodian
--      attestation. Run log in asset_scheduler_run. One run at a time
--      (application lock).
--   6. Re-issued with @suppress_result (no other change):
--      sp_asset_contract_renewal_start (436) and
--      sp_asset_attestation_generate (431, also @scheduled: no campaign row
--      when nothing was generated or marked overdue).
--   7. Readers / writers for the Asset Notifications screen and the
--      own list of each recipient (My Notifications).
--   8. Menu: Asset & Contract -> Asset Notifications (also carried in 274).
--
-- NOT DONE HERE: activity templates, asset schedules and task generation
--   for calibration / maintenance / standalone licences (Phase 6.2 -- their
--   profiles exist and are configurable, but nothing raises them yet);
--   privacy, retention and evidence sources (Phase 8 / 6.3); holiday
--   calendars, time zones, quiet hours and digests (no holiday calendar or
--   dispatcher exists -- D57); delivery by e-mail / Teams / webhook (no
--   dispatcher in the codebase -- 201; rows record the channels and a
--   dispatcher reports back through the delivery call); escalation of an
--   unacknowledged reminder; restrictive-use actions (9.1.9 -> 6.3).
--
-- ERROR NUMBERS: 54610-54649
--   54610 organization not found           54611 profile not found
--   54612 unknown activity                 54613 profile name required
--   54614 severity                         54615 owner not an active employee
--   54616 effective dates                  54617 acknowledgement mode
--   54618 stages missing / not readable    54619 stage kind / days / level / class
--   54620 two stages on the same day       54621 recipient type / role
--   54622 active profile already exists    54623 changed by someone else
--   54624 escalation matrix entry          54625 occurrence not found
--   54626 occurrence not open              54627 snooze not allowed
--   54628 revised date                     54629 reason required
--   54630 notification not found           54631 acknowledgement note required
--   54632 not the manager / nothing to acknowledge
--   54633 delivery status                  54634 no channel selected
--
-- ALSO EDITED: API (Program.cs registers the existing task notification
--   service and worker; TaskNotificationWorker runs the asset scheduler;
--   AssetConfig service / controller / models), Web proxy (notifications),
--   PracticeScreen + Manage.cshtml + appsettings (new screen), new
--   asset-notifications.cshtml / .js, my-notifications.cshtml (Asset &
--   Contract section) + asset-my-notifications.js, 274 (menu), docs.
-- DEPENDS ON: 117, 431, 432, 434, 435, 436.
-- Rollback: 437_asset_notifications_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_contract_renewal','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_contract_renewal_start','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_attestation','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_attestation_generate','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_technology_exception','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_technology_status') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_stored_values') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_holders_list','P') IS NULL
BEGIN
    RAISERROR('ABORT (437): run 117, 430, 431, 434, 435 and 436 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Catalogues (global)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_notification_activity','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_activity (
        activity_code      NVARCHAR(40)   NOT NULL CONSTRAINT pk_pm_asset_ntf_activity PRIMARY KEY,
        activity_name      NVARCHAR(160)  NOT NULL,
        trigger_basis      NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_ntf_act_basis CHECK (trigger_basis IN (N'DUE_DATE', N'EXPIRY_DATE', N'SUPPORT_MILESTONE',
                N'REVIEW_DATE', N'RECURRENCE_DATE', N'USAGE_THRESHOLD', N'EVENT')),
        trigger_description NVARCHAR(400) NOT NULL,
        typical_recipients NVARCHAR(400)  NOT NULL,
        source_available   BIT            NOT NULL,
        source_note        NVARCHAR(400)  NULL,
        display_order      INT            NOT NULL,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_ntf_act_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_ntf_act_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '437: asset_notification_activity created.';
END
GO

MERGE grac_practice.asset_notification_activity AS t
USING (VALUES
    (N'CALIBRATION', N'Calibration', N'DUE_DATE', N'Next calibration date of the asset (9.1.4).',
     N'Activity owner, asset owner, manager, compliance / biomedical', 0, N'Raised by the activity scheduler (Phase 6.2).', 10),
    (N'PREVENTIVE_MAINTENANCE', N'Preventive maintenance or inspection', N'DUE_DATE', N'Next maintenance / inspection date of the asset.',
     N'Maintenance owner, asset owner, manager, compliance / EHS', 0, N'Raised by the activity scheduler (Phase 6.2).', 20),
    (N'MAJOR_CONTRACT', N'Enterprise licence or major contract', N'EXPIRY_DATE',
     N'Earliest of the notice date, renewal decision date and end date of the contract version in force (9.1.5).',
     N'Contract owner, procurement, finance, IT / business owner', 1, N'Contracts of type Licence, Calibration, Managed Service or Custom.', 30),
    (N'STANDALONE_LICENCE', N'Standalone licence', N'EXPIRY_DATE', N'Licence expiry date of an asset without a matching contract.',
     N'Asset / software owner and manager', 0, N'Raised by the activity scheduler (Phase 6.2).', 40),
    (N'WARRANTY_AMC', N'Warranty / AMC / CMC / insurance', N'EXPIRY_DATE',
     N'Earliest of the notice date, renewal decision date and end date of the contract version in force (9.1.5).',
     N'Contract owner, procurement, asset owner, compliance', 1, N'Contracts of type Warranty, AMC, CMC or Insurance.', 50),
    (N'CONTRACT_EXPIRY', N'Contract expiry', N'EXPIRY_DATE', N'The day after the end date of a contract version that expired without a successor (9.1.5).',
     N'Contract owner, procurement, compliance and affected asset owners', 1, NULL, 55),
    (N'TECH_SUPPORT_END', N'Model or OS support end', N'SUPPORT_MILESTONE',
     N'Support end date of the asset model (extended, else security, else standard support) or of the installed OS release.',
     N'Technical owner, security, compliance, IT management', 1, NULL, 60),
    (N'FIRMWARE_SUPPORT_END', N'Firmware support end', N'SUPPORT_MILESTONE', N'Support end date of the installed firmware release.',
     N'Technical owner, security and compliance', 1, NULL, 70),
    (N'PRIVACY_REVIEW', N'Privacy / DPIA review', N'REVIEW_DATE', N'Next privacy / DPIA review date.',
     N'Privacy owner, process owner and DPO delegate', 0, N'Raised with the privacy profile (Phase 8).', 80),
    (N'RETENTION_REVIEW', N'Retention / deletion review', N'REVIEW_DATE', N'Retention expiry / review date.',
     N'Data owner, privacy owner, legal / compliance', 0, N'Raised with the privacy profile (Phase 8).', 90),
    (N'EVIDENCE_EXPIRY', N'Evidence / certificate expiry', N'EXPIRY_DATE', N'Expiry date of evidence or a certificate.',
     N'Evidence owner, activity owner and reviewer', 0, N'Raised with task evidence (Phase 6.3).', 100),
    (N'EXCEPTION_EXPIRY', N'Exception expiry', N'EXPIRY_DATE', N'Expiry date of an approved technology exception (430).',
     N'Exception owner, approver and compliance', 1, NULL, 110),
    (N'CUSTODIAN_ATTESTATION', N'Asset custodian attestation', N'DUE_DATE', N'Due date of an open attestation (431).',
     N'Custodian, asset owner, manager and compliance; security for lost / critical assets', 1, NULL, 120)
) AS s(activity_code, activity_name, trigger_basis, trigger_description, typical_recipients, source_available, source_note, display_order)
ON t.activity_code = s.activity_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (activity_code, activity_name, trigger_basis, trigger_description, typical_recipients, source_available, source_note, display_order, entered_by)
    VALUES (s.activity_code, s.activity_name, s.trigger_basis, s.trigger_description, s.typical_recipients, s.source_available, s.source_note,
            s.display_order, N'seed-437');
PRINT CONCAT('437: notification activities inserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_notification_recipient_type','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_recipient_type (
        recipient_code NVARCHAR(30)  NOT NULL CONSTRAINT pk_pm_asset_ntf_rtype PRIMARY KEY,
        recipient_name NVARCHAR(120) NOT NULL,
        description    NVARCHAR(400) NOT NULL,
        display_order  INT           NOT NULL,
        entered_by     NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ntf_rtype_eby DEFAULT N'system',
        entered_dt     DATETIME2     NOT NULL CONSTRAINT df_pm_asset_ntf_rtype_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '437: asset_notification_recipient_type created.';
END
GO

MERGE grac_practice.asset_notification_recipient_type AS t
USING (VALUES
    (N'ACTIVITY_OWNER', N'Activity owner', N'Contract: contract owner, else procurement owner. Support end: technical owner, else asset owner. Exception: exception owner. Attestation: the assignee (or the members of the assigned team).', 10),
    (N'ASSET_OWNER', N'Asset owner', N'Asset owner of the asset.', 20),
    (N'BUSINESS_OWNER', N'Business owner', N'Business owner field of the asset.', 30),
    (N'TECHNICAL_OWNER', N'Technical owner', N'Technical owner field of the asset (person or team).', 40),
    (N'CUSTODIAN', N'Custodian', N'Custodian field of the asset (person or team).', 50),
    (N'MAINTENANCE_OWNER', N'Maintenance owner', N'Maintenance owner field of the asset (person or team).', 60),
    (N'COMPLIANCE_OWNER', N'Compliance owner', N'Compliance owner field of the asset.', 70),
    (N'PRIVACY_OWNER', N'Privacy owner', N'Privacy owner field of the asset.', 80),
    (N'SECURITY_OWNER', N'Information security owner', N'Information security owner field of the asset (person or team).', 90),
    (N'CONTRACT_OWNER', N'Contract owner', N'Contract owner of the contract version.', 100),
    (N'PROCUREMENT_OWNER', N'Procurement owner', N'Procurement owner of the contract version.', 110),
    (N'AFFECTED_ASSET_OWNERS', N'Affected asset owners', N'Owners of the assets covered by the contract version.', 120),
    (N'EXCEPTION_APPROVER', N'Exception approver', N'The person who approved the technology exception.', 130),
    (N'MANAGER', N'Manager', N'Reporting officer of the activity owner.', 140),
    (N'DEPARTMENT_HEAD', N'Department head', N'Head of the department of the activity owner.', 150),
    (N'ROLE', N'Organization role', N'Every active holder of the selected organization role (procurement, finance, compliance, executives...).', 160)
) AS s(recipient_code, recipient_name, description, display_order)
ON t.recipient_code = s.recipient_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (recipient_code, recipient_name, description, display_order, entered_by)
    VALUES (s.recipient_code, s.recipient_name, s.description, s.display_order, N'seed-437');
PRINT CONCAT('437: recipient types inserted: ', @@ROWCOUNT);
GO

-- Default stages (9.1.3 suggested intervals; configurable per organization).
IF OBJECT_ID('grac_practice.asset_notification_default_stage','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_default_stage (
        default_stage_id   INT           IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_dstage PRIMARY KEY,
        activity_code      NVARCHAR(40)  NOT NULL
            CONSTRAINT fk_pm_asset_ntf_dstage_act REFERENCES grac_practice.asset_notification_activity(activity_code),
        stage_kind         NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_ntf_dstage_kind CHECK (stage_kind IN (N'REMINDER', N'DUE', N'ESCALATION')),
        offset_days        INT           NOT NULL,
        escalation_level   TINYINT       NOT NULL,
        notification_class NVARCHAR(20)  NOT NULL,
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ntf_dstage_eby DEFAULT N'system',
        CONSTRAINT uq_pm_asset_ntf_dstage UNIQUE (activity_code, stage_kind, offset_days)
    );
    PRINT '437: asset_notification_default_stage created.';
END
GO

;WITH src AS (
    SELECT a.activity_code, k.stage_kind, CAST(v.value AS INT) AS offset_days,
           CAST(CASE WHEN k.stage_kind <> N'ESCALATION' THEN 0
                     ELSE ISNULL(CAST(lv.value AS INT), 1) END AS TINYINT) AS escalation_level,
           CASE k.stage_kind WHEN N'REMINDER' THEN N'REMINDER' WHEN N'DUE' THEN N'REMINDER' ELSE N'ESCALATION' END AS notification_class
      FROM (VALUES
            (N'CALIBRATION',            N'REMINDER',   N'[60,30,15,7,1]',              NULL),
            (N'CALIBRATION',            N'ESCALATION', N'[1,7,15,30]',                 N'[1,2,3,3]'),
            (N'PREVENTIVE_MAINTENANCE', N'REMINDER',   N'[30,15,7,1]',                 NULL),
            (N'PREVENTIVE_MAINTENANCE', N'ESCALATION', N'[1,7,15]',                    N'[1,2,3]'),
            (N'MAJOR_CONTRACT',         N'REMINDER',   N'[180,120,90,60,30,15,7]',     NULL),
            (N'STANDALONE_LICENCE',     N'REMINDER',   N'[90,60,30,15,7]',             NULL),
            (N'STANDALONE_LICENCE',     N'ESCALATION', N'[0,7,15]',                    N'[1,2,3]'),
            (N'WARRANTY_AMC',           N'REMINDER',   N'[180,120,90,60,30,15,7]',     NULL),
            (N'CONTRACT_EXPIRY',        N'ESCALATION', N'[0]',                         NULL),
            (N'TECH_SUPPORT_END',       N'REMINDER',   N'[180,120,90,60,30]',          NULL),
            (N'TECH_SUPPORT_END',       N'ESCALATION', N'[0]',                         NULL),
            (N'FIRMWARE_SUPPORT_END',   N'REMINDER',   N'[90,60,30,15,7]',             NULL),
            (N'FIRMWARE_SUPPORT_END',   N'ESCALATION', N'[0]',                         NULL),
            (N'PRIVACY_REVIEW',         N'REMINDER',   N'[30,15,7]',                   NULL),
            (N'PRIVACY_REVIEW',         N'ESCALATION', N'[1,7]',                       N'[1,2]'),
            (N'RETENTION_REVIEW',       N'REMINDER',   N'[90,60,30]',                  NULL),
            (N'RETENTION_REVIEW',       N'ESCALATION', N'[0]',                         NULL),
            (N'EVIDENCE_EXPIRY',        N'REMINDER',   N'[90,60,30,15,7]',             NULL),
            (N'EVIDENCE_EXPIRY',        N'ESCALATION', N'[0]',                         NULL),
            (N'EXCEPTION_EXPIRY',       N'REMINDER',   N'[30,15,7,1]',                 NULL),
            (N'EXCEPTION_EXPIRY',       N'ESCALATION', N'[0]',                         NULL),
            (N'CUSTODIAN_ATTESTATION',  N'REMINDER',   N'[30,15,7]',                   NULL),
            (N'CUSTODIAN_ATTESTATION',  N'DUE',        N'[0]',                         NULL),
            (N'CUSTODIAN_ATTESTATION',  N'ESCALATION', N'[1,7,15,30]',                 N'[1,2,3,3]')
           ) k(activity_code, stage_kind, offset_list, level_list)
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = k.activity_code
     CROSS APPLY OPENJSON(k.offset_list) v
     OUTER APPLY (SELECT j.value FROM OPENJSON(k.level_list) j WHERE j.[key] = v.[key]) lv
)
MERGE grac_practice.asset_notification_default_stage AS t
USING src AS s
ON t.activity_code = s.activity_code AND t.stage_kind = s.stage_kind AND t.offset_days = s.offset_days
WHEN NOT MATCHED BY TARGET THEN
    INSERT (activity_code, stage_kind, offset_days, escalation_level, notification_class, entered_by)
    VALUES (s.activity_code, s.stage_kind, s.offset_days, s.escalation_level, s.notification_class, N'seed-437');
PRINT CONCAT('437: default stages inserted: ', @@ROWCOUNT);
GO

-- Default recipients per activity and stage kind (9.1.3 "typical
-- recipients" that are parties of the object; functions such as
-- procurement, finance or executives are organization roles the
-- organization adds -- D52). Managers and department heads come from the
-- escalation matrix.
IF OBJECT_ID('grac_practice.asset_notification_default_recipient','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_default_recipient (
        default_recipient_id INT           IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_drcp PRIMARY KEY,
        activity_code        NVARCHAR(40)  NOT NULL
            CONSTRAINT fk_pm_asset_ntf_drcp_act REFERENCES grac_practice.asset_notification_activity(activity_code),
        stage_kind           NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_ntf_drcp_kind CHECK (stage_kind IN (N'REMINDER', N'DUE', N'ESCALATION')),
        recipient_code       NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_asset_ntf_drcp_type REFERENCES grac_practice.asset_notification_recipient_type(recipient_code),
        entered_by           NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ntf_drcp_eby DEFAULT N'system',
        CONSTRAINT uq_pm_asset_ntf_drcp UNIQUE (activity_code, stage_kind, recipient_code)
    );
    PRINT '437: asset_notification_default_recipient created.';
END
GO

;WITH src AS (
    SELECT k.activity_code, kd.stage_kind, r.value AS recipient_code
      FROM (VALUES
            (N'CALIBRATION',            N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","ASSET_OWNER"]'),
            (N'CALIBRATION',            N'["ESCALATION"]',                  N'["COMPLIANCE_OWNER"]'),
            (N'PREVENTIVE_MAINTENANCE', N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","ASSET_OWNER"]'),
            (N'PREVENTIVE_MAINTENANCE', N'["ESCALATION"]',                  N'["COMPLIANCE_OWNER"]'),
            (N'MAJOR_CONTRACT',         N'["REMINDER","DUE","ESCALATION"]', N'["CONTRACT_OWNER","PROCUREMENT_OWNER"]'),
            (N'STANDALONE_LICENCE',     N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","ASSET_OWNER"]'),
            (N'WARRANTY_AMC',           N'["REMINDER","DUE","ESCALATION"]', N'["CONTRACT_OWNER","PROCUREMENT_OWNER","AFFECTED_ASSET_OWNERS"]'),
            (N'CONTRACT_EXPIRY',        N'["REMINDER","DUE","ESCALATION"]', N'["CONTRACT_OWNER","PROCUREMENT_OWNER","AFFECTED_ASSET_OWNERS"]'),
            (N'TECH_SUPPORT_END',       N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","SECURITY_OWNER","COMPLIANCE_OWNER"]'),
            (N'FIRMWARE_SUPPORT_END',   N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","SECURITY_OWNER","COMPLIANCE_OWNER"]'),
            (N'PRIVACY_REVIEW',         N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","PRIVACY_OWNER"]'),
            (N'RETENTION_REVIEW',       N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","PRIVACY_OWNER"]'),
            (N'RETENTION_REVIEW',       N'["ESCALATION"]',                  N'["COMPLIANCE_OWNER"]'),
            (N'EVIDENCE_EXPIRY',        N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER"]'),
            (N'EXCEPTION_EXPIRY',       N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","EXCEPTION_APPROVER","COMPLIANCE_OWNER"]'),
            (N'CUSTODIAN_ATTESTATION',  N'["REMINDER","DUE","ESCALATION"]', N'["ACTIVITY_OWNER","ASSET_OWNER"]'),
            (N'CUSTODIAN_ATTESTATION',  N'["ESCALATION"]',                  N'["COMPLIANCE_OWNER"]')
           ) k(activity_code, kinds, recipients)
     CROSS APPLY (SELECT value AS stage_kind FROM OPENJSON(k.kinds)) kd
     CROSS APPLY OPENJSON(k.recipients) r
)
MERGE grac_practice.asset_notification_default_recipient AS t
USING (SELECT DISTINCT activity_code, stage_kind, recipient_code FROM src) AS s
ON t.activity_code = s.activity_code AND t.stage_kind = s.stage_kind AND t.recipient_code = s.recipient_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (activity_code, stage_kind, recipient_code, entered_by)
    VALUES (s.activity_code, s.stage_kind, s.recipient_code, N'seed-437');
PRINT CONCAT('437: default recipients inserted: ', @@ROWCOUNT);
GO

-- Default escalation matrix (9.1.8). Level 0 = initial recipient. Entries
-- the BRD names as functions (department / business head, control function,
-- senior management, executive sponsor) that are not a party of the object
-- are left for the organization to add as roles (D52).
IF OBJECT_ID('grac_practice.asset_escalation_matrix_default','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_escalation_matrix_default (
        default_entry_id INT           IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_esc_dflt PRIMARY KEY,
        severity_code    NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_asset_esc_dflt_sev CHECK (severity_code IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')),
        escalation_level TINYINT       NOT NULL CONSTRAINT ck_pm_asset_esc_dflt_lvl CHECK (escalation_level BETWEEN 0 AND 3),
        recipient_code   NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_asset_esc_dflt_type REFERENCES grac_practice.asset_notification_recipient_type(recipient_code),
        entered_by       NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_esc_dflt_eby DEFAULT N'system',
        CONSTRAINT uq_pm_asset_esc_dflt UNIQUE (severity_code, escalation_level, recipient_code)
    );
    PRINT '437: asset_escalation_matrix_default created.';
END
GO

MERGE grac_practice.asset_escalation_matrix_default AS t
USING (VALUES
    (N'LOW',      0, N'ACTIVITY_OWNER'), (N'LOW',      1, N'MANAGER'), (N'LOW',      2, N'COMPLIANCE_OWNER'),
    (N'MEDIUM',   0, N'ACTIVITY_OWNER'), (N'MEDIUM',   1, N'MANAGER'), (N'MEDIUM',   2, N'DEPARTMENT_HEAD'),
    (N'MEDIUM',   3, N'COMPLIANCE_OWNER'),
    (N'HIGH',     0, N'ACTIVITY_OWNER'), (N'HIGH',     1, N'MANAGER'), (N'HIGH',     2, N'COMPLIANCE_OWNER'),
    (N'HIGH',     2, N'SECURITY_OWNER'), (N'HIGH',     2, N'PRIVACY_OWNER'),
    (N'CRITICAL', 0, N'ACTIVITY_OWNER'), (N'CRITICAL', 0, N'ASSET_OWNER'), (N'CRITICAL', 1, N'COMPLIANCE_OWNER'),
    (N'CRITICAL', 1, N'SECURITY_OWNER')
) AS s(severity_code, escalation_level, recipient_code)
ON t.severity_code = s.severity_code AND t.escalation_level = s.escalation_level AND t.recipient_code = s.recipient_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (severity_code, escalation_level, recipient_code, entered_by)
    VALUES (s.severity_code, s.escalation_level, s.recipient_code, N'seed-437');
PRINT CONCAT('437: default escalation matrix inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Organization configuration
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_notification_profile','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_profile (
        profile_id         BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_profile PRIMARY KEY,
        organization_id    BIGINT         NOT NULL,
        profile_code       NVARCHAR(60)   NOT NULL,
        profile_name       NVARCHAR(200)  NOT NULL,
        activity_code      NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_asset_ntf_profile_act REFERENCES grac_practice.asset_notification_activity(activity_code),
        severity_code      NVARCHAR(10)   NULL      -- NULL: default for the activity; set: override for that severity
            CONSTRAINT ck_pm_asset_ntf_profile_sev CHECK (severity_code IS NULL OR severity_code IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')),
        owner_employee_id  BIGINT         NULL
            CONSTRAINT fk_pm_asset_ntf_profile_owner REFERENCES grac_practice.organization_employee(employee_id),
        effective_from     DATE           NULL,
        effective_to       DATE           NULL,
        is_active          BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_active DEFAULT 1,
        ack_mode           NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_asset_ntf_profile_ack DEFAULT N'READ'
            CONSTRAINT ck_pm_asset_ntf_profile_ack CHECK (ack_mode IN (N'NONE', N'READ', N'ACTION', N'MANAGER')),
        channel_in_app     BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_inapp DEFAULT 1,
        channel_email      BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_email DEFAULT 0,
        channel_webhook    BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_hook DEFAULT 0,
        snooze_allowed     BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_snooze DEFAULT 1,
        working_days_only  BIT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_wdays DEFAULT 0,
        version_no         INT            NOT NULL CONSTRAINT df_pm_asset_ntf_profile_ver DEFAULT 1,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_ntf_profile_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_ntf_profile_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        record_version     ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_asset_ntf_profile_code UNIQUE (organization_id, profile_code),
        CONSTRAINT ck_pm_asset_ntf_profile_dates CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from),
        CONSTRAINT ck_pm_asset_ntf_profile_channel CHECK (channel_in_app = 1 OR channel_email = 1 OR channel_webhook = 1)
    );
    -- One active profile per activity and severity (NULLs compare equal: one active default).
    CREATE UNIQUE INDEX ux_pm_asset_ntf_profile_active ON grac_practice.asset_notification_profile
        (organization_id, activity_code, severity_code) WHERE is_active = 1;
    PRINT '437: asset_notification_profile created.';
END
GO

IF OBJECT_ID('grac_practice.asset_notification_stage','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_stage (
        stage_id           BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_stage PRIMARY KEY,
        profile_id         BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_ntf_stage_profile REFERENCES grac_practice.asset_notification_profile(profile_id),
        stage_kind         NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_ntf_stage_kind CHECK (stage_kind IN (N'REMINDER', N'DUE', N'ESCALATION')),
        offset_days        INT           NOT NULL CONSTRAINT ck_pm_asset_ntf_stage_days CHECK (offset_days BETWEEN 0 AND 730),
        escalation_level   TINYINT       NOT NULL CONSTRAINT ck_pm_asset_ntf_stage_lvl CHECK (escalation_level BETWEEN 0 AND 3),
        notification_class NVARCHAR(20)  NOT NULL
            CONSTRAINT ck_pm_asset_ntf_stage_class CHECK (notification_class IN (N'INFORMATIONAL', N'REMINDER', N'ESCALATION', N'CRITICAL')),
        is_active          BIT           NOT NULL CONSTRAINT df_pm_asset_ntf_stage_active DEFAULT 1,
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ntf_stage_eby DEFAULT N'system',
        entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_asset_ntf_stage_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2     NULL,
        CONSTRAINT ck_pm_asset_ntf_stage_shape CHECK (
            (stage_kind = N'REMINDER' AND offset_days > 0 AND escalation_level = 0) OR
            (stage_kind = N'DUE' AND offset_days = 0 AND escalation_level = 0) OR
            (stage_kind = N'ESCALATION' AND escalation_level BETWEEN 1 AND 3))
    );
    CREATE UNIQUE INDEX ux_pm_asset_ntf_stage_day ON grac_practice.asset_notification_stage(profile_id, stage_kind, offset_days);
    PRINT '437: asset_notification_stage created.';
END
GO

IF OBJECT_ID('grac_practice.asset_notification_stage_recipient','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_stage_recipient (
        stage_recipient_id BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_srcp PRIMARY KEY,
        stage_id           BIGINT        NOT NULL
            CONSTRAINT fk_pm_asset_ntf_srcp_stage REFERENCES grac_practice.asset_notification_stage(stage_id),
        recipient_code     NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_asset_ntf_srcp_type REFERENCES grac_practice.asset_notification_recipient_type(recipient_code),
        role_id            BIGINT        NULL
            CONSTRAINT fk_pm_asset_ntf_srcp_role REFERENCES grac_practice.organization_role(role_id),
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_ntf_srcp_eby DEFAULT N'system',
        CONSTRAINT ck_pm_asset_ntf_srcp_role CHECK ((recipient_code = N'ROLE' AND role_id IS NOT NULL) OR (recipient_code <> N'ROLE' AND role_id IS NULL))
    );
    CREATE UNIQUE INDEX ux_pm_asset_ntf_srcp ON grac_practice.asset_notification_stage_recipient(stage_id, recipient_code, role_id);
    PRINT '437: asset_notification_stage_recipient created.';
END
GO

IF OBJECT_ID('grac_practice.asset_escalation_matrix','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_escalation_matrix (
        entry_id         BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_esc_matrix PRIMARY KEY,
        organization_id  BIGINT        NOT NULL,
        severity_code    NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_asset_esc_matrix_sev CHECK (severity_code IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')),
        escalation_level TINYINT       NOT NULL CONSTRAINT ck_pm_asset_esc_matrix_lvl CHECK (escalation_level BETWEEN 0 AND 3),
        recipient_code   NVARCHAR(30)  NOT NULL
            CONSTRAINT fk_pm_asset_esc_matrix_type REFERENCES grac_practice.asset_notification_recipient_type(recipient_code),
        role_id          BIGINT        NULL
            CONSTRAINT fk_pm_asset_esc_matrix_role REFERENCES grac_practice.organization_role(role_id),
        entered_by       NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_esc_matrix_eby DEFAULT N'system',
        entered_dt       DATETIME2     NOT NULL CONSTRAINT df_pm_asset_esc_matrix_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_asset_esc_matrix_role CHECK ((recipient_code = N'ROLE' AND role_id IS NOT NULL) OR (recipient_code <> N'ROLE' AND role_id IS NULL))
    );
    CREATE UNIQUE INDEX ux_pm_asset_esc_matrix ON grac_practice.asset_escalation_matrix
        (organization_id, severity_code, escalation_level, recipient_code, role_id);
    PRINT '437: asset_escalation_matrix created.';
END
GO

-- =====================================================================
-- 3. Occurrences, outbox, run log
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_notification_occurrence','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_occurrence (
        occurrence_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_occ PRIMARY KEY,
        organization_id        BIGINT         NOT NULL,
        occurrence_key         NVARCHAR(200)  NOT NULL,
        activity_code          NVARCHAR(40)   NOT NULL
            CONSTRAINT fk_pm_asset_ntf_occ_act REFERENCES grac_practice.asset_notification_activity(activity_code),
        object_type            NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_ntf_occ_obj CHECK (object_type IN (N'CONTRACT_VERSION', N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE',
                N'TECH_EXCEPTION', N'ATTESTATION')),
        object_id              BIGINT         NOT NULL,   -- version / asset / exception / attestation
        ref_id                 BIGINT         NULL,       -- model / release the date belongs to
        asset_id               BIGINT         NULL,
        contract_id            BIGINT         NULL,
        trigger_date           DATE           NOT NULL,
        object_ref             NVARCHAR(200)  NULL,
        object_title           NVARCHAR(400)  NULL,
        severity_code          NVARCHAR(10)   NOT NULL,
        status                 NVARCHAR(12)   NOT NULL CONSTRAINT df_pm_asset_ntf_occ_status DEFAULT N'OPEN'
            CONSTRAINT ck_pm_asset_ntf_occ_status CHECK (status IN (N'OPEN', N'COMPLETED', N'SUPERSEDED')),
        last_stage_id          BIGINT         NULL
            CONSTRAINT fk_pm_asset_ntf_occ_stage REFERENCES grac_practice.asset_notification_stage(stage_id),
        last_stage_date        DATE           NULL,
        escalation_level       TINYINT        NOT NULL CONSTRAINT df_pm_asset_ntf_occ_lvl DEFAULT 0,
        last_notified_dt       DATETIME2      NULL,
        snoozed_until          DATE           NULL,
        snooze_reason          NVARCHAR(1000) NULL,
        snoozed_by             NVARCHAR(100)  NULL,
        snoozed_by_employee_id BIGINT         NULL,
        snoozed_dt             DATETIME2      NULL,
        closed_dt              DATETIME2      NULL,
        close_reason           NVARCHAR(200)  NULL,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_ntf_occ_eby DEFAULT N'scheduler',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_ntf_occ_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        record_version         ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_asset_ntf_occ_key UNIQUE (organization_id, occurrence_key)
    );
    CREATE INDEX ix_pm_asset_ntf_occ_open ON grac_practice.asset_notification_occurrence(organization_id, status, trigger_date)
        INCLUDE (activity_code, object_type, object_id);
    CREATE INDEX ix_pm_asset_ntf_occ_object ON grac_practice.asset_notification_occurrence(object_type, object_id, status);
    PRINT '437: asset_notification_occurrence created.';
END
GO

IF OBJECT_ID('grac_practice.asset_notification_outbox','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_notification_outbox (
        notification_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_ntf_outbox PRIMARY KEY,
        organization_id            BIGINT         NOT NULL,
        occurrence_id              BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ntf_out_occ REFERENCES grac_practice.asset_notification_occurrence(occurrence_id),
        profile_id                 BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ntf_out_profile REFERENCES grac_practice.asset_notification_profile(profile_id),
        profile_version            INT            NOT NULL,
        stage_id                   BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_ntf_out_stage REFERENCES grac_practice.asset_notification_stage(stage_id),
        stage_kind                 NVARCHAR(12)   NOT NULL,
        stage_offset_days          INT            NOT NULL,
        stage_date                 DATE           NOT NULL,
        escalation_level           TINYINT        NOT NULL,
        notification_class         NVARCHAR(20)   NOT NULL,
        activity_code              NVARCHAR(40)   NOT NULL,
        object_type                NVARCHAR(30)   NOT NULL,
        object_id                  BIGINT         NOT NULL,
        asset_id                   BIGINT         NULL,
        contract_id                BIGINT         NULL,
        object_ref                 NVARCHAR(200)  NULL,
        object_title               NVARCHAR(400)  NULL,
        trigger_date               DATE           NOT NULL,
        severity_code              NVARCHAR(10)   NOT NULL,
        -- Recipient + snapshot (stays readable after a change of role, e-mail or employment).
        recipient_employee_id      BIGINT         NULL
            CONSTRAINT fk_pm_asset_ntf_out_rcp REFERENCES grac_practice.organization_employee(employee_id),
        recipient_name             NVARCHAR(200)  NULL,
        recipient_email            NVARCHAR(250)  NULL,
        recipient_manager_id       BIGINT         NULL,      -- reporting officer at enqueue (manager acknowledgement)
        role_id                    BIGINT         NULL,
        role_name                  NVARCHAR(200)  NULL,
        recipient_reason_code      NVARCHAR(30)   NOT NULL,
        channels                   NVARCHAR(60)   NOT NULL,  -- IN_APP,EMAIL,WEBHOOK
        ack_mode                   NVARCHAR(10)   NOT NULL,
        subject                    NVARCHAR(400)  NULL,
        body_text                  NVARCHAR(MAX)  NULL,
        -- Delivery (201 vocabulary): Pending / Sent / Failed / Suppressed.
        status_code                NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_ntf_out_status DEFAULT N'Pending'
            CONSTRAINT ck_pm_asset_ntf_out_status CHECK (status_code IN (N'Pending', N'Sent', N'Failed', N'Suppressed')),
        attempt_count              INT            NOT NULL CONSTRAINT df_pm_asset_ntf_out_attempts DEFAULT 0,
        last_attempt_dt            DATETIME2      NULL,
        failure_reason             NVARCHAR(1000) NULL,
        sent_dt                    DATETIME2      NULL,
        -- Read / acknowledgement (9.1.1).
        read_dt                    DATETIME2      NULL,
        acknowledged_dt            DATETIME2      NULL,
        ack_note                   NVARCHAR(1000) NULL,
        manager_ack_by_employee_id BIGINT         NULL,
        manager_ack_dt             DATETIME2      NULL,
        manager_ack_note           NVARCHAR(1000) NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_ntf_out_eby DEFAULT N'scheduler',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_ntf_out_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_asset_ntf_out_ack CHECK (ack_mode IN (N'NONE', N'READ', N'ACTION', N'MANAGER'))
    );
    -- 9.1.10: one notice per profile stage, occurrence and recipient.
    CREATE UNIQUE INDEX ux_pm_asset_ntf_out_dedupe ON grac_practice.asset_notification_outbox(occurrence_id, stage_id, recipient_employee_id);
    CREATE INDEX ix_pm_asset_ntf_out_recipient ON grac_practice.asset_notification_outbox(recipient_employee_id, read_dt, entered_dt DESC);
    CREATE INDEX ix_pm_asset_ntf_out_manager ON grac_practice.asset_notification_outbox(recipient_manager_id, manager_ack_dt)
        WHERE ack_mode = N'MANAGER';
    CREATE INDEX ix_pm_asset_ntf_out_org ON grac_practice.asset_notification_outbox(organization_id, status_code, entered_dt DESC);
    PRINT '437: asset_notification_outbox created.';
END
GO

IF OBJECT_ID('grac_practice.asset_scheduler_run','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_scheduler_run (
        run_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_sched_run PRIMARY KEY,
        organization_id        BIGINT         NULL,      -- NULL: every organization
        trigger_code           NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_sched_run_trigger CHECK (trigger_code IN (N'SCHEDULED', N'MANUAL')),
        started_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_sched_run_start DEFAULT SYSUTCDATETIME(),
        finished_dt            DATETIME2      NULL,
        result                 NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_sched_run_result DEFAULT N'RUNNING',
        organizations          INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_orgs DEFAULT 0,
        renewals_started       INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_ren DEFAULT 0,
        attestations_generated INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_att DEFAULT 0,
        occurrences_opened     INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_open DEFAULT 0,
        occurrences_closed     INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_close DEFAULT 0,
        notifications_queued   INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_ntf DEFAULT 0,
        error_count            INT            NOT NULL CONSTRAINT df_pm_asset_sched_run_err DEFAULT 0,
        error_text             NVARCHAR(MAX)  NULL,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_sched_run_eby DEFAULT N'scheduler'
    );
    CREATE INDEX ix_pm_asset_sched_run_dt ON grac_practice.asset_scheduler_run(started_dt DESC);
    PRINT '437: asset_scheduler_run created.';
END
GO

-- =====================================================================
-- 4. Helpers
-- =====================================================================
-- Severity of an object (D53): the criticality of the asset (Critical /
-- High / Medium / Low); a contract version takes the highest criticality of
-- the assets it covers; nothing known -> Medium.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ntf_asset_severity (@asset_id BIGINT)
RETURNS NVARCHAR(10)
AS
BEGIN
    RETURN ISNULL((SELECT CASE c.criticality_code WHEN N'Critical' THEN N'CRITICAL' WHEN N'High' THEN N'HIGH'
                                                  WHEN N'Low' THEN N'LOW' ELSE N'MEDIUM' END
                     FROM grac_practice.organization_dependency_asset a
                     LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
                    WHERE a.asset_id = @asset_id), N'MEDIUM');
END
GO

CREATE OR ALTER FUNCTION grac_practice.fn_asset_ntf_version_severity (@version_id BIGINT)
RETURNS NVARCHAR(10)
AS
BEGIN
    DECLARE @rank INT = (SELECT MIN(CASE c.criticality_code WHEN N'Critical' THEN 1 WHEN N'High' THEN 2 WHEN N'Medium' THEN 3
                                                            WHEN N'Low' THEN 4 ELSE 3 END)
                           FROM grac_practice.asset_contract_coverage cc
                           JOIN grac_practice.organization_dependency_asset a ON a.asset_id = cc.asset_id
                           LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
                          WHERE cc.version_id = @version_id AND cc.coverage_state = N'COVERED');
    RETURN CASE @rank WHEN 1 THEN N'CRITICAL' WHEN 2 THEN N'HIGH' WHEN 4 THEN N'LOW' ELSE N'MEDIUM' END;
END
GO

-- Contract type -> renewal activity (9.1.3 rows).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ntf_contract_activity (@contract_type NVARCHAR(160))
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN CASE WHEN @contract_type IN (N'WARRANTY', N'AMC', N'CMC', N'INSURANCE') THEN N'WARRANTY_AMC' ELSE N'MAJOR_CONTRACT' END;
END
GO

-- Date of a stage: reminder N days before the trigger date, due on it,
-- escalation N days after. Working days only (D57): a Saturday / Sunday
-- moves to the next Monday (1900-01-01 was a Monday, so the result does not
-- depend on DATEFIRST).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ntf_stage_date
    (@trigger_date DATE, @stage_kind NVARCHAR(12), @offset_days INT, @working_days_only BIT)
RETURNS DATE
AS
BEGIN
    DECLARE @d DATE = CASE @stage_kind WHEN N'REMINDER' THEN DATEADD(DAY, -@offset_days, @trigger_date)
                                       WHEN N'DUE' THEN @trigger_date
                                       ELSE DATEADD(DAY, @offset_days, @trigger_date) END;
    IF @working_days_only = 1
        SET @d = CASE DATEDIFF(DAY, CONVERT(DATE, '19000101', 112), @d) % 7
                      WHEN 5 THEN DATEADD(DAY, 2, @d) WHEN 6 THEN DATEADD(DAY, 1, @d) ELSE @d END;
    RETURN @d;
END
GO

-- The profile that applies: the active, effective override for the severity,
-- else the active, effective default of the activity.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ntf_profile_for
    (@organization_id BIGINT, @activity_code NVARCHAR(40), @severity_code NVARCHAR(10), @on DATE)
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 p.profile_id AS ProfileId, p.version_no AS VersionNo, p.ack_mode AS AckMode, p.snooze_allowed AS SnoozeAllowed,
           p.working_days_only AS WorkingDaysOnly,
           CONCAT_WS(N',', CASE WHEN p.channel_in_app = 1 THEN N'IN_APP' END, CASE WHEN p.channel_email = 1 THEN N'EMAIL' END,
                     CASE WHEN p.channel_webhook = 1 THEN N'WEBHOOK' END) AS Channels
      FROM grac_practice.asset_notification_profile p
     WHERE p.organization_id = @organization_id AND p.activity_code = @activity_code AND p.is_active = 1
       AND (p.severity_code IS NULL OR p.severity_code = @severity_code)
       AND (p.effective_from IS NULL OR p.effective_from <= @on)
       AND (p.effective_to IS NULL OR p.effective_to >= @on)
     ORDER BY CASE WHEN p.severity_code IS NULL THEN 1 ELSE 0 END, p.profile_id;
GO

-- Copies the default profiles, stages, recipients and (the first time) the
-- escalation matrix into an organization (D52). Insert-only: an activity
-- that already has a profile in the organization is left alone.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_defaults_ensure
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;
    -- Nothing to add: every activity has a profile and no copied default is
    -- missing its stages (a first 437 run could copy profiles before the
    -- default stages were seeded).
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity a
                    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile p
                                       WHERE p.organization_id = @organization_id AND p.activity_code = a.activity_code))
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile p
                        WHERE p.organization_id = @organization_id AND p.entered_by = N'seed-437'
                          AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_stage s WHERE s.profile_id = p.profile_id))
        RETURN;

    DECLARE @first BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile WHERE organization_id = @organization_id)
                              THEN 0 ELSE 1 END;
    DECLARE @new TABLE (profile_id BIGINT NOT NULL, activity_code NVARCHAR(40) NOT NULL);

    BEGIN TRAN;
    INSERT grac_practice.asset_notification_profile (organization_id, profile_code, profile_name, activity_code, entered_by)
    OUTPUT inserted.profile_id, inserted.activity_code INTO @new (profile_id, activity_code)
    SELECT @organization_id, a.activity_code, a.activity_name, a.activity_code, N'seed-437'
      FROM grac_practice.asset_notification_activity a
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile p
                        WHERE p.organization_id = @organization_id AND p.activity_code = a.activity_code)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile p
                        WHERE p.organization_id = @organization_id AND p.profile_code = a.activity_code);
    INSERT @new (profile_id, activity_code)
    SELECT p.profile_id, p.activity_code
      FROM grac_practice.asset_notification_profile p
     WHERE p.organization_id = @organization_id AND p.entered_by = N'seed-437'
       AND NOT EXISTS (SELECT 1 FROM @new n WHERE n.profile_id = p.profile_id)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_stage s WHERE s.profile_id = p.profile_id);

    INSERT grac_practice.asset_notification_stage (profile_id, stage_kind, offset_days, escalation_level, notification_class, entered_by)
    SELECT n.profile_id, d.stage_kind, d.offset_days, d.escalation_level, d.notification_class, N'seed-437'
      FROM @new n
      JOIN grac_practice.asset_notification_default_stage d ON d.activity_code = n.activity_code;

    INSERT grac_practice.asset_notification_stage_recipient (stage_id, recipient_code, entered_by)
    SELECT s.stage_id, r.recipient_code, N'seed-437'
      FROM @new n
      JOIN grac_practice.asset_notification_stage s ON s.profile_id = n.profile_id
      JOIN grac_practice.asset_notification_default_recipient r ON r.activity_code = n.activity_code AND r.stage_kind = s.stage_kind;

    IF @first = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_escalation_matrix WHERE organization_id = @organization_id)
        INSERT grac_practice.asset_escalation_matrix (organization_id, severity_code, escalation_level, recipient_code, entered_by)
        SELECT @organization_id, severity_code, escalation_level, recipient_code, N'seed-437'
          FROM grac_practice.asset_escalation_matrix_default;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-notification-defaults', @organization_id, N'CREATE', NULL,
            (SELECT (SELECT activity_code AS activityCode, profile_id AS profileId FROM @new FOR JSON PATH) AS profiles,
                    @first AS matrixSeeded FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- Parties of an occurrence, as employees (D52). The caller creates
--   #np (party_code NVARCHAR(30) NOT NULL, employee_id BIGINT NOT NULL)
-- Person-or-team fields (E:<id> / T:<id>) expand to the active members of
-- the team. MANAGER / DEPARTMENT_HEAD derive from the activity owner.
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
PRINT '437: helpers created.';
GO

-- =====================================================================
-- 5. Re-issued for the scheduler (437 lines marked; the rest is verbatim)
-- =====================================================================
-- 431 body + @scheduled / @suppress_result / @out_generated.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_attestation_generate
    @organization_id BIGINT,
    @campaign_type   NVARCHAR(20)  = N'PERIODIC',
    @campaign_name   NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @due_date        DATE          = NULL,
    @actor           NVARCHAR(100) = N'system',
    @scheduled       BIT           = 0,        -- 437: scheduler run (no campaign row when nothing was generated or marked overdue)
    @suppress_result BIT           = 0,        -- 437: called by the scheduler (no result set)
    @out_generated   INT           = NULL OUTPUT
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
    SET @out_generated = @generated;                                                  -- 437
    IF @scheduled = 1 AND @campaign_type = N'PERIODIC' AND @generated = 0 AND @overdue = 0   -- 437
    BEGIN
        DELETE grac_practice.asset_attestation_campaign WHERE campaign_id = @campaign_id;
        COMMIT;
        RETURN;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-attestation-campaign', @campaign_id, N'GENERATE', NULL,
            (SELECT @campaign_type AS campaignType, @campaign_name AS campaignName, @asset_type_id AS assetTypeId, @due_date AS dueDate,
                    @generated AS generated, @skipped AS skipped, @overdue AS overdueMarked FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    IF @suppress_result = 0                                                           -- 437
    SELECT @campaign_id AS CampaignId, @generated AS Generated, @skipped AS Skipped, @overdue AS OverdueMarked;
END
GO
PRINT '437: sp_asset_attestation_generate re-issued.';
GO

-- 436 body + @suppress_result / @out_renewal_id.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_contract_renewal_start
    @organization_id   BIGINT,
    @contract_id       BIGINT,
    @renewal_type      NVARCHAR(20)   = N'RENEWAL',
    @notes             NVARCHAR(2000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @suppress_result   BIT            = 0,        -- 437: called by the scheduler (no result set)
    @out_renewal_id    BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @renewal_type = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@renewal_type)), N''), N'RENEWAL'));
    SET @notes = NULLIF(LTRIM(RTRIM(@notes)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54570, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract WHERE contract_id = @contract_id AND organization_id = @organization_id)
        THROW 54571, 'Contract not found for this organization.', 1;
    EXEC grac_practice.sp_asset_contract_sync @organization_id = @organization_id, @contract_id = @contract_id, @actor = @actor;

    DECLARE @cstatus NVARCHAR(20), @number NVARCHAR(60), @prior BIGINT;
    SELECT @cstatus = contract_status, @number = contract_number, @prior = current_version_id
      FROM grac_practice.asset_contract WHERE contract_id = @contract_id;
    IF @cstatus = N'TERMINATED'
        THROW 54591, 'The contract is terminated; it cannot be renewed.', 1;
    IF @renewal_type NOT IN (N'RENEWAL', N'EXTENSION', N'REBID', N'REPLACEMENT', N'NON_RENEWAL')
        THROW 54577, 'Select the renewal type: renewal, extension, rebid, replacement or non-renewal.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND is_open = 1)
        THROW 54572, 'The contract already has an open renewal; finish or cancel it first.', 1;
    DECLARE @pno INT, @pend DATE, @notice DATE, @decision DATE;
    SELECT @pno = v.version_no, @pend = v.effective_end, @notice = v.notice_date, @decision = v.decision_date
      FROM grac_practice.asset_contract_version v
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
     WHERE v.version_id = @prior AND s.status_code IN (N'APPROVED', N'ACTIVE', N'EXPIRED', N'SUPERSEDED') AND v.version_type <> N'TERMINATION';
    IF @pno IS NULL
        THROW 54573, 'The contract has no approved version to renew yet.', 1;

    -- 9.1.5: the earliest of notice date, decision date and end minus the expiring window (435).
    DECLARE @win INT = ISNULL((SELECT expiring_window_days FROM grac_practice.asset_coverage_settings WHERE organization_id = @organization_id), 30);
    DECLARE @due DATE = (SELECT MIN(x.d) FROM (VALUES (DATEADD(DAY, -@win, @pend)), (@notice), (@decision)) x(d));
    DECLARE @seq INT = 1 + (SELECT COUNT(*) FROM grac_practice.asset_contract_renewal WHERE contract_id = @contract_id AND prior_version_id = @prior);
    DECLARE @key NVARCHAR(120) = CONCAT(N'CR-', @number, N'-V', @pno, N'-', @seq);
    DECLARE @id BIGINT;

    BEGIN TRAN;
    INSERT grac_practice.asset_contract_renewal
        (organization_id, contract_id, occurrence_key, prior_version_id, renewal_type, current_status_id, is_open, due_date, old_expiry,
         notes, started_by_employee_id, entered_by)
    VALUES (@organization_id, @contract_id, @key, @prior, @renewal_type,
            grac_practice.fn_get_entity_status_id(N'ContractRenewal', N'OPEN'), 1, @due, @pend, @notes, @actor_employee_id, @actor);
    SET @id = SCOPE_IDENTITY();
    EXEC grac_practice.sp_asset_contract_renewal_move @renewal_id = @id, @from_code = NULL, @to_code = N'OPEN',
         @reason_code = @renewal_type, @reason_text = @notes, @actor_employee_id = @actor_employee_id, @actor = @actor;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-contract-renewal', @id, N'CREATE', NULL,
            (SELECT @contract_id AS contractId, @key AS occurrenceKey, @prior AS priorVersionId, @renewal_type AS renewalType,
                    @due AS dueDate, @pend AS oldExpiry FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SET @out_renewal_id = @id;                                                        -- 437
    IF @suppress_result = 0                                                           -- 437
    SELECT @id AS RenewalId, N'OPEN' AS Result;
END
GO
PRINT '437: sp_asset_contract_renewal_start re-issued.';
GO

-- =====================================================================
-- 6. Notification sweep for one organization (D50, D51, D53)
-- =====================================================================
-- 1. Due events of the sources wired today -> #due (one occurrence key per
--    activity, object, reference and trigger date -- 7.1.5).
-- 2. Open occurrences that are no longer due close: SUPERSEDED when the same
--    object is due on another date / reference (9.1.10 recalculation; what
--    was sent is kept), else COMPLETED. A completed occurrence whose key is
--    due again reopens (its stage history is kept, so nothing repeats).
-- 3. New keys open an occurrence.
-- 4. For every open, not snoozed occurrence: the latest stage whose date has
--    been reached fires once -- earlier stages that were never reached are
--    not replayed (D51). Recipients: the stage recipients plus the
--    escalation matrix for the severity and level, resolved now (ownership
--    changes take effect on the next notice). One outbox row per occurrence,
--    stage and recipient (9.1.10).
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
PRINT '437: sp_asset_notification_sweep created.';
GO

-- =====================================================================
-- 7. Scheduler pass (the existing TaskNotificationWorker, or Run now)
-- =====================================================================
-- For every organization with assets or contracts (or the one named):
--   a. default profiles / matrix copied in (D52)
--   b. contract effective dates applied (434 sync -- D35 had no scheduler)
--   c. periodic attestation run (431; D59)
--   d. renewal occurrences started when the first reminder stage of the
--      profile of the contract is reached (D58; 7.1.1 step 24, 7.1.5)
--   e. notification sweep
-- One run at a time (application lock); failures are logged per
-- organization / item and the pass continues.
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
               0 AS ErrorCount, N'Another scheduler run is in progress.' AS ErrorText;
        RETURN;
    END

    DECLARE @run BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    BEGIN TRY
    INSERT grac_practice.asset_scheduler_run (organization_id, trigger_code, entered_by) VALUES (@organization_id, @trigger_code, @actor);
    SET @run = SCOPE_IDENTITY();

    DECLARE @orgs INT = 0, @ren INT = 0, @att INT = 0, @opened INT = 0, @closed INT = 0, @queued INT = 0, @errors INT = 0,
            @err NVARCHAR(MAX) = NULL,
            @o INT, @c INT, @q INT, @e INT, @et NVARCHAR(MAX), @gen INT, @rid BIGINT;

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
           occurrences_closed = @closed, notifications_queued = @queued, error_count = @errors, error_text = @err
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
           error_count AS ErrorCount, error_text AS ErrorText
      FROM grac_practice.asset_scheduler_run WHERE run_id = @run;
END
GO
PRINT '437: sp_asset_scheduler_run created.';
GO

-- =====================================================================
-- 8. Configuration (Asset Notifications -> Profiles / Escalation matrix)
-- =====================================================================
-- 1. activities  2. recipient types  3. profiles  4. stages  5. stage
-- recipients  6. escalation matrix  7. organization roles  8. employees.
-- Copies the defaults in first (D52), as the 434 / 435 readers apply the
-- contract dates.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_config_get
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_asset_notification_defaults_ensure @organization_id = @organization_id, @actor = @actor;

    SELECT activity_code AS ActivityCode, activity_name AS ActivityName, trigger_basis AS TriggerBasis,
           trigger_description AS TriggerDescription, typical_recipients AS TypicalRecipients,
           source_available AS SourceAvailable, source_note AS SourceNote
      FROM grac_practice.asset_notification_activity ORDER BY display_order;

    SELECT recipient_code AS RecipientCode, recipient_name AS RecipientName, description AS Description
      FROM grac_practice.asset_notification_recipient_type ORDER BY display_order;

    SELECT p.profile_id AS ProfileId, p.profile_code AS ProfileCode, p.profile_name AS ProfileName, p.activity_code AS ActivityCode,
           a.activity_name AS ActivityName, a.trigger_basis AS TriggerBasis, a.source_available AS SourceAvailable,
           p.severity_code AS SeverityCode, p.owner_employee_id AS OwnerEmployeeId, ow.employee_name AS OwnerName,
           p.effective_from AS EffectiveFrom, p.effective_to AS EffectiveTo, p.is_active AS IsActive, p.ack_mode AS AckMode,
           p.channel_in_app AS ChannelInApp, p.channel_email AS ChannelEmail, p.channel_webhook AS ChannelWebhook,
           p.snooze_allowed AS SnoozeAllowed, p.working_days_only AS WorkingDaysOnly, p.version_no AS VersionNo,
           (SELECT COUNT(*) FROM grac_practice.asset_notification_stage s WHERE s.profile_id = p.profile_id AND s.is_active = 1) AS StageCount,
           ISNULL(p.updated_dt, p.entered_dt) AS LastChangedDt, ISNULL(p.updated_by, p.entered_by) AS LastChangedBy,
           CONVERT(BIGINT, p.record_version) AS RecordVersion
      FROM grac_practice.asset_notification_profile p
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = p.activity_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = p.owner_employee_id
     WHERE p.organization_id = @organization_id
     ORDER BY a.display_order, CASE WHEN p.severity_code IS NULL THEN 0 ELSE 1 END, p.is_active DESC, p.profile_name;

    SELECT s.profile_id AS ProfileId, s.stage_id AS StageId, s.stage_kind AS StageKind, s.offset_days AS OffsetDays,
           s.escalation_level AS EscalationLevel, s.notification_class AS NotificationClass
      FROM grac_practice.asset_notification_stage s
      JOIN grac_practice.asset_notification_profile p ON p.profile_id = s.profile_id
     WHERE p.organization_id = @organization_id AND s.is_active = 1
     ORDER BY s.profile_id, CASE s.stage_kind WHEN N'REMINDER' THEN 0 WHEN N'DUE' THEN 1 ELSE 2 END,
              CASE WHEN s.stage_kind = N'REMINDER' THEN -s.offset_days ELSE s.offset_days END;

    SELECT r.stage_id AS StageId, r.recipient_code AS RecipientCode, r.role_id AS RoleId, ro.role_name AS RoleName
      FROM grac_practice.asset_notification_stage_recipient r
      JOIN grac_practice.asset_notification_stage s ON s.stage_id = r.stage_id AND s.is_active = 1
      JOIN grac_practice.asset_notification_profile p ON p.profile_id = s.profile_id
      LEFT JOIN grac_practice.organization_role ro ON ro.role_id = r.role_id
     WHERE p.organization_id = @organization_id
     ORDER BY r.stage_id, r.recipient_code, ro.role_name;

    SELECT m.severity_code AS SeverityCode, m.escalation_level AS EscalationLevel, m.recipient_code AS RecipientCode,
           m.role_id AS RoleId, ro.role_name AS RoleName
      FROM grac_practice.asset_escalation_matrix m
      LEFT JOIN grac_practice.organization_role ro ON ro.role_id = m.role_id
     WHERE m.organization_id = @organization_id
     ORDER BY CASE m.severity_code WHEN N'LOW' THEN 1 WHEN N'MEDIUM' THEN 2 WHEN N'HIGH' THEN 3 ELSE 4 END, m.escalation_level,
              m.recipient_code, ro.role_name;

    SELECT role_id AS RoleId, role_name AS RoleName
      FROM grac_practice.organization_role
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY role_name;

    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
END
GO

-- Save a profile with its stages and stage recipients (9.1.1).
-- @stages_json: [{"stageKind":"REMINDER|DUE|ESCALATION","offsetDays":30,
--   "escalationLevel":1,"notificationClass":"REMINDER",
--   "recipients":[{"recipientCode":"ASSET_OWNER"},{"recipientCode":"ROLE","roleId":7}]}]
-- Stages are matched by kind + days: kept, updated, deactivated or added
-- (notices already sent keep pointing at their stage). Every save raises
-- the profile version recorded on later notices (9.1.10).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_profile_save
    @organization_id         BIGINT,
    @profile_id              BIGINT         = NULL,
    @activity_code           NVARCHAR(40)   = NULL,
    @profile_name            NVARCHAR(200)  = NULL,
    @severity_code           NVARCHAR(10)   = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @is_active               BIT            = 1,
    @ack_mode                NVARCHAR(10)   = N'READ',
    @channel_in_app          BIT            = 1,
    @channel_email           BIT            = 0,
    @channel_webhook         BIT            = 0,
    @snooze_allowed          BIT            = 1,
    @working_days_only       BIT            = 0,
    @stages_json             NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @profile_name = NULLIF(LTRIM(RTRIM(@profile_name)), N'');
    SET @severity_code = NULLIF(UPPER(LTRIM(RTRIM(@severity_code))), N'');
    SET @ack_mode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@ack_mode)), N''), N'READ'));
    SET @activity_code = NULLIF(UPPER(LTRIM(RTRIM(@activity_code))), N'');
    SELECT @is_active = ISNULL(@is_active, 1), @channel_in_app = ISNULL(@channel_in_app, 0), @channel_email = ISNULL(@channel_email, 0),
           @channel_webhook = ISNULL(@channel_webhook, 0), @snooze_allowed = ISNULL(@snooze_allowed, 0),
           @working_days_only = ISNULL(@working_days_only, 0);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;
    DECLARE @before NVARCHAR(MAX);
    IF @profile_id IS NOT NULL
    BEGIN
        SELECT @activity_code = activity_code FROM grac_practice.asset_notification_profile
         WHERE profile_id = @profile_id AND organization_id = @organization_id;
        IF @@ROWCOUNT = 0 THROW 54611, 'Notification profile not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile
                                                                 WHERE profile_id = @profile_id
                                                                   AND CONVERT(BIGINT, record_version) = @expected_record_version)
            THROW 54623, 'The profile was changed by someone else; reload it and try again.', 1;
    END
    IF @activity_code IS NULL OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_activity WHERE activity_code = @activity_code)
        THROW 54612, 'Select the activity of the profile.', 1;
    IF @profile_name IS NULL
        THROW 54613, 'Enter the profile name.', 1;
    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')
        THROW 54614, 'Severity must be Low, Medium, High or Critical (or empty for the default profile).', 1;
    IF @owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                       WHERE employee_id = @owner_employee_id AND organization_id = @organization_id
                                                         AND status = N'Active')
        THROW 54615, 'The profile owner must be an active employee of the organization.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54616, 'The effective end date cannot be before the start date.', 1;
    IF @ack_mode NOT IN (N'NONE', N'READ', N'ACTION', N'MANAGER')
        THROW 54617, 'Acknowledgement must be None, Read, Action or Manager.', 1;
    IF @channel_in_app = 0 AND @channel_email = 0 AND @channel_webhook = 0
        THROW 54634, 'Select at least one channel.', 1;
    IF @stages_json IS NULL OR ISJSON(@stages_json) = 0
        THROW 54618, 'The stages could not be read.', 1;

    DECLARE @st TABLE (seq INT NOT NULL PRIMARY KEY, stage_kind NVARCHAR(12) NULL, offset_days INT NULL, escalation_level INT NULL,
                       notification_class NVARCHAR(20) NULL, recipients NVARCHAR(MAX) NULL);
    INSERT @st (seq, stage_kind, offset_days, escalation_level, notification_class, recipients)
    SELECT CAST(j.[key] AS INT), UPPER(LTRIM(RTRIM(w.stageKind))), w.offsetDays, w.escalationLevel,
           UPPER(NULLIF(LTRIM(RTRIM(w.notificationClass)), N'')), w.recipients
      FROM OPENJSON(@stages_json) j
     CROSS APPLY OPENJSON(j.[value]) WITH (stageKind NVARCHAR(12) '$.stageKind', offsetDays INT '$.offsetDays',
                                           escalationLevel INT '$.escalationLevel', notificationClass NVARCHAR(20) '$.notificationClass',
                                           recipients NVARCHAR(MAX) '$.recipients' AS JSON) w;
    IF NOT EXISTS (SELECT 1 FROM @st)
        THROW 54618, 'Add at least one reminder, due or escalation stage.', 1;
    UPDATE @st SET offset_days = CASE WHEN stage_kind = N'DUE' THEN 0 ELSE offset_days END,
                   escalation_level = CASE WHEN stage_kind IN (N'REMINDER', N'DUE') THEN 0 ELSE escalation_level END,
                   notification_class = ISNULL(notification_class, CASE WHEN stage_kind = N'ESCALATION' THEN N'ESCALATION' ELSE N'REMINDER' END);
    IF EXISTS (SELECT 1 FROM @st
                WHERE stage_kind NOT IN (N'REMINDER', N'DUE', N'ESCALATION') OR stage_kind IS NULL
                   OR offset_days IS NULL OR offset_days < 0 OR offset_days > 730
                   OR (stage_kind = N'REMINDER' AND offset_days = 0)
                   OR (stage_kind = N'ESCALATION' AND (escalation_level IS NULL OR escalation_level NOT BETWEEN 1 AND 3))
                   OR notification_class NOT IN (N'INFORMATIONAL', N'REMINDER', N'ESCALATION', N'CRITICAL'))
        THROW 54619, 'Each stage needs a kind (reminder, due, escalation), days between 0 and 730 (reminders at least 1), a level 1-3 for an escalation and a class.', 1;
    IF EXISTS (SELECT stage_kind, offset_days FROM @st GROUP BY stage_kind, offset_days HAVING COUNT(*) > 1)
        THROW 54620, 'Two stages of the same kind fall on the same day.', 1;

    DECLARE @rc TABLE (seq INT NOT NULL, recipient_code NVARCHAR(30) NULL, role_id BIGINT NULL);
    INSERT @rc (seq, recipient_code, role_id)
    SELECT s.seq, UPPER(LTRIM(RTRIM(r.recipientCode))), r.roleId
      FROM @st s
     CROSS APPLY OPENJSON(ISNULL(s.recipients, N'[]')) WITH (recipientCode NVARCHAR(30) '$.recipientCode', roleId BIGINT '$.roleId') r;
    UPDATE @rc SET role_id = NULL WHERE recipient_code <> N'ROLE';
    IF EXISTS (SELECT 1 FROM @rc r
                WHERE r.recipient_code IS NULL
                   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_recipient_type t WHERE t.recipient_code = r.recipient_code)
                   OR (r.recipient_code = N'ROLE' AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role o
                                                                   WHERE o.role_id = r.role_id AND o.organization_id = @organization_id
                                                                     AND o.status = N'Active')))
        THROW 54621, 'A recipient is not a known recipient type, or a role recipient is not an active role of the organization.', 1;
    IF @is_active = 1 AND EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile
                                   WHERE organization_id = @organization_id AND activity_code = @activity_code AND is_active = 1
                                     AND ((severity_code IS NULL AND @severity_code IS NULL) OR severity_code = @severity_code)
                                     AND profile_id <> ISNULL(@profile_id, -1))
        THROW 54622, 'An active profile already exists for this activity and severity; deactivate it first.', 1;

    IF @profile_id IS NOT NULL
        SET @before = (SELECT p.profile_name AS profileName, p.severity_code AS severityCode, p.owner_employee_id AS ownerEmployeeId,
                              p.effective_from AS effectiveFrom, p.effective_to AS effectiveTo, p.is_active AS isActive, p.ack_mode AS ackMode,
                              p.channel_in_app AS channelInApp, p.channel_email AS channelEmail, p.channel_webhook AS channelWebhook,
                              p.snooze_allowed AS snoozeAllowed, p.working_days_only AS workingDaysOnly, p.version_no AS versionNo,
                              (SELECT s.stage_kind AS stageKind, s.offset_days AS offsetDays, s.escalation_level AS escalationLevel,
                                      s.notification_class AS notificationClass,
                                      (SELECT r.recipient_code AS recipientCode, r.role_id AS roleId
                                         FROM grac_practice.asset_notification_stage_recipient r WHERE r.stage_id = s.stage_id FOR JSON PATH) AS recipients
                                 FROM grac_practice.asset_notification_stage s WHERE s.profile_id = p.profile_id AND s.is_active = 1
                                FOR JSON PATH) AS stages
                         FROM grac_practice.asset_notification_profile p WHERE p.profile_id = @profile_id
                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @id BIGINT = @profile_id, @code NVARCHAR(60), @n INT = 1;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        SET @code = CONCAT(@activity_code, N'-', ISNULL(@severity_code, N'DEFAULT'));
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_notification_profile WHERE organization_id = @organization_id AND profile_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = CONCAT(@activity_code, N'-', ISNULL(@severity_code, N'DEFAULT'), N'-', @n);
        END
        INSERT grac_practice.asset_notification_profile
            (organization_id, profile_code, profile_name, activity_code, severity_code, owner_employee_id, effective_from, effective_to,
             is_active, ack_mode, channel_in_app, channel_email, channel_webhook, snooze_allowed, working_days_only, entered_by)
        VALUES (@organization_id, @code, @profile_name, @activity_code, @severity_code, @owner_employee_id, @effective_from, @effective_to,
                @is_active, @ack_mode, @channel_in_app, @channel_email, @channel_webhook, @snooze_allowed, @working_days_only, @actor);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_notification_profile
           SET profile_name = @profile_name, severity_code = @severity_code, owner_employee_id = @owner_employee_id,
               effective_from = @effective_from, effective_to = @effective_to, is_active = @is_active, ack_mode = @ack_mode,
               channel_in_app = @channel_in_app, channel_email = @channel_email, channel_webhook = @channel_webhook,
               snooze_allowed = @snooze_allowed, working_days_only = @working_days_only, version_no = version_no + 1,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE profile_id = @id;
    END

    UPDATE s
       SET is_active = CASE WHEN x.seq IS NULL THEN 0 ELSE 1 END,
           escalation_level = ISNULL(x.escalation_level, s.escalation_level),
           notification_class = ISNULL(x.notification_class, s.notification_class),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_stage s
      LEFT JOIN @st x ON x.stage_kind = s.stage_kind AND x.offset_days = s.offset_days
     WHERE s.profile_id = @id;
    INSERT grac_practice.asset_notification_stage (profile_id, stage_kind, offset_days, escalation_level, notification_class, entered_by)
    SELECT @id, x.stage_kind, x.offset_days, x.escalation_level, x.notification_class, @actor
      FROM @st x
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_stage s
                        WHERE s.profile_id = @id AND s.stage_kind = x.stage_kind AND s.offset_days = x.offset_days);

    DELETE r
      FROM grac_practice.asset_notification_stage_recipient r
      JOIN grac_practice.asset_notification_stage s ON s.stage_id = r.stage_id
     WHERE s.profile_id = @id;
    INSERT grac_practice.asset_notification_stage_recipient (stage_id, recipient_code, role_id, entered_by)
    SELECT DISTINCT s.stage_id, r.recipient_code, r.role_id, @actor
      FROM @rc r
      JOIN @st x ON x.seq = r.seq
      JOIN grac_practice.asset_notification_stage s ON s.profile_id = @id AND s.stage_kind = x.stage_kind AND s.offset_days = x.offset_days;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-notification-profile', @id, CASE WHEN @profile_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @activity_code AS activityCode, @profile_name AS profileName, @severity_code AS severityCode,
                    @owner_employee_id AS ownerEmployeeId, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                    @is_active AS isActive, @ack_mode AS ackMode, @channel_in_app AS channelInApp, @channel_email AS channelEmail,
                    @channel_webhook AS channelWebhook, @snooze_allowed AS snoozeAllowed, @working_days_only AS workingDaysOnly,
                    JSON_QUERY(@stages_json) AS stages FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS ProfileId, N'SAVED' AS Result;
END
GO

-- Replace the escalation matrix entries of one severity (9.1.8).
-- @entries_json: [{"escalationLevel":0,"recipientCode":"ACTIVITY_OWNER"},{"escalationLevel":2,"recipientCode":"ROLE","roleId":7}]
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_escalation_matrix_save
    @organization_id BIGINT,
    @severity_code   NVARCHAR(10),
    @entries_json    NVARCHAR(MAX) = NULL,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @severity_code = UPPER(LTRIM(RTRIM(ISNULL(@severity_code, N''))));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;
    IF @severity_code NOT IN (N'LOW', N'MEDIUM', N'HIGH', N'CRITICAL')
        THROW 54614, 'Severity must be Low, Medium, High or Critical.', 1;
    IF ISJSON(ISNULL(@entries_json, N'[]')) = 0
        THROW 54624, 'The escalation matrix entries could not be read.', 1;
    DECLARE @e TABLE (escalation_level INT NULL, recipient_code NVARCHAR(30) NULL, role_id BIGINT NULL);
    INSERT @e (escalation_level, recipient_code, role_id)
    SELECT w.escalationLevel, UPPER(LTRIM(RTRIM(w.recipientCode))), w.roleId
      FROM OPENJSON(ISNULL(@entries_json, N'[]')) WITH (escalationLevel INT '$.escalationLevel', recipientCode NVARCHAR(30) '$.recipientCode',
                                                         roleId BIGINT '$.roleId') w;
    UPDATE @e SET role_id = NULL WHERE recipient_code <> N'ROLE';
    IF EXISTS (SELECT 1 FROM @e x
                WHERE x.escalation_level IS NULL OR x.escalation_level NOT BETWEEN 0 AND 3 OR x.recipient_code IS NULL
                   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_recipient_type t WHERE t.recipient_code = x.recipient_code)
                   OR (x.recipient_code = N'ROLE' AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role o
                                                                   WHERE o.role_id = x.role_id AND o.organization_id = @organization_id
                                                                     AND o.status = N'Active')))
        THROW 54624, 'Each entry needs a level 0-3 and a known recipient type; a role must be an active role of the organization.', 1;

    DECLARE @before NVARCHAR(MAX) = (SELECT escalation_level AS escalationLevel, recipient_code AS recipientCode, role_id AS roleId
                                       FROM grac_practice.asset_escalation_matrix
                                      WHERE organization_id = @organization_id AND severity_code = @severity_code FOR JSON PATH);
    BEGIN TRAN;
    DELETE grac_practice.asset_escalation_matrix WHERE organization_id = @organization_id AND severity_code = @severity_code;
    INSERT grac_practice.asset_escalation_matrix (organization_id, severity_code, escalation_level, recipient_code, role_id, entered_by)
    SELECT DISTINCT @organization_id, @severity_code, escalation_level, recipient_code, role_id, @actor FROM @e;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-escalation-matrix', @organization_id, N'UPDATE', @before,
            (SELECT @severity_code AS severityCode, JSON_QUERY(ISNULL(@entries_json, N'[]')) AS entries FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO
PRINT '437: configuration procedures created.';
GO

-- =====================================================================
-- 9. Occurrences, notification log, delivery, runs (administrators)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_occurrence_list
    @organization_id BIGINT,
    @status          NVARCHAR(12)  = N'OPEN',      -- OPEN | COMPLETED | SUPERSEDED | ALL
    @activity_code   NVARCHAR(40)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'OPEN'));
    SET @activity_code = NULLIF(LTRIM(RTRIM(@activity_code)), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.activity_code AS ActivityCode,
           a.activity_name AS ActivityName, o.object_type AS ObjectType, o.object_id AS ObjectId, o.asset_id AS AssetId,
           o.contract_id AS ContractId, o.object_ref AS ObjectRef, o.object_title AS ObjectTitle, o.trigger_date AS TriggerDate,
           DATEDIFF(DAY, @today, o.trigger_date) AS DaysToTrigger, o.severity_code AS SeverityCode, o.status AS Status,
           o.last_stage_date AS LastStageDate, ls.stage_kind AS LastStageKind, ls.offset_days AS LastStageOffsetDays,
           o.escalation_level AS EscalationLevel, o.last_notified_dt AS LastNotifiedDt, o.snoozed_until AS SnoozedUntil,
           o.snooze_reason AS SnoozeReason, o.closed_dt AS ClosedDt, o.close_reason AS CloseReason,
           (SELECT COUNT(*) FROM grac_practice.asset_notification_outbox x WHERE x.occurrence_id = o.occurrence_id) AS NotificationCount,
           ns.NextStageDate,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_notification_occurrence o
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = o.activity_code
      LEFT JOIN grac_practice.asset_notification_stage ls ON ls.stage_id = o.last_stage_id
     OUTER APPLY (SELECT MIN(sd.d) AS NextStageDate      -- aggregate over the applied column only (Msg 8124)
                    FROM grac_practice.fn_asset_ntf_profile_for(o.organization_id, o.activity_code, o.severity_code, @today) f
                    JOIN grac_practice.asset_notification_profile p ON p.profile_id = f.ProfileId
                    JOIN grac_practice.asset_notification_stage s ON s.profile_id = p.profile_id AND s.is_active = 1
                   CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(o.trigger_date, s.stage_kind, s.offset_days, p.working_days_only) AS d) sd
                   WHERE o.status = N'OPEN'
                     AND sd.d > ISNULL(o.last_stage_date, DATEADD(DAY, -1, @today))) ns
     WHERE o.organization_id = @organization_id
       AND (@status = N'ALL' OR o.status = @status)
       AND (@activity_code IS NULL OR o.activity_code = @activity_code)
       AND (@search IS NULL OR o.object_ref LIKE N'%' + @search + N'%' OR o.object_title LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN o.status = N'OPEN' THEN 0 ELSE 1 END, o.trigger_date, o.occurrence_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Occurrence detail: 1. occurrence  2. stage schedule of the profile that
-- applies (date, reached, sent)  3. notifications sent for it.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_occurrence_get
    @organization_id BIGINT,
    @occurrence_id   BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id)
        THROW 54625, 'Notification occurrence not found for this organization.', 1;

    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.activity_code AS ActivityCode, a.activity_name AS ActivityName,
           a.trigger_basis AS TriggerBasis, a.trigger_description AS TriggerDescription, o.object_type AS ObjectType, o.object_id AS ObjectId,
           o.asset_id AS AssetId, o.contract_id AS ContractId, o.object_ref AS ObjectRef, o.object_title AS ObjectTitle,
           o.trigger_date AS TriggerDate, o.severity_code AS SeverityCode, o.status AS Status, o.escalation_level AS EscalationLevel,
           o.last_stage_date AS LastStageDate, o.last_notified_dt AS LastNotifiedDt, o.snoozed_until AS SnoozedUntil,
           o.snooze_reason AS SnoozeReason, o.snoozed_by AS SnoozedBy, sb.employee_name AS SnoozedByName, o.snoozed_dt AS SnoozedDt,
           o.closed_dt AS ClosedDt, o.close_reason AS CloseReason, o.entered_dt AS OpenedDt,
           f.ProfileId, p.profile_name AS ProfileName, f.VersionNo AS ProfileVersion, f.AckMode, f.SnoozeAllowed, f.Channels,
           CONVERT(BIGINT, o.record_version) AS RecordVersion
      FROM grac_practice.asset_notification_occurrence o
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = o.activity_code
      LEFT JOIN grac_practice.organization_employee sb ON sb.employee_id = o.snoozed_by_employee_id
     OUTER APPLY grac_practice.fn_asset_ntf_profile_for(o.organization_id, o.activity_code, o.severity_code, @today) f
      LEFT JOIN grac_practice.asset_notification_profile p ON p.profile_id = f.ProfileId
     WHERE o.occurrence_id = @occurrence_id;

    SELECT s.stage_id AS StageId, s.stage_kind AS StageKind, s.offset_days AS OffsetDays, s.escalation_level AS EscalationLevel,
           s.notification_class AS NotificationClass, d.d AS StageDate,
           CASE WHEN d.d <= @today THEN 1 ELSE 0 END AS Reached,
           (SELECT COUNT(*) FROM grac_practice.asset_notification_outbox x WHERE x.occurrence_id = o.occurrence_id AND x.stage_id = s.stage_id) AS SentCount
      FROM grac_practice.asset_notification_occurrence o
     CROSS APPLY grac_practice.fn_asset_ntf_profile_for(o.organization_id, o.activity_code, o.severity_code, @today) f
      JOIN grac_practice.asset_notification_profile p ON p.profile_id = f.ProfileId
      JOIN grac_practice.asset_notification_stage s ON s.profile_id = p.profile_id AND s.is_active = 1
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(o.trigger_date, s.stage_kind, s.offset_days, p.working_days_only) AS d) d
     WHERE o.occurrence_id = @occurrence_id
     ORDER BY d.d, s.escalation_level;

    SELECT x.notification_id AS NotificationId, x.stage_kind AS StageKind, x.stage_offset_days AS StageOffsetDays, x.stage_date AS StageDate,
           x.escalation_level AS EscalationLevel, x.notification_class AS NotificationClass, x.profile_version AS ProfileVersion,
           x.recipient_employee_id AS RecipientEmployeeId, x.recipient_name AS RecipientName, x.recipient_reason_code AS RecipientReasonCode,
           x.role_name AS RoleName, x.channels AS Channels, x.status_code AS StatusCode, x.attempt_count AS AttemptCount,
           x.failure_reason AS FailureReason, x.entered_dt AS EnteredDt, x.read_dt AS ReadDt, x.acknowledged_dt AS AcknowledgedDt,
           x.ack_mode AS AckMode, x.ack_note AS AckNote, x.manager_ack_dt AS ManagerAckDt, mg.employee_name AS ManagerAckByName
      FROM grac_practice.asset_notification_outbox x
      LEFT JOIN grac_practice.organization_employee mg ON mg.employee_id = x.manager_ack_by_employee_id
     WHERE x.occurrence_id = @occurrence_id
     ORDER BY x.entered_dt DESC, x.notification_id DESC;
END
GO

-- Snooze / reschedule an open occurrence (9.1.1; D55): the revised date and
-- the reason are mandatory and audited; no notice is sent before the revised
-- date, then the latest stage reached fires. An empty date resumes now.
-- Who may: APPROVE on Asset Notifications (the configured roles).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_occurrence_snooze
    @organization_id         BIGINT,
    @occurrence_id           BIGINT,
    @snoozed_until           DATE           = NULL,
    @reason                  NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE), @status NVARCHAR(12), @act NVARCHAR(40), @sev NVARCHAR(10),
            @old DATE, @allowed BIT;
    SELECT @status = status, @act = activity_code, @sev = severity_code, @old = snoozed_until
      FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id AND organization_id = @organization_id;
    IF @status IS NULL THROW 54625, 'Notification occurrence not found for this organization.', 1;
    IF @status <> N'OPEN' THROW 54626, 'Only an open occurrence can be snoozed or rescheduled.', 1;
    IF @expected_record_version IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence
                                                             WHERE occurrence_id = @occurrence_id
                                                               AND CONVERT(BIGINT, record_version) = @expected_record_version)
        THROW 54623, 'The occurrence was changed by someone else; reload it and try again.', 1;
    SELECT @allowed = SnoozeAllowed FROM grac_practice.fn_asset_ntf_profile_for(@organization_id, @act, @sev, @today);
    IF @snoozed_until IS NOT NULL AND ISNULL(@allowed, 0) = 0
        THROW 54627, 'The notification profile does not allow snoozing or rescheduling.', 1;
    IF @snoozed_until IS NOT NULL AND (@snoozed_until <= @today OR @snoozed_until > DATEADD(DAY, 365, @today))
        THROW 54628, 'The revised date must be after today and within a year.', 1;
    IF @reason IS NULL THROW 54629, 'Enter the reason.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_notification_occurrence
       SET snoozed_until = @snoozed_until, snooze_reason = @reason, snoozed_by = @actor, snoozed_by_employee_id = @actor_employee_id,
           snoozed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE occurrence_id = @occurrence_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-notification-occurrence', @occurrence_id, CASE WHEN @snoozed_until IS NULL THEN N'RESUME' ELSE N'SNOOZE' END,
            (SELECT @old AS snoozedUntil FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @snoozed_until AS snoozedUntil, @reason AS reason, @actor_employee_id AS actorEmployeeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @occurrence_id AS OccurrenceId, CASE WHEN @snoozed_until IS NULL THEN N'RESUMED' ELSE N'SNOOZED' END AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_log
    @organization_id    BIGINT,
    @status_code        NVARCHAR(20)  = NULL,       -- Pending | Sent | Failed | Suppressed
    @activity_code      NVARCHAR(40)  = NULL,
    @notification_class NVARCHAR(20)  = NULL,
    @search             NVARCHAR(200) = NULL,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status_code = NULLIF(LTRIM(RTRIM(@status_code)), N'');
    SET @activity_code = NULLIF(LTRIM(RTRIM(@activity_code)), N'');
    SET @notification_class = NULLIF(LTRIM(RTRIM(@notification_class)), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;

    SELECT x.notification_id AS NotificationId, x.occurrence_id AS OccurrenceId, x.activity_code AS ActivityCode,
           a.activity_name AS ActivityName, x.object_ref AS ObjectRef, x.object_title AS ObjectTitle, x.trigger_date AS TriggerDate,
           x.stage_kind AS StageKind, x.stage_offset_days AS StageOffsetDays, x.stage_date AS StageDate,
           x.escalation_level AS EscalationLevel, x.notification_class AS NotificationClass, x.severity_code AS SeverityCode,
           x.profile_version AS ProfileVersion, x.recipient_employee_id AS RecipientEmployeeId, x.recipient_name AS RecipientName,
           x.recipient_email AS RecipientEmail, x.recipient_reason_code AS RecipientReasonCode, x.role_name AS RoleName,
           x.channels AS Channels, x.status_code AS StatusCode, x.attempt_count AS AttemptCount, x.last_attempt_dt AS LastAttemptDt,
           x.failure_reason AS FailureReason, x.sent_dt AS SentDt, x.read_dt AS ReadDt, x.ack_mode AS AckMode,
           x.acknowledged_dt AS AcknowledgedDt, x.manager_ack_dt AS ManagerAckDt, x.entered_dt AS EnteredDt,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_notification_outbox x
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = x.activity_code
     WHERE x.organization_id = @organization_id
       AND (@status_code IS NULL OR x.status_code = @status_code)
       AND (@activity_code IS NULL OR x.activity_code = @activity_code)
       AND (@notification_class IS NULL OR x.notification_class = @notification_class)
       AND (@search IS NULL OR x.object_ref LIKE N'%' + @search + N'%' OR x.object_title LIKE N'%' + @search + N'%'
            OR x.recipient_name LIKE N'%' + @search + N'%')
     ORDER BY x.entered_dt DESC, x.notification_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- A dispatcher reports a delivery (9.1.10): SENT, or FAILED with the reason.
-- A failure goes back to Pending for a retry until the third attempt, then
-- stays Failed and is listed for administrators (D56).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_delivery
    @organization_id BIGINT,
    @notification_id BIGINT,
    @status_code     NVARCHAR(20),
    @failure_reason  NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @status_code = UPPER(LTRIM(RTRIM(ISNULL(@status_code, N''))));
    SET @failure_reason = NULLIF(LTRIM(RTRIM(@failure_reason)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_outbox WHERE notification_id = @notification_id AND organization_id = @organization_id)
        THROW 54630, 'Notification not found.', 1;
    IF @status_code NOT IN (N'SENT', N'FAILED') OR (@status_code = N'FAILED' AND @failure_reason IS NULL)
        THROW 54633, 'Report SENT, or FAILED with the failure reason.', 1;
    DECLARE @result NVARCHAR(20);
    BEGIN TRAN;
    UPDATE grac_practice.asset_notification_outbox
       SET attempt_count = attempt_count + 1, last_attempt_dt = SYSUTCDATETIME(),
           status_code = CASE WHEN @status_code = N'SENT' THEN N'Sent' WHEN attempt_count + 1 >= 3 THEN N'Failed' ELSE N'Pending' END,
           sent_dt = CASE WHEN @status_code = N'SENT' THEN SYSUTCDATETIME() ELSE sent_dt END,
           failure_reason = CASE WHEN @status_code = N'SENT' THEN NULL ELSE @failure_reason END,
           @result = CASE WHEN @status_code = N'SENT' THEN N'Sent' WHEN attempt_count + 1 >= 3 THEN N'Failed' ELSE N'Pending' END
     WHERE notification_id = @notification_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-notification', @notification_id, N'DELIVERY', NULL,
            (SELECT @status_code AS reported, @result AS statusCode, @failure_reason AS failureReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @notification_id AS NotificationId, @result AS Result;
END
GO

-- Scheduler run log. Counts and errors of a run over every organization are
-- shown only as its time and result (they cover other organizations).
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
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.error_count END AS ErrorCount,
           CASE WHEN r.organization_id IS NULL THEN NULL ELSE r.error_text END AS ErrorText,
           r.entered_by AS EnteredBy
      FROM grac_practice.asset_scheduler_run r
     WHERE r.organization_id IS NULL OR r.organization_id = @organization_id
     ORDER BY r.started_dt DESC, r.run_id DESC;
END
GO
PRINT '437: administrator readers and writers created.';
GO

-- =====================================================================
-- 10. Notifications of the recipient (My Notifications)
-- =====================================================================
-- Rows addressed to the employee, plus (manager acknowledgement -- D54)
-- rows of the people who report to them that wait for their confirmation.
-- @filter: UNREAD | READ | TO_ACKNOWLEDGE | TO_CONFIRM | ALL
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_mine
    @employee_id BIGINT,
    @filter      NVARCHAR(20) = N'UNREAD',
    @page_number INT          = 1,
    @page_size   INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @filter = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@filter)), N''), N'UNREAD'));
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 100 THEN 100 ELSE @page_size END;

    SELECT x.notification_id AS NotificationId, x.activity_code AS ActivityCode, a.activity_name AS ActivityName,
           x.object_type AS ObjectType, x.object_id AS ObjectId, x.asset_id AS AssetId, x.contract_id AS ContractId,
           x.object_ref AS ObjectRef, x.object_title AS ObjectTitle, x.trigger_date AS TriggerDate, x.stage_kind AS StageKind,
           x.stage_offset_days AS StageOffsetDays, x.escalation_level AS EscalationLevel, x.notification_class AS NotificationClass,
           x.severity_code AS SeverityCode, x.recipient_reason_code AS RecipientReasonCode, x.role_name AS RoleName,
           x.subject AS Subject, x.body_text AS BodyText, x.ack_mode AS AckMode, x.read_dt AS ReadDt,
           x.acknowledged_dt AS AcknowledgedDt, x.ack_note AS AckNote, x.manager_ack_dt AS ManagerAckDt, x.entered_dt AS EnteredDt,
           x.recipient_name AS RecipientName, v.is_confirmation AS IsManagerConfirmation,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_notification_outbox x
      JOIN grac_practice.asset_notification_activity a ON a.activity_code = x.activity_code
     CROSS APPLY (SELECT CASE WHEN x.recipient_employee_id = @employee_id THEN 0 ELSE 1 END AS is_confirmation) v
     WHERE (x.recipient_employee_id = @employee_id
            OR (x.ack_mode = N'MANAGER' AND x.acknowledged_dt IS NOT NULL AND x.manager_ack_dt IS NULL
                AND x.recipient_manager_id = @employee_id))
       AND (@filter = N'ALL'
            OR (@filter = N'UNREAD' AND v.is_confirmation = 0 AND x.read_dt IS NULL)
            OR (@filter = N'READ' AND v.is_confirmation = 0 AND x.read_dt IS NOT NULL)
            OR (@filter = N'TO_ACKNOWLEDGE' AND v.is_confirmation = 0 AND x.ack_mode IN (N'ACTION', N'MANAGER') AND x.acknowledged_dt IS NULL)
            OR (@filter = N'TO_CONFIRM' AND v.is_confirmation = 1))
     ORDER BY x.entered_dt DESC, x.notification_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_mine_counts
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ISNULL(SUM(CASE WHEN x.recipient_employee_id = @employee_id AND x.read_dt IS NULL THEN 1 ELSE 0 END), 0) AS UnreadCount,
           ISNULL(SUM(CASE WHEN x.recipient_employee_id = @employee_id AND x.read_dt IS NOT NULL THEN 1 ELSE 0 END), 0) AS ReadCount,
           ISNULL(SUM(CASE WHEN x.recipient_employee_id = @employee_id AND x.ack_mode IN (N'ACTION', N'MANAGER')
                            AND x.acknowledged_dt IS NULL THEN 1 ELSE 0 END), 0) AS ToAcknowledgeCount,
           ISNULL(SUM(CASE WHEN x.recipient_employee_id <> @employee_id THEN 1 ELSE 0 END), 0) AS ToConfirmCount
      FROM grac_practice.asset_notification_outbox x
     WHERE x.recipient_employee_id = @employee_id
        OR (x.ack_mode = N'MANAGER' AND x.acknowledged_dt IS NOT NULL AND x.manager_ack_dt IS NULL AND x.recipient_manager_id = @employee_id);
END
GO

-- READ (mark read), ACKNOWLEDGE (with the action taken -- note required for
-- Action / Manager acknowledgement), CONFIRM (the manager confirms a
-- Manager acknowledgement of someone reporting to them). In-app reading is
-- the delivery of the in-app channel (201 precedent): Pending -> Sent.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_mine_action
    @employee_id     BIGINT,
    @notification_id BIGINT,
    @action          NVARCHAR(20),
    @note            NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @rcp BIGINT, @mgr BIGINT, @mode NVARCHAR(10), @ack DATETIME2, @mack DATETIME2;
    SELECT @rcp = recipient_employee_id, @mgr = recipient_manager_id, @mode = ack_mode, @ack = acknowledged_dt, @mack = manager_ack_dt
      FROM grac_practice.asset_notification_outbox WHERE notification_id = @notification_id;
    IF @mode IS NULL OR @employee_id IS NULL
       OR (@action IN (N'READ', N'ACKNOWLEDGE') AND ISNULL(@rcp, -1) <> @employee_id)
        THROW 54630, 'Notification not found.', 1;
    IF @action NOT IN (N'READ', N'ACKNOWLEDGE', N'CONFIRM')
        THROW 54630, 'Notification not found.', 1;
    IF @action = N'ACKNOWLEDGE' AND @mode IN (N'ACTION', N'MANAGER') AND @note IS NULL
        THROW 54631, 'Enter the action taken to acknowledge this notification.', 1;
    IF @action = N'CONFIRM' AND (@mode <> N'MANAGER' OR @ack IS NULL OR @mack IS NOT NULL OR ISNULL(@mgr, -1) <> @employee_id)
        THROW 54632, 'There is no acknowledgement waiting for your confirmation on this notification.', 1;

    BEGIN TRAN;
    IF @action = N'READ'
    BEGIN
        UPDATE grac_practice.asset_notification_outbox
           SET read_dt = ISNULL(read_dt, SYSUTCDATETIME()),
               status_code = CASE WHEN status_code = N'Pending' THEN N'Sent' ELSE status_code END,
               sent_dt = CASE WHEN status_code = N'Pending' THEN SYSUTCDATETIME() ELSE sent_dt END
         WHERE notification_id = @notification_id;
    END
    ELSE IF @action = N'ACKNOWLEDGE'
    BEGIN
        UPDATE grac_practice.asset_notification_outbox
           SET read_dt = ISNULL(read_dt, SYSUTCDATETIME()), acknowledged_dt = ISNULL(acknowledged_dt, SYSUTCDATETIME()),
               ack_note = ISNULL(@note, ack_note),
               status_code = CASE WHEN status_code = N'Pending' THEN N'Sent' ELSE status_code END,
               sent_dt = CASE WHEN status_code = N'Pending' THEN SYSUTCDATETIME() ELSE sent_dt END
         WHERE notification_id = @notification_id;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-notification', @notification_id, N'ACKNOWLEDGE', NULL,
                (SELECT @employee_id AS employeeId, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_notification_outbox
           SET manager_ack_by_employee_id = @employee_id, manager_ack_dt = SYSUTCDATETIME(), manager_ack_note = @note
         WHERE notification_id = @notification_id;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-notification', @notification_id, N'MANAGER_ACKNOWLEDGE', NULL,
                (SELECT @employee_id AS employeeId, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    END
    COMMIT;
    SELECT @notification_id AS NotificationId, @action AS Result;
END
GO

-- Mark every unread notification read that needs no acknowledgement beyond
-- reading it (None / Read). Action and manager acknowledgements stay open.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_mine_read_all
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE grac_practice.asset_notification_outbox
       SET read_dt = SYSUTCDATETIME(),
           status_code = CASE WHEN status_code = N'Pending' THEN N'Sent' ELSE status_code END,
           sent_dt = CASE WHEN status_code = N'Pending' THEN SYSUTCDATETIME() ELSE sent_dt END
     WHERE recipient_employee_id = @employee_id AND read_dt IS NULL AND ack_mode IN (N'NONE', N'READ');
    SELECT @@ROWCOUNT AS MarkedCount;
END
GO
PRINT '437: recipient procedures created.';
GO

-- =====================================================================
-- 11. Menu: Asset & Contract -> Asset Notifications (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-notifications', N'Asset Notifications', N'Practice/Index/asset-notifications', 359, N'bell-concierge', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-437', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-437');
PRINT CONCAT('437: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-437', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-notifications' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-437', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-notifications'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('437: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '437-a catalogues seeded (13 activities, 16 recipient types, default stages / recipients / matrix)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_notification_activity) >= 13
             AND (SELECT COUNT(*) FROM grac_practice.asset_notification_recipient_type) >= 16
             AND (SELECT COUNT(*) FROM grac_practice.asset_notification_default_stage WHERE activity_code = N'CALIBRATION') = 9
             AND (SELECT COUNT(*) FROM grac_practice.asset_notification_default_stage WHERE activity_code = N'MAJOR_CONTRACT') = 7
             AND EXISTS (SELECT 1 FROM grac_practice.asset_notification_default_stage
                          WHERE activity_code = N'CUSTODIAN_ATTESTATION' AND stage_kind = N'ESCALATION' AND offset_days = 30 AND escalation_level = 3)
             AND (SELECT COUNT(*) FROM grac_practice.asset_notification_default_recipient) > 0
             AND (SELECT COUNT(DISTINCT severity_code) FROM grac_practice.asset_escalation_matrix_default) = 4
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '437-b tables and the dedupe index present',
       CASE WHEN OBJECT_ID('grac_practice.asset_notification_profile','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_notification_stage','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_notification_stage_recipient','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_escalation_matrix','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_notification_occurrence','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_notification_outbox','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_scheduler_run','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_ntf_out_dedupe' AND is_unique = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '437-c procedures and functions present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_notification_defaults_ensure', 'sp_asset_notification_parties', 'sp_asset_notification_sweep',
                                'sp_asset_scheduler_run', 'sp_asset_notification_config_get', 'sp_asset_notification_profile_save',
                                'sp_asset_escalation_matrix_save', 'sp_asset_notification_occurrence_list',
                                'sp_asset_notification_occurrence_get', 'sp_asset_notification_occurrence_snooze',
                                'sp_asset_notification_log', 'sp_asset_notification_delivery', 'sp_asset_scheduler_runs',
                                'sp_asset_notification_mine', 'sp_asset_notification_mine_counts', 'sp_asset_notification_mine_action',
                                'sp_asset_notification_mine_read_all')) = 17
             AND OBJECT_ID('grac_practice.fn_asset_ntf_asset_severity') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_ntf_version_severity') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_ntf_contract_activity') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_ntf_stage_date') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_ntf_profile_for') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '437-d re-issued for the scheduler (renewal start, attestation generate)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_contract_renewal_start')) LIKE '%@out_renewal_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_attestation_generate')) LIKE '%@scheduled%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_attestation_generate')) LIKE '%sp_asset_attestation_create%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '437-e stage dates (reminder before, escalation after, weekend moves to Monday)',
       CASE WHEN grac_practice.fn_asset_ntf_stage_date('20261231', N'REMINDER', 30, 0) = '20261201'
             AND grac_practice.fn_asset_ntf_stage_date('20261231', N'ESCALATION', 7, 0) = '20270107'
             AND grac_practice.fn_asset_ntf_stage_date('20261003', N'DUE', 0, 1) = '20261005'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '437-f menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-notifications' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: an Active contract (434) of type AMC whose version ends within
--   180 days and covers two assets (435) with an owner; an asset with an
--   OS release whose support ends within 180 days (430); an open
--   attestation (431); people A (Admin) and B (asset owner, with a
--   reporting officer C).
--   1. Asset & Contract -> Asset Notifications -> Profiles: every activity
--      has a default profile with the 9.1.3 stages (Warranty / AMC: 180 ...
--      7 days; Custodian attestation: 30 / 15 / 7, due, 1 / 7 / 15 / 30).
--      Activities without a source yet are marked "source in Phase 6.2 /
--      8". Escalation matrix shows the 9.1.8 defaults per severity.
--   2. Scheduler -> Run now. The run log shows the counts. Contracts ->
--      Renewals: the AMC contract has an Open renewal started by the
--      scheduler. Occurrences: one open occurrence per contract / asset /
--      attestation with its trigger date and the stage last sent.
--   3. As B: Home -> My Notifications -> Asset & Contract: one notice per
--      occurrence (the latest stage reached only). Run now again: nothing
--      new (one notice per stage, occurrence and person).
--   4. As A: edit the Warranty / AMC profile -> Acknowledgement: Manager,
--      add a 200-day reminder... (saved; profile version 2). Snooze an
--      occurrence: no date or no reason -> refused; revised date + reason
--      -> snoozed; Run now sends nothing for it until that date.
--   5. As B: a Manager-acknowledgement notice needs the action taken; as C:
--      "To confirm" lists it -> Confirm.
--   6. Change the contract version end date (new version) -> Run now: the
--      old occurrence is Superseded (its notices kept), a new one opens.
-- =====================================================================
