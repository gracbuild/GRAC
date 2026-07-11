# GRAC Part 2 - Practice Intelligence Layer Design

## Purpose

GRAC Part 2 converts Part 1 repository intelligence into organization-specific operational practice intelligence.

Part 1 answers: what compliance expectations exist?

Part 2 answers: how each organization implements those expectations, who owns them, what dependencies they rely on, what evidence is expected, and what operational conditions can cause failure.

The central object is `Practice Instance`. Future audit, risk, vendor, task, resilience, and continuous assurance capabilities should derive from Practice Instance metadata.

## Module Boundary

Part 2 should be developed as a separate module:

```text
PracticeManagement
  database
  docs
  src
    PracticeManagement.Api
    PracticeManagement.Web
```

The module should reference Part 1 repository records instead of copying them. Repository controls, requirements, obligations, artifacts, releases, and source structure nodes remain the system of record in `GRAC_New`.

Part 2 should use a separate schema, recommended:

```sql
GRAC_Practice
```

Repository references should store Part 1 primary keys plus origin/context metadata. Do not denormalize repository names except for optional audit snapshots.

## Core Flow

```text
Organization
  -> Organization Metadata
    -> Applicability Discovery
      -> Artifact / Release Subscription
        -> Repository Import View
          -> Organization Control Applicability
            -> Organization Requirement Applicability
              -> Practice
                -> Practice Instance
                  -> Dependencies
                  -> Evidence Configuration
                  -> Assurance Attributes
                  -> Vendor Attributes
                  -> Risk Attributes
                  -> Audit Attributes
                  -> Task Attributes
                  -> Resilience Attributes
                  -> Future Integration Triggers
```

## Origin Model

Every organization-facing object must have `origin_type`:

```text
Repository
Organization
Hybrid
```

Use this consistently for controls, requirements, practices, and evidence configurations.

Recommended rule:

- `Repository`: directly references Part 1 object with no organization change.
- `Organization`: created by the organization without repository origin.
- `Hybrid`: based on repository object but enriched or overridden by organization-specific configuration.

## Database Design

All major tables require:

```sql
status,
entered_by,
entered_dt,
updated_by,
updated_dt
```

No physical delete. Use `Inactive`, `Retired`, `Disabled`, or module-specific status values.

### Organization Foundation

`organization`

- `organization_id` identity primary key
- `organization_code` unique business code
- `organization_name`
- `industry_option_id`
- `entity_type_option_id`
- `country_option_id`
- `status`
- audit columns

`organization_metadata_definition`

- configurable metadata catalogue
- examples: Deposit Taking Status, Asset Size, Cloud Adoption, Stores Cardholder Data, Geographic Presence
- fields: `metadata_key`, `metadata_name`, `data_type`, `lookup_group`, `is_required`, `status`, audit columns

`organization_metadata_value`

- `organization_id`
- `metadata_definition_id`
- typed value columns: `value_text`, `value_number`, `value_date`, `value_bool`, `value_json`
- `status`
- audit columns

`organization_business_function`

- `organization_id`
- `function_code`
- `function_name`
- `owner_user_id` or owner text until user master integration
- `criticality`
- `status`
- audit columns

### Applicability Discovery

`applicability_evaluation`

- `evaluation_id`
- `organization_id`
- `evaluation_dt`
- `evaluation_status`
- `evaluated_by`
- `input_metadata_json`
- `status`
- audit columns

`applicability_evaluation_result`

- `evaluation_result_id`
- `evaluation_id`
- repository references: `authority_id`, `artifact_id`, `release_id`, `applicability_rule_id`
- `recommendation_type`: Authority, Artifact, Release
- `recommendation_status`: Recommended, Accepted, Rejected, Overridden
- `override_reason`
- `confidence_score`
- `status`
- audit columns

### Repository Subscription

`organization_repository_subscription`

- `subscription_id`
- `organization_id`
- `authority_id`
- `artifact_id`
- `release_id`
- `subscription_type`: Automatic, Manual
- `subscription_status`: Active, Disabled, Superseded
- `source_evaluation_id`
- `effective_dt`
- `end_dt`
- `status`
- audit columns

This table represents what repository intelligence is exposed to the organization. It must not copy repository records.

### Organization Control Context

`organization_control`

- `organization_control_id`
- `organization_id`
- `origin_type`
- `repository_control_id` nullable
- `control_code` required for organization controls
- `control_name`
- `description`
- `business_justification`
- `effective_dt`
- `review_frequency`
- `applicability_status`: Applicable, Not Applicable, Deferred, Accepted Risk
- `exclusion_justification`
- ownership: `primary_owner`, `secondary_owner`, `backup_owner`
- `business_function_id`
- `criticality`
- `status`
- audit columns

Repository-origin controls should have `repository_control_id`. Organization-origin controls should have organization-owned code/name.

### Organization Requirement Context

`organization_requirement`

- `organization_requirement_id`
- `organization_id`
- `origin_type`
- `repository_requirement_id` nullable
- `organization_control_id`
- `requirement_code`
- `requirement_name`
- `requirement_statement`
- `objective`
- `applicability_status`: Applicable, Implemented, Not Applicable, Deferred, Accepted Risk
- `exclusion_justification`
- `implementation_status`
- `status`
- audit columns

Business rule: any Not Applicable, Deferred, or Accepted Risk status requires justification.

### Obligation Context

`organization_obligation_context`

- `organization_obligation_context_id`
- `organization_id`
- `organization_requirement_id`
- `repository_obligation_id` nullable
- repository context: `release_id`, `structure_node_id`
- `origin_type`
- `obligation_status`: Applicable, Not Applicable, Deferred, Accepted Risk
- `frequency_type`
- `frequency_value`
- `frequency_unit`
- `due_within`
- `severity`
- `status`
- audit columns

This enables release/source-node-specific obligation differences without duplicating the Part 1 obligation master.

### Practice Management

`practice`

- `practice_id`
- `organization_id`
- `organization_requirement_id`
- `origin_type`
- `practice_code`
- `practice_name`
- `description`
- `practice_owner`
- `status`
- audit columns

Business rule: one requirement can have multiple practices.

`practice_instance`

- `practice_instance_id`
- `practice_id`
- `organization_id`
- `instance_code`
- `instance_name`
- `owner`
- `primary_owner`
- `secondary_owner`
- `business_function_id`
- `department`
- `frequency_type`
- `frequency_value`
- `frequency_unit`
- `assurance_mode`: Manual, Semi-Automated, Automated, Hybrid
- `criticality`: Critical, High, Medium, Low
- `implementation_status`
- `status`
- audit columns

Business rule: a practice is not implemented unless at least one active practice instance exists.

### Practice Instance Intelligence

`practice_instance_dependency`

- `practice_instance_id`
- `dependency_type`: Person, Tool, Asset, Vendor, Application, Process, Location
- `dependency_name`
- `dependency_reference`
- `owner`
- `criticality`
- `status`
- audit columns

`practice_instance_evidence_config`

- `practice_instance_id`
- `repository_obligation_id` nullable
- `evidence_type`
- `evidence_category`
- `inherited_from_repository`
- `organization_modified`
- `mandatory_flag`
- `collection_method`: Manual, Automated
- `collection_frequency`
- `evidence_owner`
- `alignment_status`: Fully Aligned, Partially Aligned, Organization Defined, Not Configured
- `status`
- audit columns

`practice_instance_assurance_attribute`

- `practice_instance_id`
- manual attributes: owner availability, role changes, training status, certification status, leave status, successor availability
- automated attributes: license expiry, support expiry, vendor support status, patch status, monitoring status, backup status, health status
- `status`
- audit columns

`practice_instance_vendor_attribute`

- `practice_instance_id`
- `vendor_name`
- `contract_reference`
- `sla_reference`
- `service_criticality`
- `dependency_criticality`
- `status`
- audit columns

`practice_instance_risk_attribute`

- `practice_instance_id`
- `operational_impact`
- `compliance_impact`
- `financial_impact`
- `cyber_impact`
- `reputational_impact`
- `risk_notes`
- `status`
- audit columns

`practice_instance_audit_attribute`

- `practice_instance_id`
- `auditable_asset`
- `auditable_tool`
- `configuration_scope`
- `audit_frequency_recommendation`
- `status`
- audit columns

`practice_instance_task_attribute`

- `practice_instance_id`
- `execution_frequency`
- `due_date_logic`
- `reminder_schedule`
- `escalation_matrix_json`
- `sla`
- `evidence_requirement`
- `status`
- audit columns

`practice_instance_resilience_attribute`

- `practice_instance_id`
- `single_person_dependency`
- `single_vendor_dependency`
- `single_tool_dependency`
- `single_asset_dependency`
- `resilience_notes`
- `status`
- audit columns

### Future Integration Trigger Matrix

`future_integration_trigger`

- `trigger_id`
- `practice_instance_id`
- `trigger_condition`
- `future_lead_type`
- `source_attribute_type`
- `source_attribute_id`
- `trigger_status`: Candidate, Accepted, Suppressed
- `status`
- audit columns

Examples:

- Vendor dependency exists -> Third Party Risk Assessment
- Manual practice instance -> Recurring Task/Ticket Management
- Critical practice instance -> Risk Assessment
- Evidence configuration exists -> Continuous Audit Candidate
- Critical business function mapping -> BCP Assessment

### Audit And Security

`practice_audit_trace`

- immutable audit trail for major entities
- stores before/after JSON snapshot where useful
- protected against update/delete

`practice_approval_action`

- approval actions, comments, status changes

`practice_security_role`, `practice_security_permission`, `practice_security_role_permission`, `practice_security_user_role`

- same pattern as Part 1, or shared role store if integrated later.

## API Design

Use the same encrypted API model as Part 1.

Browser calls Web gateway:

```text
GET  /practice-management-gateway/{area}
POST /practice-management-gateway/{area}
POST /practice-management-gateway/{area}/{id}/retire
POST /practice-management-gateway/{area}/{id}/approve
```

Web gateway calls API:

```text
POST /api/practice-management/secure/query
POST /api/practice-management/secure/manage
```

The gateway keeps signed tokens and encryption material out of browser JavaScript.

### API Areas

- `organizations`
- `organization-metadata`
- `applicability-discovery`
- `applicability-results`
- `repository-subscriptions`
- `repository-import`
- `organization-controls`
- `organization-requirements`
- `control-applicability`
- `requirement-applicability`
- `practices`
- `practice-instances`
- `dependencies`
- `evidence-configurations`
- `assurance-attributes`
- `vendor-attributes`
- `risk-attributes`
- `audit-attributes`
- `task-attributes`
- `resilience-attributes`
- `future-triggers`
- `lookups`
- `audit-trace`

### Stored Procedures

Recommended facade procedures:

```sql
dbo.pm_get_repository
dbo.pm_manage_repository
dbo.pm_evaluate_applicability
dbo.pm_generate_future_triggers
```

All SQL operations must use parameters/stored procedures. Avoid dynamic SQL unless validated and controlled by metadata tables.

## Frontend Page List

1. Organization Dashboard
2. Organization Onboarding
3. Organization Metadata
4. Applicability Discovery
5. Applicability Evaluation History
6. Repository Artifact / Release Subscription
7. Repository Import View
8. Organization Defined Controls
9. Organization Defined Requirements
10. Control Applicability & Ownership
11. Requirement Applicability Status
12. Practice Management
13. Practice Instance Management
14. Dependency Intelligence
15. Evidence Configuration
16. Assurance Attributes
17. Vendor Attributes
18. Risk Attributes
19. Audit Attributes
20. Task/Ticket Trigger Attributes
21. Resilience Attributes
22. Future Integration Trigger Matrix
23. Audit Traceability

## Navigation Flow

Primary organization flow:

```text
Organization
  -> Metadata
  -> Applicability Discovery
  -> Subscriptions
  -> Repository Import View
  -> Controls
  -> Requirements
  -> Practices
  -> Practice Instances
  -> Intelligence Attributes
```

Drill-down flow:

```text
Organization
  -> Subscribed Release
    -> Imported Repository Controls
      -> Requirements
        -> Obligations
          -> Practice
            -> Practice Instance
```

Practice-instance workspace flow:

```text
Practice Instance
  -> Ownership
  -> Dependencies
  -> Evidence
  -> Assurance
  -> Vendor
  -> Risk
  -> Audit
  -> Task
  -> Resilience
  -> Future Triggers
```

Use encrypted navigation context, same as Part 1. Do not expose internal IDs in plain query strings.

## UI Principles

- Enterprise dashboard, not a demo grid.
- Proper Add/Edit forms, no user-facing JSON input.
- 3-dot actions menu per row.
- Compact filters with organization, status, origin type, criticality, owner, business function.
- Drill-down headers should use business codes/names, not raw IDs.
- Practice Instance should have a workspace-style detail page with tabs or side navigation for attribute groups.
- Apply RBAC at menu, page, and action level.
- Client-side validation is useful, but server-side validation is mandatory.
- Show user-safe errors only; detailed exceptions remain in logs with references.

## Implementation Plan

### Project Setup

1. Create `PracticeManagement.sln`.
2. Add `PracticeManagement.Api`.
3. Add `PracticeManagement.Web`.
4. Reuse/reference `ControlManagement.Security` initially, or move it to a shared `Grac.Security` library later.
5. Add `PracticeManagement/database`.
6. Add appsettings for encrypted API, token signing, CORS, database, and path base.

### Database

1. Create `001_practice_management_schema.sql`.
2. Create `002_practice_management_procedures.sql`.
3. Create `003_practice_management_seed.sql`.
4. Create `004_practice_management_security.sql`.
5. Add sample organization, metadata, subscriptions, controls, requirements, practices, and practice instances.

### API

1. Implement secure query/manage envelope endpoints.
2. Implement repository reference validation.
3. Implement organization-scoped authorization checks.
4. Implement applicability evaluation service.
5. Implement subscription service.
6. Implement practice instance intelligence services.
7. Implement future trigger generation service.

### Web

1. Login/security shell copied from current ControlManagement style.
2. Organization selection context.
3. Build screens listed above using proper forms and grids.
4. Add Practice Instance workspace page.
5. Add encrypted navigation between organization, control, requirement, practice, and instance contexts.
6. Add RBAC-aware menu and action rendering.

## Phase-Wise Development Plan

### Phase 1 - Foundation

- Create separate PracticeManagement projects.
- Establish schema, security, audit, soft delete, and lookup tables.
- Implement encrypted API gateway pattern.
- Create Organization Onboarding and Organization Metadata screens.

### Phase 2 - Applicability And Subscription

- Evaluate Part 1 applicability rules against organization metadata.
- Show recommendations.
- Allow accept/reject/override.
- Create artifact/release subscriptions.
- Add repository import view for subscribed controls, requirements, and obligations.

### Phase 3 - Organization Controls And Requirements

- Create organization-defined controls and requirements.
- Add origin type support.
- Add control applicability and ownership.
- Add requirement applicability status and justification logic.
- Support future mapping readiness to repository records.

### Phase 4 - Practice And Practice Instance Core

- Create Practice Management.
- Create Practice Instance Management.
- Enforce implementation rule: practice requires active instance.
- Add ownership, business function, frequency, assurance mode, criticality.

### Phase 5 - Practice Instance Intelligence

- Add dependency intelligence.
- Add evidence configuration.
- Add assurance, vendor, risk, audit, task, and resilience attributes.
- Add compact workspace UI for Practice Instance.

### Phase 6 - Future Trigger Matrix

- Generate future leads from Practice Instance attributes.
- Provide suppress/accept/candidate handling.
- Prepare API contracts for future Risk, Audit, Vendor, Task, Resilience, and Continuous Assurance modules.

### Phase 7 - Hardening And Pilot Readiness

- RBAC hardening.
- Server-side validation coverage.
- Audit trail verification.
- VAPT checklist.
- Publish profile, IIS path base, CSP, local assets, and production appsettings verification.
- Smoke test complete navigation and encrypted API flow.

## Open Design Decisions

1. Whether `ControlManagement.Security` should remain referenced directly or be extracted into a neutral shared `Grac.Security` project.
2. Whether Part 2 should use `GRAC_Practice` schema or reuse `GRAC_New` with a strict table prefix. `GRAC_Practice` is recommended.
3. Whether ownership fields initially store text/user code or integrate immediately with the main GRAC user master.
4. Whether applicability evaluation should be SQL-only in Phase 2 or a service-layer evaluator using metadata expressions from Part 1.
5. Whether Practice Instance attribute groups should be separate tabs on one workspace page or individual pages linked from the instance.

