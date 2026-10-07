-- =====================================================================
-- 428  Asset Register -- registration on the asset form template
--      (Asset & Contract Management, Phase 4 increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 5 (asset master data and lifecycle statuses), 5.1.14
--   (dynamic form and conditional logic), 5.1.16 (cross-field
--   validation), 5.2.1 ("apply the same template rules to the UI, API,
--   imports ..."; "preserve the template version used by each asset
--   record"), 17.1 phase 4 ("registration, dynamic rendering").
--   The asset record stays organization_dependency_asset (decision D3);
--   the Settings -> Dependencies -> Assets tab keeps working.
--   Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. Asset lifecycle statuses -- the 27 BRD 5 statuses on the
--      state-machine framework (entity Asset), each with its BRD phase
--      (asset_lifecycle_status_phase) and the legacy lifecycle_status it
--      keeps in step (decision D5: Acquisition / Readiness -> Planned,
--      Operation / Movement / Exception / pending retirement ->
--      Commissioned, Disposed / Archived -> Decommissioned).
--      Only the creation transition (-> Draft) is seeded here; the
--      lifecycle transitions and their approvals / evidence are the next
--      increment (4.2) -- the BRD gives the statuses and workflows (5, 11)
--      but not the transition matrix, which will be proposed there.
--   2. organization_dependency_asset gains template_id (the template
--      version the record was registered with -- 5.2.1), current_status_id
--      and record_version. Existing assets are given the status matching
--      their legacy lifecycle_status (asset_legacy_status_map; one
--      BACKFILL row per asset in the immutable transition log).
--   3. asset_field_value -- the values of VALUE-stored dictionary fields
--      (typed copies for number / date / reference queries). COLUMN
--      fields stay in their asset columns.
--   4. One evaluation engine: fn_asset_form_evaluate (the 421 logic moved
--      into a function, unchanged); sp_asset_form_template_evaluate (421)
--      is re-issued to read it, so the template Preview, the register
--      form and every save use the same rules.
--   5. fn_asset_master_lookup -- the values every MASTER: lookup source
--      may take for an organization (taxonomy in effect, locations,
--      employees, teams, departments, divisions, vendors, processes,
--      practices, criticality, templates, approved catalogue makes /
--      models / firmware / OS releases). The form's pickers and the save
--      validation read the same function. MASTER:COUNTRY and
--      MASTER:CURRENCY have no master table yet and are stored as
--      entered; MASTER:CONTRACT arrives with contracts (Phase 5) and must
--      stay empty until then.
--   6. asset_field_validation_rule -- the cross-field rules the field
--      dictionary states in its validation text (5.1 / 5.1.16): not a
--      future date, on or after / after another date, non-negative,
--      positive, not greater than another field, never lower than the
--      stored value. Seeded insert-only from the BRD wording; severity
--      ERROR unless the BRD allows an approved exception (WARNING).
--   7. sp_asset_register_save -- one save path for the register UI and
--      the API (and later imports): pins the template, overlays the
--      submitted values on the stored ones, derives category /
--      subcategory from the asset type, runs the template rules, then
--      checks mandatory fields, data types, lookup values, the rule
--      table, model / make / asset type consistency (5.1.16), serial
--      uniqueness within make and model (warning -- "warn or block
--      according to policy"; no policy is configured yet) and approved
--      firmware / OS compatibility for the model (warning until
--      technology exceptions exist -- 4.3). Hidden fields that hold a
--      value follow the template field's hidden-value behaviour (5.1.14):
--      RETAIN keeps it; CLEAR and MIGRATE need the user's RETAIN / CLEAR
--      decision before the save goes ahead. Nothing is written when an
--      error or an open decision remains; the issues are returned.
--   8. Readers: sp_asset_register_list, sp_asset_register_get,
--      sp_asset_register_form (resolves the template and returns
--      sp_asset_form_template_get), sp_asset_register_lookups.
--   9. Menu "Asset Register" (asset-register) under Asset & Contract;
--      Admin grant VIEW / ADD / EDIT.
--
-- NOT DONE HERE (next increments): lifecycle transitions, approvals and
--   history views (4.2); installed firmware / OS history and technology
--   exceptions (4.3, was 3.4); ownership / location history, custodian
--   acknowledgement and attestation (4.4); verification exceptions,
--   transfer, maintenance, calibration and disposal workflows (4.5+);
--   migrating an asset to a newer template version (an approved
--   migration -- 5.1.14); checklist generation (Phase 6).
--
-- ERROR NUMBERS: 54950-54969 (validation problems are returned as rows,
--   not raised)
--   54950 organization not found          54951 asset not found
--   54952 changed by someone else         54953 asset type cannot change
--   54954 asset type not active / in effect 54955 no active form template
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml,
--   new partial + script asset-register, both appsettings.json.
-- DEPENDS ON: 420-427.
-- Rollback: 428_asset_register_core_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_field_options') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_taxonomy_selectable') IS NULL
   OR OBJECT_ID('grac_practice.asset_os_release','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_valuation_config','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','lifecycle_status') IS NULL
BEGIN
    RAISERROR('ABORT (428): run 420 to 427 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Asset lifecycle statuses (BRD 5) and their phases
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'Asset', N'DRAFT',                  N'Draft',                   10, 0, 1),
    (N'Asset', N'REQUESTED',              N'Requested',               20, 0, 0),
    (N'Asset', N'APPROVED',               N'Approved',                30, 0, 0),
    (N'Asset', N'ORDERED',                N'Ordered',                 40, 0, 0),
    (N'Asset', N'RECEIVED',               N'Received',                50, 0, 0),
    (N'Asset', N'UNDER_INSPECTION',       N'Under Inspection',        60, 0, 0),
    (N'Asset', N'PENDING_INSTALLATION',   N'Pending Installation',    70, 0, 0),
    (N'Asset', N'PENDING_COMMISSIONING',  N'Pending Commissioning',   80, 0, 0),
    (N'Asset', N'ACTIVE',                 N'Active',                  90, 0, 0),
    (N'Asset', N'MAINTENANCE',            N'Maintenance',            100, 0, 0),
    (N'Asset', N'REPAIR',                 N'Repair',                 110, 0, 0),
    (N'Asset', N'OUT_OF_SERVICE',         N'Out of Service',         120, 0, 0),
    (N'Asset', N'QUARANTINED',            N'Quarantined',            130, 0, 0),
    (N'Asset', N'STORAGE',                N'Storage',                140, 0, 0),
    (N'Asset', N'TRANSFER_PENDING',       N'Transfer Pending',       150, 0, 0),
    (N'Asset', N'TRANSFERRED',            N'Transferred',            160, 0, 0),
    (N'Asset', N'OWNER_CHANGE_PENDING',   N'Owner Change Pending',   170, 0, 0),
    (N'Asset', N'LOST',                   N'Lost',                   180, 0, 0),
    (N'Asset', N'STOLEN',                 N'Stolen',                 190, 0, 0),
    (N'Asset', N'RECALLED',               N'Recalled',               200, 0, 0),
    (N'Asset', N'OBSOLETE',               N'Obsolete',               210, 0, 0),
    (N'Asset', N'NON_COMPLIANT',          N'Non-Compliant',          220, 0, 0),
    (N'Asset', N'PENDING_DECOMMISSION',   N'Pending Decommission',   230, 0, 0),
    (N'Asset', N'SANITIZATION_PENDING',   N'Sanitization Pending',   240, 0, 0),
    (N'Asset', N'DISPOSAL_APPROVAL',      N'Disposal Approval',      250, 0, 0),
    (N'Asset', N'DISPOSED',               N'Disposed',               260, 0, 0),
    (N'Asset', N'ARCHIVED',               N'Archived',               270, 1, 0)
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial,
            N'BRD v1.7 section 5 asset lifecycle status.', N'seed-428');
PRINT CONCAT('428: Asset statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES (CAST(NULL AS NVARCHAR(60)), N'DRAFT', 0, 0, N'Register an asset.')) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'Asset'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'Asset', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-428');
PRINT CONCAT('428: Asset creation rule inserted: ', @@ROWCOUNT);
GO

IF OBJECT_ID('grac_practice.asset_lifecycle_status_phase','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_lifecycle_status_phase (
        status_code             NVARCHAR(60)  NOT NULL CONSTRAINT pk_pm_asset_status_phase PRIMARY KEY,
        phase_code              NVARCHAR(30)  NOT NULL
            CONSTRAINT ck_pm_asset_status_phase CHECK (phase_code IN
                (N'ACQUISITION', N'READINESS', N'OPERATION', N'MOVEMENT', N'EXCEPTION', N'RETIREMENT')),
        phase_name              NVARCHAR(60)  NOT NULL,
        legacy_lifecycle_status NVARCHAR(30)  NOT NULL
            CONSTRAINT ck_pm_asset_status_phase_legacy CHECK (legacy_lifecycle_status IN (N'Planned', N'Commissioned', N'Decommissioned')),
        entered_by              NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_status_phase_eby DEFAULT N'system',
        entered_dt              DATETIME2     NOT NULL CONSTRAINT df_pm_asset_status_phase_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '428: asset_lifecycle_status_phase created.';
END
GO

MERGE grac_practice.asset_lifecycle_status_phase AS t
USING (VALUES
    (N'DRAFT', N'ACQUISITION', N'Acquisition', N'Planned'),
    (N'REQUESTED', N'ACQUISITION', N'Acquisition', N'Planned'),
    (N'APPROVED', N'ACQUISITION', N'Acquisition', N'Planned'),
    (N'ORDERED', N'ACQUISITION', N'Acquisition', N'Planned'),
    (N'RECEIVED', N'ACQUISITION', N'Acquisition', N'Planned'),
    (N'UNDER_INSPECTION', N'READINESS', N'Readiness', N'Planned'),
    (N'PENDING_INSTALLATION', N'READINESS', N'Readiness', N'Planned'),
    (N'PENDING_COMMISSIONING', N'READINESS', N'Readiness', N'Planned'),
    (N'ACTIVE', N'OPERATION', N'Operation', N'Commissioned'),
    (N'MAINTENANCE', N'OPERATION', N'Operation', N'Commissioned'),
    (N'REPAIR', N'OPERATION', N'Operation', N'Commissioned'),
    (N'OUT_OF_SERVICE', N'OPERATION', N'Operation', N'Commissioned'),
    (N'QUARANTINED', N'OPERATION', N'Operation', N'Commissioned'),
    (N'STORAGE', N'MOVEMENT', N'Movement', N'Commissioned'),
    (N'TRANSFER_PENDING', N'MOVEMENT', N'Movement', N'Commissioned'),
    (N'TRANSFERRED', N'MOVEMENT', N'Movement', N'Commissioned'),
    (N'OWNER_CHANGE_PENDING', N'MOVEMENT', N'Movement', N'Commissioned'),
    (N'LOST', N'EXCEPTION', N'Exception', N'Commissioned'),
    (N'STOLEN', N'EXCEPTION', N'Exception', N'Commissioned'),
    (N'RECALLED', N'EXCEPTION', N'Exception', N'Commissioned'),
    (N'OBSOLETE', N'EXCEPTION', N'Exception', N'Commissioned'),
    (N'NON_COMPLIANT', N'EXCEPTION', N'Exception', N'Commissioned'),
    (N'PENDING_DECOMMISSION', N'RETIREMENT', N'Retirement', N'Commissioned'),
    (N'SANITIZATION_PENDING', N'RETIREMENT', N'Retirement', N'Commissioned'),
    (N'DISPOSAL_APPROVAL', N'RETIREMENT', N'Retirement', N'Commissioned'),
    (N'DISPOSED', N'RETIREMENT', N'Retirement', N'Decommissioned'),
    (N'ARCHIVED', N'RETIREMENT', N'Retirement', N'Decommissioned')
) AS s(status_code, phase_code, phase_name, legacy_lifecycle_status)
ON t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, phase_code, phase_name, legacy_lifecycle_status, entered_by)
    VALUES (s.status_code, s.phase_code, s.phase_name, s.legacy_lifecycle_status, N'seed-428');
PRINT CONCAT('428: status phases inserted: ', @@ROWCOUNT);
GO

-- Legacy lifecycle_status (123) -> starting status for assets that have
-- no register status yet (existing rows and rows the Assets tab adds).
IF OBJECT_ID('grac_practice.asset_legacy_status_map','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_legacy_status_map (
        legacy_lifecycle_status NVARCHAR(30)  NOT NULL CONSTRAINT pk_pm_asset_legacy_status PRIMARY KEY,
        status_code             NVARCHAR(60)  NOT NULL
            CONSTRAINT fk_pm_asset_legacy_status_phase REFERENCES grac_practice.asset_lifecycle_status_phase(status_code),
        entered_by              NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_legacy_status_eby DEFAULT N'system',
        entered_dt              DATETIME2     NOT NULL CONSTRAINT df_pm_asset_legacy_status_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '428: asset_legacy_status_map created.';
END
GO

MERGE grac_practice.asset_legacy_status_map AS t
USING (VALUES (N'Planned', N'DRAFT'), (N'Commissioned', N'ACTIVE'), (N'Decommissioned', N'DISPOSED')) AS s(legacy_lifecycle_status, status_code)
ON t.legacy_lifecycle_status = s.legacy_lifecycle_status
WHEN NOT MATCHED BY TARGET THEN
    INSERT (legacy_lifecycle_status, status_code, entered_by) VALUES (s.legacy_lifecycle_status, s.status_code, N'seed-428');
GO

-- =====================================================================
-- 2. Asset record columns, values table
-- =====================================================================
IF COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset ADD template_id BIGINT NULL
        CONSTRAINT fk_pm_org_asset_template REFERENCES grac_practice.asset_form_template(template_id);
IF COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset ADD current_status_id INT NULL
        CONSTRAINT fk_pm_org_asset_lifecycle_state REFERENCES grac_practice.entity_status_master(entity_status_id);
IF COL_LENGTH('grac_practice.organization_dependency_asset','record_version') IS NULL
    ALTER TABLE grac_practice.organization_dependency_asset ADD record_version ROWVERSION NOT NULL;
GO

IF OBJECT_ID('grac_practice.asset_field_value','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_value (
        asset_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_field_value_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        field_definition_id INT            NOT NULL
            CONSTRAINT fk_pm_asset_field_value_def REFERENCES grac_practice.asset_field_definition(field_definition_id),
        value_text          NVARCHAR(MAX)  NOT NULL,   -- canonical: ISO dates, numbers as entered, JSON array for multi-select
        value_number        DECIMAL(38, 6) NULL,
        value_date          DATE           NULL,
        value_ref           BIGINT         NULL,       -- id for single-select master lookups
        entered_by          NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_field_value_eby DEFAULT N'system',
        entered_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_asset_field_value_edt DEFAULT SYSUTCDATETIME(),
        updated_by          NVARCHAR(100)  NULL,
        updated_dt          DATETIME2      NULL,
        CONSTRAINT pk_pm_asset_field_value PRIMARY KEY (asset_id, field_definition_id)
    );
    CREATE INDEX ix_pm_asset_field_value_def ON grac_practice.asset_field_value(field_definition_id, value_ref);
    PRINT '428: asset_field_value created.';
END
GO

-- Existing assets: register status from the legacy lifecycle status, with
-- one BACKFILL row each in the transition log.
DECLARE @done TABLE (asset_id BIGINT PRIMARY KEY, status_id INT NOT NULL);
UPDATE a
   SET current_status_id = s.entity_status_id
OUTPUT inserted.asset_id, inserted.current_status_id INTO @done (asset_id, status_id)
  FROM grac_practice.organization_dependency_asset a
  JOIN grac_practice.asset_legacy_status_map m ON m.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
  JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = m.status_code
 WHERE a.current_status_id IS NULL;
INSERT grac_practice.entity_state_transition_log (entity_type, entity_id, from_status_id, to_status_id, actor_employee_id,
                                                  actor_role_code, reason_code, reason_text)
SELECT N'Asset', d.asset_id, NULL, d.status_id, NULL, NULL, N'BACKFILL_428',
       N'Starting status taken from the legacy lifecycle status.'
  FROM @done d;
DECLARE @backfilled INT = (SELECT COUNT(*) FROM @done);
PRINT CONCAT('428: existing assets given a register status: ', @backfilled);
GO

-- =====================================================================
-- 3. One evaluation engine (421 logic, moved into a function unchanged)
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_form_evaluate (@template_id BIGINT, @values_json NVARCHAR(MAX))
RETURNS @out TABLE (
    FieldDefinitionId INT            NOT NULL PRIMARY KEY,
    FieldKey          NVARCHAR(100)  NOT NULL,
    DisplayLabel      NVARCHAR(200)  NOT NULL,
    SectionId         BIGINT         NOT NULL,
    IsVisible         INT            NOT NULL,
    IsMandatory       INT            NOT NULL,
    VisibilityByRule  INT            NOT NULL,
    RulesFired        NVARCHAR(MAX)  NULL,
    ValueSupplied     INT            NOT NULL,
    SectionOrder      INT            NOT NULL,
    FieldOrder        INT            NOT NULL)
AS
BEGIN
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @raw TABLE (field_key NVARCHAR(100) NOT NULL, val NVARCHAR(MAX) NULL, val_type INT NOT NULL);
    INSERT @raw (field_key, val, val_type)
    SELECT j.[key], j.[value], j.[type] FROM OPENJSON(@values_json) j;

    DECLARE @elem TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @raw r CROSS APPLY OPENJSON(r.val) a
     WHERE r.val_type = 4 AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';
    INSERT @elem (field_key, elem)
    SELECT r.field_key, LEFT(LTRIM(RTRIM(s.[value])), 400)
      FROM @raw r CROSS APPLY STRING_SPLIT(ISNULL(r.val, N''), N'|') s
     WHERE r.val_type IN (1, 2, 3) AND LTRIM(RTRIM(s.[value])) <> N'';

    DECLARE @cond TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @cond (rule_id, group_no, ok)
    SELECT c.rule_id, c.group_no,
           CASE c.operator_code
             WHEN N'EQ'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 1 ELSE 0 END
             WHEN N'NEQ'       THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key AND e.elem = c.compare_value) THEN 0 ELSE 1 END
             WHEN N'IN'        THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'NOT_IN'    THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e
                                                       JOIN STRING_SPLIT(ISNULL(c.compare_value, N''), N'|') l ON LTRIM(RTRIM(l.[value])) = e.elem
                                                      WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'EMPTY'     THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 0 ELSE 1 END
             WHEN N'NOT_EMPTY' THEN CASE WHEN EXISTS (SELECT 1 FROM @elem e WHERE e.field_key = d.field_key) THEN 1 ELSE 0 END
             WHEN N'GT'  THEN CASE WHEN nv.num >  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'GTE' THEN CASE WHEN nv.num >= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LT'  THEN CASE WHEN nv.num <  TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'LTE' THEN CASE WHEN nv.num <= TRY_CONVERT(DECIMAL(38, 6), c.compare_value) THEN 1 ELSE 0 END
             WHEN N'DATE_BEFORE_TODAY' THEN CASE WHEN nv.dt < @today THEN 1 ELSE 0 END
             WHEN N'DATE_AFTER_TODAY'  THEN CASE WHEN nv.dt > @today THEN 1 ELSE 0 END
             WHEN N'DATE_WITHIN_DAYS'  THEN CASE WHEN nv.dt >= @today
                                                  AND nv.dt <= DATEADD(DAY, ISNULL(TRY_CONVERT(INT, c.compare_value), 0), @today) THEN 1 ELSE 0 END
             ELSE 0 END
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
      OUTER APPLY (SELECT TOP (1) TRY_CONVERT(DECIMAL(38, 6), e.elem) AS num, TRY_CONVERT(DATE, e.elem) AS dt
                     FROM @elem e WHERE e.field_key = d.field_key) nv
     WHERE r.template_id = @template_id AND r.is_active = 1;

    DECLARE @group TABLE (rule_id BIGINT NOT NULL, group_no INT NOT NULL, ok INT NOT NULL);
    INSERT @group (rule_id, group_no, ok)
    SELECT rule_id, group_no, MIN(ok) FROM @cond GROUP BY rule_id, group_no;

    DECLARE @rule TABLE (rule_id BIGINT PRIMARY KEY, ok INT NOT NULL);
    INSERT @rule (rule_id, ok)
    SELECT rule_id, MAX(ok) FROM @group GROUP BY rule_id;

    DECLARE @state TABLE (field_definition_id INT PRIMARY KEY, has_show INT NOT NULL, show_ok INT NOT NULL, require_ok INT NOT NULL,
                          fired NVARCHAR(MAX) NULL);
    INSERT @state (field_definition_id, has_show, show_ok, require_ok, fired)
    SELECT r.target_field_definition_id,
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN 1 ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           MAX(CASE WHEN r.action_code IN (N'REQUIRE', N'SHOW_AND_REQUIRE') THEN x.ok ELSE 0 END),
           STRING_AGG(CASE WHEN x.ok = 1 THEN r.rule_name END, N'; ')
      FROM grac_practice.asset_form_template_rule r
      JOIN @rule x ON x.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1
     GROUP BY r.target_field_definition_id;

    INSERT @out (FieldDefinitionId, FieldKey, DisplayLabel, SectionId, IsVisible, IsMandatory, VisibilityByRule,
                 RulesFired, ValueSupplied, SectionOrder, FieldOrder)
    SELECT f.field_definition_id, d.field_key, d.display_label, f.section_id,
           eff.is_visible,
           CASE WHEN eff.is_visible = 1 AND (f.is_mandatory = 1 OR ISNULL(s.require_ok, 0) = 1) THEN 1 ELSE 0 END,
           CASE WHEN ISNULL(s.has_show, 0) = 1 THEN 1 ELSE 0 END,
           s.fired,
           CASE WHEN EXISTS (SELECT 1 FROM @raw v WHERE v.field_key = d.field_key) THEN 1 ELSE 0 END,
           x.display_order, f.display_order
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
      LEFT JOIN @state s ON s.field_definition_id = f.field_definition_id
      CROSS APPLY (SELECT CASE WHEN ISNULL(s.has_show, 0) = 1 THEN s.show_ok ELSE CAST(f.is_visible AS INT) END AS is_visible) eff
     WHERE f.template_id = @template_id;
    RETURN;
END
GO

-- Re-issued from 421: same parameters, checks and columns; the logic is
-- now the function above.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_evaluate
    @organization_id BIGINT,
    @template_id     BIGINT,
    @values_json     NVARCHAR(MAX) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                    WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;
    SELECT FieldDefinitionId, FieldKey, DisplayLabel, SectionId, IsVisible, IsMandatory, VisibilityByRule, RulesFired, ValueSupplied
      FROM grac_practice.fn_asset_form_evaluate(@template_id, @values_json)
     ORDER BY SectionOrder, FieldOrder;
END
GO
PRINT '428: evaluation engine ready.';
GO

-- =====================================================================
-- 4. Values every MASTER: lookup source may take for an organization
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_master_lookup (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT N'MASTER:ASSET_CATEGORY' AS Source, CAST(c.asset_category_id AS NVARCHAR(160)) AS Value,
           c.asset_category_name AS Label, CAST(NULL AS NVARCHAR(160)) AS ParentValue
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = f.NodeId
     WHERE f.NodeKind = N'CATEGORY'
    UNION ALL
    SELECT N'MASTER:ASSET_SUBCATEGORY', CAST(s.subcategory_id AS NVARCHAR(160)),
           CASE WHEN p.subcategory_id IS NULL THEN s.subcategory_name ELSE p.subcategory_name + N' / ' + s.subcategory_name END,
           CAST(s.asset_category_id AS NVARCHAR(160))
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = f.NodeId
      LEFT JOIN grac_practice.dependency_asset_subcategory_master p ON p.subcategory_id = s.parent_subcategory_id
     WHERE f.NodeKind = N'SUBCATEGORY'
    UNION ALL
    SELECT N'MASTER:ASSET_TYPE', CAST(t.asset_type_id AS NVARCHAR(160)), t.asset_type_name, CAST(t.subcategory_id AS NVARCHAR(160))
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = f.NodeId
     WHERE f.NodeKind = N'TYPE'
    UNION ALL
    SELECT N'MASTER:ORGANIZATION', CAST(o.organization_id AS NVARCHAR(160)), o.organization_name, NULL
      FROM grac_practice.organization o WHERE o.organization_id = @organization_id
    UNION ALL
    SELECT N'MASTER:LOCATION', CAST(l.location_id AS NVARCHAR(160)), l.location_name, NULL
      FROM grac_practice.organization_location l WHERE l.organization_id = @organization_id AND l.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE', CAST(e.employee_id AS NVARCHAR(160)), e.employee_name, NULL
      FROM grac_practice.organization_employee e WHERE e.organization_id = @organization_id AND e.status = N'Active'
    UNION ALL
    SELECT N'MASTER:TEAM', CAST(t.team_id AS NVARCHAR(160)), t.team_name, NULL
      FROM grac_practice.organization_team t WHERE t.organization_id = @organization_id AND t.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE_OR_TEAM', N'E:' + CAST(e.employee_id AS NVARCHAR(150)), e.employee_name, NULL
      FROM grac_practice.organization_employee e WHERE e.organization_id = @organization_id AND e.status = N'Active'
    UNION ALL
    SELECT N'MASTER:EMPLOYEE_OR_TEAM', N'T:' + CAST(t.team_id AS NVARCHAR(150)), t.team_name + N' (team)', NULL
      FROM grac_practice.organization_team t WHERE t.organization_id = @organization_id AND t.status = N'Active'
    UNION ALL
    SELECT N'MASTER:DEPARTMENT', CAST(d.department_id AS NVARCHAR(160)), d.department_name, NULL
      FROM grac_practice.organization_department d WHERE d.organization_id = @organization_id AND d.status = N'Active'
    UNION ALL
    SELECT N'MASTER:DIVISION', CAST(d.division_id AS NVARCHAR(160)), d.division_name, NULL
      FROM grac_practice.organization_division d WHERE d.organization_id = @organization_id AND d.status = N'Active'
    UNION ALL
    SELECT N'MASTER:VENDOR', CAST(v.vendor_id AS NVARCHAR(160)), v.vendor_name, NULL
      FROM grac_practice.organization_dependency_vendor v WHERE v.organization_id = @organization_id AND v.status = N'Active'
    UNION ALL
    SELECT N'MASTER:PROCESS', CAST(p.process_id AS NVARCHAR(160)), p.process_name, NULL
      FROM grac_practice.organization_dependency_process p WHERE p.organization_id = @organization_id AND p.status = N'Active'
    UNION ALL
    SELECT N'MASTER:PRACTICE', CAST(p.practice_id AS NVARCHAR(160)), p.practice_name, NULL
      FROM grac_practice.practice p WHERE p.organization_id = @organization_id AND p.status = N'Active'
    UNION ALL
    SELECT N'MASTER:CRITICALITY', CAST(c.criticality_id AS NVARCHAR(160)), c.criticality_name, NULL
      FROM grac_practice.criticality_master c WHERE c.is_active = 1
    UNION ALL
    SELECT N'MASTER:ASSET_FORM_TEMPLATE', CAST(t.template_id AS NVARCHAR(160)), CONCAT(t.template_name, N' v', t.version_no),
           CAST(t.asset_type_id AS NVARCHAR(160))
      FROM grac_practice.asset_form_template t WHERE t.organization_id = @organization_id AND t.is_active_version = 1
    UNION ALL
    SELECT N'MASTER:MAKE', CAST(m.make_id AS NVARCHAR(160)), m.make_name, NULL
      FROM grac_practice.asset_make m
     WHERE m.status = N'Active' AND (m.organization_id IS NULL OR m.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:MODEL', CAST(d.model_id AS NVARCHAR(160)),
           CONCAT(d.model_name, CASE WHEN d.variant IS NULL THEN N'' ELSE N' ' + d.variant END,
                  CASE WHEN d.model_number IS NULL THEN N'' ELSE N' (' + d.model_number + N')' END),
           CAST(d.make_id AS NVARCHAR(160))
      FROM grac_practice.asset_model d
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
     WHERE s.status_code = N'APPROVED' AND (d.organization_id IS NULL OR d.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:FIRMWARE', CAST(r.release_id AS NVARCHAR(160)),
           CONCAT(p.product_name, N' ', r.version, CASE WHEN r.build IS NULL THEN N'' ELSE N' build ' + r.build END),
           CAST(p.publisher_make_id AS NVARCHAR(160))
      FROM grac_practice.asset_firmware_release r
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE s.status_code NOT IN (N'DRAFT', N'WITHDRAWN') AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
    UNION ALL
    SELECT N'MASTER:OS_RELEASE', CAST(r.release_id AS NVARCHAR(160)),
           CONCAT(p.product_name, CASE WHEN r.edition IS NULL THEN N'' ELSE N' ' + r.edition END, N' ', r.version,
                  CASE WHEN r.architecture IS NULL THEN N'' ELSE N' ' + r.architecture END),
           CAST(p.publisher_make_id AS NVARCHAR(160))
      FROM grac_practice.asset_os_release r
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE s.status_code <> N'DRAFT' AND (r.organization_id IS NULL OR r.organization_id = @organization_id);
GO

-- Stored values of one asset, one row per dictionary field that has a
-- value: COLUMN fields from the asset row, VALUE fields from
-- asset_field_value, and the lifecycle status for asset_status.
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
     WHERE a.asset_id = @asset_id;
GO
PRINT '428: lookup and stored-value functions ready.';
GO

-- =====================================================================
-- 5. Cross-field rules stated in the dictionary validation text
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_field_validation_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_field_validation_rule (
        rule_id         INT            IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_field_val_rule PRIMARY KEY,
        field_key       NVARCHAR(100)  NOT NULL,
        rule_code       NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_field_val_rule_code CHECK (rule_code IN
                (N'NOT_FUTURE', N'ON_OR_AFTER', N'AFTER', N'NON_NEGATIVE', N'POSITIVE', N'NOT_GREATER_THAN', N'NOT_BELOW_STORED')),
        other_field_key NVARCHAR(100)  NULL,
        severity        NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_field_val_rule_sev CHECK (severity IN (N'ERROR', N'WARNING')),
        message         NVARCHAR(300)  NOT NULL,
        brd_text        NVARCHAR(300)  NULL,
        is_active       BIT            NOT NULL CONSTRAINT df_pm_asset_field_val_rule_active DEFAULT 1,
        entered_by      NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_field_val_rule_eby DEFAULT N'system',
        entered_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_asset_field_val_rule_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_asset_field_val_rule UNIQUE (field_key, rule_code, other_field_key)
    );
    PRINT '428: asset_field_validation_rule created.';
END
GO

MERGE grac_practice.asset_field_validation_rule AS t
USING (VALUES
    (N'manufacture_date', N'NOT_FUTURE', NULL, N'ERROR', N'Manufacture date cannot be a future date.', N'Cannot be a future date'),
    (N'purchase_date', N'NOT_FUTURE', NULL, N'ERROR', N'Purchase date cannot be a future date.', N'Cannot be a future date'),
    (N'purchase_date', N'ON_OR_AFTER', N'manufacture_date', N'WARNING', N'Purchase date is before the manufacture date; record the reason.', N'Purchase normally cannot precede manufacture without reason (5.1.16)'),
    (N'last_vulnerability_scan_date', N'NOT_FUTURE', NULL, N'ERROR', N'Last vulnerability scan date cannot be a future date.', N'Cannot be future date'),
    (N'last_calibration_date', N'NOT_FUTURE', NULL, N'ERROR', N'Last calibration date cannot be a future date.', N'Cannot be a future date'),
    (N'last_maintenance_date', N'NOT_FUTURE', NULL, N'ERROR', N'Last maintenance date cannot be a future date.', N'Cannot be a future date'),
    (N'last_inspection_date', N'NOT_FUTURE', NULL, N'ERROR', N'Last inspection date cannot be a future date.', N'Cannot be future date'),
    (N'last_electrical_safety_test', N'NOT_FUTURE', NULL, N'ERROR', N'Last electrical safety test cannot be a future date.', N'Cannot be future date'),
    (N'registration_date', N'NOT_FUTURE', NULL, N'ERROR', N'Registration date cannot be a future date.', N'Cannot be future date'),
    (N'last_service_date', N'NOT_FUTURE', NULL, N'ERROR', N'Last service date cannot be a future date.', N'Cannot be future date'),
    (N'sanitization_date', N'NOT_FUTURE', NULL, N'ERROR', N'Sanitization date cannot be a future date.', N'Cannot be future date'),
    (N'assignment_end_date', N'ON_OR_AFTER', N'assignment_start_date', N'ERROR', N'Assignment end date must follow the assignment start date.', N'Assignment start cannot be after assignment end'),
    (N'warranty_expiry_date', N'ON_OR_AFTER', N'warranty_start_date', N'ERROR', N'Warranty expiry cannot be before the warranty start date.', N'Warranty start must be on or before warranty expiry'),
    (N'capitalization_date', N'ON_OR_AFTER', N'purchase_date', N'WARNING', N'Capitalization date is before the purchase date; this needs approval.', N'Not before purchase date unless approved'),
    (N'lease_rental_end_date', N'AFTER', N'lease_rental_start_date', N'ERROR', N'Lease / rental end date must follow the start date.', N'Must follow start date'),
    (N'registration_expiry', N'AFTER', N'registration_date', N'ERROR', N'Registration expiry must follow the registration date.', N'Must follow registration date where applicable'),
    (N'coverage_end_date', N'ON_OR_AFTER', N'coverage_start_date', N'ERROR', N'Coverage end date cannot be before the coverage start date.', N'Coverage start must not follow coverage end'),
    (N'archive_date', N'ON_OR_AFTER', N'disposal_date', N'ERROR', N'Archive date must be on or after the disposal date.', N'Must be on or after disposal date'),
    (N'purchase_cost', N'NON_NEGATIVE', NULL, N'ERROR', N'Purchase cost cannot be negative.', N'Non-negative'),
    (N'residual_value', N'NON_NEGATIVE', NULL, N'ERROR', N'Residual value cannot be negative.', N'Non-negative'),
    (N'residual_value', N'NOT_GREATER_THAN', N'purchase_cost', N'ERROR', N'Residual value cannot exceed the purchase cost.', N'Cannot exceed purchase cost'),
    (N'depreciation_rate', N'NON_NEGATIVE', NULL, N'ERROR', N'Depreciation rate cannot be negative.', N'Non-negative'),
    (N'expected_useful_life', N'POSITIVE', NULL, N'ERROR', N'Expected useful life must be a positive value.', N'Positive value'),
    (N'calibration_frequency', N'POSITIVE', NULL, N'ERROR', N'Calibration frequency must be a positive value.', N'Positive value'),
    (N'maintenance_frequency', N'POSITIVE', NULL, N'ERROR', N'Maintenance frequency must be a positive value.', N'Positive value'),
    (N'service_interval', N'POSITIVE', NULL, N'ERROR', N'Service interval must be a positive value.', N'Positive value'),
    (N'retention_period', N'POSITIVE', NULL, N'ERROR', N'Retention period must be a positive value.', N'Positive value'),
    (N'current_meter_reading', N'NON_NEGATIVE', NULL, N'ERROR', N'Meter reading cannot be negative.', N'Non-negative'),
    (N'current_meter_reading', N'NOT_BELOW_STORED', NULL, N'ERROR', N'Meter reading cannot be lower than the previous reading (an approved reset arrives with maintenance workflows).', N'Cannot be lower than previous reading without approved reset'),
    (N'odometer_reading', N'NON_NEGATIVE', NULL, N'ERROR', N'Odometer reading cannot be negative.', N'Non-negative'),
    (N'odometer_reading', N'NOT_BELOW_STORED', NULL, N'ERROR', N'Odometer reading cannot be lower than the previous reading.', N'Cannot be lower than previous reading')
) AS s(field_key, rule_code, other_field_key, severity, message, brd_text)
ON t.field_key = s.field_key AND t.rule_code = s.rule_code AND ISNULL(t.other_field_key, N'') = ISNULL(s.other_field_key, N'')
WHEN NOT MATCHED BY TARGET THEN
    INSERT (field_key, rule_code, other_field_key, severity, message, brd_text, entered_by)
    VALUES (s.field_key, s.rule_code, s.other_field_key, s.severity, s.message, s.brd_text, N'seed-428');
PRINT CONCAT('428: validation rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 6. Save -- one path for the register UI, the API and later imports.
--    Returns one result set of issues (Severity ERROR | WARNING |
--    DECISION, FieldKey, Message). @out_result: SAVED | INVALID |
--    NEEDS_DECISION. Nothing is written unless the result is SAVED.
--    @values_json: { field_key: value } -- dates yyyy-mm-dd, multi-select
--    as a JSON array, quantity as "number unit". Keys left out keep their
--    stored value. @hidden_decisions_json: { field_key: "RETAIN"|"CLEAR" }.
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

    -- Installed firmware / OS without an approved compatibility mapping (5.1.16): warning until technology exceptions exist.
    DECLARE @fw BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version' AND submitted = 1)),
            @os BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system' AND submitted = 1));
    IF @fw IS NOT NULL AND @model_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_firmware_compatibility c
         WHERE c.release_id = @fw AND c.is_active = 1 AND c.approval_status = N'APPROVED' AND c.asset_type_id = @asset_type_id
           AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
           AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @m_make OR c.make_id IS NULL)))
           AND (c.effective_from IS NULL OR c.effective_from <= @today) AND (c.effective_to IS NULL OR c.effective_to >= @today))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'firmware_version', N'This firmware has no approved compatibility record for the model.');
    IF @os IS NOT NULL AND @model_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_os_compatibility c
         WHERE c.release_id = @os AND c.is_active = 1 AND c.approval_status = N'APPROVED' AND c.asset_type_id = @asset_type_id
           AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
           AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @m_make OR c.make_id IS NULL))))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'operating_system', N'This operating system has no approved compatibility record for the model.');

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
PRINT '428: sp_asset_register_save created.';
GO

-- =====================================================================
-- 7. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @asset_type_id   INT           = NULL,
    @status_code     NVARCHAR(60)  = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) NOT BETWEEN 1 AND 200 THEN 25 ELSE @page_size END;

    ;WITH rows_ AS (
        SELECT a.asset_id, a.asset_name, a.asset_type_id, a.template_id, a.owner_id, a.location_id, a.criticality_id,
               a.asset_category_id, a.asset_subcategory_id, a.updated_dt, a.entered_dt,
               COALESCE(cs.status_code, ls.status_code) AS status_code
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
          LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
         WHERE a.organization_id = @organization_id
           AND (@asset_type_id IS NULL OR a.asset_type_id = @asset_type_id)
           AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR CAST(a.asset_id AS NVARCHAR(30)) = @search)
    )
    SELECT r.asset_id AS AssetId, r.asset_name AS AssetName,
           c.asset_category_name AS CategoryName, s.subcategory_name AS SubcategoryName,
           r.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           r.status_code AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           r.template_id AS TemplateId, tpl.version_no AS TemplateVersion,
           e.employee_name AS OwnerName, l.location_name AS LocationName, cr.criticality_name AS CriticalityName,
           ISNULL(r.updated_dt, r.entered_dt) AS LastChanged,
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
     WHERE @status_code IS NULL OR r.status_code = @status_code
     ORDER BY ISNULL(r.updated_dt, r.entered_dt) DESC, r.asset_id DESC
     OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54951, 'Asset not found for this organization.', 1;

    -- 1. The record
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, a.asset_category_id AS CategoryId, a.asset_subcategory_id AS SubcategoryId,
           a.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           a.template_id AS TemplateId, tpl.version_no AS TemplateVersion, tpl.template_name AS TemplateName,
           active.template_id AS ActiveTemplateId, active.version_no AS ActiveTemplateVersion,
           COALESCE(cs.status_code, ls.status_code) AS StatusCode, sm.status_name AS StatusName, ph.phase_name AS PhaseName,
           a.lifecycle_status AS LegacyLifecycleStatus, CONVERT(BIGINT, a.record_version) AS RecordVersion,
           a.entered_by AS EnteredBy, a.entered_dt AS EnteredDt, a.updated_by AS UpdatedBy, a.updated_dt AS UpdatedDt
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.asset_form_template tpl ON tpl.template_id = a.template_id
      LEFT JOIN grac_practice.asset_form_template active
             ON active.organization_id = a.organization_id AND active.asset_type_id = a.asset_type_id AND active.is_active_version = 1
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
      LEFT JOIN grac_practice.entity_status_master sm ON sm.entity_type = N'Asset' AND sm.status_code = COALESCE(cs.status_code, ls.status_code)
      LEFT JOIN grac_practice.asset_lifecycle_status_phase ph ON ph.status_code = COALESCE(cs.status_code, ls.status_code)
     WHERE a.asset_id = @asset_id;

    -- 2. Stored values by field key
    SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id);

    -- 3. Status history
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, emp.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'Asset' AND l.entity_id = @asset_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;
END
GO

-- The form for an asset type: the given template version (an existing
-- asset's), else the Active version; returns sp_asset_form_template_get.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_form
    @organization_id BIGINT,
    @asset_type_id   INT    = NULL,
    @template_id     BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @template_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_form_template WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;
    IF @template_id IS NULL
        SELECT @template_id = template_id FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_active_version = 1;
    IF @template_id IS NULL
        THROW 54955, 'This asset type has no Active form template. Activate one on Asset Form Templates first.', 1;
    EXEC grac_practice.sp_asset_form_template_get @organization_id = @organization_id, @template_id = @template_id;
END
GO

-- Picker values for the MASTER: sources a form uses (comma-separated list).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_lookups
    @organization_id BIGINT,
    @sources         NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.Source, m.Value, m.Label, m.ParentValue
      FROM grac_practice.fn_asset_master_lookup(@organization_id) m
     WHERE @sources IS NULL OR m.Source IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@sources, N','))
     ORDER BY m.Source, m.Label;
END
GO
PRINT '428: register readers created.';
GO

-- =====================================================================
-- 8. Menu: Asset & Contract -> Asset Register (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-register', N'Asset Register', N'Practice/Index/asset-register', 349, N'boxes-stacked', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-428', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-428');
PRINT CONCAT('428: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-428', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-register' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 0, N'Active', @active_rs, N'seed-428', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-register'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('428: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '428-a Asset lifecycle: the 27 BRD statuses, each with a phase' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'Asset') = 27
             AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_status_master s
                              WHERE s.entity_type = N'Asset'
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = s.status_code))
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '428-b asset columns + values table present',
       CASE WHEN COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_field_value','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '428-c every existing asset has a register status',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE current_status_id IS NULL)
            THEN 'PASS' ELSE 'CHECK' END
UNION ALL
SELECT '428-d template evaluate reads the shared engine (re-issued)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_evaluate')) LIKE '%fn_asset_form_evaluate%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '428-e every COLUMN dictionary field maps to a column the register reads',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition d
                              WHERE d.storage_kind = N'COLUMN'
                                AND d.column_name NOT IN (N'asset_id', N'asset_name', N'asset_category_id', N'asset_subcategory_id',
                                                          N'asset_type_id', N'organization_id', N'location_id', N'owner_id',
                                                          N'purchase_dt', N'warranty_expiry_dt', N'amc_expiry_dt', N'criticality_id',
                                                          N'remarks', N'entered_by', N'entered_dt', N'updated_by', N'updated_dt'))
            THEN 'PASS' ELSE 'FAIL -- a COLUMN field is not mapped in fn_asset_stored_values / sp_asset_register_save' END
UNION ALL
SELECT '428-f validation rules only name dictionary fields',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_validation_rule r
                              WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition d WHERE d.field_key = r.field_key)
                                 OR (r.other_field_key IS NOT NULL
                                     AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition d WHERE d.field_key = r.other_field_key)))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '428-g procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_register_save', 'sp_asset_register_list', 'sp_asset_register_get',
                                'sp_asset_register_form', 'sp_asset_register_lookups')) = 5 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '428-h menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-register' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs an Active asset form template for at least one asset type (420).
--   1. Asset & Contract -> Asset Register lists the organization's assets
--      (existing ones show Active / Draft / Disposed from their legacy
--      lifecycle status).
--   2. New Asset: pick category -> subcategory -> asset type; the form of
--      the Active template opens with its sections. Change a field that
--      drives a rule -- dependent fields appear / become required at once.
--   3. Save with a mandatory field empty -- the field is flagged, nothing
--      is saved. Fill it; a future purchase date is refused; a residual
--      value above the purchase cost is refused.
--   4. Pick a make and a model of another make -- refused (model / make).
--   5. Save -- status Draft, template version recorded; reopen: the
--      values come back. Settings -> Dependencies -> Assets still shows it.
--   6. Edit so a field with hidden-value behaviour CLEAR becomes hidden --
--      the save asks to keep or clear the stored value.
--   7. Open the same asset in two tabs and save both -- the second save is
--      refused (changed by someone else).
-- =====================================================================
