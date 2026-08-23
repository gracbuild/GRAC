-- =====================================================================
-- 136 Custom checklist questions per scope + event
--
-- WHAT THIS IS FOR
-- ----------------
-- The scope mapping moves into the master-data forms: Role Master's
-- Add/Edit gets Onboarding and Offboarding sections, and a new org-scoped
-- Asset Category Assurance screen gets Commissioning and Decommissioning.
-- In each section the user ticks the inherited obligations AND can add
-- their own questions.
--
-- Only the custom questions are new. Listing the obligations and recording
-- the tick already exist -- sp_event_obligation_mapping_list and
-- sp_event_obligation_applicability_save (128/129) -- and the forms call
-- those unchanged. This migration adds nothing that duplicates them.
--
-- WHERE A CUSTOM QUESTION LIVES
-- -----------------------------
-- In grac_practice.checklist_item, on a checklist owned by the scope.
-- A third question store was the alternative and was rejected: checklist_item
-- already carries item type, mandatory, evidence-required and sequence, and
-- event_instance_item already materialises from it, so a new table would
-- mean re-implementing all of that and then teaching the resolver about it.
--
-- Finding "the checklist for this role and this event" by name would work
-- until somebody renamed one. The ownership is therefore explicit: the
-- checklist row itself records the scope and event it belongs to, and
-- is_scope_managed marks it as maintained by the form rather than by hand
-- on the Checklists screen.
--
-- The scoped event_checklist_mapping row is created with the checklist, so
-- a question added in the form actually fires -- authoring a question that
-- silently never appears would be worse than not offering the option.
--
-- Objects:
--   * grac_practice.checklist  (+ scope_dimension, scope_role_id,
--                                 scope_asset_category_id, event_type_id,
--                                 event_type_code, is_scope_managed)
--   * sp_org_scope_question_list    NEW
--   * sp_org_scope_question_save    NEW
--   * sp_org_scope_question_delete  NEW
--
-- ERROR CODES: 52400-52419 (133 owns 52300-52319).
--
-- Depends on 066, 126, 127, 128.
-- Rollback: 136_scope_custom_questions_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.checklist','U') IS NULL
   OR OBJECT_ID('grac_practice.event_checklist_mapping','U') IS NULL
   OR OBJECT_ID('grac_practice.entity_type_master','U') IS NULL
   OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    RAISERROR('136: prerequisites missing (run 066, 123 and 126 first).', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. checklist -- which scope and event this checklist belongs to
-- =====================================================================
IF COL_LENGTH('grac_practice.checklist','scope_dimension') IS NULL
    ALTER TABLE grac_practice.checklist ADD scope_dimension NVARCHAR(40) NULL;
GO
IF COL_LENGTH('grac_practice.checklist','scope_role_id') IS NULL
    ALTER TABLE grac_practice.checklist ADD scope_role_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.checklist','scope_asset_category_id') IS NULL
    ALTER TABLE grac_practice.checklist ADD scope_asset_category_id INT NULL;
GO
IF COL_LENGTH('grac_practice.checklist','event_type_id') IS NULL
    ALTER TABLE grac_practice.checklist ADD event_type_id BIGINT NULL;   -- soft ref GRAC_New
GO
IF COL_LENGTH('grac_practice.checklist','event_type_code') IS NULL
    ALTER TABLE grac_practice.checklist ADD event_type_code NVARCHAR(60) NULL;
GO
IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NULL
    ALTER TABLE grac_practice.checklist ADD is_scope_managed BIT NULL;
GO

-- Checklists that existed before 136 were authored by hand on the
-- Checklists screen. They stay editable there and are never touched by the
-- role / category forms.
IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL
    EXEC('UPDATE grac_practice.checklist SET is_scope_managed = 0 WHERE is_scope_managed IS NULL;');
GO

IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'df_pm_checklist_scope_managed')
    EXEC('ALTER TABLE grac_practice.checklist
              ADD CONSTRAINT df_pm_checklist_scope_managed DEFAULT 0 FOR is_scope_managed;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_checklist_scope_role')
    ALTER TABLE grac_practice.checklist
        ADD CONSTRAINT fk_pm_checklist_scope_role
            FOREIGN KEY (scope_role_id) REFERENCES grac_practice.organization_role(role_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_checklist_scope_asset_cat')
    ALTER TABLE grac_practice.checklist
        ADD CONSTRAINT fk_pm_checklist_scope_asset_cat
            FOREIGN KEY (scope_asset_category_id)
            REFERENCES grac_practice.dependency_asset_category_master(asset_category_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_checklist_scope')
    EXEC('ALTER TABLE grac_practice.checklist
              ADD CONSTRAINT ck_pm_checklist_scope CHECK (
                  scope_dimension IS NULL
               OR (scope_dimension = N''ORG_ROLE''
                       AND scope_role_id IS NOT NULL AND scope_asset_category_id IS NULL)
               OR (scope_dimension = N''ASSET_CATEGORY''
                       AND scope_asset_category_id IS NOT NULL AND scope_role_id IS NULL));');
GO

-- A scope-managed checklist must know which scope and event it serves,
-- otherwise the form cannot find it again and would create a second one.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_checklist_scope_managed')
    EXEC('ALTER TABLE grac_practice.checklist
              ADD CONSTRAINT ck_pm_checklist_scope_managed CHECK (
                  is_scope_managed = 0 OR is_scope_managed IS NULL
               OR (scope_dimension IS NOT NULL AND event_type_id IS NOT NULL));');
GO

-- Exactly one managed checklist per (organization, scope value, event).
IF COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'uq_pm_checklist_scope_managed'
                      AND object_id = OBJECT_ID('grac_practice.checklist'))
    EXEC('CREATE UNIQUE INDEX uq_pm_checklist_scope_managed
              ON grac_practice.checklist(organization_id, scope_dimension,
                                         scope_role_id, scope_asset_category_id, event_type_id)
              WHERE is_scope_managed = 1;');
GO

COMMIT TRAN;
GO


-- =====================================================================
-- 2. sp_org_scope_question_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_scope_question_list
    @organization_id         BIGINT,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT       = NULL,
    @scope_asset_category_id INT          = NULL,
    @event_type_code         NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @event_type_code IS NULL
        THROW 52400, 'sp_org_scope_question_list: organization_id and event_type_code are required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 52401, 'sp_org_scope_question_list: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;

    SELECT ci.checklist_item_id  AS ChecklistItemId,
           ci.checklist_id       AS ChecklistId,
           ci.item_sequence      AS SortOrder,
           ci.item_text          AS QuestionText,
           ci.item_type          AS ItemType,
           ci.is_mandatory       AS IsMandatory,
           ci.evidence_required  AS EvidenceRequired,
           ci.responsible_role   AS ResponsibleRole,
           ci.status             AS Status
    FROM   grac_practice.checklist c
    JOIN   grac_practice.checklist_item ci ON ci.checklist_id = c.checklist_id
    WHERE  c.organization_id  = @organization_id
      AND  c.is_scope_managed = 1
      AND  c.scope_dimension  = @scope_dimension
      AND  ISNULL(c.scope_role_id, -1)           = ISNULL(@scope_role_id, -1)
      AND  ISNULL(c.scope_asset_category_id, -1) = ISNULL(@scope_asset_category_id, -1)
      AND  c.event_type_code  = @event_type_code
      AND  ci.status          = N'Active'
    ORDER BY ci.item_sequence, ci.checklist_item_id;
END;
GO


-- =====================================================================
-- 3. sp_org_scope_question_save
--
--    Creates the managed checklist and its scoped mapping on first use, so
--    the question fires from the moment it is saved.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_scope_question_save
    @organization_id         BIGINT,
    @scope_dimension         NVARCHAR(40),
    @scope_role_id           BIGINT        = NULL,
    @scope_asset_category_id INT           = NULL,
    @event_type_code         NVARCHAR(60),
    @checklist_item_id       BIGINT        = NULL,   -- NULL = add
    @question_text           NVARCHAR(500),
    @is_mandatory            BIT           = 1,
    @evidence_required       BIT           = 0,
    @responsible_role        NVARCHAR(100) = NULL,
    @sort_order              INT           = NULL,
    @actor                   NVARCHAR(100) = 'api',
    @out_checklist_item_id   BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @event_type_code IS NULL
        THROW 52402, 'sp_org_scope_question_save: organization_id and event_type_code are required.', 1;
    IF @scope_dimension NOT IN (N'ORG_ROLE', N'ASSET_CATEGORY')
        THROW 52403, 'sp_org_scope_question_save: scope_dimension must be ORG_ROLE or ASSET_CATEGORY.', 1;
    IF @question_text IS NULL OR LEN(LTRIM(RTRIM(@question_text))) = 0
        THROW 52404, 'sp_org_scope_question_save: the checklist text is required.', 1;

    IF @scope_dimension = N'ORG_ROLE'
    BEGIN
        SET @scope_asset_category_id = NULL;
        IF @scope_role_id IS NULL
            THROW 52405, 'sp_org_scope_question_save: scope_role_id is required for ORG_ROLE.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @scope_role_id AND organization_id = @organization_id)
            THROW 52406, 'sp_org_scope_question_save: role does not belong to this organization.', 1;
    END
    ELSE
    BEGIN
        SET @scope_role_id = NULL;
        IF @scope_asset_category_id IS NULL
            THROW 52407, 'sp_org_scope_question_save: scope_asset_category_id is required for ASSET_CATEGORY.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_category_master
                        WHERE asset_category_id = @scope_asset_category_id AND is_active = 1)
            THROW 52408, 'sp_org_scope_question_save: unknown or inactive asset category.', 1;
    END

    DECLARE @event_type_id BIGINT, @subject_entity NVARCHAR(100), @event_type_name NVARCHAR(120);
    SELECT @event_type_id = event_type_id, @subject_entity = subject_entity, @event_type_name = event_name
    FROM   GRAC_New.event_type_master
    WHERE  event_code = @event_type_code AND status = N'Active';

    IF @event_type_id IS NULL
        THROW 52409, 'sp_org_scope_question_save: unknown or inactive event type.', 1;

    BEGIN TRAN;

    -- ---- find or create the managed checklist ------------------------
    DECLARE @checklist_id BIGINT;
    SELECT @checklist_id = checklist_id
    FROM   grac_practice.checklist
    WHERE  organization_id  = @organization_id
      AND  is_scope_managed = 1
      AND  scope_dimension  = @scope_dimension
      AND  ISNULL(scope_role_id, -1)           = ISNULL(@scope_role_id, -1)
      AND  ISNULL(scope_asset_category_id, -1) = ISNULL(@scope_asset_category_id, -1)
      AND  event_type_id    = @event_type_id;

    IF @checklist_id IS NULL
    BEGIN
        DECLARE @scope_label NVARCHAR(200) =
            CASE WHEN @scope_dimension = N'ORG_ROLE'
                 THEN (SELECT role_name FROM grac_practice.organization_role WHERE role_id = @scope_role_id)
                 ELSE (SELECT asset_category_name FROM grac_practice.dependency_asset_category_master
                        WHERE asset_category_id = @scope_asset_category_id) END;

        -- checklist_code is UNIQUE per organization, so it is built from the
        -- ids rather than the names: renaming a role must not orphan its
        -- questions or collide with another code.
        DECLARE @code NVARCHAR(60) = LEFT(CONCAT(N'SCOPE-', @event_type_id, N'-',
                                          COALESCE(@scope_role_id, @scope_asset_category_id)), 60);

        INSERT grac_practice.checklist
            (organization_id, checklist_code, checklist_name, description, version, status,
             scope_dimension, scope_role_id, scope_asset_category_id,
             event_type_id, event_type_code, is_scope_managed, entered_by)
        VALUES
            (@organization_id, @code,
             LEFT(CONCAT(@event_type_name, N' -- ', @scope_label), 200),
             N'Maintained from the scope form. Edit these questions there, not on the Checklists screen.',
             N'1.0', N'Active',
             @scope_dimension, @scope_role_id, @scope_asset_category_id,
             @event_type_id, @event_type_code, 1, @actor);
        SET @checklist_id = SCOPE_IDENTITY();
    END

    -- ---- make sure it actually fires ---------------------------------
    -- A question the user authored that never reaches a checklist would be
    -- worse than not offering the option at all.
    DECLARE @entity_type_id BIGINT = (
        SELECT TOP 1 entity_type_id FROM grac_practice.entity_type_master
         WHERE organization_id = @organization_id
           AND entity_type_code = CASE WHEN @subject_entity LIKE N'%ASSET%' THEN N'ASSET' ELSE N'PEOPLE' END
           AND status = N'Active');

    DECLARE @event_definition_id BIGINT = (
        SELECT TOP 1 event_definition_id FROM grac_practice.event_definition
         WHERE organization_id = @organization_id AND event_code = @event_type_code AND status = N'Active');

    IF @entity_type_id IS NULL OR @event_definition_id IS NULL
        THROW 52410, 'sp_org_scope_question_save: the organization has no entity type / event definition for this event. Run migration 126.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_checklist_mapping
                    WHERE organization_id     = @organization_id
                      AND event_definition_id = @event_definition_id
                      AND checklist_id        = @checklist_id
                      AND ISNULL(scope_role_id, -1)           = ISNULL(@scope_role_id, -1)
                      AND ISNULL(scope_asset_category_id, -1) = ISNULL(@scope_asset_category_id, -1))
        INSERT grac_practice.event_checklist_mapping
            (organization_id, entity_type_id, event_definition_id, checklist_id,
             scope_dimension, scope_role_id, scope_asset_category_id, status, entered_by)
        VALUES
            (@organization_id, @entity_type_id, @event_definition_id, @checklist_id,
             @scope_dimension, @scope_role_id, @scope_asset_category_id, N'Active', @actor);

    -- ---- the question itself -----------------------------------------
    IF @sort_order IS NULL
        SELECT @sort_order = ISNULL(MAX(item_sequence), 0) + 1
        FROM   grac_practice.checklist_item WHERE checklist_id = @checklist_id;

    IF @checklist_item_id IS NULL
    BEGIN
        INSERT grac_practice.checklist_item
            (checklist_id, item_sequence, item_text, item_type, is_mandatory,
             evidence_required, responsible_role, status, entered_by)
        VALUES
            (@checklist_id, @sort_order, @question_text, N'Manual', @is_mandatory,
             @evidence_required, @responsible_role, N'Active', @actor);
        SET @out_checklist_item_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.checklist_item
           SET item_sequence     = @sort_order,
               item_text         = @question_text,
               is_mandatory      = @is_mandatory,
               evidence_required = @evidence_required,
               responsible_role  = @responsible_role
         WHERE checklist_item_id = @checklist_item_id
           AND checklist_id      = @checklist_id;

        IF @@ROWCOUNT = 0
            THROW 52411, 'sp_org_scope_question_save: checklist not found for this scope.', 1;

        SET @out_checklist_item_id = @checklist_item_id;
    END

    INSERT grac_practice.event_audit
        (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, N'Checklist', @checklist_id,
         CASE WHEN @checklist_item_id IS NULL THEN N'Create' ELSE N'Update' END, @actor,
         CONCAT(N'scope=', @scope_dimension,
                N';value=', COALESCE(@scope_role_id, @scope_asset_category_id),
                N';event=', @event_type_code,
                N';item=', @out_checklist_item_id),
         SYSUTCDATETIME());

    COMMIT TRAN;

    SELECT @out_checklist_item_id AS ChecklistItemId, @checklist_id AS ChecklistId;
END;
GO


-- =====================================================================
-- 4. sp_org_scope_question_delete
--
--    Soft delete. A question that has already been answered on a raised
--    checklist is evidence; removing the row would leave those answers
--    pointing at nothing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_scope_question_delete
    @organization_id   BIGINT,
    @checklist_item_id BIGINT,
    @actor             NVARCHAR(100) = 'api'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @checklist_id BIGINT, @managed BIT;
    SELECT @checklist_id = c.checklist_id, @managed = c.is_scope_managed
    FROM   grac_practice.checklist_item ci
    JOIN   grac_practice.checklist c ON c.checklist_id = ci.checklist_id
    WHERE  ci.checklist_item_id = @checklist_item_id
      AND  c.organization_id    = @organization_id;

    IF @checklist_id IS NULL
        THROW 52412, 'sp_org_scope_question_delete: checklist not found for this organization.', 1;
    IF @managed = 0
        THROW 52413, 'sp_org_scope_question_delete: this belongs to a hand-authored checklist. Edit it on the Checklists screen.', 1;

    UPDATE grac_practice.checklist_item
       SET status = N'Inactive'
     WHERE checklist_item_id = @checklist_item_id;

    INSERT grac_practice.event_audit
        (organization_id, entity_type, entity_id, action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, N'Checklist', @checklist_id, N'Delete', @actor,
         CONCAT(N'item=', @checklist_item_id, N';soft-deleted'), SYSUTCDATETIME());
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'checklist.scope_dimension'  AS Check_, CASE WHEN COL_LENGTH('grac_practice.checklist','scope_dimension')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'checklist.is_scope_managed', CASE WHEN COL_LENGTH('grac_practice.checklist','is_scope_managed') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'one managed checklist per scope', CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uq_pm_checklist_scope_managed') THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_scope_question_list',   CASE WHEN OBJECT_ID('grac_practice.sp_org_scope_question_list','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_scope_question_save',   CASE WHEN OBJECT_ID('grac_practice.sp_org_scope_question_save','P')   IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_org_scope_question_delete', CASE WHEN OBJECT_ID('grac_practice.sp_org_scope_question_delete','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- The four event codes the two forms will use must exist per organization,
-- or adding a question throws 52410.
SELECT o.organization_id, o.organization_name AS OrganizationName,
       SUM(CASE WHEN ed.event_code = N'PEOPLE_ONBOARDING'     THEN 1 ELSE 0 END) AS PeopleOnboard,
       SUM(CASE WHEN ed.event_code = N'PEOPLE_OFFBOARDING'    THEN 1 ELSE 0 END) AS PeopleOffboard,
       SUM(CASE WHEN ed.event_code = N'ASSET_COMMISSIONING'   THEN 1 ELSE 0 END) AS AssetCommission,
       SUM(CASE WHEN ed.event_code = N'ASSET_DECOMMISSIONING' THEN 1 ELSE 0 END) AS AssetDecommission
FROM   grac_practice.organization o
LEFT JOIN grac_practice.event_definition ed
       ON ed.organization_id = o.organization_id AND ed.status = N'Active'
WHERE  o.status = N'Active'
GROUP BY o.organization_id, o.organization_name
ORDER BY o.organization_id;

PRINT '136 Scope custom questions deployed.';
PRINT 'Any organization showing a 0 above needs migration 126 re-run before questions can be added.';
GO

SET NOEXEC OFF;
GO
