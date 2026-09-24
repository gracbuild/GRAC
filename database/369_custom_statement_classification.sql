-- =====================================================================
-- 369 Custom Statement Classification (organization-scoped, per Custom
--     Release)
--
-- Background (change request 2026-09-22, part 2): Statement Classification
-- on the Add Control Statement form was, until now, simply the Level-1
-- Source Structure node titles (see practice.js buildClassificationOptions
-- prior to this migration) -- the user clarified this was conceptually
-- wrong. The real/shared classification master lives in the Control
-- Management product's own schema: GRAC_New.statement_classification
-- (see ControlManagement/database/001_control_management_schema.sql),
-- tagged per REAL framework release (release_id -> GRAC_New.release).
--
-- Custom Releases authored in THIS product have no real GRAC_New.release_id
-- (grac_practice.repository_subscription.release_id is NULL for them; the
-- UI represents a Custom Release with a synthetic ReleaseId = -1 *
-- subscription_id -- see PracticeRepositoryService.QuerySubscribedFrameworksAsync),
-- so grac_new.statement_classification can never be tagged against a
-- Custom Release directly. The user's explicit instruction: do NOT write
-- custom/organization-added classifications into grac_new.statement_classification
-- (that table is shared across every organization). Instead, custom
-- classifications get their own table in THIS product's own schema
-- (grac_practice), scoped by organization_id so one organization's custom
-- classification is never visible to another -- and, per the user's
-- follow-up answer, additionally scoped by subscription_id (the specific
-- Custom Release) so a classification added while authoring one Custom
-- Release does not leak into another Custom Release of the same
-- organization.
--
-- grac_new.statement_classification is left completely untouched by this
-- migration -- and, per the user's follow-up (2026-09-22), it is not READ
-- either: the Add Control Statement form's Release dropdown only ever
-- offers Custom Releases, so "classification against release" means
-- against the Custom Release (subscription_id), and the shared Control
-- Management master (tagged per REAL framework release) simply does not
-- apply here. PracticeRepositoryService.QueryCustomStatementClassificationAsync
-- reads ONLY this new table, scoped to (organization_id, subscription_id).
--
-- Rollback: 369_custom_statement_classification_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.repository_subscription','U') IS NULL
BEGIN
    RAISERROR('369: run 001 schema first (grac_practice.repository_subscription not found).', 16, 1);
    RETURN;
END
GO

IF OBJECT_ID('grac_practice.custom_statement_classification','U') IS NULL
CREATE TABLE grac_practice.custom_statement_classification(
 classification_id      BIGINT IDENTITY PRIMARY KEY,
 organization_id        BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
 subscription_id        BIGINT NOT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
 classification_code    NVARCHAR(80) NULL,
 classification_name    NVARCHAR(200) NOT NULL,
 classification_scheme  NVARCHAR(200) NULL,
 description             NVARCHAR(MAX) NULL,
 display_order           INT NOT NULL DEFAULT 0,
 status                  NVARCHAR(30) NOT NULL DEFAULT 'Active',
 entered_by              NVARCHAR(100) NOT NULL,
 entered_dt              DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
 updated_by              NVARCHAR(100) NULL,
 updated_dt              DATETIME2 NULL,
 CONSTRAINT uq_pm_custom_statement_classification UNIQUE(organization_id,subscription_id,classification_name)
);
GO

IF NOT EXISTS(
    SELECT 1 FROM sys.indexes
    WHERE name='ix_pm_custom_statement_classification_lookup'
      AND object_id=OBJECT_ID('grac_practice.custom_statement_classification')
)
CREATE INDEX ix_pm_custom_statement_classification_lookup
    ON grac_practice.custom_statement_classification(organization_id, subscription_id, status)
    INCLUDE (classification_name, classification_code, classification_scheme, display_order);
GO

SELECT
    CASE WHEN OBJECT_ID('grac_practice.custom_statement_classification','U') IS NOT NULL THEN 'YES' ELSE 'NO' END AS Table_custom_statement_classification,
    CASE WHEN EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_custom_statement_classification_lookup') THEN 'YES' ELSE 'NO' END AS Index_lookup;
GO
