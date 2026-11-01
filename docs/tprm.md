# Third-Party Risk Management (migrations 486-490)

Source: BRD "GRAC Third-Party Risk Management" v1.0 (attached 2026-10-24).
Built as an extension of GRAC, in the Practice Management architecture:
SQL Server procedures own every rule (schema `grac_practice`), the API tier
binds and shapes, the Web tier checks session / organization / menu grant
and proxies, the screens are partials with their own scripts.

The BRD's rule "do not build an independent TPRM implementation of GRAC's
existing core capabilities" decides the integration: vendors, practice
instances, obligations, assurance findings, contracts, the Evidence Center,
the Gap Register and the Risk Centre are **read or linked, never copied**.

## Contents

1. Gap analysis -- what GRAC already had, what was added
2. Decisions
3. Data model (ERD) and configuration layers
4. Integration map
5. Database (486-490)
6. Workflow rules per step
7. Monitoring (scheduler)
8. Screens
9. API reference
10. Roles and permissions
11. BRD acceptance criteria -> where they are met
12. Deploy / rollback
13. Not in this delivery
14. Verification done

## 1. Gap analysis

| BRD need | Existing in GRAC | Added |
|---|---|---|
| Third-party register | `organization_dependency_vendor` (a dependency, no lifecycle, no identifiers, no contacts) | `tprm_third_party` (+ categories, contacts, status history), **linked** to the vendor (`vendor_id`), never a copy |
| Engagement per service | none | `tprm_engagement` + scope, links, exposure snapshots, history |
| Discovery of what depends on the third party | `practice_dependency_resolution`, `organization_dependency_application.vendor_id`, `practice_instance_obligation`, `org_assurance_observation` (+ execution entity), `practice_gap`, `risk_register.linked_vendor_id`, `asset_contract.vendor_id` | `sp_tprm_engagement_discover` reads them; "Record discovery" stores DISCOVERED links to validate |
| Configurable lists, scoring, questionnaires, rules | per-module masters, no baseline / organization layering | 486: baseline + organization override layer for lists, library, rules, custom fields; versioned templates |
| Evidence | Evidence Center (476/477): items, versions, visibility | `tprm_evidence_link` pins Evidence Center items (or an external reference) to responses, safeguards, findings |
| Remediation tracking | Gap Register (`sp_custom_gap_save`) | a finding can be raised to the Gap Register (`source_reference_type = 'TprmFinding'`) |
| Enterprise risk | Risk Centre candidates (`sp_risk_candidate_create`, idempotent per source) and register | new risk source `ThirdParty`; escalate one candidate per engagement, or link an existing risk |
| Scheduler | `TaskNotificationWorker` passes | a TPRM monitoring pass in the same worker |
| Dashboards | management dashboard framework (414/416/451) | `sp_dashboard_tprm`, `tprm-dashboard` screen |
| Menu / permissions | `menu_master`, role menu permissions | root `nav-tprm` with five screens |

## 2. Decisions

| # | Decision | Why / where |
|---|---|---|
| D1 | Configuration rows with `organization_id NULL` are the GRAC baseline; an organization **overrides** a baseline row with its own row pointing at it (`baseline_*_id`) or adds its own. The effective view is a function (`fn_tprm_*_effective`). | BRD 6.3; the baseline is never written from an organization (486) |
| D2 | Risk models and questionnaires are **templates with versions** (DRAFT, ACTIVE, SUPERSEDED, DISCARDED; one active, one draft). A GRAC template is **adopted** (copied) into the organization; a newer GRAC version shows "Update available" and is taken as a new Draft. | BRD 11, acceptance 8 |
| D3 | An inherent assessment **pins** the risk-model version; a due-diligence round pins each questionnaire version. Later template changes never touch past records. | acceptance 8 |
| D4 | Operational records store **codes**; labels come from the effective lists at read time. Lists of kind MEANING map each organization value to a fixed meaning the workflow uses (statuses, decisions, effectiveness, ratings). | BRD 6.1 (configurable statuses / decisions) |
| D5 | A GRAC vendor is **linked** to a third party (unique per vendor), not copied. Import never changes the vendor. | acceptance 3 |
| D6 | Discovery is **read-only** until the user records it (DISCOVERED links + snapshot); links are then validated or removed. | BRD step 2 |
| D7 | Duplicate check on registration and import (identifiers, normalised name, vendor name). Result `DUPLICATES` = nothing saved; repeat with `confirmDuplicates`. | BRD step 1 |
| D8 | Only a **verified** effective / partially effective safeguard reduces residual risk. Verification needs a method other than attestation; by evidence review it needs accepted evidence. | BRD step 3 ("effectiveness not assumed") |
| D9 | Residual per dimension = inherent x (1 - max(0, reduction - uplift)), never below the model floor; overall by the model's aggregation (weighted average, highest dimension, blended). | 489 `sp_tprm_residual_calculate` |
| D10 | Evidence is reviewed (accepted / rejected) by someone **other than** the person who added it. | BRD 9 (separation of duties) |
| D11 | Approval path = first matching approval rule (priority; residual band rank, else inherent; or criticality rank). Levels require the GRAC role named on the rule when the organization has it (`organization_employee.role_id`), otherwise any approver with APPROVE. SoD: not the requester, not an assessor, a different person per level. Delegations are dated. | BRD step 4 |
| D12 | Risk acceptance is time-bound (end date within the rule's maximum) with a mandatory review date. | BRD step 4 |
| D12a | Rejecting a re-approval of a live engagement suspends it and flags reassessment, so it cannot be resumed without a new assessment and decision. Closing (exit, cancel) closes its open findings and reviews; findings already in the Gap Register stay there. | 489 `sp_tprm_decision_act`, `sp_tprm_engagement_lifecycle` |
| D13 | Risk Centre: **ESCALATE** = one candidate per engagement through `sp_risk_candidate_create` (its idempotency returns the open one), **LINK** = an existing enterprise risk. Nothing is copied automatically. | acceptance 12 |
| D14 | Activation gate: the latest decision is an approval **of the current risk assessment**; no reassessment pending; mandatory onboarding checks done or waived; mandatory conditions closed; actual exposure compared; no open material deviation. A decision is requested only on a due-diligence round done for the current assessment (also again from APPROVED / ONBOARDING after a reassessment). | BRD step 5 |
| D15 | Material change on a live engagement (criticality, data exposure, service model, locations; scope change; material deviation) flags **reassessment**; the monitoring pass raises a triggered review. | acceptance 11 |
| D16 | Monitoring reviews are raised once per **source key** (idempotent pass). | 489 `tprm_review.source_key` |
| D17 | Custom fields: typed (text, number, date, boolean, single / multi select, reference), mandatory, validation, conditional visibility, role-restricted edit (by the caller's GRAC role). | BRD 6.2 |
| D18 | External respondent portal: **not built**; third-party answers are entered internally with respondent type THIRD_PARTY. | section 13 |
| D19 | API tier generated from the procedure signatures (`tools/tprm/gen_csharp.py`) in the house style (typed request records, explicit `AddParam`, dictionary rows). | parameter drift is impossible |
| D20 | Baseline content (487) is labelled `GRAC baseline (illustrative)`, `is_regulatory = 0`; sample records are flagged `is_sample` and named "SAMPLE - ...". | BRD 5.2 / 5.3 |

## 3. Data model and configuration layers

```
                      CONFIGURATION (486, baseline NULL org + org overrides)
 tprm_reference_list --< tprm_reference_value          tprm_library_item (SAFEGUARD | EVIDENCE_REQUIREMENT | TREATMENT_ACTION)
 tprm_approval_rule    tprm_review_rule    tprm_approval_delegation    tprm_custom_field --< tprm_custom_field_value
 tprm_template --< tprm_template_version --< RISK_MODEL: tprm_rm_dimension --< tprm_rm_factor --< tprm_rm_factor_option
                                          |              tprm_rm_band, tprm_rm_tier_rule
                                          +-< QUESTIONNAIRE: tprm_q_section --< tprm_q_question --< tprm_q_option

                      OPERATIONS (488, 489)
 organization_dependency_vendor (GRAC) <-0..1- tprm_third_party --< tprm_third_party_contact / _category / _status_history
                                                     |
                                                     +--< tprm_engagement --< tprm_engagement_scope (PROPOSED | ACTUAL)
                                                            |              --< tprm_engagement_link (VENDOR, PRACTICE_INSTANCE, DEPENDENCY,
                                                            |                    APPLICATION, CONTRACT, ENTERPRISE_RISK, RISK_CANDIDATE, GAP)
                                                            |              --< tprm_exposure_snapshot (PROPOSED | DISCOVERED | ACTUAL)
                                                            |              --< tprm_engagement_history
                                                            +--< tprm_risk_assessment (pins rm version) --< _answer, _dimension
                                                            +--< tprm_dd_assessment --< tprm_dd_questionnaire (pins q version) --< tprm_dd_response
                                                            |                       --< tprm_safeguard_assessment
                                                            +--< tprm_evidence_link (-> evidence_item / file, GRAC 476)
                                                            +--< tprm_finding (-> custom_gap, GRAC Gap Register)
                                                            +--< tprm_decision --< tprm_decision_approval
                                                            +--< tprm_onboarding_item (ONBOARDING | EXIT)
                                                            +--< tprm_engagement_deviation
                                                            +--< tprm_review
```

Effective configuration for an organization: `fn_tprm_reference_effective`,
`fn_tprm_library_effective`, `fn_tprm_approval_rule_effective`,
`fn_tprm_review_rule_effective`, `fn_tprm_template_effective`,
`fn_tprm_risk_model_version`. Origin per row: `GRAC`, `GRAC_OVERRIDDEN`,
`ORGANIZATION`.

## 4. Integration map

| GRAC capability | TPRM use | Object |
|---|---|---|
| Vendors (Dependencies) | discovery + import / link | `organization_dependency_vendor`, `sp_tprm_vendor_discovery`, `sp_tprm_vendor_import` |
| Practice instances, practices, obligations | discovery, links | `practice_dependency_resolution`, `practice_instance`, `practice_instance_obligation` |
| Applications | scope items, discovery, links | `organization_dependency_application` |
| Assurance | findings shown in discovery; new open findings raise ASSURANCE_FAILURE reviews | `org_assurance_observation`, `org_assurance_execution_entity` |
| Practice gaps | discovery | `practice_gap` |
| Contracts (Asset & Contract) | engagement contract, discovery, links | `asset_contract` (optional: guarded with `OBJECT_ID`) |
| Evidence Center | evidence (pinned versions), picker, upload | `evidence_item`, `evidence_item_file`, `fn_pm_evidence_item_visible`, `Shared/evidence-picker.js` |
| Gap Register | finding -> gap | `sp_custom_gap_save` (`TprmFinding`) |
| Risk Centre | escalate / link | `risk_source_master` row `ThirdParty`, `sp_risk_candidate_create`, `risk_register` |
| Roles | approval levels, custom-field access | `organization_role`, `organization_employee.role_id` |
| Audit | decisions and configuration | `practice_audit_trace` via `sp_tprm_audit`; engagement events in `tprm_engagement_history` |
| Dashboards | module dashboard | `sp_dashboard_tprm`, `ManagementDashboards`, `management-dashboard.js` |
| Scheduler | monitoring pass | `TaskNotificationWorker` (`TprmMonitoring*`) |

## 5. Database

| File | Content | Errors |
|---|---|---|
| `486_tprm_configuration.sql` | 18 configuration tables, effective-view functions, configuration procedures (lists, library, rules, delegations, custom fields, templates: create / adopt / new version / header / items / activate / retire / compare) | 57500-57599 |
| `487_tprm_baseline_seed.sql` (generated by `tools/tprm/gen_487.py`) | 19 lists, 127 values, 58 library items, 4 approval + 4 review rules, risk model `GRAC_TPRM_STANDARD` v1 (8 dimensions, 19 factors, 4 bands, tier rules), 8 questionnaires (core, enhanced, cloud, app dev, managed security, payment / API, HR / payroll, KYC), 6 sample profiles; templates inserted only when missing | -- |
| `488_tprm_third_parties_engagements.sql` | third parties, engagements, scope, links, discovery, inherent risk | 57600-57699 |
| `489_tprm_due_diligence_decision_monitoring.sql` | due diligence, safeguards, evidence, findings, residual, decisions and approvals, Risk Centre, onboarding, deviations, activation, lifecycle, reviews, monitoring sweep; risk source `ThirdParty` | 57700-57899 |
| `490_tprm_menu_dashboard.sql` | `sp_dashboard_tprm`, menu root `nav-tprm` + 5 screens, grants | 57900 |

Every file is re-runnable, ASCII-only, guards its prerequisites
(`SET NOEXEC ON`), ends with PASS / FAIL checks and has a `_rollback.sql`
(generated by `tools/tprm/gen_rollbacks.py`). `274_menu_master_seed.sql`
carries the 490 menu rows.

## 6. Workflow rules per step

| Step | Stages | Rules (procedure) |
|---|---|---|
| 1 Registration | third-party status from `TP_STATUS` meanings | duplicate check; contacts; categories; custom fields; status follows engagements (`sp_tprm_third_party_sync_status`) |
| 2 Scope & inherent risk | SCOPING -> RISK_ASSESSED | scope items PROPOSED / ACTUAL; discovery; assessment needs data exposure; factors prefilled from scope; mandatory factors; tier from band + minimum tier rules |
| 3 Due diligence | DUE_DILIGENCE | questionnaires by core / category / tier / type; question applicability by tier, category, data rank, access; follow-ups by parent answer; answer -> automatic deficiency for flagged options; rating; safeguards applicable by question, contract clause or dimension score >= 50; verification (D8); completion needs mandatory answers, ratings, safeguard assessment, evidence or a finding where evidence is expected, no evidence still awaiting review; a new round copies answers and results, but a verification that rested on evidence is re-done with the new round's evidence |
| 4 Decision | PENDING_DECISION -> APPROVED / REJECTED / back to DUE_DILIGENCE | D11-D13; conditions become CONDITION findings that block activation; live engagements return to their stage |
| 5 Onboarding | ONBOARDING -> ACTIVE | checks from `ONBOARDING_CHECK`; exposure comparison and deviations; activation gate (D14); next review from the review rule |
| Lifecycle | ACTIVE, SUSPENDED, EXITING, EXITED, CANCELLED | suspend / resume (no pending reassessment), renew (new end date, renewal review), scope change (reassessment), exit (EXIT_CHECK checks: data return, deletion evidence, access, dependencies), cancel before activation; history kept |

## 7. Monitoring

`sp_tprm_monitoring_sweep(@organization_id NULL = all)` -- run by
`TaskNotificationWorker` every `TaskNotification:TprmMonitoringIntervalMinutes`
(default 60; `TprmMonitoringEnabled=false` leaves it to SQL Agent) and by
"Run monitoring now" on Reviews. Raises, once per source key:

| Review type | When |
|---|---|
| PERIODIC (SCHEDULED) | next review date within the rule's lead days |
| CONTRACT_EXPIRY | engagement end within the rule's contract alert days |
| CERTIFICATION_EXPIRY | latest accepted evidence of a requirement expiring within the cert alert days |
| ACCEPTANCE_EXPIRY | risk acceptance ending within 30 days |
| TRIGGERED | reassessment flagged (monthly), overdue remediation (monthly), a new open assurance finding on the vendor or a linked practice instance since activation |

A trigger listed in the rule's reassessment triggers flags the engagement.

## 8. Screens

| Screen | Partial / script | Content |
|---|---|---|
| `tprm-dashboard` | `management-dashboard` (shared) | KPIs, ageing, distributions, lists; drills to Engagements (stage / band / criticality / attention) and Reviews (status / type / dueWithin) |
| `tprm-third-parties` | `tprm-third-parties.cshtml`, `js/Tprm/tprm-third-parties.js` | register, detail (engagements, contacts, profile, status history), vendor import, sample load |
| `tprm-engagements` | `tprm-engagements.cshtml`, `js/Tprm/tprm-engagements.js` | list + workspace: Scope & exposure, Inherent risk, Due diligence, Decision, Onboarding & monitoring, History |
| `tprm-reviews` | `tprm-reviews.cshtml`, `js/Tprm/tprm-reviews.js` | review queue, complete / cancel, run monitoring |
| `tprm-configuration` | `tprm-configuration.cshtml`, `js/Tprm/tprm-configuration.js` | reference lists, library, templates (version editor, compare, adopt, activate), rules, delegations, custom fields; GRAC baseline scope for PM_ADMIN |

Shared: `Partials/_tprm-form-dialog.cshtml` (one form dialog + the shared
`tprm-` styles) and `js/Tprm/tprm-common.js` (`window.gracTprm`: api,
lookups, form builder, custom fields). Reused: `pm-grid.js`,
`Shared/dashboard-drill.js`, `Shared/evidence-picker.js` +
`_evidence-picker-dialog`, `gracOrgPref`, `gracUi`.

## 9. API reference

Browser: `/practice/api/tprm/...` (Web `Controllers/TprmController.cs`,
proxy). API: `/api/practice/tprm/...` (`Controllers/TprmController.cs`,
`Services/TprmService.cs`, `Models/TprmModels.cs`, registered by
`AddPracticeTprmService()`). GET takes its fields in the query string, POST
in a JSON body; `organizationId` is required except for the GRAC baseline
configuration (platform administrator). Fields ending in `Json` are JSON
text. Responses: rows `{ data, totalRows }`; sets `{ <set>: [rows] }`;
commands `{ success, result }` where `result.Result` says what happened;
**409** `{ duplicate: true, result, duplicates, error }` when possible
duplicates were found (nothing saved); a refusal **400** `{ error }` with
the procedure's sentence.

Caller headers stamped by the Web tier from the session:
`X-PM-Caller-Employee-Id`, `X-PM-Caller-Is-Admin`,
`X-PM-Caller-Is-Platform-Admin` (PM_ADMIN).

| Method | Route (`/api/practice/tprm/...`) | Procedure | Result | Request fields (besides `organizationId`) |
|---|---|---|---|---|
| GET | `lookups` | `sp_tprm_lookups` | `{ values, employees, businessFunctions, processes, applications, vendors, contracts, library, customFields, riskModel, dimensions, bands, evidenceTypes, roles }` | -- |
| GET | `config/reference` | `sp_tprm_config_reference_get` | `{ lists, values }` | listCode |
| POST | `config/reference/values` | `sp_tprm_reference_value_save` | `{ success, result }` | valueId, listCode, valueCode, label, description, meaningCode, rankNo, colorHex, isMandatory, displayOrder, status |
| POST | `config/reference/overrides` | `sp_tprm_reference_value_override` | `{ success, result }` | baselineValueId, label, description, rankNo, colorHex, isMandatory, displayOrder, isHidden, reset |
| GET | `config/library` | `sp_tprm_library_list` | `{ data, totalRows }` | libraryCode |
| POST | `config/library/items` | `sp_tprm_library_save` | `{ success, result }` | itemId, libraryCode, itemCode, itemName, description, categoryCode, dimensionCode, guidance, effectivenessCriteria, isContractClause, evidenceRequirementCode, evidenceTypeId, validityMonths, reviewRequired, defaultDueDays, defaultOwnerHint, sourceAuthority, sourceDocument, sourceVersion, sourceReference, applicabilityNote, isRegulatory, displayOrder, status |
| POST | `config/library/overrides` | `sp_tprm_library_override` | `{ success, result }` | baselineItemId, itemName, description, categoryCode, dimensionCode, guidance, effectivenessCriteria, isContractClause, evidenceRequirementCode, evidenceTypeId, validityMonths, reviewRequired, defaultDueDays, defaultOwnerHint, displayOrder, isHidden, reset |
| GET | `config/rules` | `sp_tprm_rules_get` | `{ approvalRules, reviewRules, delegations, roles }` | -- |
| POST | `config/rules/approval` | `sp_tprm_approval_rule_save` | `{ success, result }` | ruleId, baselineRuleId, ruleCode, ruleName, description, priority, minBandRank, minCriticalityRank, approvalLevels, level1RoleName, level2RoleName, level3RoleName, sodRequired, escalateToRiskCentre, maxAcceptanceMonths, allowedDecisionCodes, isHidden, status |
| POST | `config/rules/review` | `sp_tprm_review_rule_save` | `{ success, result }` | ruleId, baselineRuleId, ruleCode, ruleName, description, priority, minBandRank, minCriticalityRank, reviewFrequencyMonths, evidenceRenewalMonths, contractExpiryAlertDays, certExpiryAlertDays, reviewLeadDays, reassessmentTriggerCodes, monitoringNote, isHidden, status |
| POST | `config/delegations` | `sp_tprm_delegation_save` | `{ success, result }` | delegationId, fromEmployeeId, toEmployeeId, validFrom, validTo, reason, revoke |
| GET | `config/custom-fields` | `sp_tprm_custom_field_list` | `{ data, totalRows }` | entityCode, activeOnly |
| POST | `config/custom-fields` | `sp_tprm_custom_field_save` | `{ success, result }` | fieldId, entityCode, fieldCode, label, description, dataType, isMandatory, defaultValue, validationRegex, minValue, maxValue, maxLength, optionsJson, referenceKind, visibleWhenFieldCode, visibleWhenValue, accessRoleNames, isSearchable, isFilterable, isReportable, displayOrder, status |
| GET | `config/templates` | `sp_tprm_template_list` | `{ data, totalRows }` | templateKind |
| GET | `config/templates/versions/{versionId}` | `sp_tprm_template_version_get` | `{ header, versions, + kind sets }` | -- |
| GET | `config/templates/compare` | `sp_tprm_template_compare` | `{ data, totalRows }` | versionA, versionB |
| POST | `config/templates` | `sp_tprm_template_create` | `{ success, result }` | templateKind, templateCode, templateName, description, copyFromVersionId |
| POST | `config/templates/{baselineTemplateId}/adopt` | `sp_tprm_template_adopt` | `{ success, result }` | -- |
| POST | `config/templates/{templateId}/new-version` | `sp_tprm_template_new_version` | `{ success, result }` | -- |
| POST | `config/templates/{templateId}/retire` | `sp_tprm_template_retire` | `{ success, result }` | restore |
| POST | `config/templates/versions/{versionId}/header` | `sp_tprm_template_version_header_save` | `{ success, result }` | templateName, description, changeSummary, isCore, appliesServiceCategories, appliesMinTierRank, appliesEngagementTypes, aggregationMethod, blendPct, effectiveReductionPct, partialReductionPct, residualFloorPct, deficiencyUpliftPct, isDefault |
| POST | `config/templates/versions/{versionId}/risk-items` | `sp_tprm_rm_item_save` | `{ success, result }` | itemType, itemId, code, name, description, weight, dimensionCode, isMandatory, prefillSource, optionsJson, minScore, rankNo, colorHex, ddTierCode, conditionKind, displayOrder |
| POST | `config/templates/versions/{versionId}/questionnaire-items` | `sp_tprm_q_item_save` | `{ success, result }` | itemType, itemId, code, text, description, sectionCode, responseType, isMandatory, evidenceExpected, evidenceRequirementCode, safeguardCode, dimensionCode, minTierRank, appliesServiceCategories, appliesMinDataRank, appliesAccessCodes, parentQuestionCode, triggerOptionCodes, weight, sourceAuthority, sourceDocument, sourceVersion, sourceReference, applicabilityNote, isRegulatory, optionsJson, displayOrder |
| POST | `config/templates/versions/{versionId}/items/remove` | `sp_tprm_template_item_remove` | `{ success, result }` | itemType, itemId |
| POST | `config/templates/versions/{versionId}/activate` | `sp_tprm_template_version_activate` | `{ success, result }` | discard, changeSummary |
| GET | `third-parties` | `sp_tprm_third_party_list` | `{ data, totalRows }` | search, statusCode, serviceCategoryCode, includeArchived, sample, pageNumber, pageSize |
| GET | `third-parties/{thirdPartyId}` | `sp_tprm_third_party_get` | `{ header, categories, contacts, engagements, history, customValues, duplicates }` | -- |
| POST | `third-parties` | `sp_tprm_third_party_save` | `{ success, result }` | thirdPartyId, legalName, tradingName, registrationNumber, taxId, leiCode, providerTypeCode, primaryServiceCategoryCode, categoriesCsv, reportingCategoryCode, country, stateRegion, city, address, website, parentCompany, yearEstablished, employeeCountBand, annualRevenueBand, certificationsText, profileNotes, relationshipOwnerEmployeeId, contactsJson, customJson, confirmDuplicates, expectedRecordVersion |
| POST | `third-parties/{thirdPartyId}/status` | `sp_tprm_third_party_status` | `{ success, result }` | statusCode, archive, reason |
| GET | `vendors` | `sp_tprm_vendor_discovery` | `{ data, totalRows }` | search, onlyUnlinked |
| POST | `vendors/{vendorId}/import` | `sp_tprm_vendor_import` | `{ success, result }` | thirdPartyId, createEngagement, confirmDuplicates |
| POST | `samples/load` | `sp_tprm_sample_load` | `{ success, result }` | -- |
| GET | `engagements` | `sp_tprm_engagement_list` | `{ data, totalRows }` | search, thirdPartyId, stageCode, bandCode, criticalityCode, ownerEmployeeId, attention, pageNumber, pageSize |
| GET | `engagements/{engagementId}` | `sp_tprm_engagement_get` | `{ header, scope, links, snapshots, history, customValues, dimensions }` | -- |
| POST | `engagements` | `sp_tprm_engagement_save` | `{ success, result }` | engagementId, thirdPartyId, engagementTitle, serviceDescription, scopeDescription, businessPurpose, serviceCategoryCode, engagementTypeCode, serviceModelCode, deliveryLocations, isExisting, contractId, contractReference, contractValue, currencyCode, proposedStartDt, proposedEndDt, actualStartDt, actualEndDt, renewalDt, businessOwnerEmployeeId, relationshipOwnerEmployeeId, assessorEmployeeId, serviceCriticalityCode, dataExposureCode, rtoHours, rpoHours, slaSummary, notes, customJson, expectedRecordVersion |
| POST | `engagements/{engagementId}/scope` | `sp_tprm_scope_item_save` | `{ success, result }` | scopeItemId, itemKind, exposureMode, refId, itemCode, itemName, criticalityCode, country, isCritical, notes |
| POST | `engagements/scope/{scopeItemId}/remove` | `sp_tprm_scope_item_remove` | `{ success, result }` | -- |
| GET | `engagements/{engagementId}/discovery` | `sp_tprm_engagement_discover` | `{ summary, instances, obligations, dependencies, findings, gaps, risks, contracts }` | -- |
| POST | `engagements/{engagementId}/discovery` | `sp_tprm_engagement_discover` | `{ summary, instances, obligations, dependencies, findings, gaps, risks, contracts }` | -- |
| POST | `engagements/{engagementId}/links` | `sp_tprm_link_save` | `{ success, result }` | linkKind, targetId, note, linkSource |
| POST | `engagements/links/{linkId}/action` | `sp_tprm_link_action` | `{ success, result }` | action, note |
| POST | `engagements/{engagementId}/risk-assessments` | `sp_tprm_risk_assessment_start` | `{ success, result }` | triggerCode, triggerNote |
| GET | `risk-assessments/{assessmentId}` | `sp_tprm_risk_assessment_get` | `{ header, dimensions, factors, options, answers, bands }` | -- |
| POST | `risk-assessments/{assessmentId}/answers` | `sp_tprm_risk_answers_save` | `{ success, result }` | answersJson, notes |
| POST | `risk-assessments/{assessmentId}/complete` | `sp_tprm_risk_assessment_complete` | `{ success, result }` | discard |
| POST | `engagements/{engagementId}/residual` | `sp_tprm_residual_recalculate` | `{ success, result }` | -- |
| POST | `engagements/{engagementId}/due-diligence` | `sp_tprm_dd_start` | `{ success, result }` | dueDt, assessorEmployeeId, reviewerEmployeeId, copyPrevious |
| GET | `engagements/{engagementId}/due-diligence` | `sp_tprm_dd_get` | `{ header, questionnaires, sections, questions, options, safeguards, evidence, findings, dimensions, rounds }` | ddId |
| POST | `due-diligence/responses/{responseId}` | `sp_tprm_dd_response_save` | `{ success, result }` | respondentType, answerOptionCodes, answerText, answerNumber, answerDate |
| POST | `due-diligence/responses/{responseId}/rate` | `sp_tprm_dd_response_rate` | `{ success, result }` | ratingCode, assessorComment, reviewerComment |
| POST | `due-diligence/safeguards/{sgAssessmentId}` | `sp_tprm_safeguard_save` | `{ success, result }` | isApplicable, existenceCode, contractClauseRef, effectivenessCode, verificationMethod, verify, verificationNote, comment |
| POST | `due-diligence/{ddId}/complete` | `sp_tprm_dd_complete` | `{ success, result }` | summary |
| GET | `evidence/candidates` | `sp_tprm_evidence_candidates` | `{ data, totalRows }` | search, evidenceTypeId, pageNumber, pageSize |
| POST | `engagements/{engagementId}/evidence` | `sp_tprm_evidence_link_add` | `{ success, result }` | targetKind, targetId, sourceKind, evidenceItemId, externalReference, externalLocation, title, evidenceRequirementCode, validFrom, validTo, note |
| POST | `evidence/{tprmEvidenceId}/review` | `sp_tprm_evidence_review` | `{ success, result }` | action, note |
| POST | `engagements/{engagementId}/findings` | `sp_tprm_finding_save` | `{ success, result }` | findingId, findingKind, title, description, severityCode, dimensionCode, treatmentActionCode, ownerEmployeeId, dueDt, isMandatoryForActivation, exceptionUntil, customJson, expectedRecordVersion |
| POST | `findings/{findingId}/action` | `sp_tprm_finding_action` | `{ success, result }` | action, note |
| GET | `engagements/{engagementId}/decision` | `sp_tprm_decision_get` | `{ pack, rule, decisions, approvals, openFindings, riskLinks, outcomes, delegations }` | -- |
| POST | `engagements/{engagementId}/decision/submit` | `sp_tprm_decision_submit` | `{ success, result }` | submissionNote |
| POST | `decisions/{decisionId}/act` | `sp_tprm_decision_act` | `{ success, result }` | action, outcomeCode, rationale, riskAccepted, acceptanceUntil, mandatoryReviewDt, conditionsJson, onBehalfOfEmployeeId |
| POST | `decisions/{decisionId}/withdraw` | `sp_tprm_decision_withdraw` | `{ success, result }` | note |
| POST | `engagements/{engagementId}/risk-centre` | `sp_tprm_risk_escalate` | `{ success, result }` | mode, riskRegisterId, candidateTitle, summary |
| POST | `engagements/{engagementId}/onboarding/start` | `sp_tprm_onboarding_start` | `{ success, result }` | -- |
| GET | `engagements/{engagementId}/onboarding` | `sp_tprm_onboarding_get` | `{ readiness, onboardingChecks, exitChecks, conditions, deviations, snapshots, reviews, reviewRule }` | -- |
| POST | `onboarding/items/{itemId}/action` | `sp_tprm_onboarding_item_action` | `{ success, result }` | action, note, evidenceReference |
| POST | `engagements/{engagementId}/exposure/compare` | `sp_tprm_exposure_compare` | `{ success, result }` | confirmProposed |
| POST | `deviations/{deviationId}/action` | `sp_tprm_deviation_action` | `{ success, result }` | action, note |
| POST | `engagements/{engagementId}/activate` | `sp_tprm_engagement_activate` | `{ success, result }` | actualStartDt, note |
| POST | `engagements/{engagementId}/lifecycle` | `sp_tprm_engagement_lifecycle` | `{ success, result }` | action, reason, newEndDt |
| GET | `reviews` | `sp_tprm_review_list` | `{ data, totalRows }` | status, reviewType, engagementId, dueWithinDays, ownerEmployeeId, search, pageNumber, pageSize |
| POST | `engagements/{engagementId}/reviews` | `sp_tprm_review_raise` | `{ success, result }` | triggerCode, triggerDetail, dueDt, ownerEmployeeId, customJson |
| POST | `reviews/{reviewId}/complete` | `sp_tprm_review_complete` | `{ success, result }` | outcomeCode, outcomeNote, cancel |
| POST | `monitoring/run` | `sp_tprm_monitoring_sweep` | `{ success, result }` | -- |

## 10. Roles and permissions

BRD roles map to the screen grants in Role Master (490 grants the `Admin`
role VIEW / ADD / EDIT / APPROVE on every TPRM screen; other roles are
granted by the organization):

| BRD role | Typical grant |
|---|---|
| TPRM Administrator | tprm-configuration ADD / EDIT / APPROVE |
| Business / Relationship Owner | tprm-third-parties ADD / EDIT, tprm-engagements ADD / EDIT |
| Due-Diligence Assessor, Evidence Reviewer | tprm-engagements EDIT (SoD enforced in SQL) |
| Risk Reviewer / Approver | tprm-engagements APPROVE (+ the approval rule's role) |
| Auditor | VIEW on every TPRM screen |

Web rules (`TprmController`): GET VIEW; config POST ADD / EDIT,
activate / retire / delegations APPROVE, baseline PM_ADMIN; third parties
ADD (new) / EDIT; engagements ADD (new) / EDIT; decisions act, activate,
waivers, accepting a deviation, suspend / resume / exit / cancel APPROVE;
reviews complete EDIT, raise ADD (or engagements EDIT), monitoring run
APPROVE. Tenant isolation: every call checks `IsOrganizationAllowed`, and
every procedure filters by `organization_id`.

## 11. Acceptance criteria

| # | Criterion | Met by |
|---|---|---|
| 1 | one third party, many engagements | `tprm_third_party` 1 -- n `tprm_engagement` |
| 2 | separate scope, assessment, DD, decision per engagement | all keyed by `engagement_id` |
| 3 | vendors discovered and linked | `sp_tprm_vendor_discovery` / `_import`, D5 |
| 4 | instances, practices, obligations, assurance findings surfaced | `sp_tprm_engagement_discover` |
| 5 | prospective engagements assessed | PROPOSED scope + assessment before any link |
| 6 | baseline questionnaires and samples at deployment | 487 |
| 7 | organization customisation without changing the baseline | D1, D17, templates D2 |
| 8 | template updates keep customisations and past records | D2, D3 |
| 9 | five steps + configurable decisions | stages, `DECISION` list with meanings |
| 10 | actual vs proposed exposure | `sp_tprm_exposure_compare`, deviations |
| 11 | material change / scheduled review -> reassessment | D15, D16, monitoring |
| 12 | Risk Centre link / escalate, no duplication | D13 |
| 13 | RBAC, tenant isolation, audit | section 10; `tprm_engagement_history`, `tprm_third_party_status_history`, `practice_audit_trace` |
| 14 | dashboards | `tprm-dashboard` |

## 12. Deploy / rollback

1. Database, in order: `486`, `487`, `488`, `489`, `490` (each prints PASS /
   FAIL). Then re-run `274_menu_master_seed.sql` only if the menu snapshot is
   being re-applied (it carries the 490 rows).
2. API + Web (new: Api `TprmController`, `TprmService`, `TprmModels`,
   `TprmServiceRegistration`; Web `TprmController`, partials, `js/Tprm`;
   changed: `Program.cs`, `TaskNotificationWorker.cs`,
   `ManagementDashboardService.cs`, `ManagementDashboards.cs`,
   `PracticeScreen.cs`, `Manage.cshtml`, `management-dashboard.js`).
3. Optional: TPRM Configuration -> adopt the GRAC risk model / questionnaires
   to customise them; Third Parties -> Load sample records to explore.

Rollback (reverse order 490 -> 486, each `_rollback.sql`): procedures and
functions are dropped; tables are dropped only when they hold no rows (488
removes sample records first; 487 removes the baseline only when no
organization configuration or engagement depends on it); the `ThirdParty`
risk source is removed, or set Inactive when candidates use it. Gaps and
risk candidates raised from TPRM stay in the Gap Register / Risk Centre.
Remove the 490 rows from `274_menu_master_seed.sql`.

## 13. Not in this delivery

- External respondent portal (third parties answering online) -- D18.
- E-mail notification of due reviews (reviews appear in the Reviews queue and
  the dashboard; My Notifications integration can follow the 477 pattern).
- Exports / scheduled reports of TPRM data.
- Fourth-party records as separate third parties (fourth parties are scope
  items with a category and country).

## 14. Verification done

- An independent read-through of 486-490 for run-time and workflow defects; the
  defects it found (live re-approval rejection, evidence left unreviewed,
  copied verifications, flagged options without severity, verification
  without effectiveness, decisions on an older assessment, activation after
  a reassessment, unverify rule, review result, closing findings, sweep
  numbering) were fixed.
- All SQL files parse (sqlfluff, T-SQL dialect, 0 unparsable); a column /
  INSERT / UPDATE cross-check against the table definitions; external
  objects and parameters checked against their migrations (476, 204/205,
  378, 324, 101, 434).
- API and Web C# compiled (net8.0) against stubs of the two unavailable
  packages; the TPRM Razor partials compiled.
- Every script: `node --check`.
