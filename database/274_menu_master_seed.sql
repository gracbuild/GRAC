-- =====================================================================
-- 274 menu_master snapshot + full menu permissions for every org role
--
-- WHAT THIS IS
--   The navigation tree, taken from the running database as a 98-row
--   snapshot (docs/Menu.xlsx, exported 2026-09-03) and turned into an
--   idempotent script, plus a full menu-permission grant for every role
--   in every organisation.
--
--   272_master_data_seed.sql deliberately left menu_master out: the tree
--   is the product of ~35 migrations that insert, rename, re-parent AND
--   DELETE rows, so its final state cannot be re-derived by reading those
--   files -- only by replaying them in order, or by reading a live
--   database. This script is that reading. 272's header exclusion note
--   now points here.
--
-- THE SNAPSHOT IS AUTHORITATIVE
--   Unlike 272, this script is a MERGE with UPDATE, not insert-only. A
--   menu row already in the target database is brought in line with the
--   snapshot (name, url, display_order, icon, module_type, status,
--   parent). That is the point: after this runs, menu_master matches the
--   sheet. Rows in the target that are NOT in the sheet are left alone --
--   nothing is deleted.
--
-- IDENTITY AND PARENTS
--   menu_id is IDENTITY, so the ids in the export mean nothing in another
--   database. Every reference is resolved by menu_key instead:
--     Section 1 upserts the 98 rows with parent_menu_id untouched,
--     Section 2 wires the 68 parent links by (child_key -> parent_key),
--     and re-NULLs the 30 roots.
--   That two-pass shape is what makes the order of the rows irrelevant
--   and the self-referencing FK safe.
--
-- STATUS SPELLING, PRESERVED AS FOUND
--   The export carries three spellings: 'Active' (54 rows), 'Inactive'
--   (37) and 'InActive' (7). They are written through verbatim. Only
--   'Active' passes the status filters in the menu and permission code,
--   so 'InActive' and 'Inactive' behave identically -- normalising them
--   would be a change to live data this script has no mandate to make.
--
-- SECTION 3 IS A REAL PERMISSION CHANGE -- READ THIS
--   As asked, every ACTIVE role of every in-scope organisation gets
--   can_view / can_add / can_edit / can_delete / can_approve = 1 on every
--   active menu. Rows that already exist are RAISED to full rights (the
--   220_grac_admin_users.sql pattern), not just topped up.
--
--   That includes the read-only roles. 'Viewer' is seeded by
--   deployment/03 and 273 with can_view only; after this script it can
--   add, edit, delete and approve everywhere. Set @RolesScope = 'ADMIN'
--   in section 3 to grant only the Admin / ORG_ADMIN role and leave the
--   others as they are.
--
-- AMENDED AFTER EXPORT
--   The sheet is the 2026-09-03 export, but some lines no longer match it
--   on purpose. Because this script UPDATEs what it finds, leaving the
--   export values in place would silently undo the migrations below on
--   the next run. Any future placement change must be reflected here the
--   same way, and the row / link / root counts quoted above are the
--   original export's, not a running total.
--
--   332 -- Event Profiles added:
--     'event-profiles' is a NEW row not in the export, display_order 317
--     and parent 'nav-organization' -- beside 'asset-category-assurance',
--     the asset-side counterpart of the same scoping feature. It is
--     carried here as well as in 332 because this snapshot is the
--     authoritative tree; without it the next run of this script would
--     leave the row but no future re-export would keep it.
--
--   275 -- Calendar moved out of Assurance:
--     'assurance-calendar' carries module_type 'Oversight',
--     display_order 290 and parent 'nav-oversight'.
--
--   280 -- UI terminology, Audit Management only:
--     'org-assurance-definitions' reads 'Audit Definitions' and
--     'org-assurance-plans' reads 'Audit Plans'. Display names only --
--     menu_key, url, parent and permissions are untouched, and the
--     legacy 'Assurance Management' rows keep their own labels.
--
--   279 -- one audit list:
--     'org-assurance-definitions', 'org-assurance-scope-builder' and
--     'org-assurance-question-sets' are 'Inactive'. They are hidden, not
--     deleted -- their ids and permission grants survive, and their
--     routes still resolve. Audit Definition is the only list.
--
--   276 -- Assurance became Audit Management:
--     'nav-assurance' reads 'Audit Management' (the KEY is unchanged --
--     renaming it would orphan every permission row pointing at it);
--     two container rows were added, 'org-audit-definition' and
--     'org-audit-configuration'; the eight setup screens hang off those
--     containers at step orders 10..50; and every row in the group
--     carries module_type 'Audit Management'.
--
--   347 -- Organization branch realignment (2026-09-16, per sir):
--     'role-menu-permissions' ("Role Permission") and
--     'ownership-management' ("Ownership Management") are re-parented from
--     'nav-administration' to 'nav-organization', at display_order 120 and
--     220. 'nav-oversight' and 'nav-assurance' swap display_order (200 and
--     300) so Oversight sorts before Audit Management. See 347 for the
--     full reasoning -- everything else in the Organization and Governance
--     branches was already correct and needed no change.
--
--   358 -- Document Uploads renamed + moved under Governance (per sir):
--     'document-uploads' reads 'Document Library' (menu_key unchanged),
--     re-parented from 'nav-documents' to 'nav-governance', module_type
--     'Governance', display_order 130 (after Operationalize's 120).
--     'document-acknowledgements' and 'my-acknowledgements' are untouched
--     -- Sir named this one screen specifically; they stay under
--     'nav-documents'. See 358 for the full reasoning, including the
--     matching PracticeScreen.cs Title/Group change that keeps the page's
--     own heading and eyebrow in step with this sidebar move.
--
--   359 -- Document Management nested under Governance (per sir,
--     clarifying 358): 'nav-documents' ("Document Management") is no
--     longer a root -- it is re-parented under 'nav-governance',
--     module_type 'Governance', display_order 130 (the slot 358 had
--     given 'document-uploads' directly, now freed and reused by its own
--     parent folder). 'nav-documents' is REMOVED from the 30-row roots
--     list below (it was a root there; it no longer is), and a new
--     ('nav-documents', 'nav-governance') row is added to the parent-link
--     list instead. 'document-uploads' moves back to being a child of
--     'nav-documents' (module_type 'Documents', display_order 10, its
--     pre-358 slot) instead of a direct Governance child -- the rename to
--     'Document Library' from 358 is kept. document-acknowledgements and
--     my-acknowledgements are untouched -- they were already parented to
--     'nav-documents' by 155 and travel with it automatically. See 359
--     for the full reasoning.
--
--   373 -- Risk Centre promoted to a top-level menu (per sir):
--     'risk-centre' reads 'Risk Management' (menu_key unchanged),
--     re-parented from 'nav-oversight' to a root (removed from the
--     parent-link list, added to the root list), module_type
--     'Risk Management' (matching every other root's self-named
--     module_type), display_order unchanged (280 -- sorts between
--     'Oversight' at 200 and 'Operations'/'Audit Management' at 300
--     among the roots, same relative slot it held among Oversight's
--     children). No other Risk-named row, and no other child of
--     'nav-oversight', is touched. See 373 for the full reasoning,
--     including why PracticeScreen.cs's page heading was deliberately
--     left alone this time (sir scoped this one to the menu only).
--
-- Re-runnable: yes. A second run makes no changes.
-- Rollback: database/274_menu_master_seed_rollback.sql
-- DEPENDS ON: 022 (menu_master, organization_role_menu_permission),
--             027 (organization_role.role_code), 272 (record_status_master).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (274): schema grac_practice is missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN
    PRINT 'ABORT (274): grac_practice.menu_master is missing. Run 022_practice_login_menu_permissions.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_role','U') IS NULL
BEGIN
    PRINT 'ABORT (274): organization_role / organization_role_menu_permission missing. Run 022 first.';
    SET @prereqs_ok = 0;
END

IF NOT EXISTS(SELECT 1 FROM grac_practice.record_status_master WHERE status_code = N'Active')
BEGIN
    PRINT 'ABORT (274): record_status_master has no Active row. Run 272_master_data_seed.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('274_menu_master_seed: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

PRINT '274: applying the menu_master snapshot.';
GO

-- =====================================================================
-- 1. The 98 menu rows, keyed on menu_key. parent_menu_id is deliberately
--    NOT set here -- section 2 does that once every row exists.
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'Governance'                    , N'Governance'                        , NULL                                          ,    1, N'timeline'              , N'Practice Management'        , N'InActive'),
    (N'business-functions'            , N'Business Function Management'      , N'Practice/Index/business-functions'          ,   80, N'briefcase'             , N'Organization Administration', N'Inactive'),
    (N'committees'                    , N'Committee Management'              , N'Practice/Index/committees'                  ,  100, N'users-gear'            , N'Organization Administration', N'Inactive'),
    (N'departments'                   , N'Department Management'             , N'Practice/Index/departments'                 ,   70, N'building-user'         , N'Organization Administration', N'Inactive'),
    (N'dependency-applications'       , N'Applications'                      , N'Practice/Index/dependency-applications'     ,  150, N'window-restore'        , N'Organization Dependencies'  , N'Inactive'),
    (N'dependency-assets'             , N'Assets'                            , N'Practice/Index/dependency-assets'           ,  180, N'server'                , N'Organization Dependencies'  , N'Inactive'),
    (N'dependency-processes'          , N'Processes'                         , N'Practice/Index/dependency-processes'        ,  190, N'arrows-spin'           , N'Organization Dependencies'  , N'Inactive'),
    (N'dependency-tools'              , N'Tools'                             , N'Practice/Index/dependency-tools'            ,  160, N'screwdriver-wrench'    , N'Organization Dependencies'  , N'Inactive'),
    (N'dependency-vendors'            , N'Vendors'                           , N'Practice/Index/dependency-vendors'          ,  170, N'handshake'             , N'Organization Dependencies'  , N'Inactive'),
    (N'locations'                     , N'Location Management'               , N'Practice/Index/locations'                   ,   60, N'location-dot'          , N'Organization Administration', N'Inactive'),
    (N'Organization'                  , N'Organization'                      , NULL                                          ,  500, N'building-user'         , N'Organization Administration', N'InActive'),
    (N'Subscribed Releases'           , N'Subscribed Releases'               , N'/Practice/Index/organization-controls'      ,    1, N'shield'                , N'Practice Management'        , N'Active'),
    (N'organization-dependencies'     , N'Dependencies'                      , N'Practice/Index/organization-dependencies'   ,  197, N'diagram-project'       , N'Organization'               , N'Active'),
    (N'organization-metadata'         , N'Organization Metadata'             , N'Practice/Index/organization-metadata'       ,   40, N'sliders'               , N'Organization Setup'         , N'Inactive'),
    (N'Practices'                     , N'Practices'                         , NULL                                          ,    2, N'list-check'            , N'Practice Management'        , N'Active'),
    (N'organizations'                 , N'Organization Onboarding'           , N'Practice/Index/organizations'               ,   30, N'building'              , N'Organization Setup'         , N'Inactive'),
    (N'organization-setup'            , N'Organization Setup'                , N'Practice/Index/organization-setup'          ,   10, N'building'              , N'Organization Setup'         , N'Active'),
    -- Inactive since 288. Every job this screen held moved to
    -- Operationalize: create -> Configure (139), profile + retire -> 222,
    -- restore + retired visibility + practice/requirement drill-down ->
    -- 287. Kept as a row rather than deleted so menu_id and every
    -- permission grant survive; the route still resolves for deep links.
    -- This line is the authority -- flipping it back to Active here
    -- un-retires the screen on the next run of this snapshot.
    (N'practice-instances'            , N'Practice Instances'                , N'Practice/Index/practice-instances'          ,  115, N'network-wired'         , N'Practice Management'        , N'Inactive'),
    (N'Operationalize'                , N'Operationalize'                    , N'/Practice/Index/resolve'                    ,  230, N'gears'                 , N'Practice Management'        , N'Active'),
    (N'organization-controls'         , N'Repository Subscriptions'          , N'Practice/Index/organization-controls'       ,  100, N'bookmark'              , N'Governance'                 , N'Active'),
    (N'role-menu-permissions'         , N'Role Menu Permission'              , N'Practice/Index/role-menu-permissions'       ,  120, N'list-check'            , N'Organization Administration', N'Active'),
    (N'Configure'                     , N'Configure'                         , N'/Practice/Index/organization-requirements'  ,  110, N'user-lock'             , N'Organization Administration', N'InActive'),
    (N'teams'                         , N'Team Management'                   , N'Practice/Index/teams'                       ,   90, N'people-group'          , N'Organization Administration', N'Inactive'),
    (N'users'                         , N'User Management'                   , N'Practice/Index/users'                       ,  130, N'users'                 , N'Organization Administration', N'Active'),
    (N'ownership-management'          , N'Ownership Management'              , N'Practice/Index/ownership-management'        ,  220, N'user-gear'             , N'Organization Administration', N'Active'),
    (N'workbench-applications'        , N'Applications'                      , N'Practice/Index/workbench-applications'      ,  240, N'window-restore'        , N'Registers'                  , N'Inactive'),
    (N'workbench-assets'              , N'Assets'                            , N'Practice/Index/workbench-assets'            ,  270, N'server'                , N'Registers'                  , N'Inactive'),
    (N'workbench-committees'          , N'Committees'                        , N'Practice/Index/workbench-committees'        ,  290, N'users-gear'            , N'Registers'                  , N'Inactive'),
    (N'workbench-locations'           , N'Locations'                         , N'Practice/Index/workbench-locations'         ,  310, N'location-dot'          , N'Registers'                  , N'Inactive'),
    (N'workbench-processes'           , N'Processes'                         , N'Practice/Index/workbench-processes'         ,  300, N'arrows-spin'           , N'Registers'                  , N'Inactive'),
    (N'workbench-teams'               , N'Teams'                             , N'Practice/Index/workbench-teams'             ,  280, N'people-group'          , N'Registers'                  , N'Inactive'),
    (N'workbench-tools'               , N'Tools'                             , N'Practice/Index/workbench-tools'             ,  250, N'screwdriver-wrench'    , N'Registers'                  , N'Inactive'),
    (N'workbench-vendors'             , N'Vendors'                           , N'Practice/Index/workbench-vendors'           ,  260, N'handshake'             , N'Registers'                  , N'Inactive'),
    (N'dashboard'                     , N'Dashboard'                         , N'Practice/Index'                             ,    0, N'chart-line'            , N'Dashboard'                  , N'Active'),
    (N'organization-administration'   , N'Administration'                    , N'Practice/Index/organization-administration' ,  195, N'building-user'         , N'Organization'               , N'Active'),
    (N'source-statements'             , N'Source Statements'                 , N'Practice/Index/source-statements'           ,  105, N'file-lines'            , N'Governance'                 , N'Active'),
    (N'organization-requirements'     , N'Organization Practices'            , N'Practice/Index/organization-requirements'   ,  110, N'list-check'            , N'Practice Management'        , N'Active'),
    (N'menu-master'                   , N'Menu Master'                       , N'Practice/Index/menu-master'                 ,    6, N'bars'                  , N'System'                     , N'Active'),
    (N'audit-trace'                   , N'Audit Traceability'                , N'Practice/Index/audit-trace'                 ,  900, N'timeline'              , N'Governance'                 , N'Active'),
    (N'practice-operationalization'   , N'Practice Operationalization'       , N'/Practice/Index/practice-operationalization',  230, N'gears'                 , N'Practice Management'        , N'Inactive'),
    (N'roles'                         , N'Role Master'                       , N'Practice/Index/roles'                       ,  110, N'user-lock'             , N'Organization Administration', N'Active'),
    (N'resolve'                       , N'Operationalize'                    , N'Practice/Index/resolve'                     ,  120, N'gears'                 , N'Governance'                 , N'Active'),
    (N'assurance-activities'          , N'Assurance Activity List'           , N'Practice/Index/assurance-activities'        ,  620, N'clipboard-list'        , N'Assurance Management'       , N'Inactive'),
    (N'Assurance Management'          , N'Assurance Management'              , NULL                                          ,    2, N'chart-line'            , N'Assurance Management'       , N'InActive'),
    (N'assurance-execution'           , N'Assurance Execution'               , N'Practice/Index/assurance-execution'         ,  630, N'person-circle-check'   , N'Assurance Management'       , N'Inactive'),
    (N'assurance-findings'            , N'Findings'                          , N'Practice/Index/assurance-findings'          ,  670, N'triangle-exclamation'  , N'Assurance Management'       , N'Inactive'),
    (N'assurance-generation'          , N'Assurance Activity Generation'     , N'Practice/Index/assurance-generation'        ,  610, N'calendar-plus'         , N'Assurance Management'       , N'Inactive'),
    (N'assurance-results'             , N'Assurance Result'                  , N'Practice/Index/assurance-results'           ,  660, N'square-poll-vertical'  , N'Assurance Management'       , N'Inactive'),
    (N'assurance-signals'             , N'Assurance Signals'                 , N'Practice/Index/assurance-signals'           ,  680, N'wave-square'           , N'Assurance Management'       , N'Inactive'),
    (N'assurance-trends'              , N'Trend Engine'                      , N'Practice/Index/assurance-trends'            ,  690, N'chart-column'          , N'Assurance Management'       , N'Inactive'),
    (N'audit-intelligence'            , N'Audit Intelligence View'           , N'Practice/Index/audit-intelligence'          ,  710, N'magnifying-glass-chart', N'Assurance Management'       , N'Inactive'),
    (N'dependency-assurance'          , N'Dependency Assurance'              , N'Practice/Index/dependency-assurance'        ,  650, N'network-wired'         , N'Assurance Management'       , N'Inactive'),
    (N'evidence-assurance'            , N'Evidence Assurance'                , N'Practice/Index/evidence-assurance'          ,  640, N'file-circle-check'     , N'Assurance Management'       , N'Inactive'),
    (N'practice-health'               , N'Practice Health Engine'            , N'Practice/Index/practice-health'             ,  700, N'heart-pulse'           , N'Assurance Management'       , N'Inactive'),
    (N'risk-intelligence'             , N'Risk Intelligence View'            , N'Practice/Index/risk-intelligence'           ,  720, N'shield-halved'         , N'Assurance Management'       , N'Inactive'),
    (N'user-role-assignments'         , N'User Role Assignment'              , N'/Practice/Index/user-role-assignments'      ,  515, N'user-gear'             , N'Administration'             , N'Active'),
    -- Calendar moved from Assurance to Oversight by 275. The snapshot is
    -- authoritative and applied with UPDATE, so it has to carry the new
    -- placement or a re-run would drag Calendar back under Assurance.
    (N'assurance-calendar'            , N'Calendar'                          , N'Practice/Index/assurance-calendar'          ,  290, N'calendar-days'         , N'Oversight'                  , N'Active'),
    (N'Assurance - Dashboard'         , N'Assurance Dashboard'               , N'Practice/Index/assurance-dashboard'         ,  690, N'chart-column'          , N'Assurance Management'       , N'InActive'),
    (N'assurance-dashboard'           , N'Assurance Dashboard'               , N'Practice/Index/assurance-dashboard'         ,  600, N'chart-line'            , N'Assurance Management'       , N'Inactive'),
    (N'tasks'                         , N'Task Center'                       , N'Practice/Index/tasks'                       ,  228, N'list-check'            , N'Oversight'                  , N'Active'),
    (N'gaps'                          , N'Gap Center'                        , N'Practice/Index/gaps'                        ,  224, N'triangle-exclamation'  , N'Oversight'                  , N'Active'),
    (N'nav-administration'            , N'Administration'                    , NULL                                          ,  500, N'user-shield'           , N'Administration'             , N'InActive'),
    (N'nav-governance'                , N'Governance'                        , NULL                                          ,  100, N'landmark'              , N'Governance'                 , N'Active'),
    (N'nav-operations'                , N'Operations'                        , NULL                                          ,  300, N'gears'                 , N'Operations'                 , N'Inactive'),
    (N'nav-organization'              , N'Organization'                      , NULL                                          ,  500, N'building'              , N'Organization'               , N'Active'),
    (N'nav-oversight'                 , N'Oversight'                         , NULL                                          ,  200, N'binoculars'            , N'Oversight'                  , N'Active'),
    (N'nav-registers'                 , N'Registers'                         , NULL                                          ,  600, N'network-wired'         , N'Registers'                  , N'Inactive'),
    (N'repository-subscriptions'      , N'Repository Subscriptions (Admin)'  , N'Practice/Index/repository-subscriptions'    ,   50, N'bookmark'              , N'Organization Setup'         , N'Inactive'),
    (N'nav-assurance'                 , N'Audit Management'                         , NULL                                          ,  300, N'clipboard-check'         , N'Audit Management'                  , N'Active'),
    (N'event-assurance'               , N'Event Assurance'                   , N'Practice/Index/event-assurance'             ,  457, N'shield-halved'         , N'Workflow'                   , N'Active'),
    (N'nav-workflow'                  , N'Workflow'                          , NULL                                          ,  450, N'diagram-project'       , N'Workflow'                   , N'InActive'),
    (N'workflow-checklists'           , N'Checklists'                        , N'Practice/Index/workflow-checklists'         ,  455, N'list-check'            , N'Workflow'                   , N'Active'),
    (N'workflow-dashboard'            , N'Workflow Dashboard'                , N'Practice/Index/workflow-dashboard'          ,  458, N'chart-line'            , N'Workflow'                   , N'Active'),
    (N'workflow-entity-types'         , N'Entity Types'                      , N'Practice/Index/workflow-entity-types'       ,  453, N'shapes'                , N'Workflow'                   , N'Active'),
    (N'workflow-event-mappings'       , N'Event-Checklist Mappings'          , N'Practice/Index/workflow-event-mappings'     ,  456, N'link'                  , N'Workflow'                   , N'Active'),
    (N'workflow-events'               , N'Events'                            , N'Practice/Index/workflow-events'             ,  454, N'bolt'                  , N'Workflow'                   , N'Active'),
    (N'workflows'                     , N'Workflow Definitions'              , N'Practice/Index/workflows'                   ,  451, N'sitemap'               , N'Workflow'                   , N'Active'),
    (N'workflow-stages'               , N'Workflow Stages'                   , N'Practice/Index/workflow-stages'             ,  452, N'route'                 , N'Workflow'                   , N'Active'),
    -- Audit Management containers, added by 276. Both are pages AND
    -- parents; the sidebar honours a parent's menu_url since 276.
    (N'org-audit-definition'          , N'Audit Definition'                  , N'Practice/org-audit-definition'              ,  440, N'file-shield'           , N'Audit Management'                  , N'Active'),
    (N'org-audit-configuration'       , N'Audit Configuration'               , N'Practice/org-audit-configuration'           ,  450, N'sliders'               , N'Audit Management'                  , N'Active'),
    (N'org-assurance-definitions'     , N'Audit Definitions'             , N'Practice/org-assurance-definitions'         ,   10, N'file-shield'           , N'Audit Management'                  , N'Inactive'),
    (N'org-assurance-scope-builder'   , N'Scope Builder'                     , N'Practice/org-assurance-scope-builder'       ,   20, N'diagram-project'       , N'Audit Management'                  , N'Inactive'),
    (N'org-assurance-question-sets'   , N'Question Sets'                     , N'Practice/org-assurance-question-sets'       ,   30, N'clipboard-list'        , N'Audit Management'                  , N'Inactive'),
    (N'org-assurance-evidence-config' , N'Evidence Config'                   , N'Practice/org-assurance-evidence-config'     ,   10, N'file-circle-check'     , N'Audit Management'                  , N'Active'),
    (N'org-assurance-workflow-config' , N'Workflow Config'                   , N'Practice/org-assurance-workflow-config'     ,   20, N'sitemap'               , N'Audit Management'                  , N'Active'),
    (N'org-assurance-scoring-config'  , N'Scoring Config'                    , N'Practice/org-assurance-scoring-config'      ,   30, N'gauge'                 , N'Audit Management'                  , N'Active'),
    (N'org-assurance-plans'           , N'Audit Plans'                   , N'Practice/org-assurance-plans'               ,  466, N'calendar-days'         , N'Audit Management'                  , N'Active'),
    (N'org-assurance-triggers'        , N'Triggers'                          , N'Practice/org-assurance-triggers'            ,   40, N'bolt'                  , N'Audit Management'                  , N'Active'),
    (N'org-assurance-scope-resolution', N'Scope Resolution'                  , N'Practice/org-assurance-scope-resolution'    ,   50, N'circle-nodes'          , N'Audit Management'                  , N'Active'),
    (N'org-assurance-executions'      , N'Executions'                        , N'Practice/org-assurance-executions'          ,  469, N'play-circle'           , N'Audit Management'                  , N'Active'),
    (N'org-assurance-observations'    , N'Observations'                      , N'Practice/org-assurance-observations'        ,  470, N'triangle-exclamation'  , N'Audit Management'                  , N'Active'),
    (N'asset-category-assurance'      , N'Asset Category Assurance'          , N'Practice/Index/asset-category-assurance'    ,  316, N'boxes-stacked'         , N'Operations'                 , N'Active'),
    -- Added by migration 332, after the export. The snapshot UPDATEs what
    -- it finds, so leaving this out would delete the Event Profiles menu
    -- row on the next run of this script.
    (N'event-profiles'                , N'Event Profiles'                    , N'Practice/Index/event-profiles'              ,  317, N'users-gear'            , N'Organization'               , N'Active'),
    (N'document-uploads'              , N'Document Library'                  , N'Practice/Index/document-uploads'            ,   10, N'file-lines'            , N'Documents'                  , N'Active'),   -- renamed by 358, re-nested by 359
    (N'document-acknowledgements'     , N'Document Acknowledgements'         , N'Practice/Index/document-acknowledgements'   ,   20, N'file-signature'        , N'Documents'                  , N'Active'),
    (N'my-acknowledgements'           , N'My Acknowledgements'               , N'Practice/Index/my-acknowledgements'         ,   30, N'inbox'                 , N'Documents'                  , N'Active'),
    (N'nav-documents'                 , N'Document Management'               , NULL                                          ,  130, N'folder-open'           , N'Governance'                 , N'Active'),   -- moved by 359
    (N'exception-centre'              , N'Exception Centre'                  , N'Practice/Index/exception-centre'            ,  270, N'shield-halved'         , N'Oversight'                  , N'Active'),
    (N'risk-centre'                   , N'Risk Management'                   , N'Practice/Index/risk-centre'                 ,  280, N'triangle-exclamation'  , N'Risk Management'            , N'Active'),   -- renamed + promoted to root by 373
    -- Inactive since 289 -- HIDDEN, NOT SUPERSEDED. Nothing replaces this
    -- screen: it is the only way to adopt Control Management SLA masters
    -- and tune warning / escalation thresholds and notify roles, and its
    -- data is still read by gap SLA matching (184) and Task Centre due
    -- dates (195). Flip this back to Active the moment a threshold has to
    -- change or a new SLA master needs adopting. The route still resolves
    -- for a direct link while it is hidden.
    (N'org-sla-config'                , N'SLA Configuration'                 , N'Practice/org-sla-config'                    ,  550, N'clock'                 , N'Governance'                 , N'Inactive'),
    (N'my-notifications'              , N'My Notifications'                  , N'Practice/Index/my-notifications'            ,  270, N'bell'                  , N'Oversight'                  , N'Active'),
    (N'risk-acceptance-authority'     , N'Risk Acceptance Approval Authority', N'Practice/Index/risk-acceptance-authority'   ,  260, N'user-shield'           , N'Organization'               , N'Active')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type, status)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (
       ISNULL(t.menu_name,   N'') <> ISNULL(s.menu_name,   N'')
    OR ISNULL(t.menu_url,    N'') <> ISNULL(s.menu_url,    N'')
    OR ISNULL(t.display_order, -1) <> ISNULL(s.display_order, -1)
    OR ISNULL(t.icon_class,  N'') <> ISNULL(s.icon_class,  N'')
    OR ISNULL(t.module_type, N'') <> ISNULL(s.module_type, N'')
    OR ISNULL(t.status,      N'') <> ISNULL(s.status,      N'')
) THEN UPDATE SET
    menu_name     = s.menu_name,
    menu_url      = s.menu_url,
    display_order = s.display_order,
    icon_class    = s.icon_class,
    module_type   = s.module_type,
    status        = s.status,
    updated_by    = N'seed-274',
    updated_dt    = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, s.status, N'seed-274');

PRINT '274: menu rows inserted or updated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. Parent wiring, by key. 68 child -> parent links.
-- =====================================================================
UPDATE m
SET    parent_menu_id = p.menu_id,
       updated_by     = N'seed-274',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    (N'business-functions'            , N'nav-organization'),
    (N'committees'                    , N'nav-organization'),
    (N'departments'                   , N'nav-organization'),
    (N'dependency-applications'       , N'nav-operations'),
    (N'dependency-assets'             , N'nav-operations'),
    (N'dependency-processes'          , N'nav-operations'),
    (N'dependency-tools'              , N'nav-operations'),
    (N'dependency-vendors'            , N'nav-operations'),
    (N'locations'                     , N'nav-organization'),
    (N'Subscribed Releases'           , N'Governance'),
    (N'organization-dependencies'     , N'nav-organization'),
    (N'organization-metadata'         , N'nav-organization'),
    (N'Practices'                     , N'Governance'),
    (N'organizations'                 , N'nav-organization'),
    (N'organization-setup'            , N'Organization'),
    (N'practice-instances'            , N'nav-governance'),
    (N'Operationalize'                , N'Practices'),
    (N'organization-controls'         , N'nav-governance'),
    (N'role-menu-permissions'         , N'nav-organization'),   -- moved by 347
    (N'Configure'                     , N'Practices'),
    (N'teams'                         , N'nav-organization'),
    (N'users'                         , N'nav-administration'),
    (N'ownership-management'          , N'nav-organization'),   -- moved by 347
    (N'workbench-applications'        , N'nav-registers'),
    (N'workbench-assets'              , N'nav-registers'),
    (N'workbench-committees'          , N'nav-registers'),
    (N'workbench-locations'           , N'nav-registers'),
    (N'workbench-processes'           , N'nav-registers'),
    (N'workbench-teams'               , N'nav-registers'),
    (N'workbench-tools'               , N'nav-registers'),
    (N'workbench-vendors'             , N'nav-registers'),
    (N'organization-administration'   , N'nav-organization'),
    (N'source-statements'             , N'nav-governance'),
    (N'organization-requirements'     , N'nav-governance'),
    (N'menu-master'                   , N'nav-administration'),
    (N'roles'                         , N'nav-organization'),
    (N'resolve'                       , N'nav-governance'),
    (N'user-role-assignments'         , N'nav-administration'),
    (N'assurance-calendar'            , N'nav-oversight'),   -- moved by 275
    (N'tasks'                         , N'nav-oversight'),
    (N'gaps'                          , N'nav-oversight'),
    (N'event-assurance'               , N'nav-workflow'),
    (N'workflow-checklists'           , N'nav-workflow'),
    (N'workflow-dashboard'            , N'nav-workflow'),
    (N'workflow-entity-types'         , N'nav-workflow'),
    (N'workflow-event-mappings'       , N'nav-workflow'),
    (N'workflow-events'               , N'nav-workflow'),
    (N'workflows'                     , N'nav-workflow'),
    (N'workflow-stages'               , N'nav-workflow'),
    (N'org-audit-definition'          , N'nav-assurance'),          -- added by 276
    (N'org-audit-configuration'       , N'nav-assurance'),          -- added by 276
    (N'org-assurance-definitions'     , N'org-audit-definition'),   -- moved by 276
    (N'org-assurance-scope-builder'   , N'org-audit-definition'),   -- moved by 276
    (N'org-assurance-question-sets'   , N'org-audit-definition'),   -- moved by 276
    (N'org-assurance-evidence-config' , N'org-audit-configuration'),   -- moved by 276
    (N'org-assurance-workflow-config' , N'org-audit-configuration'),   -- moved by 276
    (N'org-assurance-scoring-config'  , N'org-audit-configuration'),   -- moved by 276
    (N'org-assurance-plans'           , N'nav-assurance'),
    (N'org-assurance-triggers'        , N'org-audit-configuration'),   -- moved by 276
    (N'org-assurance-scope-resolution', N'org-audit-configuration'),   -- moved by 276
    (N'org-assurance-executions'      , N'nav-assurance'),
    (N'org-assurance-observations'    , N'nav-assurance'),
    (N'asset-category-assurance'      , N'nav-organization'),
    (N'event-profiles'                , N'nav-organization'),   -- added by 332
    (N'document-uploads'              , N'nav-documents'),   -- renamed by 358, re-nested by 359
    (N'document-acknowledgements'     , N'nav-documents'),
    (N'my-acknowledgements'           , N'nav-documents'),
    (N'nav-documents'                 , N'nav-governance'),   -- added by 359
    (N'exception-centre'              , N'nav-oversight'),
    (N'org-sla-config'                , N'nav-governance'),
    (N'my-notifications'              , N'nav-oversight'),
    (N'risk-acceptance-authority'     , N'nav-organization')
) AS x(child_key, parent_key) ON x.child_key = m.menu_key
JOIN   grac_practice.menu_master p ON p.menu_key = x.parent_key
WHERE  ISNULL(m.parent_menu_id, -1) <> p.menu_id;

PRINT '274: parent links set = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- The 30 rows the snapshot carries as roots. Re-NULLed so a database that
-- parented one of them differently ends up matching the sheet.
UPDATE m
SET    parent_menu_id = NULL,
       updated_by     = N'seed-274',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN  (VALUES
    (N'Governance'),
    (N'Organization'),
    (N'dashboard'),
    (N'audit-trace'),
    (N'practice-operationalization'),
    (N'assurance-activities'),
    (N'Assurance Management'),
    (N'assurance-execution'),
    (N'assurance-findings'),
    (N'assurance-generation'),
    (N'assurance-results'),
    (N'assurance-signals'),
    (N'assurance-trends'),
    (N'audit-intelligence'),
    (N'dependency-assurance'),
    (N'evidence-assurance'),
    (N'practice-health'),
    (N'risk-intelligence'),
    (N'Assurance - Dashboard'),
    (N'assurance-dashboard'),
    (N'nav-administration'),
    (N'nav-governance'),
    (N'nav-operations'),
    (N'nav-organization'),
    (N'nav-oversight'),
    (N'nav-registers'),
    (N'repository-subscriptions'),
    (N'nav-assurance'),
    (N'nav-workflow'),
    (N'risk-centre')   -- added by 373 -- promoted from a child of
                        -- 'nav-oversight' to a root (see the removed
                        -- parent-link pair above); menu_key unchanged,
                        -- now displayed as 'Risk Management'.
    -- 'nav-documents' removed by 359 -- it is no longer a root, it is
    -- now a child of 'nav-governance' (see the parent-link list above).
) AS r(menu_key) ON r.menu_key = m.menu_key
WHERE  m.parent_menu_id IS NOT NULL;

PRINT '274: root menus cleared of a parent = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 3. Full menu permissions for every organisation role.
--
--    @OrganizationId       NULL = every active organisation
--    @RolesScope           'ALL'   = every active role (what was asked)
--                          'ADMIN' = only role_name 'Admin' / role_code
--                                    'ORG_ADMIN', leaving Viewer and the
--                                    other read-only roles untouched
--    @IncludeInactiveMenus 0 = active menus only (matches 217)
-- =====================================================================
DECLARE @OrganizationId       BIGINT        = NULL;
DECLARE @RolesScope           NVARCHAR(20)  = N'ALL';
DECLARE @IncludeInactiveMenus BIT           = 0;

IF @RolesScope NOT IN (N'ALL', N'ADMIN')
    THROW 54274, '274: @RolesScope must be ALL or ADMIN.', 1;

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
    WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

-- 3a. Rows that do not exist yet.
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-274', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
CROSS JOIN grac_practice.menu_master m
WHERE (@OrganizationId IS NULL OR r.organization_id = @OrganizationId)
  AND o.status = N'Active'
  AND r.status = N'Active'
  AND (@RolesScope = N'ALL' OR r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
  AND (@IncludeInactiveMenus = 1 OR m.status = N'Active')
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);

PRINT '274: permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- 3b. Rows that exist but are not at full rights (220's pattern).
UPDATE p
SET    can_view    = 1,
       can_add     = 1,
       can_edit    = 1,
       can_delete  = 1,
       can_approve = 1,
       status      = N'Active',
       record_status_id = @active_rs,
       updated_by  = N'seed-274',
       updated_dt  = SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.organization_role r ON r.role_id = p.role_id
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_id = p.menu_id
WHERE (@OrganizationId IS NULL OR r.organization_id = @OrganizationId)
  AND o.status = N'Active'
  AND r.status = N'Active'
  AND (@RolesScope = N'ALL' OR r.role_name = N'Admin' OR r.role_code = N'ORG_ADMIN')
  AND (@IncludeInactiveMenus = 1 OR m.status = N'Active')
  AND (p.can_view = 0 OR p.can_add = 0 OR p.can_edit = 0
       OR p.can_delete = 0 OR p.can_approve = 0 OR p.status <> N'Active');

PRINT '274: permission rows raised to full rights = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- VERIFICATION
-- =====================================================================
PRINT '=== 274 verification ===';

SELECT 'menu_master rows from the snapshot' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 98 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.menu_master
WHERE entered_by = N'seed-274' OR updated_by = N'seed-274';

SELECT 'Menus with a parent that does not resolve' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS Result_
FROM grac_practice.menu_master m
WHERE m.parent_menu_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master p WHERE p.menu_id = m.parent_menu_id);

SELECT 'Menu tree by module' AS Check_,
       module_type AS Module_,
       SUM(CASE WHEN status = N'Active' THEN 1 ELSE 0 END) AS Active_,
       COUNT(*) AS Total_
FROM grac_practice.menu_master
GROUP BY module_type
ORDER BY module_type;

SELECT 'Active roles NOT at full rights on every active menu' AS Check_,
       COUNT(*) AS Count_,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REVIEW' END AS Result_
FROM grac_practice.organization_role r
JOIN grac_practice.organization o ON o.organization_id = r.organization_id
WHERE o.status = N'Active'
  AND r.status = N'Active'
  AND EXISTS (
        SELECT 1
        FROM grac_practice.menu_master m
        WHERE m.status = N'Active'
          AND NOT EXISTS (
                SELECT 1
                FROM grac_practice.organization_role_menu_permission p
                WHERE p.role_id = r.role_id
                  AND p.menu_id = m.menu_id
                  AND p.can_view = 1 AND p.can_add = 1 AND p.can_edit = 1
                  AND p.can_delete = 1 AND p.can_approve = 1
                  AND p.status = N'Active'));

SELECT 'Granted menus per organisation role' AS Check_,
       o.organization_code, r.role_name,
       COUNT(p.role_menu_permission_id) AS GrantedMenus
FROM grac_practice.organization o
JOIN grac_practice.organization_role r ON r.organization_id = o.organization_id AND r.status = N'Active'
LEFT JOIN grac_practice.organization_role_menu_permission p ON p.role_id = r.role_id AND p.status = N'Active'
WHERE o.status = N'Active'
GROUP BY o.organization_code, r.role_name
ORDER BY o.organization_code, r.role_name;

PRINT '274 menu snapshot and permission grant complete.';
GO

SET NOEXEC OFF;
GO
