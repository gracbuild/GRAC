-- =====================================================================
-- tool_import_audit_question_sets.sql  (2026-11-13)
--
-- Imports the nine sample audit Question Sets and their 90 questions from
-- GRAC_Audit_Question_Sets_9_Samples.xlsx into ONE organization:
--   sheet "Question Sets" -> grac_practice.org_assurance_question_set
--   sheet "Questions"     -> grac_practice.org_assurance_question
-- The two sheets are linked by QuestionSetCode (set_code). The workbook
-- rows are embedded below as VALUES, so the script needs no file access.
--
-- HOW IT WRITES
--   Through the screen's own procedures, so every rule the Question Sets
--   page applies applies here too:
--     sp_org_assurance_question_set_save            (077)  the set
--     sp_org_assurance_question_set_questions_save  (520)  its questions
--   One transaction for the whole import: any error rolls everything back.
--
-- COLUMN MAPPING (Questions sheet -> org_assurance_question)
--   QuestionCode        question_code       (unique within the set)
--   Question            question_text
--   ResponseType        question_type_id / _code / _name -- matched by name
--                       (spaces and case ignored) against the Admin list,
--                       sp_org_assurance_admin_question_type_list (517).
--                       "Yes / No" -> the Admin "Yes / No" type.
--   Mandatory           is_mandatory        (Yes = 1)
--   Evidence            evidence_type_id    -- matched by name or code
--                       (spaces, case, "_", "-", "/" ignored) against
--                       grac_practice.evidence_type_master, the list the
--                       Question Sets "Evidence" dropdown shows. See
--                       @MissingEvidenceType for labels not in the master.
--   Weight              weight
--   DescriptionGuidance help_text           (Description / Guidance)
--   ExpectedEvidence    expected_evidence
--   Status = Active for every question; version_number is system managed
--   (1 for a new question), so the sheet's Version column is not loaded.
--   Question order = row order within the set.
--
-- SETTINGS (edit below, in the first block)
--   @OrganizationId       REQUIRED. Left NULL, the script lists the active
--                         organizations and stops.
--   @DryRun               1 (default) = report only, nothing written.
--   @ExistingSet          What to do when the organization already has a
--                         set with the same code:
--                         'SKIP'    (default) leave it alone;
--                         'REPLACE' update its name / description / status
--                                   and make its questions exactly the
--                                   sheet's: same codes updated, new codes
--                                   added, codes not in the sheet removed
--                                   (soft delete, as the screen does).
--                         The set's owner is kept either way.
--   @MissingEvidenceType  An Evidence label with no matching evidence type:
--                         'DEFAULT' (default since 2026-11-13, sir) import
--                                  the question with @DefaultEvidenceType
--                                  ("Register"); labels that match keep
--                                  their own type;
--                         'ABORT'  stop, nothing written;
--                         'CREATE' add it to evidence_type_master
--                                  (code = the label in capitals with "_");
--                         'NONE'   import the question with Evidence = Not
--                                  Applicable (no evidence required).
--   @DefaultEvidenceType  The type 'DEFAULT' uses, matched by name or code
--                         like the labels (default "Register"). If it is
--                         not in evidence_type_master the script stops.
--
-- RUN
--   1. Set @OrganizationId, keep @DryRun = 1, run. Check the result sets:
--      sets (create / skip / replace), response types, evidence labels.
--   2. Choose @ExistingSet / @MissingEvidenceType, set @DryRun = 0, run.
--
-- DEPENDS ON: 076, 077, 517 (Admin response types), 520 (question grid).
-- ASCII-only. Re-runnable: a second run with 'SKIP' changes nothing.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @OrganizationId      BIGINT        = NULL;      -- REQUIRED
DECLARE @DryRun              BIT           = 1;
DECLARE @ExistingSet         NVARCHAR(10)  = N'SKIP';   -- SKIP | REPLACE
DECLARE @MissingEvidenceType NVARCHAR(10)  = N'DEFAULT'; -- DEFAULT | ABORT | CREATE | NONE
DECLARE @DefaultEvidenceType NVARCHAR(160) = N'Register'; -- used by DEFAULT
DECLARE @Actor               NVARCHAR(100) = N'import-question-sets-xlsx';

-- ---------------------------------------------------------------------
-- 0. Prerequisites and settings
-- ---------------------------------------------------------------------
DECLARE @missing NVARCHAR(MAX) = N'';
IF OBJECT_ID('grac_practice.org_assurance_question_set','U') IS NULL SET @missing += N' table org_assurance_question_set (076);';
IF OBJECT_ID('grac_practice.org_assurance_question','U') IS NULL     SET @missing += N' table org_assurance_question (076);';
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_save','P') IS NULL SET @missing += N' proc sp_org_assurance_question_set_save (077);';
IF OBJECT_ID('grac_practice.sp_org_assurance_question_set_questions_save','P') IS NULL SET @missing += N' proc sp_org_assurance_question_set_questions_save (520);';
IF OBJECT_ID('grac_practice.sp_org_assurance_admin_question_type_list','P') IS NULL SET @missing += N' proc sp_org_assurance_admin_question_type_list (077/517);';
IF COL_LENGTH('grac_practice.org_assurance_question','evidence_type_id') IS NULL SET @missing += N' column org_assurance_question.evidence_type_id (520);';
IF OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL SET @missing += N' table evidence_type_master (001);';
IF @missing <> N''
BEGIN
    PRINT 'ABORT: missing --' + @missing + ' Nothing was changed.';
    RETURN;
END

IF @ExistingSet NOT IN (N'SKIP', N'REPLACE')
BEGIN PRINT 'ABORT: @ExistingSet must be SKIP or REPLACE.'; RETURN; END
IF @MissingEvidenceType NOT IN (N'DEFAULT', N'ABORT', N'CREATE', N'NONE')
BEGIN PRINT 'ABORT: @MissingEvidenceType must be DEFAULT, ABORT, CREATE or NONE.'; RETURN; END

IF @OrganizationId IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @OrganizationId)
BEGIN
    PRINT 'ABORT: set @OrganizationId to one of the organizations listed below. Nothing was changed.';
    SELECT organization_id AS OrganizationId, organization_name AS OrganizationName, status AS Status
      FROM grac_practice.organization
     ORDER BY organization_name;
    RETURN;
END

-- ---------------------------------------------------------------------
-- 1. The workbook
-- ---------------------------------------------------------------------
DECLARE @sets TABLE (
    seq          INT           NOT NULL,
    set_code     NVARCHAR(80)  NOT NULL PRIMARY KEY,
    set_name     NVARCHAR(240) NOT NULL,
    description  NVARCHAR(MAX) NULL,
    status       NVARCHAR(30)  NULL);

INSERT @sets (seq, set_code, set_name, description, status) VALUES
    ( 1, N'QS-IT-INF-001', N'IT Infrastructure Management',
         N'Evaluates governance, security, availability, maintenance and monitoring of the organization''s IT infrastructure.',
         N'Active'),
    ( 2, N'QS-IT-APP-001', N'Application Management and Security',
         N'Assesses application ownership, access controls, secure development, change management, testing and operational support.',
         N'Active'),
    ( 3, N'QS-IT-SEC-001', N'Information and Cybersecurity',
         N'Evaluates the organization''s information security governance, protective controls, security monitoring, vulnerability management and incident readiness.',
         N'Active'),
    ( 4, N'QS-IT-BCP-001', N'Backup, Business Continuity and Disaster Recovery',
         N'Assesses backup governance, recoverability, business continuity planning, disaster recovery preparedness and resilience testing.',
         N'Active'),
    ( 5, N'QS-IT-CHG-001', N'IT Change and Release Management',
         N'Evaluates authorization, risk assessment, testing, segregation, deployment and post-implementation review of IT changes.',
         N'Active'),
    ( 6, N'QS-IT-INC-001', N'IT Service and Incident Management',
         N'Assesses IT service support, incident recording, prioritization, escalation, resolution, problem management and service reporting.',
         N'Active'),
    ( 7, N'QS-TPRM-001', N'Third-Party and Outsourcing Risk Management',
         N'Evaluates third-party onboarding, due diligence, risk classification, contracting, oversight, performance and exit arrangements.',
         N'Active'),
    ( 8, N'QS-HR-PAY-001', N'HR and Payroll Controls',
         N'Evaluates employee lifecycle controls, payroll data integrity, authorization, statutory processing, reconciliations and confidentiality.',
         N'Active'),
    ( 9, N'QS-FIN-TRE-001', N'Treasury and Financial Operations',
         N'Assesses controls over treasury transactions, liquidity, bank accounts, reconciliations, approvals, investments and financial reporting.',
         N'Active');

DECLARE @qs TABLE (
    set_code          NVARCHAR(80)  NOT NULL,
    question_code     NVARCHAR(80)  NOT NULL,
    seq               INT           NOT NULL,
    response_type     NVARCHAR(200) NULL,
    mandatory         NVARCHAR(10)  NULL,
    evidence_label    NVARCHAR(160) NULL,
    weight            DECIMAL(10,2) NULL,
    question_text     NVARCHAR(MAX) NOT NULL,
    help_text         NVARCHAR(MAX) NULL,
    expected_evidence NVARCHAR(MAX) NULL,
    -- resolved below
    question_type_id   BIGINT        NULL,
    question_type_code NVARCHAR(120) NULL,
    question_type_name NVARCHAR(200) NULL,
    evidence_type_id   INT           NULL,
    PRIMARY KEY (set_code, question_code));

INSERT @qs (set_code, question_code, seq, response_type, mandatory, evidence_label, weight,
            question_text, help_text, expected_evidence) VALUES
    (N'QS-IT-INF-001', N'Q001',   1, N'Yes / No', N'Yes', N'Asset Register', 10,
         N'Is there an approved inventory of IT infrastructure assets, including servers, network devices and endpoint equipment?',
         N'Verify that infrastructure assets are uniquely identified, assigned an owner and periodically reconciled.',
         N'Current infrastructure inventory, asset ownership records and reconciliation evidence.'),
    (N'QS-IT-INF-001', N'Q002',   2, N'Yes / No', N'Yes', N'Asset Register', 10,
         N'Are infrastructure assets classified according to business criticality and information sensitivity?',
         N'Check whether asset classification considers criticality, data handled and operational dependency.',
         N'Asset classification register and criticality criteria.'),
    (N'QS-IT-INF-001', N'Q003',   3, N'Yes / No', N'Yes', N'System Report', 10,
         N'Are operating systems, firmware and infrastructure components maintained on supported versions?',
         N'Identify unsupported or end-of-life components and examine approved exception handling.',
         N'Hardware and software lifecycle reports, vendor support status and exception approvals.'),
    (N'QS-IT-INF-001', N'Q004',   4, N'Yes / No', N'Yes', N'User Register', 10,
         N'Is infrastructure access restricted to authorized administrators and reviewed periodically?',
         N'Examine administrative access lists and evidence of periodic authorization reviews.',
         N'Administrator access listing, approvals and access review records.'),
    (N'QS-IT-INF-001', N'Q005',   5, N'Yes / No', N'Yes', N'Configuration Export', 10,
         N'Are secure configuration standards defined and applied to servers, network devices and endpoints?',
         N'Sample infrastructure components and compare settings with approved hardening standards.',
         N'Hardening standards, configuration baselines and compliance reports.'),
    (N'QS-IT-INF-001', N'Q006',   6, N'Yes / No', N'Yes', N'Vulnerability Report', 15,
         N'Are infrastructure vulnerabilities identified, risk-rated and remediated within defined timelines?',
         N'Review vulnerability assessment results, remediation ageing and approved risk exceptions.',
         N'Vulnerability scan reports, remediation tickets and exception approvals.'),
    (N'QS-IT-INF-001', N'Q007',   7, N'Yes / No', N'Yes', N'System Report', 10,
         N'Are infrastructure capacity and performance monitored against defined thresholds?',
         N'Check monitoring coverage, alert thresholds and evidence of action on capacity constraints.',
         N'Capacity dashboards, utilization reports and incident or change records.'),
    (N'QS-IT-INF-001', N'Q008',   8, N'Yes / No', N'Yes', N'Inspection Report', 10,
         N'Are physical and environmental safeguards implemented for critical infrastructure locations?',
         N'Verify physical access restrictions, power protection, cooling, fire detection and environmental monitoring.',
         N'Data centre inspection records, access logs and maintenance reports.'),
    (N'QS-IT-INF-001', N'Q009',   9, N'Yes / No', N'Yes', N'Backup Report', 10,
         N'Are infrastructure backups and configuration backups performed and periodically tested where applicable?',
         N'Sample backup jobs and verify successful completion, retention and restoration testing.',
         N'Backup schedules, job reports and restoration test results.'),
    (N'QS-IT-INF-001', N'Q010',  10, N'Yes / No', N'Yes', N'Change Register', 5,
         N'Are infrastructure changes authorized, documented and traceable?',
         N'Trace a sample of infrastructure changes from request and approval through implementation and closure.',
         N'Change requests, approvals, implementation records and closure evidence.'),
    (N'QS-IT-APP-001', N'Q001',  11, N'Yes / No', N'Yes', N'Application Register', 10,
         N'Is each critical business application assigned an accountable business owner and technical owner?',
         N'Verify ownership, accountability and escalation responsibilities for critical applications.',
         N'Application inventory, ownership records and responsibility matrix.'),
    (N'QS-IT-APP-001', N'Q002',  12, N'Yes / No', N'Yes', N'Role Matrix', 10,
         N'Are application roles and permissions formally defined and approved by the relevant business owners?',
         N'Review role definitions and confirm that permissions are aligned to business responsibilities.',
         N'Role-permission matrix and business owner approvals.'),
    (N'QS-IT-APP-001', N'Q003',  13, N'Yes / No', N'Yes', N'Review Register', 10,
         N'Are application access rights periodically reviewed and inappropriate access corrected?',
         N'Sample application access reviews and trace exceptions to remediation.',
         N'Access certification reports, exception records and remediation evidence.'),
    (N'QS-IT-APP-001', N'Q004',  14, N'Yes / No', N'Yes', N'Change Register', 15,
         N'Are application changes subject to documented request, approval, testing and release procedures?',
         N'Trace a sample of releases through authorization, testing, approval and deployment.',
         N'Change tickets, test results, release approvals and deployment logs.'),
    (N'QS-IT-APP-001', N'Q005',  15, N'Yes / No', N'Yes', N'Configuration Export', 10,
         N'Are development, test and production environments appropriately segregated?',
         N'Check environment separation and restrictions on production access by developers.',
         N'Environment architecture, access lists and deployment controls.'),
    (N'QS-IT-APP-001', N'Q006',  16, N'Yes / No', N'Yes', N'Test Report', 10,
         N'Is application input, processing and output validation implemented for critical business transactions?',
         N'Inspect validation controls and sample rejected, corrected or exception transactions.',
         N'Application test cases, validation rules and exception reports.'),
    (N'QS-IT-APP-001', N'Q007',  17, N'Yes / No', N'Yes', N'Vulnerability Report', 10,
         N'Are application security vulnerabilities assessed and remediated before production release or within defined timelines?',
         N'Review application security testing and follow-up of identified vulnerabilities.',
         N'SAST/DAST or VAPT reports, remediation evidence and release approvals.'),
    (N'QS-IT-APP-001', N'Q008',  18, N'Yes / No', N'Yes', N'Audit Log', 10,
         N'Are application logs sufficient to identify user activity, privileged actions and critical transaction events?',
         N'Verify logging coverage, protection, retention and review for critical application events.',
         N'Application audit logs, logging configuration and review records.'),
    (N'QS-IT-APP-001', N'Q009',  19, N'Yes / No', N'Yes', N'Interface Register', 10,
         N'Are application interfaces and integrations authenticated, authorized and monitored?',
         N'Review critical interfaces, credentials or certificates, access restrictions and failure monitoring.',
         N'Interface inventory, API or integration configuration and monitoring reports.'),
    (N'QS-IT-APP-001', N'Q010',  20, N'Yes / No', N'Yes', N'Incident Register', 5,
         N'Are application incidents, defects and recurring problems recorded and tracked to resolution?',
         N'Sample incidents and defects and verify ownership, root cause and closure.',
         N'Incident tickets, problem records and root-cause analyses.'),
    (N'QS-IT-SEC-001', N'Q001',  21, N'Yes / No', N'Yes', N'Policy Document', 10,
         N'Is an information security policy approved by management and communicated to relevant personnel?',
         N'Check approval, review date, scope and evidence of communication.',
         N'Approved information security policy and communication records.'),
    (N'QS-IT-SEC-001', N'Q002',  22, N'Yes / No', N'Yes', N'Asset Register', 10,
         N'Are information assets and information repositories identified and classified?',
         N'Verify that sensitive information assets have owners and appropriate classification.',
         N'Information asset inventory, classification register and ownership records.'),
    (N'QS-IT-SEC-001', N'Q003',  23, N'Yes / No', N'Yes', N'Responsibility Matrix', 10,
         N'Are security responsibilities formally assigned, including oversight of information security risks?',
         N'Review designated roles, reporting lines and governance committee oversight.',
         N'Organization chart, role descriptions and committee terms of reference or minutes.'),
    (N'QS-IT-SEC-001', N'Q004',  24, N'Yes / No', N'Yes', N'System Report', 10,
         N'Are endpoint protection and security configuration controls deployed across in-scope devices?',
         N'Check deployment coverage, update status, policy enforcement and exceptions.',
         N'Endpoint security console reports, coverage reports and exception approvals.'),
    (N'QS-IT-SEC-001', N'Q005',  25, N'Yes / No', N'Yes', N'Configuration Export', 10,
         N'Are network security controls implemented to restrict and monitor traffic between trusted and untrusted networks?',
         N'Review firewall rules, network segmentation and periodic rule recertification.',
         N'Firewall rulebase, network diagrams and rule review records.'),
    (N'QS-IT-SEC-001', N'Q006',  26, N'Yes / No', N'Yes', N'Vulnerability Report', 15,
         N'Are vulnerability assessments and penetration tests conducted at defined intervals and after significant changes where required?',
         N'Verify scope, independence, coverage, findings and remediation tracking.',
         N'VA/PT reports, scope documents, remediation tracker and retest evidence.'),
    (N'QS-IT-SEC-001', N'Q007',  27, N'Yes / No', N'Yes', N'Monitoring Report', 10,
         N'Are security alerts and logs monitored, investigated and escalated within defined timelines?',
         N'Examine monitoring coverage, alert triage, escalation and closure records.',
         N'SIEM or monitoring reports, alert tickets and investigation records.'),
    (N'QS-IT-SEC-001', N'Q008',  28, N'Yes / No', N'Yes', N'Configuration Export', 10,
         N'Is sensitive information protected during storage and transmission using appropriate safeguards?',
         N'Review encryption, key management, secure transfer and approved exceptions.',
         N'Encryption standards, system configurations and key management records.'),
    (N'QS-IT-SEC-001', N'Q009',  29, N'Yes / No', N'Yes', N'Incident Register', 10,
         N'Are cybersecurity incidents recorded, assessed, escalated and reported to relevant authorities within applicable timelines?',
         N'Sample incidents and verify classification, escalation, reporting decisions and timelines.',
         N'Incident register, investigation reports and regulatory or stakeholder notifications, where applicable.'),
    (N'QS-IT-SEC-001', N'Q010',  30, N'Yes / No', N'Yes', N'Training Record', 5,
         N'Are employees made aware of information security responsibilities and emerging cyber threats?',
         N'Review awareness coverage, completion and effectiveness assessment.',
         N'Training calendar, attendance records and awareness assessment results.'),
    (N'QS-IT-BCP-001', N'Q001',  31, N'Yes / No', N'Yes', N'Policy Document', 10,
         N'Is there an approved backup policy defining systems in scope, frequency, retention and responsibilities?',
         N'Verify policy approval and alignment with business and regulatory requirements.',
         N'Approved backup policy, schedules and responsibility matrix.'),
    (N'QS-IT-BCP-001', N'Q002',  32, N'Yes / No', N'Yes', N'Backup Schedule', 10,
         N'Are critical applications, databases and infrastructure components covered by defined backup arrangements?',
         N'Reconcile critical systems against backup coverage and identify exclusions.',
         N'Critical system inventory, backup matrix and job schedules.'),
    (N'QS-IT-BCP-001', N'Q003',  33, N'Yes / No', N'Yes', N'Backup Report', 10,
         N'Are backup jobs monitored and failures investigated and resolved promptly?',
         N'Sample backup failures and verify alerting, escalation and successful reruns.',
         N'Backup job reports, failure alerts and resolution tickets.'),
    (N'QS-IT-BCP-001', N'Q004',  34, N'Yes / No', N'Yes', N'Configuration Export', 10,
         N'Are backup copies protected against unauthorized access, alteration, ransomware and site-level disruption?',
         N'Review access restrictions, immutability or offline copies, encryption and separation.',
         N'Backup architecture, access lists and storage configuration.'),
    (N'QS-IT-BCP-001', N'Q005',  35, N'Yes / No', N'Yes', N'Retention Schedule', 10,
         N'Are backup retention periods aligned with approved business, legal and regulatory requirements?',
         N'Sample backup classes and verify retention and secure disposal arrangements.',
         N'Retention schedule, backup configuration and disposal records.'),
    (N'QS-IT-BCP-001', N'Q006',  36, N'Yes / No', N'Yes', N'Test Report', 15,
         N'Are restoration tests performed periodically to demonstrate that backed-up information can be recovered?',
         N'Review restoration test scope, results, exceptions and corrective actions.',
         N'Restoration test plans, logs, results and remediation records.'),
    (N'QS-IT-BCP-001', N'Q007',  37, N'Yes / No', N'Yes', N'Assessment Report', 10,
         N'Is a business impact analysis conducted to identify critical processes and recovery priorities?',
         N'Verify process criticality, dependencies, impact horizons and approved recovery objectives.',
         N'Business impact analysis, critical process register and approved RTO/RPO.'),
    (N'QS-IT-BCP-001', N'Q008',  38, N'Yes / No', N'Yes', N'Plan Document', 10,
         N'Are business continuity and disaster recovery plans documented, approved and periodically updated?',
         N'Check plan ownership, activation criteria, contacts, dependencies and review history.',
         N'Approved BCP/DR plans, contact lists and review records.'),
    (N'QS-IT-BCP-001', N'Q009',  39, N'Yes / No', N'Yes', N'Drill Report', 10,
         N'Are disaster recovery arrangements tested periodically, with results and corrective actions documented?',
         N'Review drill scenarios, participation, actual recovery performance and closure of gaps.',
         N'DR drill reports, actual RTO/RPO results and action tracker.'),
    (N'QS-IT-BCP-001', N'Q010',  40, N'Yes / No', N'Yes', N'Action Register', 5,
         N'Are lessons from continuity incidents and exercises incorporated into updated plans and controls?',
         N'Trace exercise or incident findings to plan updates and completed corrective actions.',
         N'Post-exercise reviews, incident lessons learned and revised plans.'),
    (N'QS-IT-CHG-001', N'Q001',  41, N'Yes / No', N'Yes', N'Policy Document', 10,
         N'Is there an approved change management procedure covering applications, infrastructure and configuration changes?',
         N'Verify the procedure defines change types, roles, approvals and emergency change handling.',
         N'Approved change management policy or procedure.'),
    (N'QS-IT-CHG-001', N'Q002',  42, N'Yes / No', N'Yes', N'Change Register', 10,
         N'Are changes recorded in a central register or approved workflow before implementation?',
         N'Sample changes and confirm complete records, unique identifiers and traceability.',
         N'Change register, workflow records and change tickets.'),
    (N'QS-IT-CHG-001', N'Q003',  43, N'Yes / No', N'Yes', N'Risk Assessment', 10,
         N'Are changes assessed for business impact, information security risk and operational dependencies?',
         N'Review risk and impact assessments for representative changes.',
         N'Change impact assessments, risk assessments and dependency analysis.'),
    (N'QS-IT-CHG-001', N'Q004',  44, N'Yes / No', N'Yes', N'Approval Record', 10,
         N'Are changes approved by authorized personnel before implementation?',
         N'Verify approval authority and timing against the change implementation date.',
         N'Change approvals and delegated authority matrix.'),
    (N'QS-IT-CHG-001', N'Q005',  45, N'Yes / No', N'Yes', N'Test Report', 15,
         N'Are changes adequately tested in a non-production environment before release?',
         N'Inspect test plans, results, defects and business acceptance for sampled changes.',
         N'Test cases, test results, defect logs and user acceptance sign-off.'),
    (N'QS-IT-CHG-001', N'Q006',  46, N'Yes / No', N'Yes', N'User Register', 10,
         N'Are development, testing and production responsibilities appropriately segregated?',
         N'Examine access rights and deployment responsibilities for incompatible duties.',
         N'Environment access lists, role matrix and segregation review.'),
    (N'QS-IT-CHG-001', N'Q007',  47, N'Yes / No', N'Yes', N'Deployment Log', 10,
         N'Are production deployments restricted to authorized personnel and performed through controlled procedures?',
         N'Trace deployments to approved release records and deployment logs.',
         N'Release approvals, deployment logs and privileged access records.'),
    (N'QS-IT-CHG-001', N'Q008',  48, N'Yes / No', N'Yes', N'Rollback Plan', 10,
         N'Are rollback or recovery procedures defined for changes that fail or cause service disruption?',
         N'Check rollback readiness and evidence of execution where changes failed.',
         N'Rollback plans, release records and incident references.'),
    (N'QS-IT-CHG-001', N'Q009',  49, N'Yes / No', N'Yes', N'Emergency Change Register', 10,
         N'Are emergency changes documented, approved or retrospectively reviewed within a defined period?',
         N'Sample emergency changes and verify justification, authorization and retrospective review.',
         N'Emergency change tickets, approvals and post-implementation reviews.'),
    (N'QS-IT-CHG-001', N'Q010',  50, N'Yes / No', N'Yes', N'Review Record', 5,
         N'Are completed changes reviewed to confirm expected outcomes and identify unintended impacts?',
         N'Review post-implementation checks, business confirmation and closure evidence.',
         N'Post-implementation review records and change closure approvals.'),
    (N'QS-IT-INC-001', N'Q001',  51, N'Yes / No', N'Yes', N'Procedure Document', 10,
         N'Is there a defined process for users to report IT incidents and service requests?',
         N'Verify available reporting channels, ownership and user communication.',
         N'Service desk procedure, portal details and user guidance.'),
    (N'QS-IT-INC-001', N'Q002',  52, N'Yes / No', N'Yes', N'Incident Register', 10,
         N'Are incidents and service requests recorded with unique references and sufficient details?',
         N'Sample records for description, date, requester, affected service and assigned owner.',
         N'Incident and service request register or ticket extracts.'),
    (N'QS-IT-INC-001', N'Q003',  53, N'Yes / No', N'Yes', N'Priority Matrix', 10,
         N'Are incidents prioritized based on business impact and urgency using defined criteria?',
         N'Review priority definitions and consistency of classification in sampled tickets.',
         N'Incident priority matrix and sampled incident tickets.'),
    (N'QS-IT-INC-001', N'Q004',  54, N'Yes / No', N'Yes', N'Escalation Record', 10,
         N'Are incidents assigned to responsible personnel and escalated when service targets are at risk?',
         N'Trace ownership changes, escalation triggers and management involvement.',
         N'Ticket assignment history, escalation records and SLA alerts.'),
    (N'QS-IT-INC-001', N'Q005',  55, N'Yes / No', N'Yes', N'SLA Report', 15,
         N'Are incident resolution and response targets defined, monitored and reported?',
         N'Compare actual response and resolution times with approved service targets.',
         N'SLA definitions, performance dashboards and breach reports.'),
    (N'QS-IT-INC-001', N'Q006',  56, N'Yes / No', N'Yes', N'Root Cause Report', 10,
         N'Are major incidents subject to documented investigation and root-cause analysis?',
         N'Review major incident classification, analysis, impact and corrective actions.',
         N'Major incident reports and root-cause analyses.'),
    (N'QS-IT-INC-001', N'Q007',  57, N'Yes / No', N'Yes', N'Problem Register', 10,
         N'Are recurring incidents analyzed and managed through a problem management process?',
         N'Identify repeat incidents and verify problem records, workarounds and permanent fixes.',
         N'Problem register, trend reports and corrective action records.'),
    (N'QS-IT-INC-001', N'Q008',  58, N'Yes / No', N'Yes', N'Communication Record', 10,
         N'Are users informed about significant incidents, service disruptions and restoration progress?',
         N'Check communication timeliness, audience and closure notifications.',
         N'User notifications, service advisories and incident communication logs.'),
    (N'QS-IT-INC-001', N'Q009',  59, N'Yes / No', N'Yes', N'Incident Register', 10,
         N'Are incidents involving information security or personal data escalated through the appropriate security and privacy processes?',
         N'Verify routing, specialist involvement and regulatory reporting assessment where applicable.',
         N'Security incident records, escalation evidence and reporting assessments.'),
    (N'QS-IT-INC-001', N'Q010',  60, N'Yes / No', N'Yes', N'Management Report', 5,
         N'Are incident trends and service performance reviewed by management at defined intervals?',
         N'Check management review of volumes, recurring causes, SLA performance and actions.',
         N'Monthly service reports, dashboards and review minutes.'),
    (N'QS-TPRM-001', N'Q001',  61, N'Yes / No', N'Yes', N'Policy Document', 10,
         N'Is there an approved policy or framework governing third-party and outsourced service arrangements?',
         N'Verify governance requirements, applicability, approval and periodic review.',
         N'Approved third-party risk or outsourcing policy.'),
    (N'QS-TPRM-001', N'Q002',  62, N'Yes / No', N'Yes', N'Vendor Register', 10,
         N'Are third parties identified and recorded in a centralized vendor register?',
         N'Reconcile a sample of active vendors against procurement, finance and service records.',
         N'Vendor master, outsourced service register and ownership details.'),
    (N'QS-TPRM-001', N'Q003',  63, N'Yes / No', N'Yes', N'Due Diligence Report', 15,
         N'Is risk-based due diligence conducted before engaging third parties for material or sensitive services?',
         N'Review financial, operational, security, compliance and reputation checks as relevant to service risk.',
         N'Due diligence questionnaires, assessment reports and approval records.'),
    (N'QS-TPRM-001', N'Q004',  64, N'Yes / No', N'Yes', N'Risk Assessment', 10,
         N'Are third parties classified according to service criticality, data access and business impact?',
         N'Check risk classification criteria and whether critical vendors receive enhanced oversight.',
         N'Vendor risk ratings, service criticality assessments and rationale.'),
    (N'QS-TPRM-001', N'Q005',  65, N'Yes / No', N'Yes', N'Agreement', 10,
         N'Are contracts reviewed and approved before services commence, with required safeguards included?',
         N'Inspect clauses for scope, confidentiality, security, audit rights, subcontracting, incident notification and termination.',
         N'Executed contracts, legal review and approval records.'),
    (N'QS-TPRM-001', N'Q006',  66, N'Yes / No', N'Yes', N'User Register', 10,
         N'Are third-party access to organizational systems and information restricted to approved requirements?',
         N'Sample vendor accounts and verify authorization, least privilege, monitoring and expiry.',
         N'Third-party access approvals, access listings and review records.'),
    (N'QS-TPRM-001', N'Q007',  67, N'Yes / No', N'Yes', N'SLA Report', 10,
         N'Is third-party service performance and compliance monitored against agreed service levels and obligations?',
         N'Review service reviews, SLA performance, exceptions and follow-up actions.',
         N'Service reports, SLA dashboards and review minutes.'),
    (N'QS-TPRM-001', N'Q008',  68, N'Yes / No', N'Yes', N'Risk Register', 10,
         N'Are third-party risks and control deficiencies periodically reassessed and tracked to closure?',
         N'Review reassessments, assurance reports, issues and remediation status.',
         N'Vendor risk assessments, assurance reports and action trackers.'),
    (N'QS-TPRM-001', N'Q009',  69, N'Yes / No', N'Yes', N'Approval Record', 5,
         N'Are subcontracting and material changes to third-party services subject to appropriate review and approval?',
         N'Verify notification, impact assessment and approval for subcontractors or material service changes.',
         N'Subcontractor disclosures, change notifications and approvals.'),
    (N'QS-TPRM-001', N'Q010',  70, N'Yes / No', N'Yes', N'Exit Plan', 10,
         N'Are vendor exit, transition and data return or destruction arrangements defined for service termination?',
         N'Check exit plans for critical vendors, transition responsibilities and confirmation of data return or destruction.',
         N'Exit plans, termination records and data return or destruction certificates.'),
    (N'QS-HR-PAY-001', N'Q001',  71, N'Yes / No', N'Yes', N'Employee Register', 10,
         N'Are employee records created and maintained based on approved recruitment and joining documentation?',
         N'Sample new joiners and verify identity, employment terms and approval evidence.',
         N'Employee master records, joining documents and appointment approvals.'),
    (N'QS-HR-PAY-001', N'Q002',  72, N'Yes / No', N'Yes', N'Change Register', 10,
         N'Are changes to employee master data supported by authorized requests and appropriate validation?',
         N'Sample changes to salary, bank details, designation and personal data.',
         N'Employee change requests, approvals and system change history.'),
    (N'QS-HR-PAY-001', N'Q003',  73, N'Yes / No', N'Yes', N'Payroll Input Report', 10,
         N'Are payroll inputs such as attendance, leave, overtime and variable pay validated before processing?',
         N'Trace selected payroll inputs to source records and approvals.',
         N'Attendance reports, leave records, overtime approvals and variable pay inputs.'),
    (N'QS-HR-PAY-001', N'Q004',  74, N'Yes / No', N'Yes', N'Approval Record', 15,
         N'Is payroll reviewed and approved by authorized personnel before salary disbursement?',
         N'Verify independent review of payroll registers and approval before payment.',
         N'Payroll register, review checklist and payment authorization.'),
    (N'QS-HR-PAY-001', N'Q005',  75, N'Yes / No', N'Yes', N'Approval Record', 10,
         N'Are changes to salary structures, allowances and deductions appropriately authorized?',
         N'Sample compensation changes and verify approval under delegated authority.',
         N'Compensation revision letters, approvals and payroll master change logs.'),
    (N'QS-HR-PAY-001', N'Q006',  76, N'Yes / No', N'Yes', N'Reconciliation Report', 10,
         N'Are payroll calculations independently checked or subjected to defined validation controls?',
         N'Review validation controls and sample recalculation or exception checks.',
         N'Payroll validation reports, sample recalculations and exception logs.'),
    (N'QS-HR-PAY-001', N'Q007',  77, N'Yes / No', N'Yes', N'Bank Reconciliation', 10,
         N'Are payroll payments reconciled with approved payroll records and bank debit or payment confirmations?',
         N'Trace payroll totals to bank payment files and reconciliation records.',
         N'Approved payroll summary, bank payment confirmation and reconciliation.'),
    (N'QS-HR-PAY-001', N'Q008',  78, N'Yes / No', N'Yes', N'Statutory Return', 10,
         N'Are statutory payroll deductions, contributions and filings calculated and remitted within applicable timelines?',
         N'Sample applicable statutory obligations and verify calculation, payment and filing dates.',
         N'Statutory challans, returns, payment receipts and reconciliation.'),
    (N'QS-HR-PAY-001', N'Q009',  79, N'Yes / No', N'Yes', N'User Register', 10,
         N'Are access to employee and payroll information restricted to authorized HR, payroll and finance personnel?',
         N'Review access rights, segregation of duties and periodic access certification.',
         N'Payroll application access list, role matrix and review records.'),
    (N'QS-HR-PAY-001', N'Q010',  80, N'Yes / No', N'Yes', N'Exit Checklist', 5,
         N'Are employee exits communicated promptly to payroll and relevant system owners to prevent unauthorized payments and access?',
         N'Sample leavers and verify final settlement, payroll removal and access deactivation coordination.',
         N'Exit checklist, final settlement records and access deactivation evidence.'),
    (N'QS-FIN-TRE-001', N'Q001',  81, N'Yes / No', N'Yes', N'Policy Document', 10,
         N'Are treasury activities governed by an approved policy defining permitted activities, limits and responsibilities?',
         N'Verify policy approval, scope, review cycle and delegated authorities.',
         N'Treasury policy, approval records and review history.'),
    (N'QS-FIN-TRE-001', N'Q002',  82, N'Yes / No', N'Yes', N'Approval Record', 10,
         N'Are bank accounts opened, modified and closed only with appropriate authorization?',
         N'Sample bank account changes and trace approvals to authorized signatories or committees.',
         N'Bank account register, board or management approvals and bank correspondence.'),
    (N'QS-FIN-TRE-001', N'Q003',  83, N'Yes / No', N'Yes', N'Transaction Register', 15,
         N'Are treasury transactions initiated, reviewed and approved in accordance with defined authority limits?',
         N'Sample transactions and verify maker-checker controls and compliance with limits.',
         N'Treasury transaction register, approval workflow and authority matrix.'),
    (N'QS-FIN-TRE-001', N'Q004',  84, N'Yes / No', N'Yes', N'Responsibility Matrix', 10,
         N'Are treasury dealing, settlement, accounting and reconciliation responsibilities appropriately segregated?',
         N'Review role allocation and identify incompatible duties or compensating controls.',
         N'Organization structure, role matrix and system access listing.'),
    (N'QS-FIN-TRE-001', N'Q005',  85, N'Yes / No', N'Yes', N'Liquidity Report', 10,
         N'Are cash balances and liquidity positions monitored against approved limits and forecast requirements?',
         N'Review liquidity reports, forecasts, limit breaches and management actions.',
         N'Daily cash position, liquidity forecasts and limit monitoring reports.'),
    (N'QS-FIN-TRE-001', N'Q006',  86, N'Yes / No', N'Yes', N'Bank Reconciliation', 15,
         N'Are bank and treasury account reconciliations performed regularly and independently reviewed?',
         N'Sample reconciliations and inspect ageing, unresolved items and reviewer sign-off.',
         N'Bank statements, reconciliation statements and review evidence.'),
    (N'QS-FIN-TRE-001', N'Q007',  87, N'Yes / No', N'Yes', N'Investment Register', 10,
         N'Are investments and treasury exposures recorded accurately and valued in accordance with approved requirements?',
         N'Trace selected holdings to confirmations, valuation sources and accounting records.',
         N'Investment register, broker or custodian confirmations and valuation reports.'),
    (N'QS-FIN-TRE-001', N'Q008',  88, N'Yes / No', N'Yes', N'Limit Monitoring Report', 10,
         N'Are transaction limits and counterparty exposure limits monitored and breaches escalated?',
         N'Review approved limits, monitoring frequency, breach logs and escalation.',
         N'Limit approvals, exposure reports and breach escalation records.'),
    (N'QS-FIN-TRE-001', N'Q009',  89, N'Yes / No', N'Yes', N'Transaction Document', 5,
         N'Are treasury transactions supported by complete documentation and independently verified settlement records?',
         N'Sample transactions for deal confirmations, settlement instructions and accounting support.',
         N'Deal tickets, confirmations, settlement statements and ledger entries.'),
    (N'QS-FIN-TRE-001', N'Q010',  90, N'Yes / No', N'Yes', N'Management Report', 5,
         N'Are treasury and financial reports reviewed by management for accuracy, exceptions and significant movements?',
         N'Inspect management review evidence and follow-up of unusual balances or movements.',
         N'Treasury MIS, financial reports and management review minutes.');

-- Every question's set must be in the Question Sets sheet.
IF EXISTS (SELECT 1 FROM @qs q WHERE NOT EXISTS (SELECT 1 FROM @sets s WHERE s.set_code = q.set_code))
BEGIN
    PRINT 'ABORT: questions refer to a QuestionSetCode not in the Question Sets sheet.';
    SELECT DISTINCT q.set_code AS UnknownQuestionSetCode FROM @qs q
     WHERE NOT EXISTS (SELECT 1 FROM @sets s WHERE s.set_code = q.set_code);
    RETURN;
END

-- ---------------------------------------------------------------------
-- 2. Response types -- the Admin list, matched by name
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS #rt;
CREATE TABLE #rt (Id BIGINT NULL, Code NVARCHAR(120) NULL, Name NVARCHAR(200) NULL, Description NVARCHAR(MAX) NULL);
INSERT #rt (Id, Code, Name, Description)
EXEC grac_practice.sp_org_assurance_admin_question_type_list;

UPDATE q
   SET question_type_id   = rt.Id,
       question_type_code = rt.Code,
       question_type_name = rt.Name
  FROM @qs q
 CROSS APPLY (SELECT TOP 1 r.Id, r.Code, r.Name FROM #rt r
               WHERE REPLACE(LOWER(r.Name), N' ', N'') = REPLACE(LOWER(q.response_type), N' ', N'')
                  OR REPLACE(LOWER(r.Code), N' ', N'') = REPLACE(LOWER(q.response_type), N' ', N'')
               ORDER BY r.Id) rt;

-- ---------------------------------------------------------------------
-- 3. Evidence labels -- evidence_type_master, matched by name or code
-- ---------------------------------------------------------------------
DECLARE @ev TABLE (
    evidence_label   NVARCHAR(160) NOT NULL PRIMARY KEY,
    norm             NVARCHAR(160) NOT NULL,
    question_count   INT           NOT NULL,
    evidence_type_id INT           NULL,
    new_code         NVARCHAR(60)  NULL);

INSERT @ev (evidence_label, norm, question_count)
SELECT q.evidence_label,
       REPLACE(REPLACE(REPLACE(REPLACE(LOWER(q.evidence_label), N' ', N''), N'_', N''), N'-', N''), N'/', N''),
       COUNT(*)
  FROM @qs q
 WHERE q.evidence_label IS NOT NULL
   AND LOWER(q.evidence_label) NOT IN (N'not applicable', N'n/a', N'none')
 GROUP BY q.evidence_label;

UPDATE e
   SET evidence_type_id = m.evidence_type_id
  FROM @ev e
 CROSS APPLY (SELECT TOP 1 t.evidence_type_id
                FROM grac_practice.evidence_type_master t
               WHERE t.is_active = 1
                 AND (REPLACE(REPLACE(REPLACE(REPLACE(LOWER(t.evidence_type_name), N' ', N''), N'_', N''), N'-', N''), N'/', N'') = e.norm
                   OR REPLACE(REPLACE(REPLACE(REPLACE(LOWER(t.evidence_type_code), N' ', N''), N'_', N''), N'-', N''), N'/', N'') = e.norm)
               ORDER BY t.evidence_type_id) m;

-- The type a missing label gets under 'DEFAULT' -- same matching rule.
DECLARE @default_ev_id INT, @default_ev_text NVARCHAR(300);
SELECT TOP 1 @default_ev_id   = t.evidence_type_id,
             @default_ev_text = t.evidence_type_code + N' - ' + t.evidence_type_name
  FROM grac_practice.evidence_type_master t
 WHERE t.is_active = 1
   AND (REPLACE(REPLACE(REPLACE(REPLACE(LOWER(t.evidence_type_name), N' ', N''), N'_', N''), N'-', N''), N'/', N'')
          = REPLACE(REPLACE(REPLACE(REPLACE(LOWER(@DefaultEvidenceType), N' ', N''), N'_', N''), N'-', N''), N'/', N'')
     OR REPLACE(REPLACE(REPLACE(REPLACE(LOWER(t.evidence_type_code), N' ', N''), N'_', N''), N'-', N''), N'/', N'')
          = REPLACE(REPLACE(REPLACE(REPLACE(LOWER(@DefaultEvidenceType), N' ', N''), N'_', N''), N'-', N''), N'/', N''))
 ORDER BY t.evidence_type_id;

-- Code a missing label would get ('CREATE').
UPDATE @ev
   SET new_code = LEFT(UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(evidence_label)), N' ', N'_'), N'/', N'_'), N'-', N'_')), 60)
 WHERE evidence_type_id IS NULL;

-- ---------------------------------------------------------------------
-- 4. Report
-- ---------------------------------------------------------------------
SELECT s.seq AS [#], s.set_code AS SetCode, s.set_name AS SetName,
       (SELECT COUNT(*) FROM @qs q WHERE q.set_code = s.set_code) AS Questions,
       CASE WHEN x.org_assurance_question_set_id IS NULL THEN 'CREATE'
            WHEN @ExistingSet = N'REPLACE'                THEN 'REPLACE (exists, id ' + CAST(x.org_assurance_question_set_id AS VARCHAR(20)) + ')'
            ELSE 'SKIP (exists, id ' + CAST(x.org_assurance_question_set_id AS VARCHAR(20)) + ')' END AS Action
  FROM @sets s
  LEFT JOIN grac_practice.org_assurance_question_set x
         ON x.organization_id = @OrganizationId AND x.set_code = s.set_code AND x.is_active = 1
 ORDER BY s.seq;

SELECT q.response_type AS ResponseTypeInSheet, COUNT(*) AS Questions,
       ISNULL(MAX(q.question_type_name), '** NOT FOUND in the Admin response types **') AS MatchedAdminType
  FROM @qs q
 GROUP BY q.response_type;

SELECT e.evidence_label AS EvidenceInSheet, e.question_count AS Questions,
       CASE WHEN e.evidence_type_id IS NOT NULL
            THEN 'matched: ' + t.evidence_type_code + ' - ' + t.evidence_type_name
            WHEN @MissingEvidenceType = N'DEFAULT' AND @default_ev_id IS NOT NULL
                                                  THEN 'MISSING -> default type: ' + @default_ev_text
            WHEN @MissingEvidenceType = N'DEFAULT' THEN 'MISSING -> default type "' + @DefaultEvidenceType + '" is NOT in evidence_type_master: import stops'
            WHEN @MissingEvidenceType = N'CREATE' THEN 'MISSING -> will be created as ' + e.new_code
            WHEN @MissingEvidenceType = N'NONE'   THEN 'MISSING -> imported as Not Applicable'
            ELSE 'MISSING -> import stops (@MissingEvidenceType = ABORT)' END AS Result
  FROM @ev e
  LEFT JOIN grac_practice.evidence_type_master t ON t.evidence_type_id = e.evidence_type_id
 ORDER BY CASE WHEN e.evidence_type_id IS NULL THEN 0 ELSE 1 END, e.evidence_label;

DECLARE @bad_rt INT = (SELECT COUNT(*) FROM @qs WHERE question_type_id IS NULL AND question_type_code IS NULL);
DECLARE @bad_ev INT = (SELECT COUNT(*) FROM @ev WHERE evidence_type_id IS NULL);
DECLARE @clash  INT = (SELECT COUNT(*) FROM @ev e
                        WHERE e.evidence_type_id IS NULL
                          AND EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_code = e.new_code));

IF @bad_rt > 0
BEGIN
    PRINT 'ABORT: ' + CAST(@bad_rt AS VARCHAR(10)) + ' question(s) have a Response Type the Admin list does not have (see the second result set). Nothing was changed.';
    RETURN;
END
IF @bad_ev > 0 AND @MissingEvidenceType = N'ABORT'
BEGIN
    PRINT 'STOP: ' + CAST(@bad_ev AS VARCHAR(10)) + ' Evidence label(s) are not in evidence_type_master (see the third result set).'
        + ' Set @MissingEvidenceType to CREATE or NONE, or add / rename the types, then run again. Nothing was changed.';
    RETURN;
END
IF @bad_ev > 0 AND @MissingEvidenceType = N'DEFAULT' AND @default_ev_id IS NULL
BEGIN
    PRINT 'ABORT: the default evidence type "' + @DefaultEvidenceType + '" is not in evidence_type_master.'
        + ' Set @DefaultEvidenceType to a type that exists (name or code), or use CREATE / NONE. Nothing was changed.';
    SELECT evidence_type_id AS EvidenceTypeId, evidence_type_code AS Code, evidence_type_name AS Name
      FROM grac_practice.evidence_type_master WHERE is_active = 1 ORDER BY display_order, evidence_type_name;
    RETURN;
END
IF @bad_ev > 0 AND @MissingEvidenceType = N'CREATE' AND @clash > 0
BEGIN
    PRINT 'ABORT: a code for a new evidence type is already used by another type. Rename that label or use NONE. Nothing was changed.';
    RETURN;
END

-- A code the organization used for a set that was later removed (is_active
-- = 0) cannot be created again: set_code is unique per organization
-- whether or not the row is active (uq_pm_oa_qset_code).
IF EXISTS (SELECT 1 FROM @sets s
            JOIN grac_practice.org_assurance_question_set x
              ON x.organization_id = @OrganizationId AND x.set_code = s.set_code AND x.is_active = 0
           WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_question_set y
                              WHERE y.organization_id = @OrganizationId AND y.set_code = s.set_code AND y.is_active = 1))
BEGIN
    PRINT 'ABORT: these set codes belong to removed (inactive) sets in this organization and cannot be created again. Nothing was changed.';
    SELECT x.set_code AS RemovedSetCode, x.org_assurance_question_set_id AS QuestionSetId, x.set_name AS SetName
      FROM grac_practice.org_assurance_question_set x
      JOIN @sets s ON s.set_code = x.set_code
     WHERE x.organization_id = @OrganizationId AND x.is_active = 0;
    RETURN;
END

IF @DryRun = 1
BEGIN
    PRINT 'DRY RUN -- nothing was changed. Review the three result sets, then set @DryRun = 0 and run again.';
    RETURN;
END

-- ---------------------------------------------------------------------
-- 5. Import (one transaction)
-- ---------------------------------------------------------------------
BEGIN TRY
    BEGIN TRAN;

    IF @bad_ev > 0 AND @MissingEvidenceType = N'CREATE'
    BEGIN
        DECLARE @base_order INT = (SELECT ISNULL(MAX(display_order), 0) FROM grac_practice.evidence_type_master);
        INSERT grac_practice.evidence_type_master
            (evidence_type_code, evidence_type_name, display_order, is_active, entered_by, entered_dt)
        SELECT e.new_code, LTRIM(RTRIM(e.evidence_label)),
               @base_order + ROW_NUMBER() OVER (ORDER BY e.evidence_label), 1, @Actor, SYSUTCDATETIME()
          FROM @ev e
         WHERE e.evidence_type_id IS NULL;
        PRINT 'Evidence types created: ' + CAST(@@ROWCOUNT AS VARCHAR(10));

        UPDATE e SET evidence_type_id = t.evidence_type_id
          FROM @ev e JOIN grac_practice.evidence_type_master t ON t.evidence_type_code = e.new_code
         WHERE e.evidence_type_id IS NULL;
    END

    IF @MissingEvidenceType = N'DEFAULT'
        UPDATE @ev SET evidence_type_id = @default_ev_id WHERE evidence_type_id IS NULL;

    -- 'NONE' leaves evidence_type_id NULL = Not Applicable.
    UPDATE q SET evidence_type_id = e.evidence_type_id
      FROM @qs q JOIN @ev e ON e.evidence_label = q.evidence_label;

    DECLARE @set_code NVARCHAR(80), @set_name NVARCHAR(240), @description NVARCHAR(MAX), @status NVARCHAR(30),
            @existing_id BIGINT, @owner_id BIGINT, @owner_name NVARCHAR(240),
            @set_id BIGINT, @json NVARCHAR(MAX), @saved INT,
            @created INT = 0, @replaced INT = 0, @skipped INT = 0, @questions INT = 0;

    DECLARE set_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT set_code, set_name, description, ISNULL(status, N'Active') FROM @sets ORDER BY seq;
    OPEN set_cursor;
    FETCH NEXT FROM set_cursor INTO @set_code, @set_name, @description, @status;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @existing_id = NULL, @owner_id = NULL, @owner_name = NULL, @set_id = NULL;
        SELECT @existing_id = org_assurance_question_set_id,
               @owner_id    = owner_employee_id,
               @owner_name  = owner_display_name
          FROM grac_practice.org_assurance_question_set
         WHERE organization_id = @OrganizationId AND set_code = @set_code AND is_active = 1;

        IF @existing_id IS NOT NULL AND @ExistingSet = N'SKIP'
        BEGIN
            SET @skipped += 1;
        END
        ELSE
        BEGIN
            EXEC grac_practice.sp_org_assurance_question_set_save
                 @organization_id     = @OrganizationId,
                 @question_set_id     = @existing_id,
                 @set_code            = @set_code,
                 @set_name            = @set_name,
                 @description         = @description,
                 @owner_employee_id   = @owner_id,      -- kept on REPLACE
                 @owner_display_name  = @owner_name,
                 @status              = @status,
                 @actor               = @Actor,
                 @question_set_id_out = @set_id OUTPUT;

            -- The grid, in the shape the Question Sets screen posts. A
            -- code the set already has carries its questionId, so it is
            -- updated in place (version +1 only if its content changed).
            SET @json = (
                SELECT x.org_assurance_question_id AS questionId,
                       q.question_code             AS questionCode,
                       q.question_text             AS questionText,
                       q.help_text                 AS helpText,
                       q.question_type_id          AS questionTypeId,
                       q.question_type_code        AS questionTypeCode,
                       q.question_type_name        AS questionTypeName,
                       CAST(CASE WHEN LOWER(q.mandatory) IN (N'yes', N'y', N'true', N'1') THEN 1 ELSE 0 END AS BIT) AS isMandatory,
                       q.evidence_type_id          AS evidenceTypeId,
                       q.expected_evidence         AS expectedEvidence,
                       q.weight                    AS weight,
                       N'Active'                   AS status,
                       ROW_NUMBER() OVER (ORDER BY q.seq) AS displayOrder
                  FROM @qs q
                  LEFT JOIN grac_practice.org_assurance_question x
                         ON x.org_assurance_question_set_id = @set_id
                        AND x.question_code = q.question_code
                        AND x.is_active = 1
                 WHERE q.set_code = @set_code
                 ORDER BY q.seq
                   FOR JSON PATH);

            EXEC grac_practice.sp_org_assurance_question_set_questions_save
                 @organization_id = @OrganizationId,
                 @question_set_id = @set_id,
                 @questions_json  = @json,
                 @actor           = @Actor,
                 @saved_count     = @saved OUTPUT;

            SET @questions += ISNULL(@saved, 0);
            IF @existing_id IS NULL SET @created += 1; ELSE SET @replaced += 1;
        END

        FETCH NEXT FROM set_cursor INTO @set_code, @set_name, @description, @status;
    END
    CLOSE set_cursor;
    DEALLOCATE set_cursor;

    COMMIT;
    PRINT 'Imported. Sets created: ' + CAST(@created AS VARCHAR(10))
        + ', replaced: ' + CAST(@replaced AS VARCHAR(10))
        + ', skipped: ' + CAST(@skipped AS VARCHAR(10))
        + '. Questions written: ' + CAST(@questions AS VARCHAR(10)) + '.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    IF CURSOR_STATUS('local', 'set_cursor') >= -1
    BEGIN
        IF CURSOR_STATUS('local', 'set_cursor') >= 0 CLOSE set_cursor;
        DEALLOCATE set_cursor;
    END
    PRINT 'FAILED -- everything was rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH;

-- Result: the organization's copies of the workbook's sets.
SELECT s.set_code AS SetCode, s.set_name AS SetName, s.status AS Status,
       (SELECT COUNT(*) FROM grac_practice.org_assurance_question q
         WHERE q.org_assurance_question_set_id = s.org_assurance_question_set_id AND q.is_active = 1) AS ActiveQuestions,
       (SELECT SUM(q.weight) FROM grac_practice.org_assurance_question q
         WHERE q.org_assurance_question_set_id = s.org_assurance_question_set_id AND q.is_active = 1) AS TotalWeight
  FROM grac_practice.org_assurance_question_set s
  JOIN @sets w ON w.set_code = s.set_code
 WHERE s.organization_id = @OrganizationId AND s.is_active = 1
 ORDER BY w.seq;
