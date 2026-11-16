-- =====================================================================
-- 568  Audit Reports (Audit Change spec 4.9 -- reports; P1 phase H;
--      docs/audit-change-p0-plan.md)
--
-- REQUEST (2026-11-16, sir): formal audit reports. Sir's answers:
--   * One report per ENGAGEMENT, covering all its executions.
--   * Built in the app from the audit data, with editable narrative
--     sections; printed / saved as PDF from the browser. A configurable
--     report TEMPLATE = which sections, their order, headings and
--     standard text.
--   Sections (spec 4.9): audit objective and mandate; scope and
--   methodology; audit period; executive summary; audit coverage; key
--   findings with risk ratings; management responses; recommendations;
--   overall audit conclusion; approval and issue history.
--   Lifecycle (assumed, said so to sir): Draft -> In Review (the lead
--   submits) -> Approved (the engagement Reviewer, else the lead; every
--   execution of the engagement Approved or Closed) or Returned (reason)
--   -> Issued (the lead; the report's data is frozen as issued).
--   Revise: an Issued report goes back to Draft as version + 1; every
--   issued version stays readable.
--
-- WHAT THIS DOES
--   1. NEW org_assurance_report_section_master (10 sections, seeded).
--   2. NEW org_assurance_report_template / _template_section -- per
--      organization; a "Standard Audit Report" template is made from the
--      master the first time an organization's templates are read.
--   3. NEW org_assurance_report (one per engagement), _report_section
--      (heading, order, included, narrative), _report_issue (each issued
--      version: the assembled data and sections, frozen), _report_history.
--   4. NEW fn_org_assurance_engagement_roles(@plan_item_id, @employee_id)
--      -- lead / reviewer of an engagement for a person (566 team).
--   5. NEW procedures: report_section_master_list, report_template_list /
--      _get / _save, report_list, report_create, report_data_json (the
--      report's data as one JSON document -- live, and frozen at issue),
--      report_get, report_section_save, report_action.
--   6. Menu: Audit Assurance -> Audit Reports (472, after Observations),
--      the Audit Plans permissions copied; written back into 274.
--
-- ERRORS: 54070 lead only; 54071 reviewer only; 54072 not allowed in the
--   report's state; 54073 the engagement has no execution; 54074 the
--   engagement already has a report; 54075 not found; 54076 executive
--   summary / conclusion missing; 54077 executions not all approved /
--   closed; 54078 reason required; 54079 template invalid.
-- DEPENDS ON: 566, 567.
-- Rollback: 568_audit_reports_rollback.sql.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_rows','IF') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_working_paper','U') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_observation','management_response') IS NULL
BEGIN
    PRINT 'ABORT (568): run 566 and 567 first. Nothing was changed.';
    RAISERROR('568_audit_reports: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The report sections (spec 4.9)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_report_section_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_section_master(
        section_code    NVARCHAR(40)  NOT NULL CONSTRAINT pk_pm_oa_rpt_sec_master PRIMARY KEY,
        default_heading NVARCHAR(200) NOT NULL,
        description     NVARCHAR(400) NULL,
        display_order   INT           NOT NULL CONSTRAINT df_pm_oa_rpt_sec_master_order DEFAULT 0,
        is_active       BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_sec_master_active DEFAULT 1,
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_rpt_sec_master_by DEFAULT 'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_oa_rpt_sec_master_dt DEFAULT SYSUTCDATETIME()
    );
    PRINT '568.1: org_assurance_report_section_master created.';
END
GO
INSERT INTO grac_practice.org_assurance_report_section_master (section_code, default_heading, description, display_order, entered_by)
SELECT s.code, s.heading, s.descr, s.ord, N'seed-568'
  FROM (VALUES
    (N'OBJECTIVE',       N'Audit Objective and Mandate', N'The engagement objective, subject and the audits'' mandates', 1),
    (N'SCOPE',           N'Scope and Methodology',       N'The engagement scope, the audits and approach, items in scope, testing methods used', 2),
    (N'PERIOD',          N'Audit Period',                N'Planned and actual dates, plan and financial year', 3),
    (N'EXEC_SUMMARY',    N'Executive Summary',           N'Written by the lead auditor', 4),
    (N'COVERAGE',        N'Audit Coverage',              N'Per audit: questions concluded, working papers, score and band', 5),
    (N'FINDINGS',        N'Key Findings',                N'The findings with their risk rating (severity), condition and status', 6),
    (N'RESPONSES',       N'Management Responses',        N'Each finding''s management response and corrective action', 7),
    (N'RECOMMENDATIONS', N'Recommendations',             N'Each finding''s recommendation', 8),
    (N'CONCLUSION',      N'Overall Audit Conclusion',    N'The audits'' conclusions and the overall conclusion written by the lead', 9),
    (N'HISTORY',         N'Approval and Issue History',  N'Who prepared, reviewed, approved and issued the report, and when', 10)) s(code, heading, descr, ord)
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_section_master m WHERE m.section_code = s.code);
GO

-- =====================================================================
-- 2. Report templates (per organization)
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_report_template','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_template(
        report_template_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt_tpl PRIMARY KEY,
        organization_id    BIGINT        NOT NULL,
        template_code      NVARCHAR(60)  NOT NULL,
        template_name      NVARCHAR(200) NOT NULL,
        description        NVARCHAR(1000) NULL,
        is_default         BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_tpl_default DEFAULT 0,
        is_active          BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_tpl_active DEFAULT 1,
        entered_by         NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_rpt_tpl_by DEFAULT 'system',
        entered_dt         DATETIME2     NOT NULL CONSTRAINT df_pm_oa_rpt_tpl_dt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2     NULL,
        CONSTRAINT fk_pm_oa_rpt_tpl_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT uq_pm_oa_rpt_tpl_code UNIQUE(organization_id, template_code)
    );
    PRINT '568.2: org_assurance_report_template created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_report_template_section','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_template_section(
        template_section_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt_tpl_sec PRIMARY KEY,
        report_template_id  BIGINT        NOT NULL,
        section_code        NVARCHAR(40)  NOT NULL,
        heading             NVARCHAR(200) NOT NULL,
        display_order       INT           NOT NULL,
        is_included         BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_tpl_sec_incl DEFAULT 1,
        standard_text       NVARCHAR(MAX) NULL,
        CONSTRAINT fk_pm_oa_rpt_tpl_sec_tpl FOREIGN KEY(report_template_id)
            REFERENCES grac_practice.org_assurance_report_template(report_template_id),
        CONSTRAINT fk_pm_oa_rpt_tpl_sec_master FOREIGN KEY(section_code)
            REFERENCES grac_practice.org_assurance_report_section_master(section_code),
        CONSTRAINT uq_pm_oa_rpt_tpl_sec UNIQUE(report_template_id, section_code)
    );
    PRINT '568.2: org_assurance_report_template_section created.';
END
GO

-- =====================================================================
-- 3. Reports
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_report','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report(
        report_id                  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt PRIMARY KEY,
        organization_id            BIGINT        NOT NULL,
        org_assurance_plan_item_id BIGINT        NOT NULL,
        report_template_id         BIGINT        NULL,
        report_code                NVARCHAR(160) NOT NULL,
        report_title               NVARCHAR(300) NOT NULL,
        version_no                 INT           NOT NULL CONSTRAINT df_pm_oa_rpt_ver DEFAULT 1,
        report_status              NVARCHAR(20)  NOT NULL CONSTRAINT df_pm_oa_rpt_status DEFAULT N'Draft',
        prepared_by                NVARCHAR(240) NULL,
        submitted_dt               DATETIME2     NULL,
        approved_by                NVARCHAR(240) NULL,
        approved_dt                DATETIME2     NULL,
        issued_by                  NVARCHAR(240) NULL,
        issued_dt                  DATETIME2     NULL,
        is_active                  BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_active DEFAULT 1,
        entered_by                 NVARCHAR(100) NOT NULL CONSTRAINT df_pm_oa_rpt_by DEFAULT 'system',
        entered_dt                 DATETIME2     NOT NULL CONSTRAINT df_pm_oa_rpt_dt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100) NULL,
        updated_dt                 DATETIME2     NULL,
        CONSTRAINT fk_pm_oa_rpt_org FOREIGN KEY(organization_id) REFERENCES grac_practice.organization(organization_id),
        CONSTRAINT fk_pm_oa_rpt_item FOREIGN KEY(org_assurance_plan_item_id)
            REFERENCES grac_practice.org_assurance_plan_item(org_assurance_plan_item_id),
        CONSTRAINT ck_pm_oa_rpt_status CHECK (report_status IN (N'Draft', N'InReview', N'Returned', N'Approved', N'Issued'))
    );
    CREATE UNIQUE INDEX uq_pm_oa_rpt_item ON grac_practice.org_assurance_report(org_assurance_plan_item_id) WHERE is_active = 1;
    PRINT '568.3: org_assurance_report created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_report_section','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_section(
        report_section_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt_sec PRIMARY KEY,
        report_id         BIGINT        NOT NULL,
        section_code      NVARCHAR(40)  NOT NULL,
        heading           NVARCHAR(200) NOT NULL,
        display_order     INT           NOT NULL,
        is_included       BIT           NOT NULL CONSTRAINT df_pm_oa_rpt_sec_incl DEFAULT 1,
        narrative         NVARCHAR(MAX) NULL,
        updated_by        NVARCHAR(100) NULL,
        updated_dt        DATETIME2     NULL,
        CONSTRAINT fk_pm_oa_rpt_sec_rpt FOREIGN KEY(report_id) REFERENCES grac_practice.org_assurance_report(report_id),
        CONSTRAINT uq_pm_oa_rpt_sec UNIQUE(report_id, section_code)
    );
    PRINT '568.3: org_assurance_report_section created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_report_issue','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_issue(
        report_issue_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt_issue PRIMARY KEY,
        report_id       BIGINT        NOT NULL,
        version_no      INT           NOT NULL,
        data_json       NVARCHAR(MAX) NOT NULL,
        sections_json   NVARCHAR(MAX) NOT NULL,
        issued_by       NVARCHAR(240) NOT NULL,
        issued_dt       DATETIME2     NOT NULL CONSTRAINT df_pm_oa_rpt_issue_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_rpt_issue_rpt FOREIGN KEY(report_id) REFERENCES grac_practice.org_assurance_report(report_id),
        CONSTRAINT uq_pm_oa_rpt_issue UNIQUE(report_id, version_no)
    );
    PRINT '568.3: org_assurance_report_issue created.';
END
GO
IF OBJECT_ID('grac_practice.org_assurance_report_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.org_assurance_report_history(
        report_history_id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_oa_rpt_hist PRIMARY KEY,
        report_id         BIGINT        NOT NULL,
        version_no        INT           NOT NULL,
        action_code       NVARCHAR(20)  NOT NULL,
        from_status       NVARCHAR(20)  NULL,
        to_status         NVARCHAR(20)  NULL,
        comment           NVARCHAR(MAX) NULL,
        actor_name        NVARCHAR(240) NULL,
        entered_dt        DATETIME2     NOT NULL CONSTRAINT df_pm_oa_rpt_hist_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT fk_pm_oa_rpt_hist_rpt FOREIGN KEY(report_id) REFERENCES grac_practice.org_assurance_report(report_id)
    );
    PRINT '568.3: org_assurance_report_history created.';
END
GO

-- =====================================================================
-- 4. Lead / reviewer of an engagement (566 team): the lead is the
--    engagement's auditor; the reviewer its active REVIEWER, else the lead.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_engagement_roles(@plan_item_id BIGINT, @employee_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT i.assigned_auditor_employee_id                         AS lead_employee_id,
           i.assigned_auditor_name                                AS lead_name,
           COALESCE(rv.employee_id, i.assigned_auditor_employee_id) AS reviewer_employee_id,
           COALESCE(rv.member_name, i.assigned_auditor_name)       AS reviewer_name,
           CAST(CASE WHEN @employee_id IS NOT NULL AND i.assigned_auditor_employee_id = @employee_id THEN 1 ELSE 0 END AS BIT) AS is_lead,
           CAST(CASE WHEN @employee_id IS NOT NULL
                      AND COALESCE(rv.employee_id, i.assigned_auditor_employee_id) = @employee_id THEN 1 ELSE 0 END AS BIT) AS is_reviewer
      FROM grac_practice.org_assurance_plan_item i
     OUTER APPLY (SELECT TOP 1 t.employee_id, t.member_name
                    FROM grac_practice.org_assurance_engagement_team t
                   WHERE t.org_assurance_plan_item_id = i.org_assurance_plan_item_id
                     AND t.is_active = 1 AND t.team_role = N'REVIEWER' AND t.employee_id IS NOT NULL
                   ORDER BY t.engagement_team_id) rv
     WHERE i.org_assurance_plan_item_id = @plan_item_id;
GO

-- =====================================================================
-- 5. Procedures
-- =====================================================================

-- 5a. The section master (the template editor's list).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_section_master_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT section_code AS SectionCode, default_heading AS DefaultHeading, description AS Description,
           display_order AS DisplayOrder
      FROM grac_practice.org_assurance_report_section_master
     WHERE is_active = 1
     ORDER BY display_order;
END
GO

-- 5b. An organization's templates (the Standard template is made from the
-- master the first time).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_template_list
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @organization_id IS NULL THROW 54079, 'organization_id is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_template WHERE organization_id = @organization_id)
    BEGIN
        BEGIN TRAN;
        INSERT INTO grac_practice.org_assurance_report_template
            (organization_id, template_code, template_name, description, is_default, entered_by)
        VALUES (@organization_id, N'STANDARD', N'Standard Audit Report',
                N'Every section of the audit report, in the order of the Audit Change specification (4.9).', 1, @actor);
        DECLARE @tid BIGINT = SCOPE_IDENTITY();
        INSERT INTO grac_practice.org_assurance_report_template_section
            (report_template_id, section_code, heading, display_order, is_included)
        SELECT @tid, section_code, default_heading, display_order, 1
          FROM grac_practice.org_assurance_report_section_master WHERE is_active = 1;
        COMMIT;
    END

    SELECT t.report_template_id AS ReportTemplateId, t.template_code AS TemplateCode, t.template_name AS TemplateName,
           t.description AS Description, t.is_default AS IsDefault, t.is_active AS IsActive,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_report_template_section s
             WHERE s.report_template_id = t.report_template_id AND s.is_included = 1) AS IncludedSectionCount,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_report r
             WHERE r.report_template_id = t.report_template_id AND r.is_active = 1) AS ReportCount,
           ISNULL(t.updated_dt, t.entered_dt) AS ChangedDt
      FROM grac_practice.org_assurance_report_template t
     WHERE t.organization_id = @organization_id
     ORDER BY t.is_default DESC, t.template_name;
END
GO

-- 5c. One template's sections (every master section; missing ones are
-- shown left out).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_template_get
    @organization_id    BIGINT,
    @report_template_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT m.section_code AS SectionCode,
           ISNULL(s.heading, m.default_heading) AS Heading,
           ISNULL(s.display_order, 100 + m.display_order) AS DisplayOrder,
           CAST(ISNULL(s.is_included, 0) AS BIT) AS IsIncluded,
           s.standard_text AS StandardText,
           m.description AS Description
      FROM grac_practice.org_assurance_report_section_master m
      JOIN grac_practice.org_assurance_report_template t
           ON t.report_template_id = @report_template_id AND t.organization_id = @organization_id
      LEFT JOIN grac_practice.org_assurance_report_template_section s
           ON s.report_template_id = t.report_template_id AND s.section_code = m.section_code
     WHERE m.is_active = 1
     ORDER BY ISNULL(s.display_order, 100 + m.display_order);
END
GO

-- 5d. Create / change a template: name, description, default, sections
-- [{ sectionCode, heading, displayOrder, isIncluded, standardText }].
-- One default per organization. Reports already made keep their sections.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_template_save
    @organization_id    BIGINT,
    @report_template_id BIGINT        = NULL,
    @template_name      NVARCHAR(200),
    @description        NVARCHAR(1000) = NULL,
    @is_default         BIT           = 0,
    @is_active          BIT           = 1,
    @sections_json      NVARCHAR(MAX),
    @actor              NVARCHAR(100) = 'system',
    @report_template_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @template_name = NULLIF(LTRIM(RTRIM(@template_name)), N'');
    IF @organization_id IS NULL OR @template_name IS NULL
        THROW 54079, 'Give the template a name.', 1;
    IF ISJSON(@sections_json) <> 1
        THROW 54079, 'The template sections are not valid.', 1;
    DECLARE @s TABLE (section_code NVARCHAR(40), heading NVARCHAR(200), display_order INT, is_included BIT, standard_text NVARCHAR(MAX));
    INSERT INTO @s
    SELECT x.sectionCode, LEFT(NULLIF(LTRIM(RTRIM(x.heading)), N''), 200), ISNULL(x.displayOrder, 0),
           ISNULL(x.isIncluded, 0), NULLIF(x.standardText, N'')
      FROM OPENJSON(@sections_json) WITH (
            sectionCode  NVARCHAR(40)  '$.sectionCode',
            heading      NVARCHAR(400) '$.heading',
            displayOrder INT           '$.displayOrder',
            isIncluded   BIT           '$.isIncluded',
            standardText NVARCHAR(MAX) '$.standardText') x;
    IF EXISTS (SELECT 1 FROM @s s WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_section_master m
                                                    WHERE m.section_code = s.section_code))
        THROW 54079, 'Unknown report section.', 1;
    IF NOT EXISTS (SELECT 1 FROM @s WHERE is_included = 1)
        THROW 54079, 'A template includes at least one section.', 1;
    IF @report_template_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_template
                                                        WHERE report_template_id = @report_template_id
                                                          AND organization_id = @organization_id)
        THROW 54075, 'The template was not found in this organization.', 1;
    IF ISNULL(@is_default, 0) = 1 AND ISNULL(@is_active, 1) = 0
        THROW 54079, 'The default template must be active.', 1;

    BEGIN TRAN;
    IF @report_template_id IS NULL
    BEGIN
        DECLARE @n INT = (SELECT COUNT(*) FROM grac_practice.org_assurance_report_template WHERE organization_id = @organization_id) + 1;
        DECLARE @code NVARCHAR(60) = N'TPL-' + RIGHT(N'00' + CAST(@n AS NVARCHAR(10)), 3);
        WHILE EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_template
                       WHERE organization_id = @organization_id AND template_code = @code)
        BEGIN
            SET @n += 1;
            SET @code = N'TPL-' + RIGHT(N'00' + CAST(@n AS NVARCHAR(10)), 3);
        END
        INSERT INTO grac_practice.org_assurance_report_template
            (organization_id, template_code, template_name, description, is_default, is_active, entered_by)
        VALUES (@organization_id, @code, @template_name, @description, ISNULL(@is_default, 0), ISNULL(@is_active, 1), @actor);
        SET @report_template_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- the only default cannot be switched off here (make another the default)
        IF ISNULL(@is_default, 0) = 0
           AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_template
                        WHERE report_template_id = @report_template_id AND is_default = 1)
            THROW 54079, 'Make another template the default first.', 1;
        UPDATE grac_practice.org_assurance_report_template
           SET template_name = @template_name, description = @description, is_default = ISNULL(@is_default, 0),
               is_active = ISNULL(@is_active, 1), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE report_template_id = @report_template_id;
        SET @report_template_id_out = @report_template_id;
    END
    IF ISNULL(@is_default, 0) = 1
        UPDATE grac_practice.org_assurance_report_template
           SET is_default = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @organization_id AND report_template_id <> @report_template_id_out AND is_default = 1;

    DELETE FROM grac_practice.org_assurance_report_template_section WHERE report_template_id = @report_template_id_out;
    INSERT INTO grac_practice.org_assurance_report_template_section
        (report_template_id, section_code, heading, display_order, is_included, standard_text)
    SELECT @report_template_id_out, s.section_code, ISNULL(s.heading, m.default_heading), s.display_order, s.is_included, s.standard_text
      FROM @s s
      JOIN grac_practice.org_assurance_report_section_master m ON m.section_code = s.section_code;
    COMMIT;
END
GO

-- 5e. The engagements that have executions, with their report.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_list
    @organization_id BIGINT,
    @employee_id     BIGINT        = NULL,
    @status          NVARCHAR(20)  = NULL,   -- NONE (no report yet) / Draft / InReview / Returned / Approved / Issued
    @search          NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54079, 'organization_id is required.', 1;
    SELECT r.EngagementId, r.EngagementCode, r.EngagementName, r.EngagementOrigin, r.PlanCode, r.ProgrammeName,
           r.AuditSubject, r.LeadAuditorName, r.EngagementStatus, r.PlannedStart, r.PlannedEnd,
           ro.reviewer_name AS ReviewerName, ro.is_lead AS IsLead, ro.is_reviewer AS IsReviewer,
           ex.ExecutionTotal, ex.ExecutionApproved,
           (SELECT COUNT(*) FROM grac_practice.org_assurance_observation o
              JOIN grac_practice.org_assurance_execution e ON e.org_assurance_execution_id = o.org_assurance_execution_id
             WHERE e.org_assurance_plan_item_id = r.EngagementId AND o.is_active = 1 AND e.is_active = 1) AS FindingCount,
           rp.report_id AS ReportId, rp.report_code AS ReportCode, rp.report_status AS ReportStatus,
           rp.version_no AS VersionNo, rp.issued_dt AS IssuedDt, rp.approved_dt AS ApprovedDt
      FROM grac_practice.fn_org_assurance_engagement_rows(@organization_id) r
     CROSS APPLY grac_practice.fn_org_assurance_engagement_roles(r.EngagementId, @employee_id) ro
     CROSS APPLY (SELECT COUNT(*) AS ExecutionTotal,
                         ISNULL(SUM(CASE WHEN s.status_code IN (N'Approved', N'Closed') THEN 1 ELSE 0 END), 0) AS ExecutionApproved
                    FROM grac_practice.org_assurance_execution e
                    JOIN grac_practice.org_assurance_execution_status_master s
                         ON s.org_assurance_execution_status_id = e.execution_status_id
                   WHERE e.org_assurance_plan_item_id = r.EngagementId AND e.is_active = 1
                     AND s.status_code <> N'Cancelled') ex
      LEFT JOIN grac_practice.org_assurance_report rp
             ON rp.org_assurance_plan_item_id = r.EngagementId AND rp.is_active = 1
     WHERE ex.ExecutionTotal > 0
       AND (NULLIF(@status, N'') IS NULL
            OR (@status = N'NONE' AND rp.report_id IS NULL)
            OR rp.report_status = @status)
       AND (NULLIF(@search, N'') IS NULL
            OR r.EngagementCode LIKE N'%' + @search + N'%' OR r.EngagementName LIKE N'%' + @search + N'%'
            OR r.AuditSubject LIKE N'%' + @search + N'%' OR rp.report_code LIKE N'%' + @search + N'%')
     ORDER BY CASE ISNULL(rp.report_status, N'NONE') WHEN N'InReview' THEN 0 WHEN N'Returned' THEN 1 WHEN N'Draft' THEN 2
                                                     WHEN N'NONE' THEN 3 WHEN N'Approved' THEN 4 ELSE 5 END,
              r.PlannedEnd DESC, r.EngagementCode;
END
GO

-- 5f. Make the engagement's report (the lead) from a template (the
-- organization's default when none is given).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_create
    @organization_id    BIGINT,
    @plan_item_id       BIGINT,
    @report_template_id BIGINT        = NULL,
    @employee_id        BIGINT,
    @actor              NVARCHAR(100) = 'system',
    @report_id_out      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @code NVARCHAR(120), @name NVARCHAR(240), @found BIT = 0;
    SELECT @code = engagement_code, @name = ISNULL(engagement_name, definition_name), @found = 1
      FROM grac_practice.org_assurance_plan_item
     WHERE org_assurance_plan_item_id = @plan_item_id AND organization_id = @organization_id AND is_active = 1;
    IF @found = 0 THROW 54075, 'The engagement was not found in this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_assurance_engagement_roles(@plan_item_id, @employee_id) WHERE is_lead = 1)
        THROW 54070, 'Only the engagement''s lead auditor prepares its report.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                     JOIN grac_practice.org_assurance_execution_status_master s
                          ON s.org_assurance_execution_status_id = e.execution_status_id
                    WHERE e.org_assurance_plan_item_id = @plan_item_id AND e.is_active = 1 AND s.status_code <> N'Cancelled')
        THROW 54073, 'The engagement has no execution to report on yet.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.org_assurance_report WHERE org_assurance_plan_item_id = @plan_item_id AND is_active = 1)
        THROW 54074, 'The engagement already has a report.', 1;

    -- the organization's default template (none yet: every master section)
    IF @report_template_id IS NULL
        SELECT TOP 1 @report_template_id = report_template_id
          FROM grac_practice.org_assurance_report_template
         WHERE organization_id = @organization_id AND is_active = 1
         ORDER BY is_default DESC, report_template_id;
    IF @report_template_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_template
                        WHERE report_template_id = @report_template_id AND organization_id = @organization_id AND is_active = 1)
        THROW 54079, 'The template is not an active template of this organization.', 1;

    DECLARE @me NVARCHAR(240) = (SELECT employee_name FROM grac_practice.organization_employee
                                  WHERE employee_id = @employee_id AND organization_id = @organization_id);
    BEGIN TRAN;
    INSERT INTO grac_practice.org_assurance_report
        (organization_id, org_assurance_plan_item_id, report_template_id, report_code, report_title, prepared_by, entered_by)
    VALUES (@organization_id, @plan_item_id, @report_template_id, LEFT(CONCAT(@code, N'-RPT'), 160),
            LEFT(CONCAT(N'Audit Report - ', @name), 300), ISNULL(@me, @actor), @actor);
    SET @report_id_out = SCOPE_IDENTITY();
    -- the template's sections; with no template, every master section
    IF @report_template_id IS NOT NULL
        INSERT INTO grac_practice.org_assurance_report_section (report_id, section_code, heading, display_order, is_included, narrative)
        SELECT @report_id_out, s.section_code, s.heading, s.display_order, s.is_included, s.standard_text
          FROM grac_practice.org_assurance_report_template_section s
         WHERE s.report_template_id = @report_template_id;
    ELSE
        INSERT INTO grac_practice.org_assurance_report_section (report_id, section_code, heading, display_order, is_included)
        SELECT @report_id_out, section_code, default_heading, display_order, 1
          FROM grac_practice.org_assurance_report_section_master WHERE is_active = 1;
    INSERT INTO grac_practice.org_assurance_report_history (report_id, version_no, action_code, to_status, actor_name)
    VALUES (@report_id_out, 1, N'CREATE', N'Draft', ISNULL(@me, @actor));
    COMMIT;
END
GO

-- 5g. The report's data as one JSON document -- the same document is shown
-- live while the report is being prepared and frozen when it is issued.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_data_json
    @report_id BIGINT,
    @json      NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @pi BIGINT;
    SELECT @org = organization_id, @pi = org_assurance_plan_item_id
      FROM grac_practice.org_assurance_report WHERE report_id = @report_id;

    SELECT @json = (
        SELECT
            JSON_QUERY((SELECT r.EngagementCode, r.EngagementName, r.EngagementOrigin, r.PlanCode, r.PlanName,
                               p.financial_year AS FinancialYear, r.ProgrammeName, r.AuditSubject,
                               r.EngagementObjective, r.ScopeSummary, r.AuditeeName, r.AuditeeRoleName,
                               r.LeadAuditorName, r.BranchName, r.DepartmentName, r.InitiationSourceName,
                               r.InitiationReason, r.ApprovalReference, r.PlannedStart, r.PlannedEnd,
                               r.ActualStart, r.ActualEnd, r.EngagementStatus
                          FROM grac_practice.fn_org_assurance_engagement_rows(@org) r
                          LEFT JOIN grac_practice.org_assurance_plan p ON p.org_assurance_plan_id = r.PlanId
                         WHERE r.EngagementId = @pi
                           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)) AS Engagement,
            JSON_QUERY(ISNULL((SELECT t.team_role AS TeamRole, t.member_name AS MemberName,
                                      t.member_designation AS Designation, t.external_organisation AS ExternalOrganisation
                                 FROM grac_practice.org_assurance_engagement_team t
                                WHERE t.org_assurance_plan_item_id = @pi AND t.is_active = 1
                                ORDER BY CASE t.team_role WHEN N'LEAD' THEN 0 WHEN N'MEMBER' THEN 1 WHEN N'REVIEWER' THEN 2
                                                          WHEN N'SME' THEN 3 ELSE 4 END, t.member_name
                                  FOR JSON PATH), N'[]')) AS Team,
            JSON_QUERY(ISNULL((SELECT e.definition_code AS DefinitionCode, e.definition_name AS DefinitionName,
                                      e.version_number AS VersionNumber, v.assurance_approach_name AS ApproachName,
                                      (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), m.mandate_name), N', ') WITHIN GROUP (ORDER BY m.display_order)
                                         FROM grac_practice.org_assurance_definition_mandate m
                                        WHERE m.org_assurance_definition_version_id = e.org_assurance_definition_version_id
                                          AND m.is_active = 1) AS Mandates,
                                      e.execution_code AS ExecutionCode, s.status_name AS ExecutionStatus,
                                      e.actual_start_dt AS ActualStart, e.actual_end_dt AS ActualEnd,
                                      e.total_entity_count AS ItemsInScope,
                                      (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_question q
                                        WHERE q.org_assurance_execution_id = e.org_assurance_execution_id) AS QuestionCount,
                                      (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_question q
                                        WHERE q.org_assurance_execution_id = e.org_assurance_execution_id
                                          AND q.conclusion_code IS NOT NULL) AS ConcludedCount,
                                      (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_question q
                                        WHERE q.org_assurance_execution_id = e.org_assurance_execution_id
                                          AND q.conclusion_code = N'UNSATISFACTORY') AS UnsatisfactoryCount,
                                      (SELECT COUNT(*) FROM grac_practice.org_assurance_execution_question q
                                        WHERE q.org_assurance_execution_id = e.org_assurance_execution_id
                                          AND q.conclusion_code = N'PARTIAL') AS PartialCount,
                                      (SELECT COUNT(*) FROM grac_practice.org_assurance_working_paper wp
                                        WHERE wp.org_assurance_execution_id = e.org_assurance_execution_id AND wp.is_active = 1) AS PaperCount,
                                      e.score_pct AS ScorePct, e.score_band_name AS ScoreBandName,
                                      e.audit_conclusion AS AuditConclusion, e.conclusion_by AS ConclusionBy
                                 FROM grac_practice.org_assurance_execution e
                                 JOIN grac_practice.org_assurance_execution_status_master s
                                      ON s.org_assurance_execution_status_id = e.execution_status_id
                                 LEFT JOIN grac_practice.org_assurance_definition_version v
                                      ON v.org_assurance_definition_version_id = e.org_assurance_definition_version_id
                                WHERE e.org_assurance_plan_item_id = @pi AND e.is_active = 1 AND s.status_code <> N'Cancelled'
                                ORDER BY e.execution_code
                                  FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS Executions,
            JSON_QUERY(ISNULL((SELECT m.method_name AS MethodName, COUNT(*) AS PaperCount
                                 FROM grac_practice.org_assurance_working_paper wp
                                 JOIN grac_practice.org_assurance_execution e ON e.org_assurance_execution_id = wp.org_assurance_execution_id
                                 JOIN grac_practice.org_assurance_testing_method_master m ON m.method_code = wp.testing_method_code
                                WHERE e.org_assurance_plan_item_id = @pi AND e.is_active = 1 AND wp.is_active = 1
                                GROUP BY m.method_name, m.display_order
                                ORDER BY m.display_order
                                  FOR JSON PATH), N'[]')) AS Methods,
            JSON_QUERY(ISNULL((SELECT o.observation_code AS ObservationCode, o.observation_title AS Title,
                                      o.observation_type AS ObservationType, o.severity_name AS Severity,
                                      sv.display_order AS SeverityOrder, os.status_name AS Status,
                                      om.origin_name AS Origin, o.observation_description AS Description,
                                      o.audit_criteria AS AuditCriteria, o.condition_text AS ConditionText,
                                      o.root_cause AS RootCause, o.risk_impact AS RiskImpact,
                                      o.recommendation AS Recommendation, o.management_response AS ManagementResponse,
                                      o.corrective_action AS CorrectiveAction,
                                      o.assigned_owner_display_name AS OwnerName, o.due_date AS TargetDate,
                                      e.execution_code AS ExecutionCode
                                 FROM grac_practice.org_assurance_observation o
                                 JOIN grac_practice.org_assurance_execution e ON e.org_assurance_execution_id = o.org_assurance_execution_id
                                 JOIN grac_practice.org_assurance_observation_status_master os
                                      ON os.org_assurance_observation_status_id = o.observation_status_id
                                 LEFT JOIN grac_practice.org_assurance_observation_severity_master sv
                                      ON sv.org_assurance_observation_severity_id = o.severity_id
                                 LEFT JOIN grac_practice.org_assurance_observation_origin_master om
                                      ON om.origin_code = o.observation_origin_code
                                WHERE e.org_assurance_plan_item_id = @pi AND e.is_active = 1 AND o.is_active = 1
                                ORDER BY ISNULL(sv.display_order, 99), o.observation_code   -- Critical (1) first
                                  FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS Findings,
            SYSUTCDATETIME() AS AssembledDt
          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
END
GO

-- 5h. One report: the row (with the caller's role), its sections, its data
-- (frozen when Issued, live otherwise), its history and issued versions.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_get
    @organization_id BIGINT,
    @report_id       BIGINT,
    @employee_id     BIGINT = NULL,
    @version_no      INT    = NULL   -- an issued version to read (default: the current)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pi BIGINT, @status NVARCHAR(20), @ver INT;
    SELECT @pi = org_assurance_plan_item_id, @status = report_status, @ver = version_no
      FROM grac_practice.org_assurance_report
     WHERE report_id = @report_id AND organization_id = @organization_id AND is_active = 1;
    IF @pi IS NULL THROW 54075, 'The report was not found in this organization.', 1;

    DECLARE @data NVARCHAR(MAX), @sections NVARCHAR(MAX), @shown INT = ISNULL(@version_no, @ver), @frozen BIT = 0;
    IF @version_no IS NOT NULL OR @status = N'Issued'
        SELECT @data = data_json, @sections = sections_json, @frozen = 1
          FROM grac_practice.org_assurance_report_issue
         WHERE report_id = @report_id AND version_no = @shown;
    IF @frozen = 0
    BEGIN
        IF @version_no IS NOT NULL AND @version_no <> @ver
            THROW 54075, 'That version of the report was not issued.', 1;
        EXEC grac_practice.sp_org_assurance_report_data_json @report_id = @report_id, @json = @data OUTPUT;
    END

    SELECT rp.report_id AS ReportId, rp.report_code AS ReportCode, rp.report_title AS ReportTitle,
           rp.version_no AS VersionNo, @shown AS ShownVersionNo, @frozen AS IsFrozen,
           rp.report_status AS ReportStatus, rp.prepared_by AS PreparedBy, rp.submitted_dt AS SubmittedDt,
           rp.approved_by AS ApprovedBy, rp.approved_dt AS ApprovedDt, rp.issued_by AS IssuedBy, rp.issued_dt AS IssuedDt,
           t.template_name AS TemplateName, rp.org_assurance_plan_item_id AS EngagementId,
           ro.lead_name AS LeadAuditorName, ro.reviewer_name AS ReviewerName,
           ro.is_lead AS IsLead, ro.is_reviewer AS IsReviewer, @data AS DataJson
      FROM grac_practice.org_assurance_report rp
      LEFT JOIN grac_practice.org_assurance_report_template t ON t.report_template_id = rp.report_template_id
     CROSS APPLY grac_practice.fn_org_assurance_engagement_roles(rp.org_assurance_plan_item_id, @employee_id) ro
     WHERE rp.report_id = @report_id;

    IF @frozen = 1
        SELECT x.SectionCode, x.Heading, x.DisplayOrder, x.IsIncluded, x.Narrative
          FROM OPENJSON(@sections) WITH (SectionCode NVARCHAR(40) '$.SectionCode', Heading NVARCHAR(200) '$.Heading',
                                          DisplayOrder INT '$.DisplayOrder', IsIncluded BIT '$.IsIncluded',
                                          Narrative NVARCHAR(MAX) '$.Narrative') x
         ORDER BY x.DisplayOrder;
    ELSE
        SELECT s.section_code AS SectionCode, s.heading AS Heading, s.display_order AS DisplayOrder,
               s.is_included AS IsIncluded, s.narrative AS Narrative
          FROM grac_practice.org_assurance_report_section s
         WHERE s.report_id = @report_id
         ORDER BY s.display_order;

    SELECT h.version_no AS VersionNo, h.action_code AS ActionCode, h.from_status AS FromStatus, h.to_status AS ToStatus,
           h.comment AS Comment, h.actor_name AS ActorName, h.entered_dt AS EnteredDt
      FROM grac_practice.org_assurance_report_history h
     WHERE h.report_id = @report_id
     ORDER BY h.entered_dt, h.report_history_id;

    SELECT i.version_no AS VersionNo, i.issued_by AS IssuedBy, i.issued_dt AS IssuedDt
      FROM grac_practice.org_assurance_report_issue i
     WHERE i.report_id = @report_id
     ORDER BY i.version_no DESC;
END
GO

-- 5i. Save the sections' narrative / inclusion (the lead; Draft or
-- Returned). @sections_json: [{ sectionCode, isIncluded, narrative }].
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_section_save
    @organization_id BIGINT,
    @report_id       BIGINT,
    @sections_json   NVARCHAR(MAX),
    @employee_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @pi BIGINT, @status NVARCHAR(20);
    SELECT @pi = org_assurance_plan_item_id, @status = report_status
      FROM grac_practice.org_assurance_report
     WHERE report_id = @report_id AND organization_id = @organization_id AND is_active = 1;
    IF @pi IS NULL THROW 54075, 'The report was not found in this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_assurance_engagement_roles(@pi, @employee_id) WHERE is_lead = 1)
        THROW 54070, 'Only the engagement''s lead auditor writes its report.', 1;
    IF @status NOT IN (N'Draft', N'Returned')
        THROW 54072, 'The report is changed while it is a Draft or Returned.', 1;
    IF ISJSON(@sections_json) <> 1 THROW 54079, 'The sections are not valid.', 1;
    BEGIN TRAN;
    UPDATE s
       SET narrative = NULLIF(x.narrative, N''), is_included = ISNULL(x.isIncluded, s.is_included),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_report_section s
      JOIN OPENJSON(@sections_json) WITH (sectionCode NVARCHAR(40) '$.sectionCode', isIncluded BIT '$.isIncluded',
                                          narrative NVARCHAR(MAX) '$.narrative') x
           ON x.sectionCode = s.section_code
     WHERE s.report_id = @report_id;
    UPDATE grac_practice.org_assurance_report SET updated_by = @actor, updated_dt = SYSUTCDATETIME() WHERE report_id = @report_id;
    COMMIT;
END
GO

-- 5j. Move a report: SUBMIT (lead: Draft / Returned -> InReview; the
-- included Executive Summary and Overall Conclusion written), RETURN
-- (reviewer: InReview -> Returned, reason), APPROVE (reviewer: InReview ->
-- Approved; every execution Approved or Closed), ISSUE (lead: Approved ->
-- Issued; the data and sections frozen as this version), REVISE (lead:
-- Issued -> Draft, version + 1, reason). The reviewer is the engagement's
-- Reviewer, else the lead.
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_report_action
    @organization_id BIGINT,
    @report_id       BIGINT,
    @action          NVARCHAR(20),
    @comment         NVARCHAR(MAX) = NULL,
    @employee_id     BIGINT,
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @action  = UPPER(LTRIM(RTRIM(@action)));
    SET @comment = NULLIF(LTRIM(RTRIM(@comment)), N'');
    IF @action NOT IN (N'SUBMIT', N'RETURN', N'APPROVE', N'ISSUE', N'REVISE')
        THROW 54072, 'Unknown report action.', 1;
    DECLARE @pi BIGINT, @status NVARCHAR(20), @ver INT;
    SELECT @pi = org_assurance_plan_item_id, @status = report_status, @ver = version_no
      FROM grac_practice.org_assurance_report
     WHERE report_id = @report_id AND organization_id = @organization_id AND is_active = 1;
    IF @pi IS NULL THROW 54075, 'The report was not found in this organization.', 1;
    DECLARE @is_lead BIT, @is_reviewer BIT;
    SELECT @is_lead = is_lead, @is_reviewer = is_reviewer FROM grac_practice.fn_org_assurance_engagement_roles(@pi, @employee_id);
    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @to NVARCHAR(20) = CASE @action WHEN N'SUBMIT' THEN N'InReview' WHEN N'RETURN' THEN N'Returned'
                                            WHEN N'APPROVE' THEN N'Approved' WHEN N'ISSUE' THEN N'Issued'
                                            ELSE N'Draft' END;

    IF @action IN (N'SUBMIT', N'ISSUE', N'REVISE') AND ISNULL(@is_lead, 0) = 0
        THROW 54070, 'Only the engagement''s lead auditor does this.', 1;
    IF @action IN (N'RETURN', N'APPROVE') AND ISNULL(@is_reviewer, 0) = 0
        THROW 54071, 'Only the engagement''s reviewer (or the lead auditor when there is none) reviews the report.', 1;
    IF (@action = N'SUBMIT' AND @status NOT IN (N'Draft', N'Returned'))
       OR (@action IN (N'RETURN', N'APPROVE') AND @status <> N'InReview')
       OR (@action = N'ISSUE' AND @status <> N'Approved')
       OR (@action = N'REVISE' AND @status <> N'Issued')
        THROW 54072, 'The report is not in a state that allows this.', 1;
    IF @action IN (N'RETURN', N'REVISE') AND @comment IS NULL
        THROW 54078, 'Give the reason.', 1;
    IF @action = N'SUBMIT'
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_report_section
                    WHERE report_id = @report_id AND is_included = 1
                      AND section_code IN (N'EXEC_SUMMARY', N'CONCLUSION')
                      AND NULLIF(LTRIM(RTRIM(narrative)), N'') IS NULL)
        THROW 54076, 'Write the Executive Summary and the Overall Audit Conclusion before submitting.', 1;
    IF @action = N'APPROVE'
       AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                     JOIN grac_practice.org_assurance_execution_status_master s
                          ON s.org_assurance_execution_status_id = e.execution_status_id
                    WHERE e.org_assurance_plan_item_id = @pi AND e.is_active = 1
                      AND s.status_code NOT IN (N'Approved', N'Closed', N'Cancelled'))
        THROW 54077, 'Every execution of the engagement must be Approved (Executions) before the report is approved.', 1;

    DECLARE @data NVARCHAR(MAX), @sections NVARCHAR(MAX);
    IF @action = N'ISSUE'
    BEGIN
        EXEC grac_practice.sp_org_assurance_report_data_json @report_id = @report_id, @json = @data OUTPUT;
        SET @sections = (SELECT s.section_code AS SectionCode, s.heading AS Heading, s.display_order AS DisplayOrder,
                                s.is_included AS IsIncluded, s.narrative AS Narrative
                           FROM grac_practice.org_assurance_report_section s
                          WHERE s.report_id = @report_id
                          ORDER BY s.display_order
                            FOR JSON PATH, INCLUDE_NULL_VALUES);
    END

    BEGIN TRAN;
    IF @action = N'ISSUE'
        INSERT INTO grac_practice.org_assurance_report_issue (report_id, version_no, data_json, sections_json, issued_by)
        VALUES (@report_id, @ver, ISNULL(@data, N'{}'), ISNULL(@sections, N'[]'), @me);
    UPDATE grac_practice.org_assurance_report
       SET report_status = @to,
           version_no    = version_no + CASE WHEN @action = N'REVISE' THEN 1 ELSE 0 END,
           submitted_dt  = CASE WHEN @action = N'SUBMIT' THEN SYSUTCDATETIME() ELSE submitted_dt END,
           approved_by   = CASE WHEN @action = N'APPROVE' THEN @me WHEN @action = N'REVISE' THEN NULL ELSE approved_by END,
           approved_dt   = CASE WHEN @action = N'APPROVE' THEN SYSUTCDATETIME() WHEN @action = N'REVISE' THEN NULL ELSE approved_dt END,
           issued_by     = CASE WHEN @action = N'ISSUE' THEN @me WHEN @action = N'REVISE' THEN NULL ELSE issued_by END,
           issued_dt     = CASE WHEN @action = N'ISSUE' THEN SYSUTCDATETIME() WHEN @action = N'REVISE' THEN NULL ELSE issued_dt END,
           updated_by    = @actor, updated_dt = SYSUTCDATETIME()
     WHERE report_id = @report_id;
    DECLARE @hist_ver INT = @ver + CASE WHEN @action = N'REVISE' THEN 1 ELSE 0 END;
    INSERT INTO grac_practice.org_assurance_report_history (report_id, version_no, action_code, from_status, to_status, comment, actor_name)
    VALUES (@report_id, @hist_ver, @action, @status, @to, @comment, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 6. Menu: Audit Assurance -> Audit Reports (472, after Observations);
--    also in 274's snapshot.
-- =====================================================================
DECLARE @assurance_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-reports', N'Audit Reports', N'Practice/org-audit-reports', 472, N'file-lines')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @assurance_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-568', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @assurance_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-568');
PRINT '568.6: org-audit-reports menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- The roles that hold Audit Plans get Audit Reports with the same rights.
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-568', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key = N'org-audit-reports'
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '568.6: org-audit-reports permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 7. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_engagement_roles'), (N'sp_org_assurance_report_section_master_list'),
               (N'sp_org_assurance_report_template_list'), (N'sp_org_assurance_report_template_get'),
               (N'sp_org_assurance_report_template_save'), (N'sp_org_assurance_report_list'),
               (N'sp_org_assurance_report_create'), (N'sp_org_assurance_report_data_json'),
               (N'sp_org_assurance_report_get'), (N'sp_org_assurance_report_section_save'),
               (N'sp_org_assurance_report_action')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('568 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.org_assurance_report_section_master) AS report_sections,
       (SELECT COUNT(*) FROM grac_practice.menu_master WHERE menu_key = N'org-audit-reports' AND status = N'Active') AS menu_rows;
PRINT '568 done: Audit Reports -- one per engagement, section templates, review, approval and issue.';
GO
