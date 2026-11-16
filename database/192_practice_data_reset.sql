-- =====================================================================
-- 192 Practice Management data reset -- keep masters, clear everything else
--
-- Sir's ask (2026-08-15): a script that deletes everything in this module
-- except the master tables.
--
-- WHAT THIS DOES
--   Deletes ROWS only. No table, FK, index, view or procedure is dropped.
--   After this runs the schema is identical -- only the data is gone.
--
-- WHAT SURVIVES (the "keep list", resolved dynamically at run time)
--   1. Every grac_practice table whose name ends in _master
--      (45 today: record_status_master, frequency_master, menu_master,
--       criticality_master, implementation_status_master,
--       gap_lifecycle_state_master, sla_process_type_master, ...).
--   2. Global, non-tenant configuration/security tables that carry no
--      organization_id and are seeded by deployment/03_Insert_Master_Data.sql
--      or by their own migration:
--         reference_option            (001) global option_group/value catalog
--         security_role               (004)
--         security_permission         (004)
--         security_role_permission    (004)
--         rbac_rule                   (040) origin-aware permission matrix
--         entity_state_transition_rule(035) state-machine transition catalog
--         feature_flag                (041) org feature toggles, FK -> feature_flag_master
--
-- WHAT GETS CLEARED
--   Every other grac_practice table -- organization + its structure
--   (division/department/location/team/committee/employee/role), practices,
--   practice_instance and its children, tasks, gaps, assurance, events,
--   workflow, evidence, documents, risks, exceptions, SLA config, audit trails.
--
-- DELIBERATE EXCLUSION FROM THE KEEP LIST
--   event_definition is NOT kept, even though it reads like configuration.
--   It is organization-scoped (organization_id NOT NULL) and carries FKs to
--   grac_practice.workflow and grac_practice.workflow_stage (migration 066),
--   both of which are cleared here. Keeping it would leave orphan rows and
--   make the workflow DELETE fail on a FK violation.
--
-- OUT OF SCOPE
--   Schema GRAC_New (Control Management / Authority Portal) is never touched,
--   including GRAC_New.evidence_type_master. This script only ever writes to
--   grac_practice.
--
-- THREE SCOPES (@Scope, ORG_RETAIN added 2026-10-13 for the org 1/2
--   keep-and-reset request)
--   'ALL'        the original behaviour described above -- clear the whole
--                module, keep only masters and global config/security.
--   'CATALOGUE'  clear ONLY the repository-subscription-and-below subtree:
--                subscription, applicability, org statements/controls/
--                requirements, practices, instances, and every table that
--                hangs off them (tasks, gaps, assurance, evidence, events,
--                risks, exceptions). Organisation, employees, roles,
--                departments, workflow definitions and masters SURVIVE.
--                Use this to reload the practice/obligation catalogue
--                without rebuilding the tenant from scratch.
--
--                Membership is not a hand-written table list. Section 2
--                seeds from @CatalogueRoots and then closes over foreign
--                keys, so every child of a root is included automatically
--                and a table added by a future migration needs no edit
--                here.
--   'ORG_RETAIN' sir's ask (2026-10-13): purge every organisation EXCEPT
--                the ids in @KeepOrganizationIds (default 1, 2) entirely --
--                their organisation row, employees, locations, departments,
--                teams, committees, roles, menu grants, feature flags,
--                workflows, event definitions, subscriptions, applicability,
--                practices, everything -- while the KEPT organisation(s)
--                keep their organisation/employee/location/department/role/
--                menu-grant/feature-flag/workflow identity but have their
--                catalogue layer reset to blank, same as a CATALOGUE reset
--                applied to just those organisations: practices, instances,
--                obligations, tasks, gaps, evidence, assurance, risks,
--                exceptions, organization_control(_requirement),
--                organization_requirement, organization_statement_practice_
--                mapping, custom_release_source_structure and
--                custom_release_statement are all cleared for kept
--                organisations too, not only purged ones.
--
--                Two tables are neither "always clear" nor "always keep":
--                organization_framework_statements and organization_
--                statement_applicability carry the applicability DECISION
--                directly (applicability_status[_id]/owner_id/reason), so
--                for a kept organisation their rows survive but are RESET
--                to applicability_status_master's 'Not Updated' row with
--                owner_id and the reason/justification column cleared --
--                "mark applicability not set" without losing the fact that
--                the organisation is still subscribed to the framework and
--                which statements it pulled in. For a purged organisation
--                these two tables are deleted outright, same as everything
--                else of theirs.
--
--                Every other table -- organisation, employees, locations,
--                departments, teams, committees, roles, menu grants,
--                feature flags, workflow(_stage), event_definition,
--                repository_subscription, subscription_recommendation_
--                history -- is row-filtered: delete rows for organisations
--                NOT in @KeepOrganizationIds, keep rows for organisations
--                IN it. Section 2 resolves, for every such table, EITHER a
--                direct organization_id column OR an organization_id
--                reached through one or more FK hops to an already-resolved
--                table -- computed generically at runtime from sys.columns/
--                sys.foreign_keys (same style as the FK-level/cycle-break
--                logic below), never hand-mapped per table. A table that
--                cannot be resolved after a bounded number of passes aborts
--                the script with its name printed, rather than guessing
--                which column means "this row's organisation".
--
--                Membership and classification build on the SAME
--                @CatalogueRoots closure CATALOGUE uses (see section 2), with
--                two named carve-outs on top of it:
--                  * organization_framework_statements and organization_
--                    statement_applicability are closure members (they ARE
--                    @CatalogueRoots entries) but classified FILTERED_RESET,
--                    not UNCONDITIONAL -- that is the whole point of this
--                    scope, per the paragraph above.
--                  * repository_subscription and subscription_recommendation_
--                    history are ALSO closure members (they seed the closure
--                    as roots) but classified FILTERED, not UNCONDITIONAL --
--                    sir's ask keeps "frameowrk nte details": a kept
--                    organisation's subscription to the framework/release is
--                    identity, not applicability-downstream data, so it
--                    survives row-filtered like the organisation-structural
--                    tables, even though CATALOGUE scope (which has no idea
--                    of "kept organisations") still clears it outright.
--                Every OTHER closure member is catalogue-layer and
--                UNCONDITIONAL (cleared for kept organisations too); every
--                table outside the closure (and outside the masters/global-
--                config keep list) is organisation-structural and FILTERED.
--                This is also why ORG_RETAIN reuses @CatalogueRoots rather
--                than declaring its own list: the catalogue/structural
--                boundary is one concept, not two -- only the two small
--                carve-outs above are ORG_RETAIN-specific.
--
--                Everything else in the engine below -- the blocker
--                pre-flight, FK levelling, cycle breaking, trigger
--                handling, verification and identity reseed -- is shared
--                by all three scopes, unchanged (verification and identity
--                reseed are made delete-mode-aware, see sections 6-7, but
--                for ALL/CATALOGUE every table's mode is UNCONDITIONAL, so
--                their behaviour is unchanged).
--
-- SAFETY
--   * @DryRun = 1 by default -- prints the full plan (order + row counts) and
--     changes nothing. Set to 0 to execute.
--   * @Scope is validated below; an unrecognised value aborts.
--   * @ConfirmDatabase must be typed to match DB_NAME() before it will run
--     for real. Prevents a stray F5 against the wrong database.
--   * Pre-flight abort if any table OUTSIDE the delete set (a kept master, or
--     any table in another schema) has a FK pointing INTO the delete set.
--   * Delete order is derived from sys.foreign_keys at run time -- children
--     before parents -- so every FK stays enabled and checked throughout.
--     No NOCHECK, no constraint drop/recreate.
--   * Triggers on the tables being cleared are disabled for the duration of
--     the transaction and re-enabled before it commits. This is required,
--     not cosmetic: grac_practice.practice_audit_trace and
--     grac_practice.entity_state_transition_log each carry an
--     INSTEAD OF UPDATE, DELETE trigger that raises 51001 / 53501 to keep
--     the audit trails append-only, so a plain DELETE against them fails.
--     Only triggers that are currently ENABLED are touched, and each is
--     re-enabled by name, so a trigger an operator disabled on purpose
--     stays disabled. Trigger DDL is transactional -- if anything rolls
--     back, the triggers come back with it.
--   * The whole delete runs in one transaction. Any failure rolls back.
--
-- ROLLBACK
--   None. Deleted rows are gone. Restore from backup, then rerun
--   deployment/03_Insert_Master_Data.sql if masters also need reseeding.
--   Take a backup before running with @DryRun = 0.
--
-- Re-runnable: yes (second run finds nothing to delete).
-- Single batch on purpose -- the switches below are batch-scoped variables.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ------------------------------------------------------------------ */
/* OPERATOR SWITCHES -- edit these three lines only                    */
/* ------------------------------------------------------------------ */
DECLARE @DryRun          BIT     = 1;      -- 1 = plan only, 0 = delete for real
DECLARE @ConfirmDatabase SYSNAME = N'';    -- must equal DB_NAME() when @DryRun = 0
DECLARE @ReseedIdentity  BIT     = 1;      -- 1 = restart IDENTITY counters at 1
DECLARE @Scope           SYSNAME = N'ALL'; -- 'ALL' | 'CATALOGUE' | 'ORG_RETAIN' (see header)
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* ORG_RETAIN KEEP LIST -- only read when @Scope = 'ORG_RETAIN'.        */
/*                                                                      */
/* Organisations whose own identity (organisation/employee/location/    */
/* department/team/committee/role/menu-grant/feature-flag/workflow)     */
/* rows survive. Every organisation NOT listed here is purged           */
/* entirely. Listed organisations still have their catalogue layer      */
/* (practices and everything below applicability) reset to blank --     */
/* see the header for what "kept" means for this scope.                 */
/* ------------------------------------------------------------------ */
DECLARE @KeepOrganizationIds TABLE (organization_id BIGINT NOT NULL PRIMARY KEY);
INSERT INTO @KeepOrganizationIds (organization_id) VALUES (1), (2);
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* CATALOGUE ROOTS -- only read when @Scope = 'CATALOGUE'.             */
/*                                                                     */
/* Name only the TOP of the subtree. Everything that references these  */
/* -- children, grandchildren, link tables -- is added automatically   */
/* by the foreign-key closure in section 2, so this list stays short   */
/* and does not need editing when a new child table appears.           */
/*                                                                     */
/* The default is "repository subscription, applicability, and         */
/* everything below": what an organisation SUBSCRIBED to and everything*/
/* derived from it. Organisation, employees, roles, departments,       */
/* workflow definitions and masters are parents of these, not          */
/* children, so they survive.                                          */
/*                                                                     */
/* Run with @DryRun = 1 first and read the printed table list. If a    */
/* table you expected is missing, add its root here; if one you wanted */
/* kept appears, remove the root that pulled it in.                    */
/* ------------------------------------------------------------------ */
DECLARE @CatalogueRoots TABLE (table_name SYSNAME NOT NULL PRIMARY KEY);
INSERT INTO @CatalogueRoots (table_name) VALUES
    (N'repository_subscription'),                -- the subscription itself
    (N'subscription_recommendation_history'),
    (N'organization_framework_statements'),      -- statements pulled from the release
    (N'organization_statement_applicability'),   -- applicability decisions
    (N'organization_control'),                   -- control context per org
    (N'organization_control_requirement'),
    (N'organization_requirement'),               -- requirements derived from statements
    (N'organization_statement_practice_mapping'),
    (N'custom_release_source_structure'),        -- org-authored releases
    (N'custom_release_statement'),
    (N'practice'),                                -- practice + instance + everything below
    -- Post-run fix 5 (2026-10-13): these three are deliberately NOT FK-
    -- linked to practice/practice_instance -- each one links to its
    -- subject polymorphically instead (practice_task.subject_entity_type/
    -- _id; risk_register_schema.sql's own header on risk_analysis says
    -- why: "Soft references. A hard FK per Centre would make the Risk
    -- Centre depend on every module that can name a risk, which is the
    -- coupling we avoid"). Without a named root here the FK-closure walk
    -- can never reach them, so they default to FILTERED via their own
    -- direct organization_id column instead of UNCONDITIONAL -- meaning a
    -- kept organisation's tasks/risks/exceptions would silently survive
    -- ORG_RETAIN, contradicting "Org 1/2's own practice/task/evidence
    -- catalogue is also reset to blank" (confirmed decision, see the
    -- project doc). Naming them as roots here pulls in their real FK
    -- children automatically -- risk_register, risk_candidate,
    -- risk_residual_analysis, task_candidate and all of their own child
    -- tables -- with no further change to this script. This also means
    -- CATALOGUE scope, which shares this same closure, now actually
    -- clears tasks/risks/exceptions as its own header has always said it
    -- does.
    (N'risk_analysis'),
    (N'exception_request'),
    (N'practice_task');
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* PREFERRED RESOLUTION PARENT -- only consulted in section 2's           */
/* organization_id resolution when a FILTERED/FILTERED_RESET table's      */
/* own resolution would otherwise be genuinely ambiguous: two or more     */
/* already-resolved parents, pointing at different tables, with no       */
/* mechanical way to prefer one. Post-run fix 5 (2026-10-13): 14 tables   */
/* hit exactly this while diagnosing the ORG_RETAIN Msg 51007 block --    */
/* every one has a clear "own business subject" parent (the document,    */
/* the batch/header, the asset, the case) and a separate "who acted on   */
/* it" parent (uploader, processor, recipient, employee, role). Listed   */
/* here as an explicit, reviewed choice -- never picked silently -- one   */
/* consistent rule throughout: the row's own subject wins over whoever   */
/* merely performed an action on it.                                     */
/* ------------------------------------------------------------------ */
DECLARE @PreferredResolutionParent TABLE
(
    child_table_name            SYSNAME NOT NULL PRIMARY KEY,
    preferred_parent_table_name SYSNAME NOT NULL
);
INSERT INTO @PreferredResolutionParent (child_table_name, preferred_parent_table_name) VALUES
    (N'asset_attribute_source',                  N'organization_dependency_asset'), -- the asset, not the discovery source
    (N'asset_merge_split_member',                N'asset_merge_split_event'),       -- the event this row is a member of
    (N'asset_report_schedule_recipient',         N'asset_report_schedule'),         -- the schedule, not the employee/role
    (N'asset_split_allocation',                  N'asset_merge_split_event'),       -- the event, not the target asset
    (N'asset_workflow_case_step',                N'asset_workflow_case'),           -- the case this step belongs to
    (N'document_acknowledgement_document',       N'document_acknowledgement'),      -- the batch, not the document
    (N'document_acknowledgement_pending',        N'document_acknowledgement'),      -- the batch, not the document/processor
    (N'document_acknowledgement_user',           N'document_acknowledgement'),      -- the batch, not the document/user
    (N'document_upload_distribution_department', N'document_upload'),              -- the document, not the department
    (N'document_upload_distribution_employee',   N'document_upload'),              -- the document, not the employee
    (N'document_upload_file',                    N'document_upload'),               -- the document, not the uploader
    (N'document_upload_history',                 N'document_upload'),              -- the document, not the actor
    (N'event_profile_criteria_value',            N'event_profile'),                -- the profile, not the criteria definition
    (N'exception_request_attachment',            N'exception_request'),            -- the request, not the uploader
    -- Post-run fix 7 (2026-10-13): both FKs (employee_id, role_id) resolve
    -- immediately via their own direct organization_id column, so without
    -- this override the generic resolver sees two different resolved
    -- parents and correctly refuses rather than guess.
    (N'organization_employee_role',               N'organization_employee'),       -- this employee's role(s), not the role's employees
    -- Post-run fix 10 (2026-10-13): discovered by a live EXECUTE, not the
    -- resolver -- asset_notification_stage_recipient was never flagged
    -- ambiguous because its two FK parents never happened to both be
    -- resolved in the SAME pass: organization_role (role_id, NULLABLE --
    -- only set when recipient_code = 'ROLE') is a direct column, resolved
    -- immediately in pass 1, while asset_notification_stage (stage_id, NOT
    -- NULL -- every recipient row has a stage) only resolves a pass or two
    -- later via its own hop through asset_notification_profile. The
    -- resolver grabbed the single candidate available in pass 1 (role_id)
    -- and never revisited -- so every non-ROLE recipient (role_id NULL)
    -- resolved organization_id to NULL and was silently preserved forever,
    -- regardless of its actual organisation, until a live purge finally
    -- tried to delete the asset_notification_stage row it belongs to and
    -- hit Msg 547. stage_id is the row's real, always-present subject;
    -- role_id is optional metadata about who to notify, not which
    -- organisation owns the row.
    (N'asset_notification_stage_recipient',       N'asset_notification_stage');    -- the stage, not the (often-null) notified role
/* ------------------------------------------------------------------ */

DECLARE @sql        NVARCHAR(MAX),
        @tbl        SYSNAME,
        @trg        SYSNAME,
        @mode       SYSNAME,
        @orgExpr    NVARCHAR(MAX),
        @objid      INT,
        @lvl        INT,
        @pass       INT = 0,
        @changed    INT = 1,
        @deleted    BIGINT,
        @totalRows  BIGINT = 0,
        @blockers   INT = 0,
        @cycles     INT = 0,
        @chk        SYSNAME,
        @keepCount  INT = 0,
        @targetCount INT = 0,
        @KeepOrgIdsCsv NVARCHAR(MAX) = NULL,
        @NotUpdatedApplicabilityStatusId INT = NULL;

/* ORG_RETAIN only: a literal CSV of @KeepOrganizationIds, because a local
   table variable cannot be passed into sp_executesql-run dynamic SQL
   without a persistent CREATE TYPE (STRING_AGG is already used elsewhere
   in this codebase for exactly this kind of list-to-string job); and the
   applicability_status_master row "ORG_RETAIN mark applicability not set"
   resets to -- resolved once, by its status_code, never guessed. */
IF @Scope = N'ORG_RETAIN'
BEGIN
    SELECT @KeepOrgIdsCsv = STRING_AGG(CAST(organization_id AS NVARCHAR(20)), N',')
    FROM @KeepOrganizationIds;

    SELECT @NotUpdatedApplicabilityStatusId = applicability_status_id
    FROM grac_practice.applicability_status_master
    WHERE status_code = N'Not Updated';

    IF @NotUpdatedApplicabilityStatusId IS NULL
        THROW 51008, 'ORG_RETAIN scope: applicability_status_master has no ''Not Updated'' row. Cannot reset applicability.', 1;
END

/* Leftovers from a previous run in the same session (the dry-run path exits
   early via RETURN and never reaches the DROP TABLE block at the bottom). */
IF OBJECT_ID('tempdb..#keep')        IS NOT NULL DROP TABLE #keep;
IF OBJECT_ID('tempdb..#target')      IS NOT NULL DROP TABLE #target;
IF OBJECT_ID('tempdb..#blockers')    IS NOT NULL DROP TABLE #blockers;
IF OBJECT_ID('tempdb..#ignore_fk')   IS NOT NULL DROP TABLE #ignore_fk;
IF OBJECT_ID('tempdb..#ignore_fk_check') IS NOT NULL DROP TABLE #ignore_fk_check;
IF OBJECT_ID('tempdb..#trig')        IS NOT NULL DROP TABLE #trig;
IF OBJECT_ID('tempdb..#verify')      IS NOT NULL DROP TABLE #verify;
IF OBJECT_ID('tempdb..#kept_counts') IS NOT NULL DROP TABLE #kept_counts;
IF OBJECT_ID('tempdb..#catalogue_closure')  IS NOT NULL DROP TABLE #catalogue_closure;
IF OBJECT_ID('tempdb..#org_retain_plan')    IS NOT NULL DROP TABLE #org_retain_plan;
IF OBJECT_ID('tempdb..#org_retain_proof')   IS NOT NULL DROP TABLE #org_retain_proof;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51000, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF @Scope IS NULL OR @Scope NOT IN (N'ALL', N'CATALOGUE', N'ORG_RETAIN')
    THROW 51005, 'Set @Scope to N''ALL'', N''CATALOGUE'' or N''ORG_RETAIN''.', 1;

IF @Scope = N'ORG_RETAIN' AND NOT EXISTS (SELECT 1 FROM @KeepOrganizationIds)
    THROW 51006, 'ORG_RETAIN scope: @KeepOrganizationIds is empty. Nothing would survive -- set it or use ALL scope instead.', 1;

IF @DryRun = 0 AND (@ConfirmDatabase IS NULL OR @ConfirmDatabase <> DB_NAME())
BEGIN
    PRINT '>>> BLOCKED. Set @ConfirmDatabase = N''' + DB_NAME() + ''' to run this for real.';
    THROW 51001, 'Database confirmation missing or does not match the current database.', 1;
END

PRINT '=====================================================================';
PRINT '192 Practice Management data reset';
PRINT '  Database : ' + DB_NAME();
PRINT '  Scope    : ' + @Scope
    + CASE WHEN @Scope = N'CATALOGUE'
           THEN ' (repository subscription and everything below it)'
           WHEN @Scope = N'ORG_RETAIN'
           THEN ' (purge every organisation except @KeepOrganizationIds; reset their catalogue layer)'
           ELSE ' (whole module except masters and global config)' END;
IF @Scope = N'ORG_RETAIN'
BEGIN
    /* PRINT cannot take an inline subquery (Msg 1046: "Subqueries are not
       allowed in this context"), even one parenthesised as a scalar -- the
       value has to land in a variable first. @KeepOrgIdsCsv is already
       populated above, so it is reused here rather than querying again. */
    PRINT '  Kept org : ' + ISNULL(@KeepOrgIdsCsv, N'(none)');
END
PRINT '  Mode     : ' + CASE WHEN @DryRun = 1 THEN 'DRY RUN (nothing will be deleted)' ELSE 'EXECUTE' END;
PRINT '  Started  : ' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126) + 'Z';
PRINT '=====================================================================';

/* ------------------------------------------------------------------ */
/* 1. Keep list                                                        */
/* ------------------------------------------------------------------ */
CREATE TABLE #keep (table_name SYSNAME NOT NULL PRIMARY KEY, keep_reason NVARCHAR(60) NOT NULL);

IF @Scope IN (N'ALL', N'ORG_RETAIN')
BEGIN
    /* A handful of tables end in _master but are not global masters at
       all -- entity_type_master, risk_category_master, risk_likelihood_
       master, risk_impact_master, risk_impact_area_master are fully
       tenant-owned (organization_id NOT NULL, confirmed in 066/204/309);
       risk_type_master, committee_designation_master, threat_master and
       vulnerability_master are mixed (organization_id NULL = shared row
       every tenant sees, set = that tenant's private addition -- 285's
       and 313's own header comments say so). Migration 272 already knows
       the first five are "per-tenant, not global" (its own header lists
       them); the 192 reset never did, and kept them whole -- which left
       their FK to `organization` pointing from #keep into #target once
       organization itself was being cleared, tripping the blocker check
       in section 3.
       The fix: exclude any _master table that carries an organization_id
       column from this keep-list at all -- computed from sys.columns, so
       a future org-scoped _master table is excluded automatically without
       editing this query. It then falls into #target: ALL scope deletes
       it outright like everything else (the masters-reseed note in
       section 8 already tells the operator to reseed anything that comes
       back empty); ORG_RETAIN row-filters it like any other FILTERED
       table in section 2, and because NULL NOT IN (...) is UNKNOWN rather
       than TRUE in T-SQL, the shared/global rows in the four mixed-
       ownership tables are never matched by that filter and always
       survive, regardless of which organizations are purged. */
    INSERT INTO #keep (table_name, keep_reason)
    SELECT t.name, N'master table'
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.name LIKE '%[_]master'
      AND NOT EXISTS (SELECT 1 FROM sys.columns c
                      WHERE c.object_id = t.object_id AND c.name = N'organization_id');

    INSERT INTO #keep (table_name, keep_reason)
    SELECT v.table_name, N'global config/security'
    FROM (VALUES
            (N'reference_option'),
            (N'security_role'),
            (N'security_permission'),
            (N'security_role_permission'),
            (N'rbac_rule'),
            (N'entity_state_transition_rule'),
            -- Post-run fix 5 (2026-10-13): these 23 are global catalogue/
            -- definition tables discovered while diagnosing the ORG_RETAIN
            -- Msg 51007 block -- every one confirmed by reading its own
            -- CREATE TABLE and migration header (several literally say
            -- "(global)" in the comment), not by name pattern. No
            -- organization_id, no FK to anything organisation-scoped,
            -- seeded once via MERGE with fixed values. They do not end in
            -- _master, which is why the name-glob above never caught them.
            (N'organization_metadata_definition'),   -- 001: global metadata key catalogue
            (N'obligation_type_field_rule'),         -- 228: global per-type field rules
            (N'repository_copy_config'),             -- 391: global clone/copy registry
            (N'asset_lifecycle_status_phase'),       -- 428: BRD 5 status/phase catalogue
            (N'asset_legacy_status_map'),             -- 428: 3-row legacy status mapping
            (N'asset_field_definition'),              -- 420: global asset field schema
            (N'asset_field_validation_rule'),         -- 428: global cross-field rules
            (N'asset_lifecycle_transition_gate'),     -- 429: global transition-rule gate
            (N'asset_workflow_definition'),           -- 433: BRD 11 workflow definitions (global)
            (N'asset_workflow_step'),                 -- 433: steps of the above
            (N'asset_contract_contact_role'),         -- 434: global contact-role list
            (N'asset_notification_activity'),         -- 437: "Catalogues (global)"
            (N'asset_notification_recipient_type'),   -- 437: "Catalogues (global)"
            (N'asset_notification_default_stage'),    -- 437: global default stage intervals
            (N'asset_notification_default_recipient'),-- 437: global default recipients
            (N'asset_escalation_matrix_default'),     -- 437: global escalation defaults
            (N'asset_activity_template'),             -- 438: "Activity templates (global)"
            (N'asset_evidence_field'),                -- 439: "global catalogue"
            (N'asset_relationship_type'),             -- 440: "global, BRD 5.4"
            (N'asset_privacy_requirement'),            -- 448: "Requirement catalogue (global)"
            (N'asset_governance_kpi'),                 -- 450: "KPI catalogue (global)"
            (N'asset_report_definition'),              -- 452: "Report catalogue (global)"
            (N'dependency_type_source_config')         -- 002: global picker-source config
            -- NOTE: feature_flag is deliberately NOT in this list for
            -- ORG_RETAIN -- unlike ALL scope, feature_flag is organisation-
            -- scoped data here (it carries organization_id), so ORG_RETAIN
            -- row-filters it in section 2 instead of keeping it whole. ALL
            -- scope keeps the whole table because it clears `organization`
            -- itself, so there is no organisation left for any row in it
            -- to belong to -- that distinction does not apply here.
         ) AS v(table_name)
    WHERE EXISTS (SELECT 1 FROM sys.tables t
                  JOIN sys.schemas s ON s.schema_id = t.schema_id
                  WHERE s.name = 'grac_practice' AND t.name = v.table_name)
      AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = v.table_name);

    IF @Scope = N'ALL'
    BEGIN
        INSERT INTO #keep (table_name, keep_reason)
        SELECT N'feature_flag', N'global config/security'
        WHERE EXISTS (SELECT 1 FROM sys.tables t
                      JOIN sys.schemas s ON s.schema_id = t.schema_id
                      WHERE s.name = 'grac_practice' AND t.name = N'feature_flag')
          AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = N'feature_flag');
    END
END
/* In CATALOGUE scope the keep list is whatever the delete set does not
   claim, so it is filled in AFTER section 2. ORG_RETAIN's keep list is
   masters + global config only (above) -- organisation-structural tables
   are row-filtered, not whole-table-kept, so they belong in #target with
   delete_mode = 'FILTERED', not in #keep. */

/* ------------------------------------------------------------------ */
/* 2. Delete set                                                       */
/* ------------------------------------------------------------------ */
CREATE TABLE #target
(
    object_id       INT           NOT NULL PRIMARY KEY,
    table_name      SYSNAME       NOT NULL,
    lvl             INT           NULL,
    row_est         BIGINT        NULL,
    has_ident       BIT           NOT NULL DEFAULT 0,
    -- ORG_RETAIN only (ALL/CATALOGUE: every row is 'UNCONDITIONAL', the
    -- same whole-table delete those two scopes have always done).
    --   UNCONDITIONAL  -- DELETE FROM table; (no WHERE), same as ALL/CATALOGUE
    --   FILTERED       -- DELETE WHERE <org_resolve_expr> NOT IN (kept orgs)
    --   FILTERED_RESET -- the above DELETE, plus an UPDATE resetting
    --                     applicability for the surviving (kept-org) rows
    delete_mode     SYSNAME       NOT NULL DEFAULT N'UNCONDITIONAL',
    org_resolve_expr NVARCHAR(MAX) NULL,   -- SQL expression: this row's organization_id
    org_resolve_desc NVARCHAR(400) NULL    -- human-readable version, for the dry-run plan
);

/* Populated only for CATALOGUE / ORG_RETAIN -- the @CatalogueRoots closure,
   computed once so CATALOGUE (copies it straight into #target) and
   ORG_RETAIN (uses it to classify UNCONDITIONAL vs FILTERED) share the
   exact same algorithm instead of each carrying its own copy. */
CREATE TABLE #catalogue_closure (object_id INT NOT NULL PRIMARY KEY, table_name SYSNAME NOT NULL);

IF @Scope IN (N'CATALOGUE', N'ORG_RETAIN')
BEGIN
    INSERT INTO #catalogue_closure (object_id, table_name)
    SELECT t.object_id, t.name
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN @CatalogueRoots r ON r.table_name = t.name
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0;

    IF NOT EXISTS (SELECT 1 FROM #catalogue_closure)
        THROW 51003, 'CATALOGUE/ORG_RETAIN scope: none of the root tables exist in this database. Check @CatalogueRoots.', 1;

    IF EXISTS (SELECT 1 FROM @CatalogueRoots r
                WHERE NOT EXISTS (SELECT 1 FROM #catalogue_closure g WHERE g.table_name = r.table_name))
    BEGIN
        PRINT '>>> These named roots do not exist in grac_practice and were ignored:';
        SELECT r.table_name AS missing_root
        FROM @CatalogueRoots r
        WHERE NOT EXISTS (SELECT 1 FROM #catalogue_closure g WHERE g.table_name = r.table_name);
    END

    SET @changed = 1;
    SET @pass    = 0;
    WHILE @changed > 0 AND @pass < 100
    BEGIN
        INSERT INTO #catalogue_closure (object_id, table_name)
        SELECT DISTINCT ct.object_id, ct.name
        FROM sys.foreign_keys fk
        JOIN sys.tables  ct ON ct.object_id = fk.parent_object_id
        JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
        WHERE cs.name = 'grac_practice'
          AND ct.is_ms_shipped = 0
          AND fk.referenced_object_id IN (SELECT object_id FROM #catalogue_closure)
          AND fk.parent_object_id NOT IN (SELECT object_id FROM #catalogue_closure);

        SET @changed = @@ROWCOUNT;
        SET @pass += 1;
    END

    IF EXISTS (SELECT 1 FROM #catalogue_closure WHERE table_name LIKE '%[_]master')
    BEGIN
        PRINT '>>> BLOCKED. The @CatalogueRoots closure reached one or more _master tables:';
        SELECT table_name FROM #catalogue_closure WHERE table_name LIKE '%[_]master' ORDER BY table_name;
        PRINT '    A master should never be a child of the catalogue subtree. Either the';
        PRINT '    root list is too wide, or that master carries an unexpected FK.';
        THROW 51004, 'CATALOGUE/ORG_RETAIN scope: closure reached a master table. Nothing was deleted.', 1;
    END
END

IF @Scope = N'ALL'
BEGIN
    INSERT INTO #target (object_id, table_name, row_est, has_ident)
    SELECT t.object_id,
           t.name,
           ISNULL((SELECT SUM(ps.row_count)
                   FROM sys.dm_db_partition_stats ps
                   WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)), 0),
           CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                             WHERE ic.object_id = t.object_id) THEN 1 ELSE 0 END
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = t.name);
END
ELSE IF @Scope = N'CATALOGUE'
BEGIN
    /* ---------------------------------------------------------------- */
    /* CATALOGUE scope: the subscription-and-below subtree only.        */
    /*                                                                  */
    /* Membership was already computed into #catalogue_closure above    */
    /* (the shared block before this IF) -- seeded from @CatalogueRoots  */
    /* and closed over foreign keys, with the "no root exists" and       */
    /* "closure reached a master" checks already done there. This       */
    /* branch only copies that closure into #target.                    */
    /* ---------------------------------------------------------------- */
    INSERT INTO #target (object_id, table_name, row_est, has_ident, delete_mode)
    SELECT object_id, table_name, 0, 0, N'UNCONDITIONAL'
    FROM #catalogue_closure;

    /* Row estimates and identity flags, once the membership is settled. */
    UPDATE g
       SET g.row_est   = ISNULL((SELECT SUM(ps.row_count)
                                 FROM sys.dm_db_partition_stats ps
                                 WHERE ps.object_id = g.object_id AND ps.index_id IN (0, 1)), 0),
           g.has_ident = CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                                           WHERE ic.object_id = g.object_id) THEN 1 ELSE 0 END
    FROM #target g;

    INSERT INTO #keep (table_name, keep_reason)
    SELECT t.name, N'outside catalogue scope'
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM #target g WHERE g.object_id = t.object_id);
END
ELSE
BEGIN
    /* ---------------------------------------------------------------- */
    /* ORG_RETAIN scope. #target starts as the same "every non-master,   */
    /* non-global-config table" universe ALL scope uses, then every row  */
    /* is classified into one of three delete_mode values (see the       */
    /* header comment for the full reasoning):                           */
    /*   FILTERED_RESET -- organization_framework_statements and          */
    /*                     organization_statement_applicability. Purged-  */
    /*                     org rows deleted; kept-org rows UPDATEd back   */
    /*                     to "Not Updated" with owner/reason cleared.    */
    /*   FILTERED       -- repository_subscription and subscription_      */
    /*                     recommendation_history (named carve-outs, kept */
    /*                     despite being @CatalogueRoots entries -- see   */
    /*                     header), plus everything outside the closure:  */
    /*                     organization and its structure, menu grants,   */
    /*                     feature flags, workflow(_stage), event_         */
    /*                     definition. Purged-org rows deleted, kept-org  */
    /*                     rows survive untouched.                        */
    /*   UNCONDITIONAL  -- every other #catalogue_closure member (the     */
    /*                     practice-and-below subtree). Deleted for       */
    /*                     EVERY organization, kept or not.               */
    /* ---------------------------------------------------------------- */
    INSERT INTO #target (object_id, table_name, row_est, has_ident, delete_mode)
    SELECT t.object_id,
           t.name,
           ISNULL((SELECT SUM(ps.row_count)
                   FROM sys.dm_db_partition_stats ps
                   WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)), 0),
           CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                             WHERE ic.object_id = t.object_id) THEN 1 ELSE 0 END,
           CASE WHEN t.name IN (N'organization_framework_statements', N'organization_statement_applicability')
                    THEN N'FILTERED_RESET'
                WHEN t.name IN (N'repository_subscription', N'subscription_recommendation_history')
                    THEN N'FILTERED'
                -- Post-run fix 5 (2026-10-13): practice_audit_trace and
                -- entity_state_transition_log are the two generic,
                -- append-only audit logs (entity_type/entity_id, no real
                -- FK to anything organisation-scoped -- deliberate, so the
                -- audit trail is not coupled to every module that can be
                -- audited). They are outside the @CatalogueRoots closure
                -- for the same reason and would otherwise default to
                -- FILTERED with no way to resolve organization_id, which
                -- is exactly the Msg 51007 block. ALL scope has always
                -- wiped both of these outright (neither is a master or
                -- global-config table); ORG_RETAIN keeps that same
                -- behaviour -- UNCONDITIONAL, cleared for every
                -- organisation, kept or not -- rather than inventing new
                -- semantics for audit history of data that is itself
                -- being reset.
                WHEN t.name IN (N'practice_audit_trace', N'entity_state_transition_log')
                    THEN N'UNCONDITIONAL'
                WHEN EXISTS (SELECT 1 FROM #catalogue_closure cc WHERE cc.object_id = t.object_id)
                    THEN N'UNCONDITIONAL'
                ELSE N'FILTERED'
           END
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = t.name);

    /* ------------------------------------------------------------------ */
    /* Resolve organization_id for every FILTERED / FILTERED_RESET table.   */
    /*                                                                      */
    /* org_resolve_expr is stored as a template with a single free          */
    /* placeholder, the literal token {T}, standing for "the alias of this  */
    /* table's own row in whatever query embeds this expression". A direct  */
    /* column resolves to '{T}.organization_id'. A one-or-more-hop table     */
    /* resolves to a correlated subquery against its (already-resolved)      */
    /* parent, with the parent's OWN template spliced in and its {T}         */
    /* rebound to a globally-unique alias ('h' + the parent's object_id, so  */
    /* nesting to any depth can never collide) -- leaving exactly one free   */
    /* {T} in the result, for whoever embeds or executes THIS table's        */
    /* expression next.                                                      */
    /*                                                                      */
    /* Pass 1 resolves every direct column. Each further pass resolves any   */
    /* still-unresolved table that has exactly one foreign key to exactly    */
    /* one already-resolved table (sys.foreign_keys + a GROUP BY/HAVING      */
    /* COUNT(DISTINCT ...) check -- a table with FKs to two different        */
    /* already-resolved tables is left unresolved rather than guessed at).   */
    /* Bounded at 20 passes; the deepest real hop in this schema today is 1. */
    /* ------------------------------------------------------------------ */
    UPDATE t
       SET t.org_resolve_expr = N'{T}.organization_id',
           t.org_resolve_desc = N'direct column'
    FROM #target t
    WHERE t.delete_mode IN (N'FILTERED', N'FILTERED_RESET')
      AND EXISTS (SELECT 1 FROM sys.columns c
                  WHERE c.object_id = t.object_id AND c.name = N'organization_id');

    -- Post-run fix 7 (2026-10-13): technology_lifecycle_event (425) is a
    -- polymorphic audit log over asset_model/asset_make -- entity_type/
    -- entity_id, no declared FK (entity_type is 'MODEL' today, FIRMWARE/OS
    -- later), so the generic FK-hop resolver below can never reach it. What
    -- it logs is NOT the practice catalogue -- asset_model/asset_make are
    -- MIXED ownership (organization_id NULLable: NULL = a global/shared
    -- catalogue row every tenant sees, set = one org's own private
    -- addition), the same shape as the 9 mixed _master tables from fix 2 --
    -- so, unlike practice_audit_trace/entity_state_transition_log
    -- (Category D, fix 5), this one is NOT made UNCONDITIONAL: that would
    -- erase lifecycle history for kept orgs' own models and for globally-
    -- shared catalogue models that the mixed-ownership design otherwise
    -- always preserves. Instead it gets a hand-written, named resolution:
    -- for an entity_type = 'MODEL' row, inherit asset_model's own
    -- organization_id (NULL/global and kept-org rows preserved, purged-org
    -- rows' history deleted along with the model); any other (future)
    -- entity_type resolves to NULL, which is preserved by default rather
    -- than guessed at.
    UPDATE t
       SET t.org_resolve_expr = N'(SELECT m.organization_id FROM grac_practice.asset_model m WHERE m.model_id = {T}.entity_id AND {T}.entity_type = N''MODEL'')',
           t.org_resolve_desc = N'polymorphic -- via asset_model'
    FROM #target t
    WHERE t.table_name = N'technology_lifecycle_event'
      AND t.delete_mode IN (N'FILTERED', N'FILTERED_RESET');

    SET @pass    = 0;
    SET @changed = 1;

    WHILE @changed > 0 AND @pass < 20
    BEGIN
        ;WITH candidate_raw AS (
            SELECT fk.object_id AS fk_object_id, fk.parent_object_id, fk.referenced_object_id
            FROM sys.foreign_keys fk
            JOIN #target child  ON child.object_id  = fk.parent_object_id
            JOIN #target parent ON parent.object_id = fk.referenced_object_id
            WHERE child.delete_mode IN (N'FILTERED', N'FILTERED_RESET')
              AND child.org_resolve_expr IS NULL
              AND parent.org_resolve_expr IS NOT NULL
              AND fk.parent_object_id <> fk.referenced_object_id
        ),
        -- A child with a @PreferredResolutionParent entry has its
        -- candidates narrowed to that one named parent BEFORE the
        -- ambiguity check below ever runs, so a table with two or more
        -- genuinely valid paths is resolved by an explicit, reviewed
        -- choice instead of refused. Every other child is untouched --
        -- same candidate set as before, still refused if truly ambiguous.
        candidate AS (
            SELECT cr.*
            FROM candidate_raw cr
            WHERE NOT EXISTS (SELECT 1 FROM @PreferredResolutionParent pref
                              JOIN #target t ON t.object_id = cr.parent_object_id
                                             AND t.table_name = pref.child_table_name)
            UNION ALL
            SELECT cr.*
            FROM candidate_raw cr
            JOIN #target t ON t.object_id = cr.parent_object_id
            JOIN @PreferredResolutionParent pref ON pref.child_table_name = t.table_name
            JOIN #target p ON p.object_id = cr.referenced_object_id
                           AND p.table_name = pref.preferred_parent_table_name
        ),
        unambiguous AS (
            SELECT parent_object_id
            FROM candidate
            GROUP BY parent_object_id
            HAVING COUNT(DISTINCT referenced_object_id) = 1
        ),
        chosen AS (
            SELECT c.parent_object_id, c.referenced_object_id, fk_object_id = MIN(c.fk_object_id)
            FROM candidate c
            JOIN unambiguous u ON u.parent_object_id = c.parent_object_id
            GROUP BY c.parent_object_id, c.referenced_object_id
        )
        UPDATE t
           SET t.org_resolve_expr =
                   N'(SELECT ' + REPLACE(p.org_resolve_expr, N'{T}', N'h' + CAST(p.object_id AS NVARCHAR(20)))
                 + N' FROM grac_practice.' + QUOTENAME(p.table_name) + N' h' + CAST(p.object_id AS NVARCHAR(20))
                 + N' WHERE ' + joincols.predicate + N')',
               t.org_resolve_desc = N'via ' + p.table_name + N' (' + p.org_resolve_desc + N')'
        FROM #target t
        JOIN chosen ch ON ch.parent_object_id = t.object_id
        JOIN #target p ON p.object_id = ch.referenced_object_id
        CROSS APPLY (
            SELECT predicate =
                STUFF((SELECT N' AND h' + CAST(ch.referenced_object_id AS NVARCHAR(20)) + N'.' + QUOTENAME(rc.name)
                            + N' = {T}.' + QUOTENAME(cc.name)
                       FROM sys.foreign_key_columns fkc
                       JOIN sys.columns cc ON cc.object_id = fkc.parent_object_id
                                          AND cc.column_id = fkc.parent_column_id
                       JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id
                                          AND rc.column_id = fkc.referenced_column_id
                       WHERE fkc.constraint_object_id = ch.fk_object_id
                       ORDER BY fkc.constraint_column_id
                       FOR XML PATH(N''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 5, N'')
        ) joincols
        WHERE t.delete_mode IN (N'FILTERED', N'FILTERED_RESET')
          AND t.org_resolve_expr IS NULL;

        SET @changed = @@ROWCOUNT;
        SET @pass += 1;
    END

    IF EXISTS (SELECT 1 FROM #target
                WHERE delete_mode IN (N'FILTERED', N'FILTERED_RESET') AND org_resolve_expr IS NULL)
    BEGIN
        PRINT '>>> BLOCKED. Could not resolve organization_id for these tables:';
        SELECT table_name, delete_mode FROM #target
        WHERE delete_mode IN (N'FILTERED', N'FILTERED_RESET') AND org_resolve_expr IS NULL
        ORDER BY table_name;
        PRINT '    Either add a direct organization_id column, or an unambiguous foreign-key';
        PRINT '    path to a table that already resolves, or move this table into';
        PRINT '    @CatalogueRoots if it really belongs to the catalogue-and-below subtree.';
        THROW 51007, 'ORG_RETAIN scope: organization_id could not be resolved for one or more tables. Nothing was deleted.', 1;
    END

    /* Finally, bind every template's one remaining {T} to the real table
       alias ('d', chosen to match the DELETE/UPDATE statements in section 6). */
    UPDATE #target
       SET org_resolve_expr = REPLACE(org_resolve_expr, N'{T}', N'd')
     WHERE delete_mode IN (N'FILTERED', N'FILTERED_RESET');
END

SELECT @totalRows = SUM(row_est) FROM #target;
SELECT @keepCount = COUNT(*) FROM #keep;
SELECT @targetCount = COUNT(*) FROM #target;

/* PRINT takes a scalar expression only -- subqueries are illegal here,
   hence the counts are read into variables first. */
PRINT 'Tables kept    : ' + CAST(@keepCount AS NVARCHAR(10));
PRINT 'Tables to clear: ' + CAST(@targetCount AS NVARCHAR(10))
    + '  (approx ' + CAST(ISNULL(@totalRows, 0) AS NVARCHAR(20)) + ' rows)';
PRINT '';

/* ------------------------------------------------------------------ */
/* 3. Pre-flight: anything outside the delete set pointing into it?     */
/*    (a kept master, or a table in another schema)                     */
/* ------------------------------------------------------------------ */
SELECT fk.name                                              AS fk_name,
       QUOTENAME(cs.name) + '.' + QUOTENAME(ct.name)        AS referencing_table,
       QUOTENAME(rs.name) + '.' + QUOTENAME(rt.name)        AS referenced_table
INTO #blockers
FROM sys.foreign_keys fk
JOIN sys.tables  ct ON ct.object_id  = fk.parent_object_id
JOIN sys.schemas cs ON cs.schema_id  = ct.schema_id
JOIN sys.tables  rt ON rt.object_id  = fk.referenced_object_id
JOIN sys.schemas rs ON rs.schema_id  = rt.schema_id
WHERE fk.referenced_object_id IN (SELECT object_id FROM #target)
  AND fk.parent_object_id NOT IN (SELECT object_id FROM #target);

SELECT @blockers = COUNT(*) FROM #blockers;

IF @blockers > 0
BEGIN
    PRINT '>>> BLOCKERS: these tables are NOT being cleared but reference tables that are.';
    PRINT '    Either add the referencing table to the delete set, or add the referenced';
    PRINT '    table to the keep list, then rerun.';
    SELECT fk_name, referencing_table, referenced_table FROM #blockers ORDER BY referencing_table;
    THROW 51002, 'Foreign keys from outside the delete set point into it. Nothing was deleted.', 1;
END

/* ------------------------------------------------------------------ */
/* 4. Delete order: children (level 0) first, parents last              */
/*                                                                      */
/*    This schema contains several genuine, mutual FK cycles -- two      */
/*    tables each pointing back at the other, so no delete order can     */
/*    satisfy both directions:                                          */
/*      org_assurance_definition      <-> org_assurance_definition_version */
/*        (current_version_id / active_version_id, migration 069)       */
/*      practice_task                 <-> task_candidate                */
/*      risk_analysis                 <-> risk_register                 */
/*      risk_candidate                <-> risk_register                 */
/*      risk_register                 <-> risk_residual_analysis        */
/*    Each is broken the same way the schema intended: the nullable      */
/*    pointer column(s) on one or both sides are set to NULL first, that */
/*    FK is then ignored for ordering purposes, and the levelling is     */
/*    recomputed. A cycle over NOT NULL columns still aborts the script  */
/*    rather than guessing.                                              */
/*                                                                        */
/*    Detection only nulls an FK when the OTHER table has a real FK      */
/*    pointing back to THIS one (a genuinely mutual pair) -- not merely  */
/*    when both ends happen to be unresolved. That distinction matters:  */
/*    every table in the five cycles above also carries ordinary FKs      */
/*    into organization_employee (owner/approver/analyst/... columns),   */
/*    so organization_employee cannot level until they do, and would      */
/*    otherwise be swept into this step too even though it has no cycle   */
/*    of its own -- blanket-nulling its role_id/provider_vendor_id would  */
/*    then fail ck_pm_employee_provider_required for any ThirdParty row. */
/*    Requiring the reverse FK to actually exist keeps that kind of       */
/*    innocent, merely-downstream table out of #ignore_fk.                */
/* ------------------------------------------------------------------ */
CREATE TABLE #ignore_fk
(
    constraint_object_id INT           NOT NULL PRIMARY KEY,
    fk_name              SYSNAME       NOT NULL,
    parent_table         SYSNAME       NOT NULL,
    referenced_table     SYSNAME       NOT NULL,
    null_stmt            NVARCHAR(MAX) NOT NULL
);

/* A column being broken out of a cycle can be tied, by a CHECK constraint on
   the SAME row, to another column that is not part of the cycle at all --
   e.g. risk_candidate.registered_risk_id (the cycle column) is required
   NOT NULL whenever risk_candidate.status_code = 'Registered'
   (ck_pm_risk_candidate_registered_link). Nulling the cycle column alone
   would fail that CHECK even though the row is seconds away from being
   deleted outright (delete_mode = UNCONDITIONAL) or was never going to keep
   that column's value anyway (FILTERED/FILTERED_RESET rows that survive are
   never the ones a cycle-breaking UPDATE touches, because the UPDATE only
   ever runs during ALL/CATALOGUE/ORG_RETAIN's shared cycle-breaking step,
   on rows about to be deleted). So: any CHECK constraint on the parent
   table whose definition mentions one of the columns a #ignore_fk entry is
   about to NULL gets NOCHECK'd immediately before that UPDATE runs, and
   re-enabled (without revalidating -- the rows it would be validating are
   already gone) right after. Same transactional safety net as the trigger
   disable above: constraint DDL rolls back with everything else. */
CREATE TABLE #ignore_fk_check
(
    check_object_id INT     NOT NULL PRIMARY KEY,
    table_name      SYSNAME NOT NULL,
    check_name      SYSNAME NOT NULL
);

DECLARE @breakPass INT = 0, @broke INT = 0;

WHILE 1 = 1
BEGIN
    UPDATE #target SET lvl = NULL;
    SET @pass = 0;
    SET @changed = 1;

    /* Level 0 = nothing in the delete set references it. */
    UPDATE t
       SET t.lvl = 0
    FROM #target t
    WHERE NOT EXISTS (SELECT 1
                      FROM sys.foreign_keys fk
                      JOIN #target c ON c.object_id = fk.parent_object_id
                      WHERE fk.referenced_object_id = t.object_id
                        AND fk.parent_object_id <> fk.referenced_object_id
                        AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk));

    WHILE @changed > 0 AND @pass < 100
    BEGIN
        UPDATE t
           SET t.lvl = x.next_lvl
        FROM #target t
        CROSS APPLY (SELECT next_lvl = MAX(c.lvl) + 1
                     FROM sys.foreign_keys fk
                     JOIN #target c ON c.object_id = fk.parent_object_id
                     WHERE fk.referenced_object_id = t.object_id
                       AND fk.parent_object_id <> fk.referenced_object_id
                       AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)) x
        WHERE t.lvl IS NULL
          AND x.next_lvl IS NOT NULL
          AND NOT EXISTS (SELECT 1
                          FROM sys.foreign_keys fk2
                          JOIN #target c2 ON c2.object_id = fk2.parent_object_id
                          WHERE fk2.referenced_object_id = t.object_id
                            AND fk2.parent_object_id <> fk2.referenced_object_id
                            AND fk2.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
                            AND c2.lvl IS NULL);

        SET @changed = @@ROWCOUNT;
        SET @pass += 1;
    END

    IF NOT EXISTS (SELECT 1 FROM #target WHERE lvl IS NULL) BREAK;   -- fully ordered
    IF @breakPass >= 10 BREAK;                                       -- safety valve

    /* Still stuck: of the FKs connecting two currently-unresolved tables,
       park only the ones that are ACTUALLY on a cycle -- i.e. the other
       table has a real FK pointing back to this one, so the pair is
       genuinely mutual (A -> B and B -> A). "Both ends are stuck" alone is
       not enough: a table can be stuck purely as collateral damage from
       something else it references being caught in an unrelated cycle
       (e.g. risk_analysis/risk_register/risk_candidate/risk_residual_analysis
       cycle among themselves, and organization_employee is a dead end they
       all also point to -- organization_employee itself has no cycle, but
       it cannot level until those stuck tables do, so without this check it
       would be swept in and have role_id/provider_vendor_id blanket-NULLed
       across the whole table for no reason, which then fails
       ck_pm_employee_provider_required for any ThirdParty row). Requiring a
       mutual FK pair is what distinguishes a genuine 2-table cycle from a
       table that merely sits downstream of one. */
    INSERT INTO #ignore_fk (constraint_object_id, fk_name, parent_table, referenced_table, null_stmt)
    SELECT fk.object_id,
           fk.name,
           pt.name,
           rt.name,
           N'UPDATE grac_practice.' + QUOTENAME(pt.name) + N' SET '
             + STUFF((SELECT N', ' + QUOTENAME(c.name) + N' = NULL'
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                      ORDER BY fkc.constraint_column_id
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') + N';'
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    WHERE fk.parent_object_id     IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.referenced_object_id IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.parent_object_id <> fk.referenced_object_id
      AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
      AND NOT EXISTS (SELECT 1                                   -- every FK column must be nullable
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                        AND c.is_nullable = 0)
      AND EXISTS (SELECT 1                                       -- genuinely mutual: the other
                  FROM sys.foreign_keys fk2                       -- table has a real FK back to
                  WHERE fk2.parent_object_id     = fk.referenced_object_id   -- this one, closing an
                    AND fk2.referenced_object_id = fk.parent_object_id);     -- actual 2-table loop

    SET @broke = @@ROWCOUNT;
    IF @broke = 0 BREAK;                 -- cycle exists but cannot be broken safely
    SET @breakPass += 1;
END

SELECT @cycles = COUNT(*) FROM #target WHERE lvl IS NULL;

IF @cycles > 0
BEGIN
    PRINT '>>> Circular foreign keys that cannot be broken (NOT NULL columns on both sides):';
    SELECT table_name FROM #target WHERE lvl IS NULL ORDER BY table_name;
    THROW 51003, 'Unbreakable circular FK dependency in grac_practice. Nothing was deleted -- resolve manually.', 1;
END

IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    PRINT 'Cycle-breaking pointer columns that will be set to NULL before the deletes:';
    SELECT fk_name,
           parent_table     = N'grac_practice.' + parent_table,
           referenced_table = N'grac_practice.' + referenced_table,
           null_stmt
    FROM #ignore_fk
    ORDER BY parent_table, fk_name;

    /* Any CHECK constraint that mentions one of the columns being nulled
       above has to come off for that same UPDATE, or a row whose other
       column(s) require this one to be non-null will fail the check even
       though the row is on its way out. Matched by a plain substring
       search on sys.check_constraints.definition against the column name
       -- loose rather than exact, which only risks disabling one check too
       many (harmless: it is re-enabled, unvalidated, moments later, inside
       the same transaction, with nothing else writing to the table), never
       too few. */
    INSERT INTO #ignore_fk_check (check_object_id, table_name, check_name)
    SELECT DISTINCT cc.object_id, t.name, cc.name
    FROM #ignore_fk ifk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = ifk.constraint_object_id
    JOIN sys.columns col ON col.object_id = fkc.parent_object_id
                        AND col.column_id = fkc.parent_column_id
    JOIN sys.check_constraints cc ON cc.parent_object_id = fkc.parent_object_id
    JOIN sys.tables t ON t.object_id = cc.parent_object_id
    WHERE cc.definition LIKE N'%' + col.name + N'%';

    IF EXISTS (SELECT 1 FROM #ignore_fk_check)
    BEGIN
        PRINT 'CHECK constraints that reference those columns, taken offline for the same UPDATEs:';
        SELECT check_name, on_table = N'grac_practice.' + table_name
        FROM #ignore_fk_check
        ORDER BY table_name, check_name;
    END
END

/* ------------------------------------------------------------------ */
/* 4b. Triggers standing in the way                                     */
/*                                                                      */
/*     practice_audit_trace and entity_state_transition_log are         */
/*     append-only by design -- each has an INSTEAD OF UPDATE, DELETE   */
/*     trigger that throws rather than letting rows go. The AFTER       */
/*     INSERT/UPDATE triggers elsewhere (impl status sync, employee     */
/*     autoraise) do not fire on DELETE, but they are disabled too so   */
/*     that this script keeps working if one of them ever grows a       */
/*     DELETE branch.                                                   */
/* ------------------------------------------------------------------ */
CREATE TABLE #trig
(
    trigger_object_id INT     NOT NULL PRIMARY KEY,
    table_name        SYSNAME NOT NULL,
    trigger_name      SYSNAME NOT NULL,
    is_instead_of     BIT     NOT NULL
);

INSERT INTO #trig (trigger_object_id, table_name, trigger_name, is_instead_of)
SELECT tr.object_id, t.table_name, tr.name, tr.is_instead_of_trigger
FROM sys.triggers tr
JOIN #target t ON t.object_id = tr.parent_id
WHERE tr.is_disabled = 0
  AND tr.parent_class = 1;          -- object-level triggers only

/* ------------------------------------------------------------------ */
/* 5. The plan                                                         */
/* ------------------------------------------------------------------ */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    PRINT 'Triggers that will be disabled for the duration of the transaction:';
    SELECT trigger_name,
           on_table = N'grac_practice.' + table_name,
           kind     = CASE WHEN is_instead_of = 1
                           THEN 'INSTEAD OF -- blocks the delete, must be disabled'
                           ELSE 'AFTER -- disabled as a precaution' END
    FROM #trig
    ORDER BY table_name, trigger_name;
END

PRINT 'Delete plan (level 0 = leaf child, deleted first):';
SELECT delete_step = ROW_NUMBER() OVER (ORDER BY lvl, table_name),
       fk_level    = lvl,
       table_name  = N'grac_practice.' + table_name,
       delete_mode = delete_mode,
       approx_rows = row_est,
       identity_reseed = CASE WHEN has_ident = 1 AND delete_mode = N'UNCONDITIONAL' THEN 'yes' ELSE 'no' END,
       org_lookup  = ISNULL(org_resolve_desc, N'')
FROM #target
ORDER BY lvl, table_name;

SELECT keep_reason, table_name = N'grac_practice.' + table_name
FROM #keep
ORDER BY keep_reason, table_name;

/* ORG_RETAIN only: exact purge-vs-keep row counts per FILTERED/FILTERED_RESET
   table, so the operator can sanity-check the resolved organization_id path
   before ever setting @DryRun = 0 -- row_est above is a whole-table estimate
   and does not tell kept rows from purged ones apart. */
IF @Scope = N'ORG_RETAIN' AND EXISTS (SELECT 1 FROM #target WHERE delete_mode <> N'UNCONDITIONAL')
BEGIN
    CREATE TABLE #org_retain_plan
    (
        table_name   SYSNAME NOT NULL,
        delete_mode  SYSNAME NOT NULL,
        rows_to_purge BIGINT NOT NULL,
        rows_to_keep  BIGINT NOT NULL
    );

    DECLARE plan_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, delete_mode, org_resolve_expr
        FROM #target
        WHERE delete_mode <> N'UNCONDITIONAL'
        ORDER BY table_name;

    OPEN plan_cur;
    FETCH NEXT FROM plan_cur INTO @tbl, @mode, @orgExpr;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Post-run fix 8 (2026-10-13): SUM(CASE ...) over a table with
        -- zero rows returns NULL in T-SQL, not 0 -- the first run to ever
        -- reach this far (every earlier run aborted at the resolver first)
        -- hit this immediately on an empty FILTERED table and failed with
        -- Msg 515 inserting NULL into the NOT NULL rows_to_purge/rows_to_
        -- keep columns. ISNULL(..., 0) is the correct, obvious reading --
        -- zero rows purged/kept is not an unknown, it is zero.
        --
        -- Post-run fix 9 (2026-10-13): @orgExpr is a plain column for a
        -- direct-column table, but a parenthesised correlated subquery for
        -- any FK-hop-resolved table (section 2's "chosen" UPDATE -- see its
        -- own comment) or the one hand-written polymorphic override
        -- (technology_lifecycle_event, fix 7). Embedding that subquery
        -- straight inside SUM(CASE WHEN ... THEN 1 ELSE 0 END) hit Msg 130
        -- "Cannot perform an aggregate function on an expression containing
        -- an aggregate or a subquery" the first time this code ever ran
        -- against such a table (same reason fix 8's bug went unseen until
        -- now -- nothing reached this far before). Fixed by resolving
        -- @orgExpr into a plain column first, via CROSS APPLY, then
        -- aggregating over that column -- works uniformly for a direct
        -- column, a hop subquery, or the hand-written override, with no
        -- special-casing needed.
        SET @sql = N'INSERT INTO #org_retain_plan (table_name, delete_mode, rows_to_purge, rows_to_keep)
                     SELECT @t, @m,
                            ISNULL(SUM(CASE WHEN x.org_id NOT IN (' + @KeepOrgIdsCsv + N') THEN 1 ELSE 0 END), 0),
                            ISNULL(SUM(CASE WHEN x.org_id     IN (' + @KeepOrgIdsCsv + N') THEN 1 ELSE 0 END), 0)
                     FROM grac_practice.' + QUOTENAME(@tbl) + N' d
                     CROSS APPLY (SELECT org_id = ' + @orgExpr + N') x;';
        EXEC sp_executesql @sql, N'@t SYSNAME, @m SYSNAME', @t = @tbl, @m = @mode;
        FETCH NEXT FROM plan_cur INTO @tbl, @mode, @orgExpr;
    END

    CLOSE plan_cur;
    DEALLOCATE plan_cur;

    PRINT '';
    PRINT 'ORG_RETAIN row-filtered tables -- purge vs keep, by resolved organization_id:';
    SELECT table_name = N'grac_practice.' + table_name, delete_mode, rows_to_purge, rows_to_keep
    FROM #org_retain_plan
    ORDER BY delete_mode, table_name;

    DROP TABLE #org_retain_plan;
END

IF @DryRun = 1
BEGIN
    PRINT '';
    PRINT 'DRY RUN complete. Nothing was deleted.';
    PRINT 'To execute: set @DryRun = 0 and @ConfirmDatabase = N''' + DB_NAME() + ''' at the top.';
    PRINT 'Take a database backup first -- this script has no rollback.';
    RETURN;
END

/* ------------------------------------------------------------------ */
/* 6. Execute                                                          */
/* ------------------------------------------------------------------ */
PRINT '';
PRINT 'Deleting...';

BEGIN TRAN;

/* 6a-0. Disable the triggers on the tables being cleared. Trigger DDL is
         transactional, so a rollback anywhere below restores them. */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    DECLARE trg_off CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, trigger_name FROM #trig ORDER BY table_name, trigger_name;

    OPEN trg_off;
    FETCH NEXT FROM trg_off INTO @tbl, @trg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' DISABLE TRIGGER ' + QUOTENAME(@trg) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [trigger off] ' + @trg + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM trg_off INTO @tbl, @trg;
    END

    CLOSE trg_off;
    DEALLOCATE trg_off;
END

/* 6a. Break the FK cycles first -- these are nullable pointer columns, so
       clearing them destroys no information the deletes were not about to
       remove anyway. Any CHECK constraint standing in the way of that
       nulling comes off first and goes back on right after -- see the
       #ignore_fk_check comment above for why. */
IF EXISTS (SELECT 1 FROM #ignore_fk_check)
BEGIN
    DECLARE chk_off CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, check_name FROM #ignore_fk_check ORDER BY table_name, check_name;

    OPEN chk_off;
    FETCH NEXT FROM chk_off INTO @tbl, @chk;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' NOCHECK CONSTRAINT ' + QUOTENAME(@chk) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [check off] ' + @chk + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM chk_off INTO @tbl, @chk;
    END

    CLOSE chk_off;
    DEALLOCATE chk_off;
END

IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    DECLARE brk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT parent_table, null_stmt FROM #ignore_fk ORDER BY parent_table, fk_name;

    OPEN brk_cur;
    FETCH NEXT FROM brk_cur INTO @tbl, @sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_executesql @sql;
        PRINT '  [cycle] grac_practice.' + @tbl + ' -- pointer column(s) cleared on '
            + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';
        FETCH NEXT FROM brk_cur INTO @tbl, @sql;
    END

    CLOSE brk_cur;
    DEALLOCATE brk_cur;
END

/* Put the CHECK constraints back right away -- WITHOUT revalidating
   (WITH NOCHECK on the re-enable): the rows that would have failed are
   either already gone, in the case of a table processed earlier in level
   order, or about to be deleted outright a few statements from now in 6b,
   so there is nothing left to validate against. */
IF EXISTS (SELECT 1 FROM #ignore_fk_check)
BEGIN
    DECLARE chk_on CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, check_name FROM #ignore_fk_check ORDER BY table_name, check_name;

    OPEN chk_on;
    FETCH NEXT FROM chk_on INTO @tbl, @chk;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' WITH NOCHECK CHECK CONSTRAINT ' + QUOTENAME(@chk) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [check on] ' + @chk + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM chk_on INTO @tbl, @chk;
    END

    CLOSE chk_on;
    DEALLOCATE chk_on;
END

/* 6b. Deletes, children first. */
DECLARE del_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT object_id, table_name, lvl, delete_mode, org_resolve_expr
    FROM #target
    ORDER BY lvl, table_name;

OPEN del_cur;
FETCH NEXT FROM del_cur INTO @objid, @tbl, @lvl, @mode, @orgExpr;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @mode = N'UNCONDITIONAL'
    BEGIN
        /* Same as ALL/CATALOGUE always were: a plain, whole-table delete. */
        SET @sql = N'DELETE FROM grac_practice.' + QUOTENAME(@tbl) + N';';
        EXEC sp_executesql @sql;
        SET @deleted = @@ROWCOUNT;
    END
    ELSE
    BEGIN
        /* FILTERED and FILTERED_RESET both start with the same row-filtered
           delete -- purge every row NOT in @KeepOrganizationIds, resolved via
           @orgExpr (a direct column or an FK-hop subquery, aliased 'd' to
           match this statement). */
        SET @sql = N'DELETE d FROM grac_practice.' + QUOTENAME(@tbl) + N' d WHERE '
                 + @orgExpr + N' NOT IN (' + @KeepOrgIdsCsv + N');';
        EXEC sp_executesql @sql;
        SET @deleted = @@ROWCOUNT;

        IF @mode = N'FILTERED_RESET'
        BEGIN
            /* Only the kept organisation(s)' rows survive the delete above,
               so this UPDATE needs no further WHERE -- it only ever touches
               rows that already belong to a kept organisation. Hand-mapped
               per table (not generic), because the two tables' applicability
               columns are shaped differently (see header comment). */
            IF @tbl = N'organization_statement_applicability'
                UPDATE grac_practice.organization_statement_applicability
                   SET applicability_status    = N'Not Updated',
                       applicability_status_id = @NotUpdatedApplicabilityStatusId,
                       owner_id                = NULL,
                       exclusion_justification  = NULL,
                       updated_by               = N'reset-192',
                       updated_dt               = SYSUTCDATETIME();
            ELSE IF @tbl = N'organization_framework_statements'
                UPDATE grac_practice.organization_framework_statements
                   SET applicability_status_id = @NotUpdatedApplicabilityStatusId,
                       owner_id                = NULL,
                       applicability_reason    = NULL,
                       updated_by               = N'reset-192',
                       updated_dt               = SYSUTCDATETIME();

            PRINT '  [reset] grac_practice.' + @tbl + ' -- applicability cleared for kept organisation(s), '
                + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';
        END
    END

    IF @deleted > 0
        PRINT '  [L' + CAST(@lvl AS NVARCHAR(3)) + '] grac_practice.' + @tbl
            + ' -- ' + CAST(@deleted AS NVARCHAR(20)) + ' row(s) deleted'
            + CASE WHEN @mode <> N'UNCONDITIONAL' THEN N' (' + @mode + N')' ELSE N'' END;

    FETCH NEXT FROM del_cur INTO @objid, @tbl, @lvl, @mode, @orgExpr;
END

CLOSE del_cur;
DEALLOCATE del_cur;

/* 6c. Put the triggers back before anything else. Done inside the same
       transaction so the tables are never left unguarded. */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    DECLARE trg_on CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, trigger_name FROM #trig ORDER BY table_name, trigger_name;

    OPEN trg_on;
    FETCH NEXT FROM trg_on INTO @tbl, @trg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' ENABLE TRIGGER ' + QUOTENAME(@trg) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [trigger on ] ' + @trg + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM trg_on INTO @tbl, @trg;
    END

    CLOSE trg_on;
    DEALLOCATE trg_on;
END

/* Nothing may survive in the delete set -- verify before committing. */
DECLARE @leftover INT = 0;

CREATE TABLE #verify (table_name SYSNAME NOT NULL, remaining BIGINT NOT NULL);

DECLARE vfy_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, delete_mode, org_resolve_expr FROM #target ORDER BY table_name;

OPEN vfy_cur;
FETCH NEXT FROM vfy_cur INTO @tbl, @mode, @orgExpr;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @mode = N'UNCONDITIONAL'
        /* Original rule, unchanged: the whole table must be empty. */
        SET @sql = N'INSERT INTO #verify(table_name, remaining)
                     SELECT @t, COUNT_BIG(*) FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    ELSE
        /* FILTERED / FILTERED_RESET: only a purged organisation's rows must
           be gone -- a kept organisation's rows are expected to remain, so
           "empty" would be the wrong assertion here. */
        SET @sql = N'INSERT INTO #verify(table_name, remaining)
                     SELECT @t, COUNT_BIG(*) FROM grac_practice.' + QUOTENAME(@tbl) + N' d
                     WHERE ' + @orgExpr + N' NOT IN (' + @KeepOrgIdsCsv + N');';

    EXEC sp_executesql @sql, N'@t SYSNAME', @t = @tbl;
    FETCH NEXT FROM vfy_cur INTO @tbl, @mode, @orgExpr;
END

CLOSE vfy_cur;
DEALLOCATE vfy_cur;

SELECT @leftover = COUNT(*) FROM #verify WHERE remaining > 0;

IF @leftover > 0
BEGIN
    PRINT '>>> Rows survived the delete. Rolling back.';
    SELECT table_name, remaining FROM #verify WHERE remaining > 0 ORDER BY table_name;
    ROLLBACK TRAN;
    THROW 51004, 'Data reset did not fully clear the delete set. Transaction rolled back.', 1;
END

COMMIT TRAN;
PRINT 'Committed.';

/* ------------------------------------------------------------------ */
/* 7. Identity reseed (after COMMIT -- DBCC CHECKIDENT is not           */
/*    reliably transactional, so it must not sit inside the tran)       */
/* ------------------------------------------------------------------ */
IF @ReseedIdentity = 1
BEGIN
    PRINT 'Reseeding IDENTITY counters...';

    /* has_ident alone is not enough once a scope can leave rows behind:
       reseeding to 0 a table that still holds a kept organisation's rows
       would hand out an identity value that collides with one already in
       use on the next insert. UNCONDITIONAL is the only delete_mode that
       empties a table completely, so it is the only one eligible here.
       ALL and CATALOGUE are unaffected -- every one of their rows already
       defaults to delete_mode = 'UNCONDITIONAL'. */
    DECLARE ident_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name FROM #target
        WHERE has_ident = 1 AND delete_mode = N'UNCONDITIONAL'
        ORDER BY table_name;

    OPEN ident_cur;
    FETCH NEXT FROM ident_cur INTO @tbl;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        /* 550 (2026-11-14): RESEED 0 makes the NEXT row 1 only on a table
           that has had rows. On a table that never had one since it was
           created -- last_value NULL, or 0 left by an earlier reseed --
           SQL Server gives the FIRST row the reseed value itself, i.e. 0
           (an audit plan was stored with id 0 this way). Such a table is
           reseeded to 1 instead. */
        SET @sql = N'DBCC CHECKIDENT (''grac_practice.' + @tbl + N''', RESEED, '
                 + CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                                      WHERE ic.object_id = OBJECT_ID(N'grac_practice.' + @tbl)
                                        AND ISNULL(CONVERT(BIGINT, ic.last_value), 0) = 0)
                        THEN N'1' ELSE N'0' END
                 + N') WITH NO_INFOMSGS;';
        EXEC sp_executesql @sql;
        FETCH NEXT FROM ident_cur INTO @tbl;
    END

    CLOSE ident_cur;
    DEALLOCATE ident_cur;

    PRINT 'Identity counters restart at 1.';
END

/* ------------------------------------------------------------------ */
/* 8. Proof: masters still populated                                    */
/* ------------------------------------------------------------------ */
PRINT '';
PRINT 'Kept tables and their surviving row counts:';

CREATE TABLE #kept_counts (table_name SYSNAME NOT NULL, keep_reason NVARCHAR(60) NOT NULL, rows_kept BIGINT NOT NULL);

DECLARE keep_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM #keep ORDER BY table_name;

OPEN keep_cur;
FETCH NEXT FROM keep_cur INTO @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'INSERT INTO #kept_counts(table_name, keep_reason, rows_kept)
                 SELECT @t, (SELECT keep_reason FROM #keep WHERE table_name = @t), COUNT_BIG(*)
                 FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @sql, N'@t SYSNAME', @t = @tbl;
    FETCH NEXT FROM keep_cur INTO @tbl;
END

CLOSE keep_cur;
DEALLOCATE keep_cur;

SELECT keep_reason,
       table_name = N'grac_practice.' + table_name,
       rows_kept,
       flag = CASE WHEN rows_kept = 0 THEN 'EMPTY -- reseed via deployment/03_Insert_Master_Data.sql' ELSE '' END
FROM #kept_counts
ORDER BY keep_reason, table_name;

/* ORG_RETAIN only: the masters-style proof above says nothing about the
   row-filtered tables (they are never fully empty by design), so a
   separate proof covers them -- what actually survived, re-counted after
   commit rather than assumed from the pre-delete plan. */
IF @Scope = N'ORG_RETAIN' AND EXISTS (SELECT 1 FROM #target WHERE delete_mode <> N'UNCONDITIONAL')
BEGIN
    PRINT '';
    PRINT 'Row-filtered tables -- surviving row counts (kept organisation(s) only):';

    CREATE TABLE #org_retain_proof (table_name SYSNAME NOT NULL, delete_mode SYSNAME NOT NULL, rows_kept BIGINT NOT NULL);

    DECLARE proof_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, delete_mode FROM #target WHERE delete_mode <> N'UNCONDITIONAL' ORDER BY table_name;

    OPEN proof_cur;
    FETCH NEXT FROM proof_cur INTO @tbl, @mode;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'INSERT INTO #org_retain_proof (table_name, delete_mode, rows_kept)
                     SELECT @t, @m, COUNT_BIG(*) FROM grac_practice.' + QUOTENAME(@tbl) + N';';
        EXEC sp_executesql @sql, N'@t SYSNAME, @m SYSNAME', @t = @tbl, @m = @mode;
        FETCH NEXT FROM proof_cur INTO @tbl, @mode;
    END

    CLOSE proof_cur;
    DEALLOCATE proof_cur;

    SELECT table_name = N'grac_practice.' + table_name, delete_mode, rows_kept
    FROM #org_retain_proof
    ORDER BY delete_mode, table_name;

    DROP TABLE #org_retain_proof;
END

PRINT '';
PRINT '192 data reset finished at ' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126) + 'Z.';
PRINT 'Next: rerun deployment/03_Insert_Master_Data.sql if any kept table came back EMPTY,';
PRINT 'then recreate the organization through the UI (Organization > Setup).';

/* Belt and braces: nothing this script disabled may still be disabled. */
IF EXISTS (SELECT 1
           FROM sys.triggers tr
           JOIN #trig g ON g.trigger_object_id = tr.object_id
           WHERE tr.is_disabled = 1)
BEGIN
    PRINT '>>> WARNING: these triggers are still disabled. Re-enable them before use:';
    SELECT trigger_name, on_table = N'grac_practice.' + table_name
    FROM #trig g
    JOIN sys.triggers tr ON tr.object_id = g.trigger_object_id
    WHERE tr.is_disabled = 1;
END
ELSE IF EXISTS (SELECT 1 FROM #trig)
    PRINT 'All disabled triggers were re-enabled.';

DROP TABLE #verify;
DROP TABLE #kept_counts;
DROP TABLE #blockers;
DROP TABLE #trig;
DROP TABLE #ignore_fk;
DROP TABLE #ignore_fk_check;
DROP TABLE #target;
DROP TABLE #keep;
DROP TABLE #catalogue_closure;
GO

-- =====================================================================
-- POST-RESET: re-seed the four lifecycle event definitions   (335)
--
-- WHY THIS IS HERE
-- ----------------
-- The header above explains why event_definition is deliberately NOT on
-- the keep list: it is organization-scoped and FKs to workflow /
-- workflow_stage, both of which this script clears, so keeping it would
-- leave orphans and fail the workflow DELETE.
--
-- That reasoning is sound. What was missing is the other half: nothing
-- put the rows back. PEOPLE_ONBOARDING, PEOPLE_OFFBOARDING,
-- ASSET_COMMISSIONING and ASSET_DECOMMISSIONING are not organizational
-- configuration -- they are the codes sp_event_raise_people_lifecycle
-- and sp_event_raise_asset_lifecycle HARD-CODE (migration 126 calls them
-- "a CONTRACT with 124"). Clearing them leaves Raise Event throwing
--
--     sp_event_instance_raise_scoped: event definition not found for
--     organization.                                        (67223)
--
-- for every surviving organization, with nothing on screen explaining
-- why. Under @Scope = 'CATALOGUE' that is exactly the state the module
-- is left in: the organizations survive, their events do not.
--
-- WHAT IT DOES
-- ------------
-- Calls migration 335's sp_event_definition_ensure_baseline for every
-- surviving active organization. That procedure is INSERT-ONLY, so on a
-- 'ALL' reset -- where organization itself is cleared -- there is nothing
-- to iterate and this does nothing at all.
--
-- GUARDED, so this script still runs unchanged against a database that
-- has not had 335 applied. There it prints what to do instead, rather
-- than failing the reset over a re-seed.
--
-- Rows land with entered_by = 'reset-192', so a post-reset seed is
-- distinguishable from 126's and from 335's own gap fill.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_event_definition_ensure_baseline','P') IS NULL
BEGIN
    PRINT '';
    PRINT '>>> NOTE: sp_event_definition_ensure_baseline is not present (migration 335 not applied).';
    PRINT '>>> The four lifecycle event definitions were cleared and have NOT been restored.';
    PRINT '>>> Raise Event will fail with 67223 until you run 335_event_definition_ensure_baseline.sql';
    PRINT '>>> (or re-run 126_event_scope_baseline_seed.sql).';
END
ELSE
BEGIN
    DECLARE @reseed_org BIGINT, @reseed_count INT = 0;

    DECLARE reseed_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT organization_id FROM grac_practice.organization
        WHERE status = N'Active' ORDER BY organization_id;

    OPEN reseed_cur;
    FETCH NEXT FROM reseed_cur INTO @reseed_org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_event_definition_ensure_baseline
             @organization_id = @reseed_org, @actor = N'reset-192';
        SET @reseed_count = @reseed_count + 1;
        FETCH NEXT FROM reseed_cur INTO @reseed_org;
    END
    CLOSE reseed_cur;
    DEALLOCATE reseed_cur;

    PRINT '';
    PRINT '192: lifecycle event definitions re-seeded for '
        + CAST(@reseed_count AS VARCHAR(20)) + ' surviving active organization(s).';
END
GO

-- =====================================================================
-- POST-RESET: top up default menu/feature access                (217)
--
-- WHY THIS IS HERE
-- ----------------
-- Sir's ask for ORG_RETAIN (2026-10-13) includes "organization create
-- cheyyumbo varunna tables lu default data venam" -- the tables that get
-- populated with default data when an organization is created should
-- still carry that default data for the organization(s) this reset keeps.
-- organization_role_menu_permission and feature_flag are both cleared for
-- rows belonging to a purged organization (FILTERED, section 2), and nothing
-- above puts anything back for the organizations that survive.
--
-- WHAT IT DOES
-- ------------
-- Calls migration 217's pm_grant_organization_default_access, which grants
-- the Admin role every active menu it does not already have and enables
-- every active screen.% feature flag it does not already have. Unlike the
-- event-definition reseed above, this proc already accepts
-- @organization_id = NULL to mean "every active organization", so one call
-- covers every surviving organization under any scope -- it is INSERT-ONLY
-- and NOT EXISTS-guarded on natural keys (see 217's own header), so calling
-- it after an 'ALL' reset (no organizations left) or a 'CATALOGUE' reset
-- (menu grants/feature flags untouched, already correct) is always a no-op.
--
-- GUARDED, so this script still runs unchanged against a database that has
-- not had 217 applied.
-- =====================================================================
IF OBJECT_ID('grac_practice.pm_grant_organization_default_access','P') IS NULL
BEGIN
    PRINT '';
    PRINT '>>> NOTE: pm_grant_organization_default_access is not present (migration 217 not applied).';
    PRINT '>>> Default menu/feature access was NOT topped up for any surviving organization.';
END
ELSE
BEGIN
    DECLARE @default_access_menus INT = 0, @default_access_flags INT = 0;

    EXEC grac_practice.pm_grant_organization_default_access
         @organization_id = NULL,
         @entered_by      = N'reset-192',
         @menus_granted   = @default_access_menus OUTPUT,
         @flags_enabled   = @default_access_flags OUTPUT;

    PRINT '';
    PRINT '192: default access topped up -- '
        + CAST(@default_access_menus AS VARCHAR(20)) + ' menu grant(s), '
        + CAST(@default_access_flags AS VARCHAR(20)) + ' feature flag(s) across every active organization.';
END
GO
