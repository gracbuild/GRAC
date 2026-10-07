// =====================================================================
// AssetConfigService  (migration 420)
//
// Asset & Contract Management -- Phase 2 increment 1. Thin ADO.NET
// wrapper over the field-dictionary and asset-form-template procedures:
//
//   sp_asset_field_group_list            sp_asset_field_definition_list
//   sp_get_asset_taxonomy_lookup (241)   sp_asset_form_template_list
//   sp_asset_form_template_get           sp_asset_form_template_readiness
//   sp_asset_form_template_create        sp_asset_form_template_new_version
//   sp_asset_form_template_header_save   sp_asset_form_template_section_save
//   sp_asset_form_template_field_save    sp_asset_form_template_field_remove
//   sp_asset_form_template_transition
//   sp_asset_form_template_rule_save     sp_asset_form_template_rule_remove   (421)
//   sp_asset_form_template_evaluate (421 -- the one rule-evaluation engine)
//   sp_asset_valuation_config_* / sp_asset_valuation_calculate (422)
//   sp_asset_option_list_catalog / _get, sp_asset_option_org_save /
//   sp_asset_option_org_override (423 -- organization option lists)
//   sp_asset_taxonomy_list / _category_save / _subcategory_save /
//   _type_save, sp_asset_type_org_default_save (424 -- taxonomy governance)
//   sp_asset_tech_catalog_list, sp_asset_model_get, sp_asset_make_save,
//   sp_asset_model_save, sp_asset_model_transition (425 -- makes / models)
//   sp_asset_firmware_* / sp_asset_model_firmware_list (426 -- firmware)
//   sp_asset_os_* / sp_asset_model_os_list (427 -- operating systems)
//   sp_asset_register_* (428 -- Asset Register)
//   sp_asset_lifecycle_* (429 -- lifecycle transitions and approvals)
//   sp_asset_tech_* / sp_asset_technology_get (430 -- installed technology)
//   sp_asset_attestation_* / sp_asset_custody_get (431 -- custody and attestation)
//   sp_asset_verification_* (432 -- verification exceptions)
//   sp_asset_workflow_* (433 -- owner change, transfer, breakdown, disposal)
//   sp_asset_contract_* (434 -- contracts, versions, vendor contacts, documents)
//   sp_asset_contract_entitlement_* / _coverage_* / sp_asset_coverage_* (435 -- coverage and entitlements)
//   sp_asset_contract_renewal_* (436 -- renewal occurrences and coverage reconciliation)
//   sp_asset_notification_* / sp_asset_escalation_matrix_save / sp_asset_scheduler_* (437 --
//   notification profiles, escalation, occurrences, the scheduler pass run by TaskNotificationWorker)
//   sp_asset_activity_* (438 -- recurring asset activities: templates, schedules, occurrences, campaigns;
//   439 -- results, dispositions; sp_asset_restrictive_* restrictive-use reviews)
//   sp_asset_relationship_* / sp_asset_ci_* (440 -- CMDB relationships, CI lookup, impact analysis)
//   sp_business_service* (441 -- business services, consumers, status rules, conflicts, hierarchy)
//   sp_asset_discovery_* / sp_asset_reconciliation_* (442 -- discovery sources, rules, ingestion, queue, confidence)
//   sp_asset_stale_* / sp_asset_discovery_candidate_get (443 -- stale review, candidate registration)
//   sp_asset_merge_* (444 -- merge events, plan, approval, execution, recovery)
//   sp_asset_split_* (445 -- split events and allocation; actions through sp_asset_merge_action)
//   sp_asset_report_* (452 -- report catalogue, report runs, export log, organization report settings;
//   453 -- schedules, distribution, delivered files, retention; the delivery pass run by TaskNotificationWorker)
//
// Conventions follow OrgSlaConfigService / RoleViewDataScopeService:
// primary-constructor DI, SqlConnectionStringResolver, ViewScopeSession
// on every connection (415), snake_case @-parameters. Every business
// rule (Draft-only edits, baseline fields, segregation of duties,
// readiness gates, concurrency) lives in the procedures, so the UI, this
// API and any future import share one implementation.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IAssetConfigService
{
    Task<object> ListFieldGroupsAsync(CancellationToken ct);
    Task<object> ListFieldDefinitionsAsync(string? groupCode, string? dataTypeCode, string? sensitivityCode,
        string? search, bool placeableOnly, bool includeRetired, int pageNumber, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<Dictionary<string, object?>>> GetTaxonomyAsync(CancellationToken ct);
    Task<object> ListTemplatesAsync(long organizationId, int? assetTypeId, string? statusCode, string? search,
        int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetTemplateAsync(long organizationId, long templateId, CancellationToken ct);
    Task<object?> GetReadinessAsync(long organizationId, long templateId, CancellationToken ct);

    Task<AssetConfigWriteResult> CreateTemplateAsync(AssetTemplateCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> NewVersionAsync(long templateId, AssetTemplateNewVersionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveHeaderAsync(long templateId, AssetTemplateHeaderSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveSectionAsync(long templateId, AssetTemplateSectionSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveFieldAsync(long templateId, AssetTemplateFieldSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> RemoveFieldAsync(long templateId, AssetTemplateFieldRemoveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> TransitionAsync(long templateId, AssetTemplateTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 421 -- conditional rules + preview
    Task<AssetConfigWriteResult> SaveRuleAsync(long templateId, AssetTemplateRuleSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> RemoveRuleAsync(long templateId, AssetTemplateRuleRemoveRequest request, string actor, CancellationToken ct);
    Task<object?> EvaluateAsync(long templateId, AssetTemplateEvaluateRequest request, CancellationToken ct);

    // 422 -- asset valuation configuration
    Task<object> ListValuationAsync(long organizationId, CancellationToken ct);
    Task<object?> GetValuationAsync(long organizationId, long configId, CancellationToken ct);
    Task<object?> GetValuationReadinessAsync(long organizationId, long configId, CancellationToken ct);
    Task<AssetConfigWriteResult> CreateValuationAsync(AssetValuationCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveValuationHeaderAsync(long configId, AssetValuationHeaderSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveValuationItemAsync(long configId, AssetValuationItemSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> TransitionValuationAsync(long configId, AssetValuationTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object?> CalculateValuationAsync(long configId, AssetValuationCalculateRequest request, CancellationToken ct);

    // 423 -- organization option lists
    Task<object> ListOptionListsAsync(long organizationId, string? search, CancellationToken ct);
    Task<object?> GetOptionListAsync(long organizationId, string optionGroup, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveOrgOptionAsync(string optionGroup, AssetOptionOrgSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> OverrideOptionAsync(string optionGroup, AssetOptionOverrideRequest request, string actor, CancellationToken ct);

    // 424 -- taxonomy governance
    Task<object?> GetTaxonomyGovernanceAsync(long organizationId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveTaxonomyCategoryAsync(AssetTaxonomyCategorySaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveTaxonomySubcategoryAsync(AssetTaxonomySubcategorySaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveTaxonomyTypeAsync(AssetTaxonomyTypeSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveTypeOrgDefaultAsync(int assetTypeId, AssetTypeOrgDefaultSaveRequest request, string actor, CancellationToken ct);

    // 425 -- technology catalogue: makes and models
    Task<object?> GetTechCatalogAsync(long organizationId, CancellationToken ct);
    Task<object?> GetModelAsync(long organizationId, long modelId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveMakeAsync(AssetMakeSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveModelAsync(AssetModelSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> TransitionModelAsync(long modelId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 426 -- firmware
    Task<object?> GetFirmwareCatalogAsync(long organizationId, CancellationToken ct);
    Task<object?> GetFirmwareReleaseAsync(long organizationId, long releaseId, CancellationToken ct);
    Task<object?> GetModelFirmwareAsync(long organizationId, long modelId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveFirmwareProductAsync(AssetFirmwareProductSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveFirmwareReleaseAsync(AssetFirmwareReleaseSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> TransitionFirmwareReleaseAsync(long releaseId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveFirmwareCompatAsync(AssetFirmwareCompatSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> ApproveFirmwareCompatAsync(long compatId, AssetCatalogApproveRequest request, string actor, CancellationToken ct);

    // 427 -- operating systems
    Task<object?> GetOsCatalogAsync(long organizationId, CancellationToken ct);
    Task<object?> GetOsReleaseAsync(long organizationId, long releaseId, CancellationToken ct);
    Task<object?> GetModelOsAsync(long organizationId, long modelId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveOsProductAsync(AssetOsProductSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveOsReleaseAsync(AssetOsReleaseSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> TransitionOsReleaseAsync(long releaseId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveOsCompatAsync(AssetOsCompatSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> ApproveOsCompatAsync(long compatId, AssetCatalogApproveRequest request, string actor, CancellationToken ct);

    // 428 -- Asset Register
    Task<object> ListRegisterAsync(long organizationId, string? search, int? assetTypeId, string? statusCode, int pageNumber, int pageSize, bool pendingOnly, CancellationToken ct);
    Task<object?> GetRegisterAssetAsync(long organizationId, long assetId, CancellationToken ct);
    Task<object?> GetRegisterFormAsync(long organizationId, int? assetTypeId, long? templateId, CancellationToken ct);
    Task<object> GetRegisterLookupsAsync(long organizationId, string? sources, CancellationToken ct);
    Task<AssetRegisterSaveResult> SaveRegisterAssetAsync(AssetRegisterSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 429 -- Asset lifecycle transitions
    Task<object?> GetAssetLifecycleAsync(long organizationId, long assetId, CancellationToken ct);
    Task<object> GetLifecycleMatrixAsync(CancellationToken ct);
    Task<AssetLifecycleResult> TransitionAssetAsync(long assetId, AssetLifecycleTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideLifecycleChangeAsync(long changeId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 430 -- Installed technology
    Task<object?> GetAssetTechnologyAsync(long organizationId, long assetId, CancellationToken ct);
    Task<AssetLifecycleResult> RecordInstallationAsync(long assetId, AssetTechInstallRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RequestTechExceptionAsync(long assetId, AssetTechExceptionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideTechExceptionAsync(long exceptionId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 431 -- Custody and attestation
    Task<object?> GetAssetCustodyAsync(long organizationId, long assetId, CancellationToken ct);
    Task<object> GetAttestationProfilesAsync(long organizationId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveAttestationProfileAsync(AssetAttestationProfileSaveRequest request, string actor, CancellationToken ct);
    Task<object> GetAttestationCampaignsAsync(long organizationId, CancellationToken ct);
    Task<(object? Data, int? ErrorNumber, string? Error)> GenerateAttestationsAsync(AssetAttestationGenerateRequest request, string actor, CancellationToken ct);
    Task<object> ListAttestationsAsync(long organizationId, string? scope, string? status, long? campaignId, string? search, long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetLifecycleResult> RespondAttestationAsync(long attestationId, AssetAttestationRespondRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideAttestationAsync(long attestationId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 432 -- Verification exceptions
    Task<object> ListVerificationExceptionsAsync(long organizationId, string? scope, string? status, string? search, long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetVerificationExceptionAsync(long organizationId, long exceptionId, long? actorEmployeeId, CancellationToken ct);
    Task<AssetLifecycleResult> VerificationExceptionActionAsync(long exceptionId, AssetVerificationActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> GetVerificationSettingsAsync(long organizationId, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveVerificationSettingsAsync(AssetVerificationSettingsSaveRequest request, string actor, CancellationToken ct);
    Task<AssetConfigWriteResult> SaveVerificationRuleAsync(AssetVerificationRuleSaveRequest request, string actor, CancellationToken ct);

    // 433 -- Asset workflows
    Task<object> GetWorkflowDefinitionsAsync(long organizationId, CancellationToken ct);
    Task<object> ListWorkflowCasesAsync(long organizationId, long? assetId, bool openOnly, long? actorEmployeeId, CancellationToken ct);
    Task<object?> GetWorkflowCaseAsync(long organizationId, long caseId, long? actorEmployeeId, CancellationToken ct);
    Task<AssetLifecycleResult> StartWorkflowAsync(long assetId, AssetWorkflowStartRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> WorkflowStepAsync(long caseId, AssetWorkflowStepRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> CancelWorkflowAsync(long caseId, AssetWorkflowCancelRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 434 -- Contracts
    Task<object> ListContractsAsync(long organizationId, string? search, string? status, long? vendorId, string? contractType,
        int pageNumber, int pageSize, CancellationToken ct);
    Task<object> GetContractLookupsAsync(long organizationId, CancellationToken ct);
    Task<object?> GetContractAsync(long organizationId, long contractId, long? actorEmployeeId, CancellationToken ct);
    Task<object?> GetContractVersionAsync(long organizationId, long versionId, long? actorEmployeeId, CancellationToken ct);
    Task<object?> CompareContractVersionsAsync(long organizationId, long versionA, long versionB, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveContractAsync(AssetContractSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> CreateContractVersionAsync(long contractId, AssetContractVersionCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveContractVersionAsync(long versionId, AssetContractVersionSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> ContractVersionActionAsync(long versionId, AssetContractVersionActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveContractContactAsync(long contractId, AssetContractContactSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> ContractContactActionAsync(long mappingId, AssetContractContactActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> AddContractDocumentAsync(long versionId, AssetContractDocumentRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RemoveContractDocumentAsync(long documentId, AssetContractDocumentRemoveRequest request, string actor, CancellationToken ct);

    // 435 -- Coverage and entitlements
    Task<object> SearchContractAssetsAsync(long organizationId, string? search, int? assetTypeId, long? versionId, CancellationToken ct);
    Task<object?> GetAssetCoverageAsync(long organizationId, long assetId, CancellationToken ct);
    Task<object> ListCoverageGapsAsync(long organizationId, string? search, string? coverageType, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> GetCoverageConfigAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveEntitlementAsync(long versionId, AssetContractEntitlementRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RemoveEntitlementAsync(long entitlementId, AssetContractLineRemoveRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveCoverageAsync(long versionId, AssetContractCoverageRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> BulkAddCoverageAsync(long versionId, AssetContractCoverageBulkRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RemoveCoverageAsync(long coverageId, AssetContractLineRemoveRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveCoverageRequirementAsync(AssetCoverageRequirementRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveCoverageSettingsAsync(AssetCoverageSettingsRequest request, string actor, CancellationToken ct);

    // 436 -- Renewal occurrences
    Task<object> ListRenewalsAsync(long organizationId, long? contractId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> ListRenewalsDueAsync(long organizationId, int withinDays, CancellationToken ct);
    Task<object?> GetRenewalAsync(long organizationId, long renewalId, long? actorEmployeeId, CancellationToken ct);
    Task<AssetLifecycleResult> StartRenewalAsync(long contractId, AssetContractRenewalStartRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveRenewalAsync(long renewalId, AssetContractRenewalSaveRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RenewalActionAsync(long renewalId, AssetContractRenewalActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> ResolveRenewalItemAsync(long itemId, AssetContractRenewalResolveRequest request, string actor, CancellationToken ct);

    // 437 -- Notification profiles, escalation, occurrences, scheduler
    Task<object> GetNotificationConfigAsync(long organizationId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveNotificationProfileAsync(AssetNotificationProfileRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveEscalationMatrixAsync(AssetEscalationMatrixRequest request, string actor, CancellationToken ct);
    Task<object> ListNotificationOccurrencesAsync(long organizationId, string? status, string? activityCode, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetNotificationOccurrenceAsync(long organizationId, long occurrenceId, CancellationToken ct);
    Task<AssetLifecycleResult> SnoozeNotificationOccurrenceAsync(long occurrenceId, AssetNotificationSnoozeRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> ListNotificationLogAsync(long organizationId, string? statusCode, string? activityCode, string? notificationClass, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetLifecycleResult> ReportNotificationDeliveryAsync(long notificationId, AssetNotificationDeliveryRequest request, string actor, CancellationToken ct);
    Task<object> ListSchedulerRunsAsync(long organizationId, CancellationToken ct);
    /// <summary>One scheduler pass (sp_asset_scheduler_run): every organization when
    /// <paramref name="organizationId"/> is null. Used by TaskNotificationWorker and "Run now".</summary>
    Task<Dictionary<string, object?>> RunSchedulerAsync(long? organizationId, string triggerCode, string actor, CancellationToken ct);
    Task<object> ListMyNotificationsAsync(long employeeId, string? filter, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> CountMyNotificationsAsync(long employeeId, CancellationToken ct);
    Task<AssetLifecycleResult> MyNotificationActionAsync(long employeeId, long notificationId, AssetNotificationMineActionRequest request, string actor, CancellationToken ct);
    Task<int> ReadAllMyNotificationsAsync(long employeeId, CancellationToken ct);

    // 438 -- Recurring asset activities
    Task<object> GetActivityConfigAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveActivitySettingAsync(AssetActivitySettingRequest request, string actor, CancellationToken ct);
    Task<object> ListActivitySchedulesAsync(long organizationId, string? templateCode, string? status, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct);
    Task<object> ListActivityOccurrencesAsync(long organizationId, string? templateCode, string? status, bool reconcileOnly, long? campaignId, string? search, bool awaitingDecision, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> ListActivityCampaignsAsync(long organizationId, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetLifecycleResult> ReconcileActivityAsync(long occurrenceId, AssetActivityReconcileRequest request, string actor, CancellationToken ct);

    // 439 -- Results, dispositions, restrictive-use reviews
    Task<object?> GetActivityOccurrenceAsync(long organizationId, long occurrenceId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveActivityResultAsync(long occurrenceId, AssetActivityResultRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideActivityResultAsync(long occurrenceId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RequestActivityDispositionAsync(long occurrenceId, AssetActivityDispositionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideActivityDispositionAsync(long dispositionId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> ListRestrictiveReviewsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideRestrictiveReviewAsync(long reviewId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 440 -- CMDB relationships
    Task<object> GetRelationshipConfigAsync(long organizationId, CancellationToken ct);
    Task<object> LookupCisAsync(long organizationId, string? ciKind, string? search, CancellationToken ct);
    Task<object> ListRelationshipsAsync(long organizationId, string? ciKind, long? ciId, string? typeCode, string? status, bool criticalOnly, bool pendingOnly, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct);
    Task<object?> GetRelationshipAsync(long organizationId, long relationshipId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveRelationshipAsync(AssetRelationshipSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RelationshipActionAsync(long relationshipId, AssetRelationshipActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> GetImpactAsync(long organizationId, string ciKind, long ciId, string direction, int maxDepth, bool criticalOnly, long? previewRelationshipId, CancellationToken ct);

    // 441 -- Business services
    Task<object> GetBusinessServiceConfigAsync(long organizationId, CancellationToken ct);
    Task<object> ListBusinessServicesAsync(long organizationId, string? status, string? serviceType, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetBusinessServiceAsync(long organizationId, long serviceId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveBusinessServiceAsync(BusinessServiceSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> TransitionBusinessServiceAsync(long serviceId, BusinessServiceTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> DecideBusinessServiceRetirementAsync(long serviceId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveBusinessServiceSettingAsync(BusinessServiceSettingRequest request, string actor, CancellationToken ct);
    Task<object> ListBusinessServiceConflictsAsync(long organizationId, long? serviceId, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> GetBusinessServiceTreeAsync(long organizationId, CancellationToken ct);

    // 442 -- Asset discovery and reconciliation
    Task<object> GetDiscoveryConfigAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveDiscoverySourceAsync(AssetDiscoverySourceRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveDiscoveryPrioritiesAsync(long sourceId, AssetDiscoveryPrioritiesRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveIdentificationRuleAsync(AssetIdentificationRuleRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveDiscoverySettingAsync(AssetDiscoverySettingRequest request, string actor, CancellationToken ct);
    Task<(object? Data, int? ErrorNumber, string? Error)> IngestDiscoveryBatchAsync(long sourceId, AssetDiscoveryIngestRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> ListDiscoveryBatchesAsync(long organizationId, long? sourceId, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetDiscoveryBatchAsync(long organizationId, long batchId, CancellationToken ct);
    Task<object> ListReconciliationExceptionsAsync(long organizationId, string? status, string? kind, long? sourceId, long? assetId, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetLifecycleResult> ResolveReconciliationExceptionAsync(long exceptionId, AssetReconciliationResolveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> ListDiscoveryConfidenceAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetDiscoveryAssetAsync(long organizationId, long assetId, CancellationToken ct);

    // 443 -- Discovery follow-up: candidate registration, stale review
    Task<object?> GetDiscoveryCandidateAsync(long organizationId, long exceptionId, CancellationToken ct);
    Task<object> ListStaleReviewsAsync(long organizationId, string? view, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetStaleReviewAsync(long organizationId, long assetId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveStaleSettingAsync(AssetStaleSettingRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> OpenStaleReviewAsync(AssetStaleReviewOpenRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> StaleReviewActionAsync(long reviewId, AssetStaleReviewActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 444 -- Asset merge
    Task<object> ListMergesAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetMergeAsync(long organizationId, long eventId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveMergeAsync(AssetMergeSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> MergeActionAsync(long eventId, AssetMergeActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 445 -- Asset split (actions: MergeActionAsync, one procedure for both kinds)
    Task<object> ListSplitsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetSplitAsync(long organizationId, long eventId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveSplitAsync(AssetSplitSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 446 -- Asset Value per asset
    Task<object?> GetAssetValuationAsync(long organizationId, long assetId, CancellationToken ct);
    Task<AssetLifecycleResult> RecalculateAssetValuationAsync(long assetId, AssetValuationRecalculateRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SetAssetValuationMethodAsync(long assetId, AssetValuationMethodRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> GetValuationRecalcPreviewAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> RunValuationRecalcAsync(AssetValuationRecalcRunRequest request, long? actorEmployeeId, string actor, CancellationToken ct);

    // 447 -- CIA and criticality consistency rules
    Task<object> ListConsistencyRulesAsync(long organizationId, CancellationToken ct);
    Task<object?> GetConsistencyRuleAsync(long organizationId, long ruleId, CancellationToken ct);
    Task<object> GetConsistencyOperandsAsync(long organizationId, CancellationToken ct);
    Task<object?> PreviewConsistencyRuleAsync(long organizationId, long ruleId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveConsistencyRuleAsync(AssetConsistencyRuleSaveRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> ConsistencyRuleActionAsync(long ruleId, AssetConsistencyRuleActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<object> ListConsistencyFindingsAsync(long organizationId, string? status, string? severity, long? assetId, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetLifecycleResult> ConsistencyFindingActionAsync(long findingId, AssetConsistencyFindingActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RunConsistencyAsync(AssetConsistencyRunRequest request, string actor, CancellationToken ct);

    // 448 -- Asset privacy
    Task<object> ListPrivacyAssetsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct);
    Task<object?> GetPrivacyAssetAsync(long organizationId, long assetId, CancellationToken ct);
    Task<object> ListPrivacyExceptionsAsync(long organizationId, string? status, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> ListPrivacyReviewsAsync(long organizationId, string? status, string? kind, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> GetPrivacyRequirementsAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> SavePrivacySettingAsync(AssetPrivacySettingRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RequestPrivacyExceptionAsync(AssetPrivacyExceptionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> PrivacyExceptionActionAsync(long exceptionId, AssetPrivacyExceptionActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> CompletePrivacyReviewAsync(long reviewId, AssetPrivacyReviewCompleteRequest request, long? actorEmployeeId, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> RunPrivacyAsync(AssetPrivacyRunRequest request, string actor, CancellationToken ct);

    // 450 -- Asset governance KPIs
    Task<object?> GetGovernanceAsync(long organizationId, long? snapshotId, int trendDays, CancellationToken ct);
    Task<object?> ListGovernanceItemsAsync(long organizationId, long snapshotId, string kpiCode, string? outcome, string? search,
        int pageNumber, int pageSize, CancellationToken ct);
    Task<object> ListGovernanceSnapshotsAsync(long organizationId, int pageNumber, int pageSize, CancellationToken ct);
    Task<object> GetGovernanceSettingsAsync(long organizationId, CancellationToken ct);
    Task<AssetLifecycleResult> SaveGovernanceSettingAsync(AssetGovernanceSettingRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveGovernanceOrgSettingAsync(AssetGovernanceOrgSettingRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> SaveGovernanceRelationshipRuleAsync(AssetGovernanceRelationshipRuleRequest request, string actor, CancellationToken ct);
    Task<AssetLifecycleResult> TakeGovernanceSnapshotAsync(AssetGovernanceSnapshotRequest request, string actor, CancellationToken ct);

    // 452 -- Report catalogue and exports. allowedAreas: the screens the caller may VIEW (Web tier, from the session).
    Task<object?> GetReportCatalogueAsync(long organizationId, string? allowedAreas, bool canApprove, CancellationToken ct);
    Task<AssetReportResult> RunReportAsync(AssetReportRunRequest request, string? allowedAreas, bool canApprove, int pageNumber, int pageSize,
        CancellationToken ct);
    Task<AssetReportResult> ExportReportAsync(AssetReportRunRequest request, string? allowedAreas, bool canApprove, string actor,
        long? actorEmployeeId, CancellationToken ct);
    Task<object?> ListReportExportsAsync(long organizationId, string? allowedAreas, string? reportCode, int pageNumber, int pageSize,
        CancellationToken ct);
    Task<AssetLifecycleResult> SaveReportSettingAsync(AssetReportSettingRequest request, string? allowedAreas, string actor, CancellationToken ct);

    // 453 -- Report schedules, distribution and delivered files
    Task<object?> GetReportSchedulesAsync(long organizationId, string? allowedAreas, CancellationToken ct);
    Task<AssetLifecycleResult> SaveReportScheduleAsync(AssetReportScheduleRequest request, string? allowedAreas, string actor,
        long? actorEmployeeId, CancellationToken ct);
    Task<AssetReportResult> RunReportScheduleNowAsync(long organizationId, long scheduleId, string? allowedAreas, string actor, CancellationToken ct);
    /// <summary>The scheduled delivery pass (TaskNotificationWorker): every schedule due today, every organization
    /// (or one).</summary>
    Task<AssetReportDeliveryPassResult> RunReportDeliveriesAsync(long? organizationId, CancellationToken ct);
    Task<object?> ListReportDeliveriesAsync(long organizationId, string? allowedAreas, long? scheduleId, int pageNumber, int pageSize,
        CancellationToken ct);
    Task<AssetReportResult> ListReportDeliveryRecipientsAsync(long organizationId, long deliveryId, string? allowedAreas, CancellationToken ct);
    Task<object> ListMyReportDeliveriesAsync(long organizationId, long? employeeId, int pageNumber, int pageSize, CancellationToken ct);
    Task<AssetReportResult> DownloadReportDeliveryAsync(long organizationId, long deliveryRecipientId, long? employeeId, string? allowedAreas,
        bool canApprove, string actor, CancellationToken ct);
}

public sealed class AssetConfigService(
    IConfiguration configuration,
    ILogger<AssetConfigService> logger) : IAssetConfigService
{
    // ----------------------------------------------------------------
    // Dictionary
    // ----------------------------------------------------------------
    public async Task<object> ListFieldGroupsAsync(CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_field_group_list");
        await using var reader = await command.ExecuteReaderAsync(ct);
        var groups = await ReadRowsAsync(reader, ct);
        var dataTypes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { groups, dataTypes };
    }

    public async Task<object> ListFieldDefinitionsAsync(string? groupCode, string? dataTypeCode, string? sensitivityCode,
        string? search, bool placeableOnly, bool includeRetired, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_field_definition_list");
        AddParam(command, "@group_code",       DbType.String,  Blank(groupCode), 60);
        AddParam(command, "@data_type_code",   DbType.String,  Blank(dataTypeCode), 30);
        AddParam(command, "@sensitivity_code", DbType.String,  Blank(sensitivityCode), 20);
        AddParam(command, "@search",           DbType.String,  Blank(search), 200);
        AddParam(command, "@placeable_only",   DbType.Boolean, placeableOnly);
        AddParam(command, "@include_retired",  DbType.Boolean, includeRetired);
        AddParam(command, "@page_number",      DbType.Int32,   pageNumber);
        AddParam(command, "@page_size",        DbType.Int32,   pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<IReadOnlyList<Dictionary<string, object?>>> GetTaxonomyAsync(CancellationToken ct)
    {
        // 241's lookup; its seven gateway parameters all have defaults.
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_get_asset_taxonomy_lookup");
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    // ----------------------------------------------------------------
    // Templates -- reads
    // ----------------------------------------------------------------
    public async Task<object> ListTemplatesAsync(long organizationId, int? assetTypeId, string? statusCode, string? search,
        int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_form_template_list");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@asset_type_id",   DbType.Int32,  assetTypeId);
        AddParam(command, "@status_code",     DbType.String, Blank(statusCode), 60);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetTemplateAsync(long organizationId, long templateId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_form_template_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@template_id",     DbType.Int64, templateId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadTemplateDetailAsync(reader, ct);
    }

    /// <summary>Reads the result sets of sp_asset_form_template_get -- used
    /// by the template designer and by the register form (428), which
    /// returns the same sets.</summary>
    private static async Task<object?> ReadTemplateDetailAsync(DbDataReader reader, CancellationToken ct)
    {
        var header = await ReadRowsAsync(reader, ct);
        if (header.Count == 0) return null;
        var sections = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var fields   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var history  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        // 421: rules, their conditions, and the option values of the
        // template's OPTION: fields (empty when 421 is not deployed).
        var rules      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var conditions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var options    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { header = header[0], sections, fields, history, rules, conditions, options };
    }

    public async Task<object?> GetReadinessAsync(long organizationId, long templateId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_form_template_readiness");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@template_id",     DbType.Int64, templateId);
            var errors   = Output(command, "@out_error_count", DbType.Int32);
            var warnings = Output(command, "@out_warning_count", DbType.Int32);
            List<Dictionary<string, object?>> issues;
            await using (var reader = await command.ExecuteReaderAsync(ct))
                issues = await ReadRowsAsync(reader, ct);
            // OUTPUT values are available once the reader is closed.
            return new
            {
                issues,
                errorCount   = errors.Value   is DBNull or null ? 0 : Convert.ToInt32(errors.Value),
                warningCount = warnings.Value is DBNull or null ? 0 : Convert.ToInt32(warnings.Value)
            };
        }
        catch (SqlException ex) when (ex.Number == 54202) { return null; }
    }

    // ----------------------------------------------------------------
    // Templates -- writes
    // ----------------------------------------------------------------
    public Task<AssetConfigWriteResult> CreateTemplateAsync(AssetTemplateCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_create", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_type_id",              DbType.Int32,  request.AssetTypeId);
            AddParam(command, "@template_name",              DbType.String, request.TemplateName, 200);
            AddParam(command, "@change_reason",              DbType.String, Blank(request.ChangeReason), 1000);
            AddParam(command, "@template_owner_employee_id", DbType.Int64,  request.TemplateOwnerEmployeeId);
            AddParam(command, "@actor_employee_id",          DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                      DbType.String, actor, 100);
            return Output(command, "@out_template_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> NewVersionAsync(long templateId, AssetTemplateNewVersionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_new_version", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_template_id", DbType.Int64,  templateId);
            AddParam(command, "@change_reason",      DbType.String, request.ChangeReason, 1000);
            AddParam(command, "@actor_employee_id",  DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",              DbType.String, actor, 100);
            return Output(command, "@out_template_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> SaveHeaderAsync(long templateId, AssetTemplateHeaderSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_header_save", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@template_id",                DbType.Int64,   templateId);
            AddParam(command, "@template_name",              DbType.String,  request.TemplateName, 200);
            AddParam(command, "@approval_required",          DbType.Boolean, request.ApprovalRequired);
            AddParam(command, "@template_owner_employee_id", DbType.Int64,   request.TemplateOwnerEmployeeId);
            AddParam(command, "@effective_from",             DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",               DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@change_reason",              DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@expected_record_version",    DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
            return null;
        }, ct, templateId);

    public Task<AssetConfigWriteResult> SaveSectionAsync(long templateId, AssetTemplateSectionSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_section_save", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@template_id",     DbType.Int64,   templateId);
            AddParam(command, "@section_id",      DbType.Int64,   request.SectionId);
            AddParam(command, "@section_label",   DbType.String,  request.SectionLabel, 150);
            AddParam(command, "@tab_label",       DbType.String,  Blank(request.TabLabel), 150);
            AddParam(command, "@layout_columns",  DbType.Byte,    request.LayoutColumns);
            AddParam(command, "@display_order",   DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@is_active",       DbType.Boolean, request.IsActive);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
            return Output(command, "@out_section_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> SaveFieldAsync(long templateId, AssetTemplateFieldSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_field_save", command =>
        {
            AddParam(command, "@organization_id",          DbType.Int64,   request.OrganizationId);
            AddParam(command, "@template_id",              DbType.Int64,   templateId);
            AddParam(command, "@field_definition_id",      DbType.Int32,   request.FieldDefinitionId);
            AddParam(command, "@section_id",               DbType.Int64,   request.SectionId);
            AddParam(command, "@display_order",            DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@is_visible",               DbType.Boolean, request.IsVisible ?? true);
            AddParam(command, "@is_mandatory",             DbType.Boolean, request.IsMandatory ?? false);
            AddParam(command, "@is_read_only",             DbType.Boolean, request.IsReadOnly ?? false);
            AddParam(command, "@default_value",            DbType.String,  Blank(request.DefaultValue), 400);
            AddParam(command, "@help_text",                DbType.String,  Blank(request.HelpText), 500);
            AddParam(command, "@placeholder_text",         DbType.String,  Blank(request.PlaceholderText), 200);
            AddParam(command, "@hidden_value_behavior",    DbType.String,  Blank(request.HiddenValueBehavior) ?? "RETAIN", 10);
            AddParam(command, "@sensitivity_override",     DbType.String,  Blank(request.SensitivityOverride), 20);
            AddParam(command, "@include_in_import_export", DbType.Boolean, request.IncludeInImportExport ?? true);
            AddParam(command, "@is_searchable",            DbType.Boolean, request.IsSearchable ?? false);
            AddParam(command, "@evidence_required",        DbType.Boolean, request.EvidenceRequired ?? false);
            AddParam(command, "@actor",                    DbType.String,  actor, 100);
            return null;
        }, ct, templateId);

    public Task<AssetConfigWriteResult> RemoveFieldAsync(long templateId, AssetTemplateFieldRemoveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_field_remove", command =>
        {
            AddParam(command, "@organization_id",     DbType.Int64,  request.OrganizationId);
            AddParam(command, "@template_id",         DbType.Int64,  templateId);
            AddParam(command, "@field_definition_id", DbType.Int32,  request.FieldDefinitionId);
            AddParam(command, "@actor",               DbType.String, actor, 100);
            return null;
        }, ct, templateId);

    public Task<AssetConfigWriteResult> TransitionAsync(long templateId, AssetTemplateTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_transition", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@template_id",             DbType.Int64,  templateId);
            AddParam(command, "@to_status_code",          DbType.String, request.ToStatusCode, 60);
            AddParam(command, "@reason_text",             DbType.String, Blank(request.ReasonText), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
            return null;
        }, ct, templateId);

    // ----------------------------------------------------------------
    // 421 -- conditional rules + preview
    // ----------------------------------------------------------------
    public Task<AssetConfigWriteResult> SaveRuleAsync(long templateId, AssetTemplateRuleSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_rule_save", command =>
        {
            var conditions = System.Text.Json.JsonSerializer.Serialize((request.Conditions ?? Array.Empty<AssetTemplateRuleCondition>()).Select(c => new
            {
                groupNo = c.GroupNo ?? 1,
                sourceFieldDefinitionId = c.SourceFieldDefinitionId,
                operatorCode = c.OperatorCode,
                compareValue = c.CompareValue
            }));
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@template_id",                DbType.Int64,   templateId);
            AddParam(command, "@rule_id",                    DbType.Int64,   request.RuleId);
            AddParam(command, "@rule_name",                  DbType.String,  Blank(request.RuleName), 200);
            AddParam(command, "@target_field_definition_id", DbType.Int32,   request.TargetFieldDefinitionId);
            AddParam(command, "@action_code",                DbType.String,  request.ActionCode, 20);
            AddParam(command, "@conditions_json",            DbType.String,  conditions);
            AddParam(command, "@is_active",                  DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@display_order",              DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
            return Output(command, "@out_rule_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> RemoveRuleAsync(long templateId, AssetTemplateRuleRemoveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_form_template_rule_remove", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@template_id",     DbType.Int64,  templateId);
            AddParam(command, "@rule_id",         DbType.Int64,  request.RuleId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            return null;
        }, ct, request.RuleId);

    public async Task<object?> EvaluateAsync(long templateId, AssetTemplateEvaluateRequest request, CancellationToken ct)
    {
        try
        {
            var values = request.Values is { ValueKind: System.Text.Json.JsonValueKind.Object } v ? v.GetRawText() : "{}";
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_form_template_evaluate");
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@template_id",     DbType.Int64,  templateId);
            AddParam(command, "@values_json",     DbType.String, values);
            await using var reader = await command.ExecuteReaderAsync(ct);
            return new { fields = await ReadRowsAsync(reader, ct) };
        }
        catch (SqlException ex) when (ex.Number == 54202) { return null; }
    }

    // ----------------------------------------------------------------
    // 422 -- asset valuation configuration
    // ----------------------------------------------------------------
    public async Task<object> ListValuationAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_valuation_config_list");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return new { rows = await ReadRowsAsync(reader, ct) };
    }

    public async Task<object?> GetValuationAsync(long organizationId, long configId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_valuation_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@config_id",       DbType.Int64, configId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var header = await ReadRowsAsync(reader, ct);
        if (header.Count == 0) return null;
        var ciaLevels   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var bands       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var criticality = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var history     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var criticalityMaster = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { header = header[0], ciaLevels, bands, criticality, history, criticalityMaster };
    }

    public async Task<object?> GetValuationReadinessAsync(long organizationId, long configId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_valuation_config_readiness");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@config_id",       DbType.Int64, configId);
            var errors   = Output(command, "@out_error_count", DbType.Int32);
            var warnings = Output(command, "@out_warning_count", DbType.Int32);
            List<Dictionary<string, object?>> issues;
            await using (var reader = await command.ExecuteReaderAsync(ct))
                issues = await ReadRowsAsync(reader, ct);
            return new
            {
                issues,
                errorCount   = errors.Value   is DBNull or null ? 0 : Convert.ToInt32(errors.Value),
                warningCount = warnings.Value is DBNull or null ? 0 : Convert.ToInt32(warnings.Value)
            };
        }
        catch (SqlException ex) when (ex.Number == 54251) { return null; }
    }

    public Task<AssetConfigWriteResult> CreateValuationAsync(AssetValuationCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_valuation_config_create", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@config_name",       DbType.String, Blank(request.ConfigName), 200);
            AddParam(command, "@source_config_id",  DbType.Int64,  request.SourceConfigId);
            AddParam(command, "@change_reason",     DbType.String, Blank(request.ChangeReason), 1000);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
            return Output(command, "@out_config_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> SaveValuationHeaderAsync(long configId, AssetValuationHeaderSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_valuation_config_header_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@config_id",               DbType.Int64,   configId);
            AddParam(command, "@config_name",             DbType.String,  request.ConfigName, 200);
            AddParam(command, "@valuation_method",        DbType.String,  request.ValuationMethod, 30);
            AddParam(command, "@weight_c",                DbType.Decimal, request.WeightC);
            AddParam(command, "@weight_i",                DbType.Decimal, request.WeightI);
            AddParam(command, "@weight_a",                DbType.Decimal, request.WeightA);
            AddParam(command, "@decimal_places",          DbType.Byte,    request.DecimalPlaces);
            AddParam(command, "@rounding_mode",           DbType.String,  request.RoundingMode, 20);
            AddParam(command, "@override_allowed",        DbType.Boolean, request.OverrideAllowed);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@change_reason",           DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return null;
        }, ct, configId);

    public Task<AssetConfigWriteResult> SaveValuationItemAsync(long configId, AssetValuationItemSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_valuation_config_item_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@config_id",               DbType.Int64,   configId);
            AddParam(command, "@item_kind",               DbType.String,  request.ItemKind, 20);
            AddParam(command, "@item_id",                 DbType.Int64,   request.ItemId);
            AddParam(command, "@remove",                  DbType.Boolean, request.Remove ?? false);
            AddParam(command, "@dimension_code",          DbType.StringFixedLength, Blank(request.DimensionCode), 1);
            AddParam(command, "@score",                   DbType.Int32,   request.Score);
            AddParam(command, "@min_score",               DbType.Decimal, request.MinScore);
            AddParam(command, "@max_score",               DbType.Decimal, request.MaxScore);
            AddParam(command, "@label",                   DbType.String,  Blank(request.Label), 100);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 500);
            AddParam(command, "@review_frequency_months", DbType.Int32,   request.ReviewFrequencyMonths);
            AddParam(command, "@criticality_master_id",   DbType.Int32,   request.CriticalityMasterId);
            AddParam(command, "@display_order",           DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_item_id", DbType.Int64);
        }, ct);

    public Task<AssetConfigWriteResult> TransitionValuationAsync(long configId, AssetValuationTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_valuation_config_transition", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@config_id",               DbType.Int64,  configId);
            AddParam(command, "@to_status_code",          DbType.String, request.ToStatusCode, 60);
            AddParam(command, "@reason_text",             DbType.String, Blank(request.ReasonText), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
            return null;
        }, ct, configId);

    public async Task<object?> CalculateValuationAsync(long configId, AssetValuationCalculateRequest request, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_valuation_calculate");
            AddParam(command, "@organization_id", DbType.Int64, request.OrganizationId);
            AddParam(command, "@config_id",       DbType.Int64, configId);
            AddParam(command, "@confidentiality", DbType.Int32, request.Confidentiality);
            AddParam(command, "@integrity",       DbType.Int32, request.Integrity);
            AddParam(command, "@availability",    DbType.Int32, request.Availability);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            return rows.Count > 0 ? rows[0] : new Dictionary<string, object?>();
        }
        catch (SqlException ex) when (ex.Number == 54251) { return null; }
    }

    // ----------------------------------------------------------------
    // 423 -- organization option lists
    // ----------------------------------------------------------------
    public async Task<object> ListOptionListsAsync(long organizationId, string? search, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_option_list_catalog");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object?> GetOptionListAsync(long organizationId, string optionGroup, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_option_list_get");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@option_group",    DbType.String, optionGroup, 120);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var list    = await ReadRowsAsync(reader, ct);
            if (list.Count == 0) return null;
            var values  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            var parents = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { list = list[0], values, parents };
        }
        catch (SqlException ex) when (ex.Number == 54270) { return null; }
    }

    public Task<AssetConfigWriteResult> SaveOrgOptionAsync(string optionGroup, AssetOptionOrgSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_option_org_save", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@option_group",    DbType.String, optionGroup, 120);
            AddParam(command, "@org_option_id",   DbType.Int64,  request.OrgOptionId);
            AddParam(command, "@option_value",    DbType.String, Blank(request.OptionValue), 160);
            AddParam(command, "@option_label",    DbType.String, Blank(request.OptionLabel), 200);
            AddParam(command, "@parent_value",    DbType.String, Blank(request.ParentValue), 160);
            AddParam(command, "@display_order",   DbType.Int32,  request.DisplayOrder);
            AddParam(command, "@status",          DbType.String, Blank(request.Status) ?? "Active", 30);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            return Output(command, "@out_org_option_id", DbType.Int64);
        }, ct, request.OrgOptionId);

    public Task<AssetConfigWriteResult> OverrideOptionAsync(string optionGroup, AssetOptionOverrideRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_option_org_override", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@option_group",    DbType.String,  optionGroup, 120);
            AddParam(command, "@option_value",    DbType.String,  Blank(request.OptionValue), 160);
            AddParam(command, "@option_label",    DbType.String,  Blank(request.OptionLabel), 200);
            AddParam(command, "@display_order",   DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@hidden",          DbType.Boolean, request.Hidden ?? false);
            AddParam(command, "@reset",           DbType.Boolean, request.Reset ?? false);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
            return null;
        }, ct);

    // ----------------------------------------------------------------
    // 424 -- taxonomy governance
    // ----------------------------------------------------------------
    public async Task<object?> GetTaxonomyGovernanceAsync(long organizationId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_taxonomy_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var categories    = await ReadRowsAsync(reader, ct);
            var subcategories = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var types         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var criticality   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var roles         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var teams         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { categories, subcategories, types, criticality, roles, teams };
        }
        catch (SqlException ex) when (ex.Number == 54291) { return null; }
    }

    public Task<AssetConfigWriteResult> SaveTaxonomyCategoryAsync(AssetTaxonomyCategorySaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_taxonomy_category_save", command =>
        {
            AddParam(command, "@category_id",             DbType.Int32,   request.CategoryId);
            AddParam(command, "@category_name",           DbType.String,  Blank(request.CategoryName), 160);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@sector",                  DbType.String,  Blank(request.Sector), 120);
            AddParam(command, "@owner_name",              DbType.String,  Blank(request.OwnerName), 200);
            AddParam(command, "@standards",               DbType.String,  Blank(request.Standards), 1000);
            AddParam(command, "@default_criticality_id",  DbType.Int32,   request.DefaultCriticalityId);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@display_order",           DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_category_id", DbType.Int32);
        }, ct, request.CategoryId);

    public Task<AssetConfigWriteResult> SaveTaxonomySubcategoryAsync(AssetTaxonomySubcategorySaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_taxonomy_subcategory_save", command =>
        {
            AddParam(command, "@subcategory_id",          DbType.Int32,   request.SubcategoryId);
            AddParam(command, "@category_id",             DbType.Int32,   request.CategoryId);
            AddParam(command, "@parent_subcategory_id",   DbType.Int32,   request.ParentSubcategoryId);
            AddParam(command, "@subcategory_name",        DbType.String,  Blank(request.SubcategoryName), 200);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@display_order",           DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_subcategory_id", DbType.Int32);
        }, ct, request.SubcategoryId);

    public Task<AssetConfigWriteResult> SaveTaxonomyTypeAsync(AssetTaxonomyTypeSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_taxonomy_type_save", command =>
        {
            AddParam(command, "@asset_type_id",           DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@subcategory_id",          DbType.Int32,   request.SubcategoryId);
            AddParam(command, "@asset_type_name",         DbType.String,  Blank(request.AssetTypeName), 200);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@default_criticality_id",  DbType.Int32,   request.DefaultCriticalityId);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@display_order",           DbType.Int32,   request.DisplayOrder);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_asset_type_id", DbType.Int32);
        }, ct, request.AssetTypeId);

    public Task<AssetConfigWriteResult> SaveTypeOrgDefaultAsync(int assetTypeId, AssetTypeOrgDefaultSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_type_org_default_save", command =>
        {
            AddParam(command, "@organization_id",        DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_type_id",          DbType.Int32,  assetTypeId);
            AddParam(command, "@business_owner_role_id", DbType.Int64,  request.BusinessOwnerRoleId);
            AddParam(command, "@support_team_id",        DbType.Int64,  request.SupportTeamId);
            AddParam(command, "@actor",                  DbType.String, actor, 100);
            return null;
        }, ct, assetTypeId);

    // ----------------------------------------------------------------
    // 425 -- technology catalogue: makes and models
    // ----------------------------------------------------------------
    public async Task<object?> GetTechCatalogAsync(long organizationId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_tech_catalog_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var makes       = await ReadRowsAsync(reader, ct);
            var models      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var assetTypes  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var criticality = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { makes, models, assetTypes, criticality };
        }
        catch (SqlException ex) when (ex.Number == 54800) { return null; }
    }

    public async Task<object?> GetModelAsync(long organizationId, long modelId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_model_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@model_id",        DbType.Int64, modelId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var lifecycleEvents = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { model = header[0], lifecycleEvents, history };
        }
        catch (SqlException ex) when (ex.Number == 54807) { return null; }
    }

    public Task<AssetConfigWriteResult> SaveMakeAsync(AssetMakeSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_make_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@make_id",                 DbType.Int32,   request.MakeId);
            AddParam(command, "@make_name",               DbType.String,  Blank(request.MakeName), 200);
            AddParam(command, "@legal_name",              DbType.String,  Blank(request.LegalName), 300);
            AddParam(command, "@aliases",                 DbType.String,  Blank(request.Aliases), 1000);
            AddParam(command, "@support_portal_url",      DbType.String,  Blank(request.SupportPortalUrl), 500);
            AddParam(command, "@security_advisory_url",   DbType.String,  Blank(request.SecurityAdvisoryUrl), 500);
            AddParam(command, "@support_contact",         DbType.String,  Blank(request.SupportContact), 300);
            AddParam(command, "@support_region",          DbType.String,  Blank(request.SupportRegion), 200);
            AddParam(command, "@owner_name",              DbType.String,  Blank(request.OwnerName), 200);
            AddParam(command, "@authoritative_source",    DbType.String,  Blank(request.AuthoritativeSource), 500);
            AddParam(command, "@verified_date",           DbType.Date,    request.VerifiedDate?.Date);
            AddParam(command, "@verified_by",             DbType.String,  Blank(request.VerifiedBy), 200);
            AddParam(command, "@effective_date",          DbType.Date,    request.EffectiveDate?.Date);
            AddParam(command, "@status",                  DbType.String,  Blank(request.Status) ?? "Active", 30);
            AddParam(command, "@asset_type_ids",          DbType.String,
                request.AssetTypeIds is null ? null : string.Join(",", request.AssetTypeIds.Where(id => id > 0).Distinct()), -1);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_make_id", DbType.Int32);
        }, ct, request.MakeId);

    public Task<AssetConfigWriteResult> SaveModelAsync(AssetModelSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_model_save", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                     DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@model_id",                   DbType.Int64,   request.ModelId);
            AddParam(command, "@make_id",                    DbType.Int32,   request.MakeId);
            AddParam(command, "@asset_type_id",              DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@model_name",                 DbType.String,  Blank(request.ModelName), 200);
            AddParam(command, "@model_number",               DbType.String,  Blank(request.ModelNumber), 120);
            AddParam(command, "@family_series",              DbType.String,  Blank(request.FamilySeries), 200);
            AddParam(command, "@variant",                    DbType.String,  Blank(request.Variant), 120);
            AddParam(command, "@sku",                        DbType.String,  Blank(request.Sku), 120);
            AddParam(command, "@announcement_date",          DbType.Date,    request.AnnouncementDate?.Date);
            AddParam(command, "@release_date",               DbType.Date,    request.ReleaseDate?.Date);
            AddParam(command, "@end_of_sale_date",           DbType.Date,    request.EndOfSaleDate?.Date);
            AddParam(command, "@end_standard_support_date",  DbType.Date,    request.EndStandardSupportDate?.Date);
            AddParam(command, "@end_security_support_date",  DbType.Date,    request.EndSecuritySupportDate?.Date);
            AddParam(command, "@end_extended_support_date",  DbType.Date,    request.EndExtendedSupportDate?.Date);
            AddParam(command, "@end_of_life_date",           DbType.Date,    request.EndOfLifeDate?.Date);
            AddParam(command, "@architecture",               DbType.String,  Blank(request.Architecture), 120);
            AddParam(command, "@hardware_revision",          DbType.String,  Blank(request.HardwareRevision), 120);
            AddParam(command, "@specifications",             DbType.String,  Blank(request.Specifications), -1);
            AddParam(command, "@source_reference",           DbType.String,  Blank(request.SourceReference), 500);
            AddParam(command, "@verified_date",              DbType.Date,    request.VerifiedDate?.Date);
            AddParam(command, "@verified_by",                DbType.String,  Blank(request.VerifiedBy), 200);
            AddParam(command, "@criticality_id",             DbType.Int32,   request.CriticalityId);
            AddParam(command, "@replacement_lead_time_days", DbType.Int32,   request.ReplacementLeadTimeDays);
            AddParam(command, "@lifecycle_risk",             DbType.String,  Blank(request.LifecycleRisk), 200);
            AddParam(command, "@controls",                   DbType.String,  Blank(request.Controls), 1000);
            AddParam(command, "@lifecycle_status",           DbType.String,  Blank(request.LifecycleStatus) ?? "CURRENT", 30);
            AddParam(command, "@change_reason",              DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@expected_record_version",    DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",          DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
            return Output(command, "@out_model_id", DbType.Int64);
        }, ct, request.ModelId);

    public Task<AssetConfigWriteResult> TransitionModelAsync(long modelId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        CatalogTransitionAsync("grac_practice.sp_asset_model_transition", "@model_id", modelId, request, actorEmployeeId, actor, ct);

    // ----------------------------------------------------------------
    // 426 -- firmware
    // ----------------------------------------------------------------
    public async Task<object?> GetFirmwareCatalogAsync(long organizationId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_firmware_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var products = await ReadRowsAsync(reader, ct);
            var releases = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { products, releases };
        }
        catch (SqlException ex) when (ex.Number == 54850) { return null; }
    }

    public async Task<object?> GetFirmwareReleaseAsync(long organizationId, long releaseId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_firmware_release_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@release_id",      DbType.Int64, releaseId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var compatibility   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var lifecycleEvents = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { release = header[0], compatibility, lifecycleEvents, history };
        }
        catch (SqlException ex) when (ex.Number == 54857) { return null; }
    }

    public async Task<object?> GetModelFirmwareAsync(long organizationId, long modelId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_model_firmware_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@model_id",        DbType.Int64, modelId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            return await ReadRowsAsync(reader, ct);
        }
        catch (SqlException ex) when (ex.Number == 54807) { return null; }
    }

    public Task<AssetConfigWriteResult> SaveFirmwareProductAsync(AssetFirmwareProductSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_firmware_product_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@product_id",              DbType.Int32,   request.ProductId);
            AddParam(command, "@publisher_make_id",       DbType.Int32,   request.PublisherMakeId);
            AddParam(command, "@product_name",            DbType.String,  Blank(request.ProductName), 200);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@status",                  DbType.String,  Blank(request.Status) ?? "Active", 30);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_product_id", DbType.Int32);
        }, ct, request.ProductId);

    public Task<AssetConfigWriteResult> SaveFirmwareReleaseAsync(AssetFirmwareReleaseSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_firmware_release_save", command =>
        {
            AddParam(command, "@organization_id",              DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                       DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@release_id",                   DbType.Int64,   request.ReleaseId);
            AddParam(command, "@product_id",                   DbType.Int32,   request.ProductId);
            AddParam(command, "@version",                      DbType.String,  Blank(request.Version), 100);
            AddParam(command, "@build",                        DbType.String,  Blank(request.Build), 100);
            AddParam(command, "@branch_train",                 DbType.String,  Blank(request.BranchTrain), 100);
            AddParam(command, "@edition",                      DbType.String,  Blank(request.Edition), 100);
            AddParam(command, "@release_date",                 DbType.Date,    request.ReleaseDate?.Date);
            AddParam(command, "@engineering_support_end_date", DbType.Date,    request.EngineeringSupportEndDate?.Date);
            AddParam(command, "@standard_support_end_date",    DbType.Date,    request.StandardSupportEndDate?.Date);
            AddParam(command, "@security_fix_end_date",        DbType.Date,    request.SecurityFixEndDate?.Date);
            AddParam(command, "@end_of_life_date",             DbType.Date,    request.EndOfLifeDate?.Date);
            AddParam(command, "@known_vulnerabilities",        DbType.String,  Blank(request.KnownVulnerabilities), -1);
            AddParam(command, "@minimum_safe_version",         DbType.String,  Blank(request.MinimumSafeVersion), 100);
            AddParam(command, "@upgrade_urgency",              DbType.String,  Blank(request.UpgradeUrgency), 100);
            AddParam(command, "@package_location",             DbType.String,  Blank(request.PackageLocation), 1000);
            AddParam(command, "@checksum",                     DbType.String,  Blank(request.Checksum), 300);
            AddParam(command, "@signature",                    DbType.String,  Blank(request.Signature), 1000);
            AddParam(command, "@release_notes",                DbType.String,  Blank(request.ReleaseNotes), -1);
            AddParam(command, "@source_reference",             DbType.String,  Blank(request.SourceReference), 500);
            AddParam(command, "@verified_date",                DbType.Date,    request.VerifiedDate?.Date);
            AddParam(command, "@reviewer",                     DbType.String,  Blank(request.Reviewer), 200);
            AddParam(command, "@change_reason",                DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@expected_record_version",      DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",            DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                        DbType.String,  actor, 100);
            return Output(command, "@out_release_id", DbType.Int64);
        }, ct, request.ReleaseId);

    public Task<AssetConfigWriteResult> TransitionFirmwareReleaseAsync(long releaseId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        CatalogTransitionAsync("grac_practice.sp_asset_firmware_release_transition", "@release_id", releaseId, request, actorEmployeeId, actor, ct);

    public Task<AssetConfigWriteResult> SaveFirmwareCompatAsync(AssetFirmwareCompatSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_firmware_compat_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@compat_id",               DbType.Int64,   request.CompatId);
            AddParam(command, "@release_id",              DbType.Int64,   request.ReleaseId);
            AddParam(command, "@asset_type_id",           DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@make_id",                 DbType.Int32,   request.MakeId);
            AddParam(command, "@model_id",                DbType.Int64,   request.ModelId);
            AddParam(command, "@hardware_revision",       DbType.String,  Blank(request.HardwareRevision), 120);
            AddParam(command, "@compat_status",           DbType.String,  Blank(request.CompatStatus), 30);
            AddParam(command, "@upgrade_path",            DbType.String,  Blank(request.UpgradePath), 1000);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@evidence",                DbType.String,  Blank(request.Evidence), 1000);
            AddParam(command, "@reviewer",                DbType.String,  Blank(request.Reviewer), 200);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_compat_id", DbType.Int64);
        }, ct, request.CompatId);

    public Task<AssetConfigWriteResult> ApproveFirmwareCompatAsync(long compatId, AssetCatalogApproveRequest request, string actor, CancellationToken ct) =>
        CatalogApproveAsync("grac_practice.sp_asset_firmware_compat_approve", compatId, request, actor, ct);

    // ----------------------------------------------------------------
    // 427 -- operating systems
    // ----------------------------------------------------------------
    public async Task<object?> GetOsCatalogAsync(long organizationId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_os_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var products = await ReadRowsAsync(reader, ct);
            var releases = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { products, releases };
        }
        catch (SqlException ex) when (ex.Number == 54910) { return null; }
    }

    public async Task<object?> GetOsReleaseAsync(long organizationId, long releaseId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_os_release_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@release_id",      DbType.Int64, releaseId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var compatibility   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var lifecycleEvents = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { release = header[0], compatibility, lifecycleEvents, history };
        }
        catch (SqlException ex) when (ex.Number == 54917) { return null; }
    }

    public async Task<object?> GetModelOsAsync(long organizationId, long modelId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_model_os_list");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@model_id",        DbType.Int64, modelId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            return await ReadRowsAsync(reader, ct);
        }
        catch (SqlException ex) when (ex.Number == 54807) { return null; }
    }

    public Task<AssetConfigWriteResult> SaveOsProductAsync(AssetOsProductSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_os_product_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@product_id",              DbType.Int32,   request.ProductId);
            AddParam(command, "@publisher_make_id",       DbType.Int32,   request.PublisherMakeId);
            AddParam(command, "@family",                  DbType.String,  Blank(request.Family), 120);
            AddParam(command, "@product_name",            DbType.String,  Blank(request.ProductName), 200);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@status",                  DbType.String,  Blank(request.Status) ?? "Active", 30);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_product_id", DbType.Int32);
        }, ct, request.ProductId);

    public Task<AssetConfigWriteResult> SaveOsReleaseAsync(AssetOsReleaseSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_os_release_save", command =>
        {
            AddParam(command, "@organization_id",             DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                      DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@release_id",                  DbType.Int64,   request.ReleaseId);
            AddParam(command, "@product_id",                  DbType.Int32,   request.ProductId);
            AddParam(command, "@edition",                     DbType.String,  Blank(request.Edition), 100);
            AddParam(command, "@version",                     DbType.String,  Blank(request.Version), 100);
            AddParam(command, "@build",                       DbType.String,  Blank(request.Build), 100);
            AddParam(command, "@architecture",                DbType.String,  Blank(request.Architecture), 60);
            AddParam(command, "@release_date",                DbType.Date,    request.ReleaseDate?.Date);
            AddParam(command, "@mainstream_support_end_date", DbType.Date,    request.MainstreamSupportEndDate?.Date);
            AddParam(command, "@extended_support_end_date",   DbType.Date,    request.ExtendedSupportEndDate?.Date);
            AddParam(command, "@security_update_end_date",    DbType.Date,    request.SecurityUpdateEndDate?.Date);
            AddParam(command, "@end_of_life_date",            DbType.Date,    request.EndOfLifeDate?.Date);
            AddParam(command, "@servicing_channel",           DbType.String,  Blank(request.ServicingChannel), 100);
            AddParam(command, "@feature_version",             DbType.String,  Blank(request.FeatureVersion), 100);
            AddParam(command, "@patch_level",                 DbType.String,  Blank(request.PatchLevel), 100);
            AddParam(command, "@latest_approved_build",       DbType.String,  Blank(request.LatestApprovedBuild), 100);
            AddParam(command, "@minimum_compliant_build",     DbType.String,  Blank(request.MinimumCompliantBuild), 100);
            AddParam(command, "@source_reference",            DbType.String,  Blank(request.SourceReference), 500);
            AddParam(command, "@verified_date",               DbType.Date,    request.VerifiedDate?.Date);
            AddParam(command, "@verified_by",                 DbType.String,  Blank(request.VerifiedBy), 200);
            AddParam(command, "@is_approved_baseline",        DbType.Boolean, request.IsApprovedBaseline ?? false);
            AddParam(command, "@exception_note",              DbType.String,  Blank(request.ExceptionNote), 1000);
            AddParam(command, "@replacement_release_id",      DbType.Int64,   request.ReplacementReleaseId);
            AddParam(command, "@replacement_path",            DbType.String,  Blank(request.ReplacementPath), 500);
            AddParam(command, "@change_reason",               DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@expected_record_version",     DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",           DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                       DbType.String,  actor, 100);
            return Output(command, "@out_release_id", DbType.Int64);
        }, ct, request.ReleaseId);

    public Task<AssetConfigWriteResult> TransitionOsReleaseAsync(long releaseId, AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        CatalogTransitionAsync("grac_practice.sp_asset_os_release_transition", "@release_id", releaseId, request, actorEmployeeId, actor, ct);

    public Task<AssetConfigWriteResult> SaveOsCompatAsync(AssetOsCompatSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_os_compat_save", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@compat_id",               DbType.Int64,   request.CompatId);
            AddParam(command, "@release_id",              DbType.Int64,   request.ReleaseId);
            AddParam(command, "@asset_type_id",           DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@make_id",                 DbType.Int32,   request.MakeId);
            AddParam(command, "@model_id",                DbType.Int64,   request.ModelId);
            AddParam(command, "@processor_architecture",  DbType.String,  Blank(request.ProcessorArchitecture), 60);
            AddParam(command, "@min_firmware_release_id", DbType.Int64,   request.MinFirmwareReleaseId);
            AddParam(command, "@firmware_prerequisite",   DbType.String,  Blank(request.FirmwarePrerequisite), 500);
            AddParam(command, "@exclusions",              DbType.String,  Blank(request.Exclusions), 1000);
            AddParam(command, "@evidence",                DbType.String,  Blank(request.Evidence), 1000);
            AddParam(command, "@reviewer",                DbType.String,  Blank(request.Reviewer), 200);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return Output(command, "@out_compat_id", DbType.Int64);
        }, ct, request.CompatId);

    public Task<AssetConfigWriteResult> ApproveOsCompatAsync(long compatId, AssetCatalogApproveRequest request, string actor, CancellationToken ct) =>
        CatalogApproveAsync("grac_practice.sp_asset_os_compat_approve", compatId, request, actor, ct);

    /// <summary>One binding for the three catalogue status procedures
    /// (model 425, firmware release 426, OS release 427) -- identical
    /// parameters apart from the id name.</summary>
    private Task<AssetConfigWriteResult> CatalogTransitionAsync(string procedure, string idParameter, long id,
        AssetCatalogTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        WriteAsync(procedure, command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, idParameter,                DbType.Int64,   id);
            AddParam(command, "@to_status_code",          DbType.String,  request.ToStatusCode, 60);
            AddParam(command, "@reason_text",             DbType.String,  Blank(request.ReasonText), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return null;
        }, ct, id);

    /// <summary>One binding for the compatibility approval procedures (426, 427).</summary>
    private Task<AssetConfigWriteResult> CatalogApproveAsync(string procedure, long compatId,
        AssetCatalogApproveRequest request, string actor, CancellationToken ct) =>
        WriteAsync(procedure, command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@shared",                  DbType.Boolean, request.Shared ?? false);
            AddParam(command, "@compat_id",               DbType.Int64,   compatId);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            return null;
        }, ct, compatId);

    // ----------------------------------------------------------------
    // 428 -- Asset Register
    // ----------------------------------------------------------------
    public async Task<object> ListRegisterAsync(long organizationId, string? search, int? assetTypeId, string? statusCode,
        int pageNumber, int pageSize, bool pendingOnly, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_register_list");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@asset_type_id",   DbType.Int32,  assetTypeId);
        AddParam(command, "@status_code",     DbType.String, Blank(statusCode), 60);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        AddParam(command, "@pending_only",    DbType.Boolean, pendingOnly);     // 429
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetRegisterAssetAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_register_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var values  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { asset = header[0], values, history };
        }
        catch (SqlException ex) when (ex.Number == 54951) { return null; }
    }

    public async Task<object?> GetRegisterFormAsync(long organizationId, int? assetTypeId, long? templateId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_register_form");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@asset_type_id",   DbType.Int32, assetTypeId);
        AddParam(command, "@template_id",     DbType.Int64, templateId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadTemplateDetailAsync(reader, ct);
    }

    public async Task<object> GetRegisterLookupsAsync(long organizationId, string? sources, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_register_lookups");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@sources",         DbType.String, Blank(sources), -1);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    /// <summary>The save returns its issues as rows; only Result = SAVED
    /// wrote anything. A refusal raised by the procedure (not found,
    /// stale version, no template ...) comes back as ErrorNumber.</summary>
    public async Task<AssetRegisterSaveResult> SaveRegisterAssetAsync(AssetRegisterSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_register_save");
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",                DbType.Int64,  request.AssetId);
            AddParam(command, "@asset_type_id",           DbType.Int32,  request.AssetTypeId);
            AddParam(command, "@values_json",             DbType.String,
                request.Values is { ValueKind: System.Text.Json.JsonValueKind.Object } v ? v.GetRawText() : "{}", -1);
            AddParam(command, "@hidden_decisions_json",   DbType.String,
                request.HiddenDecisions is { ValueKind: System.Text.Json.JsonValueKind.Object } h ? h.GetRawText() : null, -1);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
            var outId     = Output(command, "@out_asset_id", DbType.Int64);
            var outResult = Output(command, "@out_result", DbType.String);
            outResult.Size = 20;
            List<Dictionary<string, object?>> issues;
            await using (var reader = await command.ExecuteReaderAsync(ct))
            {
                issues = await ReadRowsAsync(reader, ct);
            }
            var id = outId.Value is null or DBNull ? request.AssetId : Convert.ToInt64(outId.Value);
            return new AssetRegisterSaveResult(Convert.ToString(outResult.Value) ?? "INVALID", id, issues, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService sp_asset_register_save refused ({Number})", ex.Number);
            return new AssetRegisterSaveResult("REFUSED", request.AssetId, new List<Dictionary<string, object?>>(), ex.Number, ex.Message);
        }
    }

    // ----------------------------------------------------------------
    // 429 -- Asset lifecycle transitions
    // ----------------------------------------------------------------
    public async Task<object?> GetAssetLifecycleAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_lifecycle_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var current = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var moves   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var changes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { current = current.Count > 0 ? current[0] : null, moves, changes };
        }
        catch (SqlException ex) when (ex.Number == 54971) { return null; }
    }

    public async Task<object> GetLifecycleMatrixAsync(CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_lifecycle_matrix");
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public Task<AssetLifecycleResult> TransitionAssetAsync(long assetId, AssetLifecycleTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_lifecycle_transition", "changeId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",                DbType.Int64,  assetId);
            AddParam(command, "@to_status_code",          DbType.String, request.ToStatusCode, 60);
            AddParam(command, "@reason_text",             DbType.String, Blank(request.ReasonText), 1000);
            AddParam(command, "@reference_text",          DbType.String, Blank(request.ReferenceText), 400);
            AddParam(command, "@evidence_text",           DbType.String, Blank(request.EvidenceText), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideLifecycleChangeAsync(long changeId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_lifecycle_decide", "changeId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@change_id",               DbType.Int64,  changeId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 430 -- Installed technology
    // ----------------------------------------------------------------
    public async Task<object?> GetAssetTechnologyAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_technology_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var status = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var firmwareHistory = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var osHistory       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var exceptions      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { status, firmwareHistory, osHistory, exceptions };
        }
        catch (SqlException ex) when (ex.Number == 54321) { return null; }
    }

    public Task<AssetLifecycleResult> RecordInstallationAsync(long assetId, AssetTechInstallRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_tech_install_record", "installationId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",                DbType.Int64,  assetId);
            AddParam(command, "@kind",                    DbType.String, request.Kind, 10);
            AddParam(command, "@release_id",              DbType.Int64,  request.ReleaseId);
            AddParam(command, "@installed_date",          DbType.Date,   request.InstalledDate?.Date);
            AddParam(command, "@source",                  DbType.String, Blank(request.Source), 100);
            AddParam(command, "@result",                  DbType.String, Blank(request.Result), 20);
            AddParam(command, "@build_patch_level",       DbType.String, Blank(request.BuildPatchLevel), 100);
            AddParam(command, "@rollback_note",           DbType.String, Blank(request.RollbackNote), 1000);
            AddParam(command, "@licence_reference",       DbType.String, Blank(request.LicenceReference), 400);
            AddParam(command, "@evidence_text",           DbType.String, Blank(request.EvidenceText), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RequestTechExceptionAsync(long assetId, AssetTechExceptionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_tech_exception_request", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",          DbType.Int64,  assetId);
            AddParam(command, "@scope",             DbType.String, request.Scope, 10);
            AddParam(command, "@kind",              DbType.String, request.Kind, 10);
            AddParam(command, "@release_id",        DbType.Int64,  request.ReleaseId);
            AddParam(command, "@reason",            DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@controls",          DbType.String, Blank(request.CompensatingControls), 1000);
            AddParam(command, "@owner_employee_id", DbType.Int64,  request.OwnerEmployeeId);
            AddParam(command, "@expiry_date",       DbType.Date,   request.ExpiryDate?.Date);
            AddParam(command, "@review_date",       DbType.Date,   request.ReviewDate?.Date);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideTechExceptionAsync(long exceptionId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_tech_exception_decide", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@exception_id",            DbType.Int64,  exceptionId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 431 -- Custody, acknowledgement and attestation
    // ----------------------------------------------------------------
    public async Task<object?> GetAssetCustodyAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_custody_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var state = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var assignments  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var attestations = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var exceptions   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 432
            return new { state = state.Count > 0 ? state[0] : null, assignments, attestations, exceptions };
        }
        catch (SqlException ex) when (ex.Number == 54351) { return null; }
    }

    public async Task<object> GetAttestationProfilesAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_attestation_profiles");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var profiles = await ReadRowsAsync(reader, ct);
        var scopes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { profiles, scopes };
    }

    public Task<AssetConfigWriteResult> SaveAttestationProfileAsync(AssetAttestationProfileSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_attestation_profile_save", command =>
        {
            AddParam(command, "@organization_id",           DbType.Int64,   request.OrganizationId);
            AddParam(command, "@profile_id",                DbType.Int64,   request.ProfileId);
            AddParam(command, "@scope_kind",                DbType.String,  request.ScopeKind, 20);
            AddParam(command, "@scope_id",                  DbType.Int32,   request.ScopeId);
            AddParam(command, "@attestation_required",      DbType.Boolean, request.AttestationRequired ?? true);
            AddParam(command, "@participant",               DbType.String,  request.Participant, 20);
            AddParam(command, "@frequency",                 DbType.String,  request.Frequency, 20);
            AddParam(command, "@custom_interval_days",      DbType.Int32,   request.CustomIntervalDays);
            AddParam(command, "@due_window_days",           DbType.Int32,   request.DueWindowDays);
            AddParam(command, "@evidence_requirement",      DbType.String,  request.EvidenceRequirement, 20);
            AddParam(command, "@manager_approval_required", DbType.Boolean, request.ManagerApprovalRequired ?? false);
            AddParam(command, "@is_active",                 DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@expected_record_version",   DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                     DbType.String,  actor, 100);
            return Output(command, "@out_profile_id", DbType.Int64);
        }, ct, request.ProfileId);

    public async Task<object> GetAttestationCampaignsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_attestation_campaigns");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    /// <summary>Returns the run summary row (campaignId, generated, skipped,
    /// overdueMarked) or the refusal.</summary>
    public async Task<(object? Data, int? ErrorNumber, string? Error)> GenerateAttestationsAsync(AssetAttestationGenerateRequest request, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_attestation_generate");
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@campaign_type",   DbType.String, request.CampaignType ?? "PERIODIC", 20);
            AddParam(command, "@campaign_name",   DbType.String, Blank(request.CampaignName), 200);
            AddParam(command, "@asset_type_id",   DbType.Int32,  request.AssetTypeId);
            AddParam(command, "@due_date",        DbType.Date,   request.DueDate?.Date);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            return (rows.Count > 0 ? rows[0] : null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService sp_asset_attestation_generate refused ({Number})", ex.Number);
            return (null, ex.Number, ex.Message);
        }
    }

    public async Task<object> ListAttestationsAsync(long organizationId, string? scope, string? status, long? campaignId, string? search,
        long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_attestation_list");
        AddParam(command, "@organization_id",   DbType.Int64,  organizationId);
        AddParam(command, "@scope",             DbType.String, Blank(scope) ?? "ALL", 20);
        AddParam(command, "@status",            DbType.String, Blank(status), 20);
        AddParam(command, "@campaign_id",       DbType.Int64,  campaignId);
        AddParam(command, "@search",            DbType.String, Blank(search), 200);
        AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
        AddParam(command, "@page_number",       DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",         DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public Task<AssetLifecycleResult> RespondAttestationAsync(long attestationId, AssetAttestationRespondRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_attestation_respond", "attestationId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@attestation_id",          DbType.Int64,   attestationId);
            AddParam(command, "@response",                DbType.String,  request.Response, 10);
            AddParam(command, "@asset_exists",            DbType.Boolean, request.AssetExists);
            AddParam(command, "@custody_confirmed",       DbType.Boolean, request.CustodyConfirmed);
            AddParam(command, "@location_verified",       DbType.Boolean, request.LocationVerified);
            AddParam(command, "@tag_verified",            DbType.Boolean, request.TagVerified);
            AddParam(command, "@serial_verified",         DbType.Boolean, request.SerialVerified);
            AddParam(command, "@assigned_user_verified",  DbType.Boolean, request.AssignedUserVerified);
            AddParam(command, "@information_correct",     DbType.Boolean, request.InformationCorrect);
            AddParam(command, "@business_use_confirmed",  DbType.Boolean, request.BusinessUseConfirmed);
            AddParam(command, "@condition_code",          DbType.String,  Blank(request.ConditionCode), 30);
            AddParam(command, "@disagreement_category",   DbType.String,  Blank(request.DisagreementCategory), 40);
            AddParam(command, "@comments",                DbType.String,  Blank(request.Comments), 2000);
            AddParam(command, "@evidence_text",           DbType.String,  Blank(request.EvidenceText), 1000);
            AddParam(command, "@channel",                 DbType.String,  "Web", 30);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideAttestationAsync(long attestationId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_attestation_decide", "attestationId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@attestation_id",          DbType.Int64,  attestationId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 432 -- Verification exceptions
    // ----------------------------------------------------------------
    public async Task<object> ListVerificationExceptionsAsync(long organizationId, string? scope, string? status, string? search,
        long? actorEmployeeId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_verification_exception_list");
        AddParam(command, "@organization_id",   DbType.Int64,  organizationId);
        AddParam(command, "@scope",             DbType.String, Blank(scope) ?? "ALL", 20);
        AddParam(command, "@status_code",       DbType.String, Blank(status), 60);
        AddParam(command, "@search",            DbType.String, Blank(search), 200);
        AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
        AddParam(command, "@page_number",       DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",         DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetVerificationExceptionAsync(long organizationId, long exceptionId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_verification_exception_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@exception_id",      DbType.Int64, exceptionId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { exception = header[0], history };
        }
        catch (SqlException ex) when (ex.Number == 54411) { return null; }
    }

    public Task<AssetLifecycleResult> VerificationExceptionActionAsync(long exceptionId, AssetVerificationActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_verification_exception_action", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@exception_id",            DbType.Int64,  exceptionId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@outcome",                 DbType.String, Blank(request.Outcome), 30);
            AddParam(command, "@narrative",               DbType.String, Blank(request.Narrative), 2000);
            AddParam(command, "@closure_evidence",        DbType.String, Blank(request.ClosureEvidence), 1000);
            AddParam(command, "@sec_remote_lock_wipe",    DbType.String, Blank(request.SecRemoteLockWipe), 4);
            AddParam(command, "@sec_credential_review",   DbType.String, Blank(request.SecCredentialReview), 4);
            AddParam(command, "@sec_privacy_assessment",  DbType.String, Blank(request.SecPrivacyAssessment), 4);
            AddParam(command, "@sec_access_revocation",   DbType.String, Blank(request.SecAccessRevocation), 4);
            AddParam(command, "@sec_monitoring",          DbType.String, Blank(request.SecMonitoring), 4);
            AddParam(command, "@investigator",            DbType.String, Blank(request.Investigator), 40);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> GetVerificationSettingsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_verification_settings_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var rules     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var teams     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { settings = settings.Count > 0 ? settings[0] : null, rules, employees, teams };
    }

    public Task<AssetConfigWriteResult> SaveVerificationSettingsAsync(AssetVerificationSettingsSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_verification_settings_save", command =>
        {
            AddParam(command, "@organization_id",                 DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_administrator_employee_id", DbType.Int64,  request.AssetAdministratorEmployeeId);
            AddParam(command, "@fallback_team_id",                DbType.Int64,  request.FallbackTeamId);
            AddParam(command, "@escalation_level1_days",          DbType.Int32,  request.EscalationLevel1Days);
            AddParam(command, "@escalation_level2_days",          DbType.Int32,  request.EscalationLevel2Days);
            AddParam(command, "@escalation_level3_days",          DbType.Int32,  request.EscalationLevel3Days);
            AddParam(command, "@expected_record_version",         DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor",                           DbType.String, actor, 100);
            return null;
        }, ct, request.OrganizationId);

    public Task<AssetConfigWriteResult> SaveVerificationRuleAsync(AssetVerificationRuleSaveRequest request, string actor, CancellationToken ct) =>
        WriteAsync("grac_practice.sp_asset_verification_rule_save", command =>
        {
            AddParam(command, "@organization_id",           DbType.Int64,   request.OrganizationId);
            AddParam(command, "@category",                  DbType.String,  request.Category, 40);
            AddParam(command, "@primary_assignment",        DbType.String,  Blank(request.PrimaryAssignment), 30);
            AddParam(command, "@supporting_assignment",     DbType.String,  Blank(request.SupportingAssignment), 200);
            AddParam(command, "@start_sla_days",            DbType.Int32,   request.StartSlaDays);
            AddParam(command, "@start_immediate",           DbType.Boolean, request.StartImmediate ?? false);
            AddParam(command, "@resolution_sla_days",       DbType.Int32,   request.ResolutionSlaDays);
            AddParam(command, "@closure_approval_required", DbType.Boolean, request.ClosureApprovalRequired ?? false);
            AddParam(command, "@closure_evidence_required", DbType.Boolean, request.ClosureEvidenceRequired ?? false);
            AddParam(command, "@reset",                     DbType.Boolean, request.Reset ?? false);
            AddParam(command, "@actor",                     DbType.String,  actor, 100);
            return null;
        }, ct, request.OrganizationId);

    // ----------------------------------------------------------------
    // 433 -- Asset workflows
    // ----------------------------------------------------------------
    public async Task<object> GetWorkflowDefinitionsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_workflow_definitions");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var workflows = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var steps   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var options = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { workflows, steps, options };
    }

    public async Task<object> ListWorkflowCasesAsync(long organizationId, long? assetId, bool openOnly, long? actorEmployeeId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_workflow_cases");
        AddParam(command, "@organization_id",   DbType.Int64,   organizationId);
        AddParam(command, "@asset_id",          DbType.Int64,   assetId);
        AddParam(command, "@open_only",         DbType.Boolean, openOnly);
        AddParam(command, "@actor_employee_id", DbType.Int64,   actorEmployeeId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object?> GetWorkflowCaseAsync(long organizationId, long caseId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_workflow_case_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@case_id",           DbType.Int64, caseId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var steps   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { workflowCase = header[0], steps, history };
        }
        catch (SqlException ex) when (ex.Number == 54451) { return null; }
    }

    public Task<AssetLifecycleResult> StartWorkflowAsync(long assetId, AssetWorkflowStartRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_workflow_start", "caseId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",          DbType.Int64,  assetId);
            AddParam(command, "@workflow_code",     DbType.String, request.WorkflowCode, 30);
            AddParam(command, "@reason",            DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@reference_text",    DbType.String, Blank(request.ReferenceText), 400);
            AddParam(command, "@new_owner_id",      DbType.Int64,  request.NewOwnerId);
            AddParam(command, "@dest_location_id",  DbType.Int64,  request.DestLocationId);
            AddParam(command, "@dest_building",     DbType.String, Blank(request.DestBuilding), 160);
            AddParam(command, "@dest_floor",        DbType.String, Blank(request.DestFloor), 160);
            AddParam(command, "@dest_room",         DbType.String, Blank(request.DestRoom), 160);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> WorkflowStepAsync(long caseId, AssetWorkflowStepRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_workflow_step_action", "caseId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@case_id",                 DbType.Int64,  caseId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@evidence_text",           DbType.String, Blank(request.EvidenceText), 1000);
            AddParam(command, "@reference_text",          DbType.String, Blank(request.ReferenceText), 400);
            AddParam(command, "@choice",                  DbType.String, Blank(request.Choice), 20);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> CancelWorkflowAsync(long caseId, AssetWorkflowCancelRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_workflow_cancel", "caseId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@case_id",                 DbType.Int64,  caseId);
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 434 -- Contracts
    // ----------------------------------------------------------------
    public async Task<object> ListContractsAsync(long organizationId, string? search, string? status, long? vendorId, string? contractType,
        int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_contract_list");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@vendor_id",       DbType.Int64,  vendorId);
        AddParam(command, "@contract_type",   DbType.String, Blank(contractType), 160);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> GetContractLookupsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_contract_lookups");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var vendors = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var vendorUsers   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var contractTypes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var roles         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var contracts     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { vendors, vendorUsers, employees, contractTypes, roles, contracts };
    }

    public async Task<object?> GetContractAsync(long organizationId, long contractId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_contract_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@contract_id",       DbType.Int64, contractId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var versions       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var contacts       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var documents      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var approvals      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var warnings       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var contactHistory = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var coverageHistory = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            var coveragePosture = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            return new { contract = header[0], versions, contacts, documents, approvals, warnings, contactHistory, coverageHistory, coveragePosture };
        }
        catch (SqlException ex) when (ex.Number == 54511) { return null; }
    }

    public async Task<object?> GetContractVersionAsync(long organizationId, long versionId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_contract_version_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@version_id",        DbType.Int64, versionId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var contacts  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var documents = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var warnings  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var entitlements = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            var coverage     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            return new { version = header[0], contacts, documents, history, warnings, entitlements, coverage };
        }
        catch (SqlException ex) when (ex.Number == 54519) { return null; }
    }

    public async Task<object?> CompareContractVersionsAsync(long organizationId, long versionA, long versionB, long? actorEmployeeId, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_contract_version_compare");
            AddParam(command, "@organization_id",   DbType.Int64,  organizationId);
            AddParam(command, "@version_a",         DbType.Int64,  versionA);
            AddParam(command, "@version_b",         DbType.Int64,  versionB);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var heading = await ReadRowsAsync(reader, ct);
            if (heading.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var fields   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var contacts = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var coverage     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            var entitlements = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 435
            return new { heading = heading[0], fields, contacts, coverage, entitlements };
        }
        catch (SqlException ex) when (ex.Number == 54543) { return null; }
    }

    public Task<AssetLifecycleResult> SaveContractAsync(AssetContractSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_save", "contractId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@contract_id",             DbType.Int64,  request.ContractId);
            AddParam(command, "@contract_number",         DbType.String, Blank(request.ContractNumber), 60);
            AddParam(command, "@contract_name",           DbType.String, Blank(request.ContractName), 250);
            AddParam(command, "@contract_type",           DbType.String, Blank(request.ContractType), 160);
            AddParam(command, "@parent_contract_id",      DbType.Int64,  request.ParentContractId);
            AddParam(command, "@vendor_id",               DbType.Int64,  request.VendorId);
            AddParam(command, "@description",             DbType.String, Blank(request.Description), 2000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> CreateContractVersionAsync(long contractId, AssetContractVersionCreateRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_version_create", "versionId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@contract_id",       DbType.Int64,  contractId);
            AddParam(command, "@version_type",      DbType.String, request.VersionType, 20);
            AddParam(command, "@change_summary",    DbType.String, Blank(request.ChangeSummary), 2000);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveContractVersionAsync(long versionId, AssetContractVersionSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_version_save", "versionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@version_id",              DbType.Int64,   versionId);
            AddParam(command, "@version_label",           DbType.String,  Blank(request.VersionLabel), 40);
            AddParam(command, "@effective_start",         DbType.Date,    request.EffectiveStart?.Date);
            AddParam(command, "@effective_end",           DbType.Date,    request.EffectiveEnd?.Date);
            AddParam(command, "@notice_date",             DbType.Date,    request.NoticeDate?.Date);
            AddParam(command, "@decision_date",           DbType.Date,    request.DecisionDate?.Date);
            AddParam(command, "@termination_date",        DbType.Date,    request.TerminationDate?.Date);
            AddParam(command, "@contract_value",          DbType.Decimal, request.ContractValue);
            AddParam(command, "@currency_code",           DbType.String,  Blank(request.CurrencyCode), 3);
            AddParam(command, "@tax_details",             DbType.String,  Blank(request.TaxDetails), 200);
            AddParam(command, "@payment_terms",           DbType.String,  Blank(request.PaymentTerms), 400);
            AddParam(command, "@po_reference",            DbType.String,  Blank(request.PoReference), 100);
            AddParam(command, "@invoice_reference",       DbType.String,  Blank(request.InvoiceReference), 100);
            AddParam(command, "@cost_allocation",         DbType.String,  Blank(request.CostAllocation), 400);
            AddParam(command, "@renewal_terms",           DbType.String,  Blank(request.RenewalTerms), 1000);
            AddParam(command, "@service_scope",           DbType.String,  Blank(request.ServiceScope), 2000);
            AddParam(command, "@sla_terms",               DbType.String,  Blank(request.SlaTerms), 2000);
            AddParam(command, "@support_hours",           DbType.String,  Blank(request.SupportHours), 200);
            AddParam(command, "@response_time",           DbType.String,  Blank(request.ResponseTime), 100);
            AddParam(command, "@resolution_time",         DbType.String,  Blank(request.ResolutionTime), 100);
            AddParam(command, "@service_visits",          DbType.String,  Blank(request.ServiceVisits), 100);
            AddParam(command, "@contract_owner_id",       DbType.Int64,   request.ContractOwnerId);
            AddParam(command, "@procurement_owner_id",    DbType.Int64,   request.ProcurementOwnerId);
            AddParam(command, "@change_summary",          DbType.String,  Blank(request.ChangeSummary), 2000);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> ContractVersionActionAsync(long versionId, AssetContractVersionActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_version_action", "versionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@version_id",              DbType.Int64,  versionId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveContractContactAsync(long contractId, AssetContractContactSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_contact_save", "mappingId", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@mapping_id",                 DbType.Int64,   request.MappingId);
            AddParam(command, "@contract_id",                DbType.Int64,   contractId);
            AddParam(command, "@version_id",                 DbType.Int64,   request.VersionId);
            AddParam(command, "@employee_id",                DbType.Int64,   request.EmployeeId);
            AddParam(command, "@role_code",                  DbType.String,  Blank(request.RoleCode), 40);
            AddParam(command, "@is_primary",                 DbType.Boolean, request.IsPrimary ?? false);
            AddParam(command, "@effective_start",            DbType.Date,    request.EffectiveStart?.Date);
            AddParam(command, "@effective_end",              DbType.Date,    request.EffectiveEnd?.Date);
            AddParam(command, "@preferred_channel",          DbType.String,  Blank(request.PreferredChannel) ?? "EMAIL", 10);
            AddParam(command, "@notification_participation", DbType.Boolean, request.NotificationParticipation ?? true);
            AddParam(command, "@notes",                      DbType.String,  Blank(request.Notes), 1000);
            AddParam(command, "@expected_record_version",    DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",          DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> ContractContactActionAsync(long mappingId, AssetContractContactActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_contact_action", "mappingId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@mapping_id",              DbType.Int64,  mappingId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@end_date",                DbType.Date,   request.EndDate?.Date);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> AddContractDocumentAsync(long versionId, AssetContractDocumentRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_document_add", "documentId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@version_id",      DbType.Int64,  versionId);
            AddParam(command, "@document_type",   DbType.String, Blank(request.DocumentType), 30);
            AddParam(command, "@title",           DbType.String, Blank(request.Title), 250);
            AddParam(command, "@reference_text",  DbType.String, Blank(request.ReferenceText), 1000);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RemoveContractDocumentAsync(long documentId, AssetContractDocumentRemoveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_document_remove", "documentId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@document_id",     DbType.Int64,  documentId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 435 -- Coverage and entitlements
    // ----------------------------------------------------------------
    public async Task<object> SearchContractAssetsAsync(long organizationId, string? search, int? assetTypeId, long? versionId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_contract_asset_search");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@asset_type_id",   DbType.Int32,  assetTypeId);
        AddParam(command, "@version_id",      DbType.Int64,  versionId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object?> GetAssetCoverageAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_coverage_asset_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var summary = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var types        = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var lines        = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var requirements = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { summary = summary.Count > 0 ? summary[0] : null, types, lines, requirements };
        }
        catch (SqlException ex) when (ex.Number == 54557) { return null; }
    }

    public async Task<object> ListCoverageGapsAsync(long organizationId, string? search, string? coverageType, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_coverage_gaps");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@coverage_type",   DbType.String, Blank(coverageType), 160);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> GetCoverageConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_coverage_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var requirements  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var assetTypes    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var coverageTypes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { settings = settings.Count > 0 ? settings[0] : null, requirements, assetTypes, coverageTypes };
    }

    public Task<AssetLifecycleResult> SaveEntitlementAsync(long versionId, AssetContractEntitlementRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_entitlement_save", "entitlementId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@entitlement_id",  DbType.Int64,   request.EntitlementId);
            AddParam(command, "@version_id",      DbType.Int64,   versionId);
            AddParam(command, "@product_sku",     DbType.String,  Blank(request.ProductSku), 160);
            AddParam(command, "@description",     DbType.String,  Blank(request.Description), 400);
            AddParam(command, "@coverage_type",   DbType.String,  Blank(request.CoverageType), 160);
            AddParam(command, "@quantity",        DbType.Decimal, request.Quantity);
            AddParam(command, "@unit",            DbType.String,  Blank(request.Unit), 40);
            AddParam(command, "@service_level",   DbType.String,  Blank(request.ServiceLevel), 160);
            AddParam(command, "@support_hours",   DbType.String,  Blank(request.SupportHours), 200);
            AddParam(command, "@start_date",      DbType.Date,    request.StartDate?.Date);
            AddParam(command, "@end_date",        DbType.Date,    request.EndDate?.Date);
            AddParam(command, "@exclusions",      DbType.String,  Blank(request.Exclusions), 1000);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RemoveEntitlementAsync(long entitlementId, AssetContractLineRemoveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_entitlement_remove", "entitlementId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@entitlement_id",  DbType.Int64,  entitlementId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveCoverageAsync(long versionId, AssetContractCoverageRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_coverage_save", "coverageId", command =>
        {
            AddParam(command, "@organization_id",          DbType.Int64,  request.OrganizationId);
            AddParam(command, "@coverage_id",              DbType.Int64,  request.CoverageId);
            AddParam(command, "@version_id",               DbType.Int64,  versionId);
            AddParam(command, "@asset_id",                 DbType.Int64,  request.AssetId);
            AddParam(command, "@coverage_type",            DbType.String, Blank(request.CoverageType), 160);
            AddParam(command, "@coverage_state",           DbType.String, Blank(request.CoverageState) ?? "COVERED", 10);
            AddParam(command, "@entitlement_id",           DbType.Int64,  request.EntitlementId);
            AddParam(command, "@coverage_start",           DbType.Date,   request.CoverageStart?.Date);
            AddParam(command, "@coverage_end",             DbType.Date,   request.CoverageEnd?.Date);
            AddParam(command, "@service_level",            DbType.String, Blank(request.ServiceLevel), 160);
            AddParam(command, "@support_hours",            DbType.String, Blank(request.SupportHours), 200);
            AddParam(command, "@vendor_support_reference", DbType.String, Blank(request.VendorSupportReference), 400);
            AddParam(command, "@exclusion_reason",         DbType.String, Blank(request.ExclusionReason), 1000);
            AddParam(command, "@actor",                    DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> BulkAddCoverageAsync(long versionId, AssetContractCoverageBulkRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_coverage_bulk_add", "versionId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@version_id",      DbType.Int64,  versionId);
            AddParam(command, "@asset_ids",       DbType.String, string.Join(",", request.AssetIds ?? Array.Empty<long>()));
            AddParam(command, "@coverage_type",   DbType.String, Blank(request.CoverageType), 160);
            AddParam(command, "@entitlement_id",  DbType.Int64,  request.EntitlementId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RemoveCoverageAsync(long coverageId, AssetContractLineRemoveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_coverage_remove", "coverageId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@coverage_id",     DbType.Int64,  coverageId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveCoverageRequirementAsync(AssetCoverageRequirementRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_coverage_requirement_save", "requirementId", command =>
        {
            AddParam(command, "@organization_id",       DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_type_id",         DbType.Int32,  request.AssetTypeId);
            AddParam(command, "@coverage_type",         DbType.String, Blank(request.CoverageType), 160);
            AddParam(command, "@requirement_level",     DbType.String, Blank(request.RequirementLevel), 20);
            AddParam(command, "@minimum_period_months", DbType.Int32,  request.MinimumPeriodMonths);
            AddParam(command, "@licence_handling",      DbType.String, Blank(request.LicenceHandling), 12);
            AddParam(command, "@missing_action",        DbType.String, Blank(request.MissingAction) ?? "WARN", 20);
            AddParam(command, "@notes",                 DbType.String, Blank(request.Notes), 1000);
            AddParam(command, "@actor",                 DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveCoverageSettingsAsync(AssetCoverageSettingsRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_coverage_settings_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(command, "@expiring_window_days", DbType.Int32,  request.ExpiringWindowDays);
            AddParam(command, "@actor",                DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 436 -- Renewal occurrences
    // ----------------------------------------------------------------
    public async Task<object> ListRenewalsAsync(long organizationId, long? contractId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_contract_renewal_list");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@contract_id",     DbType.Int64,  contractId);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> ListRenewalsDueAsync(long organizationId, int withinDays, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_contract_renewal_due");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@within_days",     DbType.Int32, withinDays);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object?> GetRenewalAsync(long organizationId, long renewalId, long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_contract_renewal_get");
            AddParam(command, "@organization_id",   DbType.Int64, organizationId);
            AddParam(command, "@renewal_id",        DbType.Int64, renewalId);
            AddParam(command, "@actor_employee_id", DbType.Int64, actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var reconciliation = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history        = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var linkable       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { renewal = header[0], reconciliation, history, linkable };
        }
        catch (SqlException ex) when (ex.Number == 54574) { return null; }
    }

    public Task<AssetLifecycleResult> StartRenewalAsync(long contractId, AssetContractRenewalStartRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_renewal_start", "renewalId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@contract_id",       DbType.Int64,  contractId);
            AddParam(command, "@renewal_type",      DbType.String, Blank(request.RenewalType) ?? "RENEWAL", 20);
            AddParam(command, "@notes",             DbType.String, Blank(request.Notes), 2000);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveRenewalAsync(long renewalId, AssetContractRenewalSaveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_renewal_save", "renewalId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@renewal_id",              DbType.Int64,   renewalId);
            AddParam(command, "@renewal_type",            DbType.String,  Blank(request.RenewalType), 20);
            AddParam(command, "@new_expiry",              DbType.Date,    request.NewExpiry?.Date);
            AddParam(command, "@renewal_value",           DbType.Decimal, request.RenewalValue);
            AddParam(command, "@currency_code",           DbType.String,  Blank(request.CurrencyCode), 3);
            AddParam(command, "@quotation_reference",     DbType.String,  Blank(request.QuotationReference), 200);
            AddParam(command, "@po_reference",            DbType.String,  Blank(request.PoReference), 100);
            AddParam(command, "@invoice_reference",       DbType.String,  Blank(request.InvoiceReference), 100);
            AddParam(command, "@decision_comments",       DbType.String,  Blank(request.DecisionComments), 2000);
            AddParam(command, "@notes",                   DbType.String,  Blank(request.Notes), 2000);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RenewalActionAsync(long renewalId, AssetContractRenewalActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_renewal_action", "renewalId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@renewal_id",              DbType.Int64,  renewalId);
            AddParam(command, "@action",                  DbType.String, request.Action, 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@version_id",              DbType.Int64,  request.VersionId);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> ResolveRenewalItemAsync(long itemId, AssetContractRenewalResolveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_contract_renewal_item_resolve", "itemId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@item_id",         DbType.Int64,  itemId);
            AddParam(command, "@resolution_code", DbType.String, Blank(request.ResolutionCode), 20);
            AddParam(command, "@note",            DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 437 -- Notification profiles, escalation, occurrences, scheduler
    // ----------------------------------------------------------------
    public async Task<object> GetNotificationConfigAsync(long organizationId, string actor, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_config_get");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@actor",           DbType.String, actor, 100);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var empty = new List<Dictionary<string, object?>>();
        var activities     = await ReadRowsAsync(reader, ct);
        var recipientTypes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var profiles       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var stages         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var recipients     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var matrix         = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var roles          = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { activities, recipientTypes, profiles, stages, recipients, matrix, roles, employees };
    }

    public Task<AssetLifecycleResult> SaveNotificationProfileAsync(AssetNotificationProfileRequest request, string actor, CancellationToken ct)
    {
        var stages = System.Text.Json.JsonSerializer.Serialize((request.Stages ?? Array.Empty<AssetNotificationStageRequest>()).Select(s => new
        {
            stageKind = s.StageKind,
            offsetDays = s.OffsetDays,
            escalationLevel = s.EscalationLevel,
            notificationClass = s.NotificationClass,
            recipients = (s.Recipients ?? Array.Empty<AssetNotificationRecipientRequest>())
                .Select(r => new { recipientCode = r.RecipientCode, roleId = r.RoleId })
        }));
        return ResultRowWriteAsync("grac_practice.sp_asset_notification_profile_save", "profileId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@profile_id",              DbType.Int64,   request.ProfileId);
            AddParam(command, "@activity_code",           DbType.String,  Blank(request.ActivityCode), 40);
            AddParam(command, "@profile_name",            DbType.String,  Blank(request.ProfileName), 200);
            AddParam(command, "@severity_code",           DbType.String,  Blank(request.SeverityCode), 10);
            AddParam(command, "@owner_employee_id",       DbType.Int64,   request.OwnerEmployeeId);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@ack_mode",                DbType.String,  Blank(request.AckMode) ?? "READ", 10);
            AddParam(command, "@channel_in_app",          DbType.Boolean, request.ChannelInApp ?? true);
            AddParam(command, "@channel_email",           DbType.Boolean, request.ChannelEmail ?? false);
            AddParam(command, "@channel_webhook",         DbType.Boolean, request.ChannelWebhook ?? false);
            AddParam(command, "@snooze_allowed",          DbType.Boolean, request.SnoozeAllowed ?? true);
            AddParam(command, "@working_days_only",       DbType.Boolean, request.WorkingDaysOnly ?? false);
            AddParam(command, "@stages_json",             DbType.String,  stages, -1);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);
    }

    public Task<AssetLifecycleResult> SaveEscalationMatrixAsync(AssetEscalationMatrixRequest request, string actor, CancellationToken ct)
    {
        var entries = System.Text.Json.JsonSerializer.Serialize((request.Entries ?? Array.Empty<AssetEscalationEntryRequest>()).Select(e => new
        {
            escalationLevel = e.EscalationLevel,
            recipientCode = e.RecipientCode,
            roleId = e.RoleId
        }));
        return ResultRowWriteAsync("grac_practice.sp_asset_escalation_matrix_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@severity_code",   DbType.String, Blank(request.SeverityCode), 10);
            AddParam(command, "@entries_json",    DbType.String, entries, -1);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);
    }

    public async Task<object> ListNotificationOccurrencesAsync(long organizationId, string? status, string? activityCode, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_occurrence_list");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 12);
        AddParam(command, "@activity_code",   DbType.String, Blank(activityCode), 40);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetNotificationOccurrenceAsync(long organizationId, long occurrenceId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_notification_occurrence_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@occurrence_id",   DbType.Int64, occurrenceId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var stages        = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var notifications = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { occurrence = header[0], stages, notifications };
        }
        catch (SqlException ex) when (ex.Number == 54625) { return null; }
    }

    public Task<AssetLifecycleResult> SnoozeNotificationOccurrenceAsync(long occurrenceId, AssetNotificationSnoozeRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_notification_occurrence_snooze", "occurrenceId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@occurrence_id",           DbType.Int64,  occurrenceId);
            AddParam(command, "@snoozed_until",           DbType.Date,   request.SnoozedUntil?.Date);
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> ListNotificationLogAsync(long organizationId, string? statusCode, string? activityCode, string? notificationClass, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_log");
        AddParam(command, "@organization_id",    DbType.Int64,  organizationId);
        AddParam(command, "@status_code",        DbType.String, Blank(statusCode), 20);
        AddParam(command, "@activity_code",      DbType.String, Blank(activityCode), 40);
        AddParam(command, "@notification_class", DbType.String, Blank(notificationClass), 20);
        AddParam(command, "@search",             DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",        DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",          DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public Task<AssetLifecycleResult> ReportNotificationDeliveryAsync(long notificationId, AssetNotificationDeliveryRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_notification_delivery", "notificationId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@notification_id", DbType.Int64,  notificationId);
            AddParam(command, "@status_code",     DbType.String, Blank(request.StatusCode), 20);
            AddParam(command, "@failure_reason",  DbType.String, Blank(request.FailureReason), 1000);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public async Task<object> ListSchedulerRunsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_scheduler_runs");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<Dictionary<string, object?>> RunSchedulerAsync(long? organizationId, string triggerCode, string actor, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_scheduler_run");
        // A pass over every organization runs the contract dates, renewals,
        // attestation runs and the notification sweep: allow it time.
        command.CommandTimeout = 600;
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@trigger_code",    DbType.String, triggerCode, 12);
        AddParam(command, "@actor",           DbType.String, actor, 100);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return rows.Count > 0 ? rows[0] : new Dictionary<string, object?>();
    }

    public async Task<object> ListMyNotificationsAsync(long employeeId, string? filter, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_mine");
        AddParam(command, "@employee_id", DbType.Int64,  employeeId);
        AddParam(command, "@filter",      DbType.String, Blank(filter), 20);
        AddParam(command, "@page_number", DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",   DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> CountMyNotificationsAsync(long employeeId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_mine_counts");
        AddParam(command, "@employee_id", DbType.Int64, employeeId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return rows.Count > 0 ? rows[0] : new Dictionary<string, object?>();
    }

    public Task<AssetLifecycleResult> MyNotificationActionAsync(long employeeId, long notificationId, AssetNotificationMineActionRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_notification_mine_action", "notificationId", command =>
        {
            AddParam(command, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(command, "@notification_id", DbType.Int64,  notificationId);
            AddParam(command, "@action",          DbType.String, Blank(request.Action), 20);
            AddParam(command, "@note",            DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public async Task<int> ReadAllMyNotificationsAsync(long employeeId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_notification_mine_read_all");
        AddParam(command, "@employee_id", DbType.Int64, employeeId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return rows.Count > 0 && rows[0].TryGetValue("markedCount", out var n) && n is not null ? Convert.ToInt32(n) : 0;
    }

    // ----------------------------------------------------------------
    // 438 -- Recurring asset activities
    // ----------------------------------------------------------------
    public async Task<object> GetActivityConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_activity_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var templates = await ReadRowsAsync(reader, ct);
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var evidenceFields = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();   // 439
        return new { templates, employees, evidenceFields };
    }

    public Task<AssetLifecycleResult> SaveActivitySettingAsync(AssetActivitySettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@template_code",              DbType.String,  Blank(request.TemplateCode), 40);
            AddParam(command, "@is_active",                  DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@lead_days",                  DbType.Int32,   request.LeadDays);
            AddParam(command, "@due_soon_days",              DbType.Int32,   request.DueSoonDays);
            AddParam(command, "@grouping_mode",              DbType.String,  Blank(request.GroupingMode) ?? "INDIVIDUAL", 12);
            AddParam(command, "@campaign_owner_employee_id", DbType.Int64,   request.CampaignOwnerEmployeeId);
            AddParam(command, "@result_review_required",        DbType.Boolean, request.ResultReviewRequired);          // 439
            AddParam(command, "@disposition_approval_required", DbType.Boolean, request.DispositionApprovalRequired);
            AddParam(command, "@restrict_on_overdue",           DbType.String,  Blank(request.RestrictOnOverdue), 100);
            AddParam(command, "@restrict_on_fail",              DbType.Boolean, request.RestrictOnFail);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
        }, ct);

    public async Task<object> ListActivitySchedulesAsync(long organizationId, string? templateCode, string? status, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_activity_schedules");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@template_code",   DbType.String, Blank(templateCode), 40);
        AddParam(command, "@status",          DbType.String, Blank(status), 16);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        AddParam(command, "@actor",           DbType.String, actor, 100);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> ListActivityOccurrencesAsync(long organizationId, string? templateCode, string? status, bool reconcileOnly, long? campaignId, string? search, bool awaitingDecision, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_activity_occurrences");
        AddParam(command, "@organization_id", DbType.Int64,   organizationId);
        AddParam(command, "@template_code",   DbType.String,  Blank(templateCode), 40);
        AddParam(command, "@status",          DbType.String,  Blank(status), 12);
        AddParam(command, "@reconcile_only",  DbType.Boolean, reconcileOnly);
        AddParam(command, "@campaign_id",     DbType.Int64,   campaignId);
        AddParam(command, "@search",          DbType.String,  Blank(search), 200);
        AddParam(command, "@awaiting_decision", DbType.Boolean, awaitingDecision);   // 439
        AddParam(command, "@page_number",     DbType.Int32,   pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,   pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> ListActivityCampaignsAsync(long organizationId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_activity_campaigns");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@page_number",     DbType.Int32, pageNumber);
        AddParam(command, "@page_size",       DbType.Int32, pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public Task<AssetLifecycleResult> ReconcileActivityAsync(long occurrenceId, AssetActivityReconcileRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_reconcile", "occurrenceId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@occurrence_id",           DbType.Int64,  occurrenceId);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 439 -- Results, dispositions, restrictive-use reviews
    // ----------------------------------------------------------------
    public async Task<object?> GetActivityOccurrenceAsync(long organizationId, long occurrenceId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_activity_occurrence_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@occurrence_id",   DbType.Int64, occurrenceId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var result = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            var dispositions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            var reviews = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { occurrence = header[0], result = result.Count > 0 ? result[0] : null, dispositions, reviews };
        }
        catch (SqlException ex) when (ex.Number == 54670) { return null; }
    }

    public Task<AssetLifecycleResult> SaveActivityResultAsync(long occurrenceId, AssetActivityResultRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_result_save", "occurrenceId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@occurrence_id",           DbType.Int64,   occurrenceId);
            AddParam(command, "@outcome",                 DbType.String,  Blank(request.Outcome), 12);
            AddParam(command, "@performed_date",          DbType.Date,    request.PerformedDate?.Date);
            AddParam(command, "@certificate_number",      DbType.String,  Blank(request.CertificateNumber), 100);
            AddParam(command, "@certificate_expiry",      DbType.Date,    request.CertificateExpiry?.Date);
            AddParam(command, "@new_expiry",              DbType.Date,    request.NewExpiry?.Date);
            AddParam(command, "@evidence_reference",      DbType.String,  Blank(request.EvidenceReference), 400);
            AddParam(command, "@result_note",             DbType.String,  Blank(request.ResultNote), 2000);
            AddParam(command, "@submit",                  DbType.Boolean, request.Submit ?? false);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideActivityResultAsync(long occurrenceId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_result_decide", "occurrenceId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@occurrence_id",           DbType.Int64,  occurrenceId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RequestActivityDispositionAsync(long occurrenceId, AssetActivityDispositionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_disposition_request", "dispositionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@occurrence_id",           DbType.Int64,  occurrenceId);
            AddParam(command, "@disposition_type",        DbType.String, Blank(request.DispositionType), 16);
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@revised_due_date",        DbType.Date,   request.RevisedDueDate?.Date);
            AddParam(command, "@review_date",             DbType.Date,   request.ReviewDate?.Date);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideActivityDispositionAsync(long dispositionId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_activity_disposition_decide", "dispositionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@disposition_id",          DbType.Int64,  dispositionId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> ListRestrictiveReviewsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_restrictive_reviews");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 10);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        AddParam(command, "@actor",           DbType.String, actor, 100);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public Task<AssetLifecycleResult> DecideRestrictiveReviewAsync(long reviewId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_restrictive_review_decide", "reviewId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@review_id",               DbType.Int64,  reviewId);
            AddParam(command, "@decision_code",           DbType.String, Blank(request.Decision), 30);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 440 -- CMDB relationships
    // ----------------------------------------------------------------
    public async Task<object> GetRelationshipConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_relationship_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var types = await ReadRowsAsync(reader, ct);
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { types, employees };
    }

    public async Task<object> LookupCisAsync(long organizationId, string? ciKind, string? search, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_ci_lookup");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@ci_kind",         DbType.String, Blank(ciKind), 12);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@top",             DbType.Int32,  50);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object> ListRelationshipsAsync(long organizationId, string? ciKind, long? ciId, string? typeCode, string? status, bool criticalOnly, bool pendingOnly, string? search, int pageNumber, int pageSize, string actor, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_relationships");
        AddParam(command, "@organization_id", DbType.Int64,   organizationId);
        AddParam(command, "@ci_kind",         DbType.String,  Blank(ciKind), 12);
        AddParam(command, "@ci_id",           DbType.Int64,   ciId);
        AddParam(command, "@type_code",       DbType.String,  Blank(typeCode), 30);
        AddParam(command, "@status",          DbType.String,  Blank(status), 10);
        AddParam(command, "@critical_only",   DbType.Boolean, criticalOnly);
        AddParam(command, "@pending_only",    DbType.Boolean, pendingOnly);
        AddParam(command, "@search",          DbType.String,  Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,   pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,   pageSize);
        AddParam(command, "@actor",           DbType.String,  actor, 100);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetRelationshipAsync(long organizationId, long relationshipId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_relationship_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@relationship_id", DbType.Int64, relationshipId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { relationship = header[0], history };
        }
        catch (SqlException ex) when (ex.Number == 54709) { return null; }
    }

    public Task<AssetLifecycleResult> SaveRelationshipAsync(AssetRelationshipSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_relationship_save", "relationshipId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@relationship_id",         DbType.Int64,   request.RelationshipId);
            AddParam(command, "@relationship_type_code",  DbType.String,  Blank(request.RelationshipTypeCode), 30);
            AddParam(command, "@source_kind",             DbType.String,  Blank(request.SourceKind), 12);
            AddParam(command, "@source_id",               DbType.Int64,   request.SourceId);
            AddParam(command, "@target_kind",             DbType.String,  Blank(request.TargetKind), 12);
            AddParam(command, "@target_id",               DbType.Int64,   request.TargetId);
            AddParam(command, "@is_critical",             DbType.Boolean, request.IsCritical ?? false);
            AddParam(command, "@dependency_criticality",  DbType.String,  Blank(request.DependencyCriticality), 10);
            AddParam(command, "@impact_weight",           DbType.Decimal, request.ImpactWeight);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@confidence_pct",          DbType.Int32,   request.ConfidencePct);
            AddParam(command, "@owner_employee_id",       DbType.Int64,   request.OwnerEmployeeId);
            AddParam(command, "@verifier_employee_id",    DbType.Int64,   request.VerifierEmployeeId);
            AddParam(command, "@evidence_reference",      DbType.String,  Blank(request.EvidenceReference), 400);
            AddParam(command, "@change_reference",        DbType.String,  Blank(request.ChangeReference), 200);
            AddParam(command, "@service_role",            DbType.String,  Blank(request.ServiceRole), 100);   // 441
            AddParam(command, "@reason",                  DbType.String,  Blank(request.Reason), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RelationshipActionAsync(long relationshipId, AssetRelationshipActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_relationship_action", "relationshipId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@relationship_id",         DbType.Int64,  relationshipId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 20);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> GetImpactAsync(long organizationId, string ciKind, long ciId, string direction, int maxDepth, bool criticalOnly, long? previewRelationshipId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_ci_impact");
        AddParam(command, "@organization_id",         DbType.Int64,   organizationId);
        AddParam(command, "@ci_kind",                 DbType.String,  ciKind, 12);
        AddParam(command, "@ci_id",                   DbType.Int64,   ciId);
        AddParam(command, "@direction",               DbType.String,  direction, 10);
        AddParam(command, "@max_depth",               DbType.Int32,   maxDepth);
        AddParam(command, "@critical_only",           DbType.Boolean, criticalOnly);
        AddParam(command, "@preview_relationship_id", DbType.Int64,   previewRelationshipId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        var summary = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        var services = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();   // 441
        return new { rows, summary = summary.Count > 0 ? summary[0] : null, services };
    }

    // ----------------------------------------------------------------
    // 441 -- Business services
    // ----------------------------------------------------------------
    public async Task<object> GetBusinessServiceConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_business_service_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var departments = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var businessFunctions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var locations = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var criticalities = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { settings = settings.Count > 0 ? settings[0] : null, employees, departments, businessFunctions, locations, criticalities };
    }

    public async Task<object> ListBusinessServicesAsync(long organizationId, string? status, string? serviceType, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_business_services");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 10);
        AddParam(command, "@service_type",    DbType.String, Blank(serviceType), 16);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetBusinessServiceAsync(long organizationId, long serviceId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_business_service_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@service_id",      DbType.Int64, serviceId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var header = await ReadRowsAsync(reader, ct);
            if (header.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var consumers = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var supporting = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var supports = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var conflicts = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var history = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { service = header[0], consumers, supporting, supports, conflicts, history };
        }
        catch (SqlException ex) when (ex.Number == 54731) { return null; }
    }

    public Task<AssetLifecycleResult> SaveBusinessServiceAsync(BusinessServiceSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_business_service_save", "serviceId", command =>
        {
            AddParam(command, "@organization_id",             DbType.Int64,   request.OrganizationId);
            AddParam(command, "@service_id",                  DbType.Int64,   request.ServiceId);
            AddParam(command, "@service_code",                DbType.String,  Blank(request.ServiceCode), 40);
            AddParam(command, "@service_name",                DbType.String,  Blank(request.ServiceName), 200);
            AddParam(command, "@service_type",                DbType.String,  Blank(request.ServiceType), 16);
            AddParam(command, "@description",                 DbType.String,  Blank(request.Description), 2000);
            AddParam(command, "@customer_outcome",            DbType.String,  Blank(request.CustomerOutcome), 1000);
            AddParam(command, "@business_owner_employee_id",  DbType.Int64,   request.BusinessOwnerEmployeeId);
            AddParam(command, "@service_manager_employee_id", DbType.Int64,   request.ServiceManagerEmployeeId);
            AddParam(command, "@accountable_department_id",   DbType.Int64,   request.AccountableDepartmentId);
            AddParam(command, "@criticality_id",              DbType.Int32,   request.CriticalityId);
            AddParam(command, "@confidentiality_rating",      DbType.Byte,    request.ConfidentialityRating);
            AddParam(command, "@integrity_rating",            DbType.Byte,    request.IntegrityRating);
            AddParam(command, "@availability_rating",         DbType.Byte,    request.AvailabilityRating);
            AddParam(command, "@rto_hours",                   DbType.Decimal, request.RtoHours);
            AddParam(command, "@rpo_hours",                   DbType.Decimal, request.RpoHours);
            AddParam(command, "@mtpd_hours",                  DbType.Decimal, request.MtpdHours);
            AddParam(command, "@service_hours",               DbType.String,  Blank(request.ServiceHours), 200);
            AddParam(command, "@sla_text",                    DbType.String,  Blank(request.SlaText), 1000);
            AddParam(command, "@data_classification",         DbType.String,  Blank(request.DataClassification), 100);
            AddParam(command, "@privacy_classification",      DbType.String,  Blank(request.PrivacyClassification), 100);
            AddParam(command, "@review_date",                 DbType.Date,    request.ReviewDate?.Date);
            AddParam(command, "@consumers_json",              DbType.String,
                request.Consumers is null ? null : System.Text.Json.JsonSerializer.Serialize(request.Consumers.Select(c => new
                {
                    consumerKind = c.ConsumerKind, consumerRefId = c.ConsumerRefId, consumerName = c.ConsumerName, note = c.Note
                })));
            AddParam(command, "@expected_record_version",     DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",           DbType.Int64,   actorEmployeeId);
            AddParam(command, "@actor",                       DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> TransitionBusinessServiceAsync(long serviceId, BusinessServiceTransitionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_business_service_transition", "serviceId", command =>
        {
            AddParam(command, "@organization_id",          DbType.Int64,  request.OrganizationId);
            AddParam(command, "@service_id",               DbType.Int64,  serviceId);
            AddParam(command, "@to_status",                DbType.String, Blank(request.ToStatus), 10);
            AddParam(command, "@note",                     DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@consumer_review_note",     DbType.String, Blank(request.ConsumerReviewNote), 1000);
            AddParam(command, "@contract_assessment_note", DbType.String, Blank(request.ContractAssessmentNote), 1000);
            AddParam(command, "@expected_record_version",  DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",        DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                    DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> DecideBusinessServiceRetirementAsync(long serviceId, AssetLifecycleDecisionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_business_service_retirement_decide", "serviceId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@service_id",              DbType.Int64,  serviceId);
            AddParam(command, "@decision",                DbType.String, request.Decision, 10);
            AddParam(command, "@decision_note",           DbType.String, Blank(request.DecisionNote), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveBusinessServiceSettingAsync(BusinessServiceSettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_business_service_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",              DbType.Int64,   request.OrganizationId);
            AddParam(command, "@min_supporting_relationships", DbType.Int32,   request.MinSupportingRelationships);
            AddParam(command, "@retirement_approval_required", DbType.Boolean, request.RetirementApprovalRequired ?? true);
            AddParam(command, "@actor",                        DbType.String,  actor, 100);
        }, ct);

    public async Task<object> ListBusinessServiceConflictsAsync(long organizationId, long? serviceId, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_business_service_conflicts");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@service_id",      DbType.Int64,  serviceId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    // ----------------------------------------------------------------
    // 442 -- Asset discovery and reconciliation
    // ----------------------------------------------------------------
    public async Task<object> GetDiscoveryConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_discovery_config_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var empty = new List<Dictionary<string, object?>>();
        var sources = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var priorities = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var rules = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var fields = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { settings = settings.Count > 0 ? settings[0] : null, sources, priorities, rules, employees, fields };
    }

    public Task<AssetLifecycleResult> SaveDiscoverySourceAsync(AssetDiscoverySourceRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_discovery_source_save", "sourceId", command =>
        {
            AddParam(command, "@organization_id",            DbType.Int64,   request.OrganizationId);
            AddParam(command, "@source_id",                  DbType.Int64,   request.SourceId);
            AddParam(command, "@source_code",                DbType.String,  Blank(request.SourceCode), 40);
            AddParam(command, "@source_name",                DbType.String,  Blank(request.SourceName), 200);
            AddParam(command, "@source_type",                DbType.String,  Blank(request.SourceType), 12);
            AddParam(command, "@collection_mode",            DbType.String,  Blank(request.CollectionMode), 8);
            AddParam(command, "@scope_text",                 DbType.String,  Blank(request.ScopeText), 400);
            AddParam(command, "@mapping_version",            DbType.String,  Blank(request.MappingVersion), 40);
            AddParam(command, "@owner_employee_id",          DbType.Int64,   request.OwnerEmployeeId);
            AddParam(command, "@credential_reference",       DbType.String,  Blank(request.CredentialReference), 200);
            AddParam(command, "@trust_level",                DbType.Int32,   request.TrustLevel);
            AddParam(command, "@expected_interval_hours",    DbType.Int32,   request.ExpectedIntervalHours);
            AddParam(command, "@raw_retention_days",         DbType.Int32,   request.RawRetentionDays);
            AddParam(command, "@observation_retention_days", DbType.Int32,   request.ObservationRetentionDays);
            AddParam(command, "@is_active",                  DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@expected_record_version",    DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                      DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveDiscoveryPrioritiesAsync(long sourceId, AssetDiscoveryPrioritiesRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_discovery_priorities_save", "sourceId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_id",       DbType.Int64,  sourceId);
            AddParam(command, "@priorities_json", DbType.String, System.Text.Json.JsonSerializer.Serialize(
                (request.Priorities ?? new List<AssetDiscoveryPriorityItem>()).Select(p => new
                {
                    fieldKey = p.FieldKey, sourceRole = p.SourceRole, priority = p.Priority
                })));
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveIdentificationRuleAsync(AssetIdentificationRuleRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_identification_rule_save", "ruleId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@rule_id",         DbType.Int64,   request.RuleId);
            AddParam(command, "@rule_name",       DbType.String,  Blank(request.RuleName), 120);
            AddParam(command, "@attribute_keys",  DbType.String,  Blank(request.AttributeKeys), 400);
            AddParam(command, "@strength",        DbType.String,  Blank(request.Strength), 10);
            AddParam(command, "@weight",          DbType.Int32,   request.Weight);
            AddParam(command, "@is_active",       DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@display_order",   DbType.Int32,   request.DisplayOrder ?? 100);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveDiscoverySettingAsync(AssetDiscoverySettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_discovery_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",       DbType.Int64,   request.OrganizationId);
            AddParam(command, "@auto_match_score",      DbType.Int32,   request.AutoMatchScore);
            AddParam(command, "@suggested_score",       DbType.Int32,   request.SuggestedScore);
            AddParam(command, "@manual_review_score",   DbType.Int32,   request.ManualReviewScore);
            AddParam(command, "@stale_multiplier",      DbType.Int32,   request.StaleMultiplier);
            AddParam(command, "@verification_days",     DbType.Int32,   request.VerificationDays);
            AddParam(command, "@create_conflict_tasks", DbType.Boolean, request.CreateConflictTasks ?? true);
            AddParam(command, "@actor",                 DbType.String,  actor, 100);
        }, ct);

    public async Task<(object? Data, int? ErrorNumber, string? Error)> IngestDiscoveryBatchAsync(long sourceId, AssetDiscoveryIngestRequest request, long? actorEmployeeId, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_discovery_ingest");
            command.CommandTimeout = 600;   // up to 5000 records, each reconciled on its own
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_id",         DbType.Int64,  sourceId);
            AddParam(command, "@batch_reference",   DbType.String, Blank(request.BatchReference), 100);
            AddParam(command, "@channel",           DbType.String, Blank(request.Channel) ?? "UI", 10);
            AddParam(command, "@records_json",      DbType.String, request.Records is { } r ? r.GetRawText() : null);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var batch = await ReadRowsAsync(reader, ct);
            var records = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return (new { batch = batch.Count > 0 ? batch[0] : null, records }, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService sp_asset_discovery_ingest refused ({Number})", ex.Number);
            return (null, ex.Number, ex.Message);
        }
    }

    public async Task<object> ListDiscoveryBatchesAsync(long organizationId, long? sourceId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_discovery_batches");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@source_id",       DbType.Int64, sourceId);
        AddParam(command, "@page_number",     DbType.Int32, pageNumber);
        AddParam(command, "@page_size",       DbType.Int32, pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetDiscoveryBatchAsync(long organizationId, long batchId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_discovery_batch_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@batch_id",        DbType.Int64, batchId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var batch = await ReadRowsAsync(reader, ct);
            if (batch.Count == 0) return null;
            var records = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { batch = batch[0], records };
        }
        catch (SqlException ex) when (ex.Number == 54779) { return null; }
    }

    public async Task<object> ListReconciliationExceptionsAsync(long organizationId, string? status, string? kind, long? sourceId, long? assetId, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_reconciliation_exceptions");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 10);
        AddParam(command, "@exception_kind",  DbType.String, Blank(kind), 16);
        AddParam(command, "@source_id",       DbType.Int64,  sourceId);
        AddParam(command, "@asset_id",        DbType.Int64,  assetId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public Task<AssetLifecycleResult> ResolveReconciliationExceptionAsync(long exceptionId, AssetReconciliationResolveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_reconciliation_resolve", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@exception_id",            DbType.Int64,  exceptionId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 20);
            AddParam(command, "@asset_id",                DbType.Int64,  request.AssetId);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> ListDiscoveryConfidenceAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_discovery_confidence");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 12);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetDiscoveryAssetAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_discovery_asset_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var confidence = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var links = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var attributes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var exceptions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { confidence = confidence.Count > 0 ? confidence[0] : null, links, attributes, exceptions };
        }
        catch (SqlException ex) when (ex.Number == 54777) { return null; }
    }

    // ----------------------------------------------------------------
    // 443 -- Discovery follow-up: candidate registration, stale review
    // ----------------------------------------------------------------
    public async Task<object?> GetDiscoveryCandidateAsync(long organizationId, long exceptionId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_discovery_candidate_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@exception_id",    DbType.Int64, exceptionId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var exception = await ReadRowsAsync(reader, ct);
            if (exception.Count == 0) return null;
            var attributes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { exception = exception[0], attributes };
        }
        catch (SqlException ex) when (ex.Number == 54773) { return null; }
    }

    public async Task<object> ListStaleReviewsAsync(long organizationId, string? view, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_stale_reviews");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@view",            DbType.String, Blank(view), 10);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var settings = await ReadRowsAsync(reader, ct);
        var rows = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { settings = settings.Count > 0 ? settings[0] : null, rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetStaleReviewAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_stale_review_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var asset = await ReadRowsAsync(reader, ct);
            if (asset.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var links = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var dependencies = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var reviews = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { asset = asset[0], links, dependencies, reviews };
        }
        catch (SqlException ex) when (ex.Number == 54781) { return null; }
    }

    public Task<AssetLifecycleResult> SaveStaleSettingAsync(AssetStaleSettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_stale_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@retire_after_days", DbType.Int32,  request.RetireAfterDays);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> OpenStaleReviewAsync(AssetStaleReviewOpenRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_stale_review_open", "reviewId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",        DbType.Int64,  request.AssetId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // REQUEST_DECOMMISSION returns the lifecycle move's result set first; the
    // review result (ReviewId, Result) is always the last result set.
    public async Task<AssetLifecycleResult> StaleReviewActionAsync(long reviewId, AssetStaleReviewActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_stale_review_action");
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@review_id",               DbType.Int64,  reviewId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 24);
            AddParam(command, "@source_outcome",          DbType.String, Blank(request.SourceOutcome), 10);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
            var last = new List<Dictionary<string, object?>>();
            await using (var reader = await command.ExecuteReaderAsync(ct))
            {
                do
                {
                    var rows = await ReadRowsAsync(reader, ct);
                    if (rows.Count > 0) last = rows;
                } while (await reader.NextResultAsync(ct));
            }
            var row = last.Count > 0 ? last[0] : new Dictionary<string, object?>();
            row.TryGetValue("reviewId", out var id);
            row.TryGetValue("result", out var result);
            return new AssetLifecycleResult(true, Convert.ToString(result) ?? "SAVED", id is null ? null : Convert.ToInt64(id), null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService sp_asset_stale_review_action refused ({Number})", ex.Number);
            return new AssetLifecycleResult(false, null, null, ex.Number, ex.Message);
        }
    }

    // ----------------------------------------------------------------
    // 444 -- Asset merge
    // ----------------------------------------------------------------
    public Task<object> ListMergesAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct) =>
        ListMergeSplitEventsAsync("MERGE", organizationId, status, search, pageNumber, pageSize, ct);

    // 445: merges and splits share the event list (@event_kind).
    private async Task<object> ListMergeSplitEventsAsync(string kind, long organizationId, string? status, string? search, int pageNumber,
        int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_merge_events");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        AddParam(command, "@event_kind",      DbType.String, kind, 10);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object?> GetMergeAsync(long organizationId, long eventId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_merge_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@event_id",        DbType.Int64, eventId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var merge = await ReadRowsAsync(reader, ct);
            if (merge.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var assets = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var approvals = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var blockers = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var plan = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var outcomes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var fields = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var impact = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { merge = merge[0], assets, approvals, blockers, plan, outcomes, fields, impact };
        }
        catch (SqlException ex) when (ex.Number == 52902) { return null; }
    }

    public Task<AssetLifecycleResult> SaveMergeAsync(AssetMergeSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_merge_save", "eventId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_id",                DbType.Int64,  request.EventId);
            AddParam(command, "@survivor_asset_id",       DbType.Int64,  request.SurvivorAssetId);
            AddParam(command, "@duplicates_json",         DbType.String,
                System.Text.Json.JsonSerializer.Serialize(request.DuplicateAssetIds ?? new List<long>()));
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@field_choices_json",      DbType.String,
                request.FieldChoices is { Count: > 0 } choices ? System.Text.Json.JsonSerializer.Serialize(choices) : null);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 445 -- Asset split
    // ----------------------------------------------------------------
    public Task<object> ListSplitsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct) =>
        ListMergeSplitEventsAsync("SPLIT", organizationId, status, search, pageNumber, pageSize, ct);

    public async Task<object?> GetSplitAsync(long organizationId, long eventId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_split_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@event_id",        DbType.Int64, eventId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var split = await ReadRowsAsync(reader, ct);
            if (split.Count == 0) return null;
            var empty = new List<Dictionary<string, object?>>();
            var assets = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var approvals = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var blockers = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var plan = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var outcomes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var impact = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { split = split[0], assets, approvals, blockers, plan, outcomes, impact };
        }
        catch (SqlException ex) when (ex.Number == 52902) { return null; }
    }

    public Task<AssetLifecycleResult> SaveSplitAsync(AssetSplitSaveRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_split_save", "eventId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_id",                DbType.Int64,  request.EventId);
            AddParam(command, "@source_asset_id",         DbType.Int64,  request.SourceAssetId);
            AddParam(command, "@results_json",            DbType.String,
                System.Text.Json.JsonSerializer.Serialize(request.ResultAssetIds ?? new List<long>()));
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@allocations_json",        DbType.String, System.Text.Json.JsonSerializer.Serialize(
                (request.Allocations ?? new List<AssetSplitAllocationItem>()).Select(a => new
                {
                    objectKind = a.ObjectKind, objectId = a.ObjectId, objectKey = a.ObjectKey, targetAssetId = a.TargetAssetId, fieldMode = a.FieldMode
                })));
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // 444 / 445: one action procedure for merges and splits.
    public Task<AssetLifecycleResult> MergeActionAsync(long eventId, AssetMergeActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_merge_action", "eventId", command =>
        {
            command.CommandTimeout = 300;   // EXECUTE / RECOVER walk every object of up to 10 duplicates
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_id",                DbType.Int64,  eventId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 10);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 446 -- Asset Value per asset
    // ----------------------------------------------------------------
    public async Task<object?> GetAssetValuationAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_valuation_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var current = await ReadRowsAsync(reader, ct);
            var empty = new List<Dictionary<string, object?>>();
            var history  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var risks    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 447
            var findings = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;   // 447
            return new { current = current.Count > 0 ? current[0] : null, history, risks, findings };
        }
        catch (SqlException ex) when (ex.Number == 53000) { return null; }
    }

    public Task<AssetLifecycleResult> RecalculateAssetValuationAsync(long assetId, AssetValuationRecalculateRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_valuation_recalculate", "assetId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",          DbType.Int64,  assetId);
            AddParam(command, "@reason_text",       DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SetAssetValuationMethodAsync(long assetId, AssetValuationMethodRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_valuation_method_set", "assetId", command =>
        {
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",          DbType.Int64,  assetId);
            AddParam(command, "@method",            DbType.String, Blank(request.Method), 30);
            AddParam(command, "@reason_text",       DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    public async Task<object> GetValuationRecalcPreviewAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_valuation_recalc_preview");
        command.CommandTimeout = 120;   // evaluates every asset of the organization
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var empty = new List<Dictionary<string, object?>>();
        var summary = await ReadRowsAsync(reader, ct);
        var moves   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var assets  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var runs    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { summary = summary.Count > 0 ? summary[0] : null, moves, assets, runs };
    }

    public Task<AssetLifecycleResult> RunValuationRecalcAsync(AssetValuationRecalcRunRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_valuation_recalc_run", "runId", command =>
        {
            command.CommandTimeout = 600;   // one calculation per affected asset
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@reason_text",       DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@expected_affected", DbType.Int32,  request.ExpectedAffected);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",             DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 447 -- CIA and criticality consistency rules
    // ----------------------------------------------------------------
    public async Task<object> ListConsistencyRulesAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_consistency_rules");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await ReadRowsAsync(reader, ct);
    }

    public async Task<object?> GetConsistencyRuleAsync(long organizationId, long ruleId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_consistency_rule_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@rule_id",         DbType.Int64, ruleId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var rule       = await ReadRowsAsync(reader, ct);
            var conditions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var versions   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { rule = rule.Count > 0 ? rule[0] : null, conditions, versions };
        }
        catch (SqlException ex) when (ex.Number == 53011) { return null; }
    }

    public async Task<object> GetConsistencyOperandsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_consistency_operands");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var operands = await ReadRowsAsync(reader, ct);
        var scopes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { operands, scopes };
    }

    public async Task<object?> PreviewConsistencyRuleAsync(long organizationId, long ruleId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_consistency_rule_preview");
            command.CommandTimeout = 120;   // evaluates every asset of the organization
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@rule_id",         DbType.Int64, ruleId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var summary = await ReadRowsAsync(reader, ct);
            var assets = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { summary = summary.Count > 0 ? summary[0] : null, assets };
        }
        catch (SqlException ex) when (ex.Number == 53011) { return null; }
    }

    public Task<AssetLifecycleResult> SaveConsistencyRuleAsync(AssetConsistencyRuleSaveRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_consistency_rule_save", "ruleId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@rule_id",                 DbType.Int64,   request.RuleId);
            AddParam(command, "@rule_name",               DbType.String,  Blank(request.RuleName), 200);
            AddParam(command, "@description",             DbType.String,  Blank(request.Description), 1000);
            AddParam(command, "@scope_kind",              DbType.String,  Blank(request.ScopeKind) ?? "TENANT", 12);
            AddParam(command, "@scope_ref_id",            DbType.Int64,   request.ScopeRefId);
            AddParam(command, "@severity",                DbType.String,  Blank(request.Severity), 20);
            AddParam(command, "@action_code",             DbType.String,  Blank(request.ActionCode), 20);
            AddParam(command, "@override_allowed",        DbType.Boolean, request.OverrideAllowed ?? true);
            AddParam(command, "@max_override_days",       DbType.Int32,   request.MaxOverrideDays);
            AddParam(command, "@effective_from",          DbType.Date,    request.EffectiveFrom?.Date);
            AddParam(command, "@effective_to",            DbType.Date,    request.EffectiveTo?.Date);
            AddParam(command, "@change_reason",           DbType.String,  Blank(request.ChangeReason), 1000);
            AddParam(command, "@conditions_json",         DbType.String,  System.Text.Json.JsonSerializer.Serialize(
                (request.Conditions ?? new List<AssetConsistencyConditionItem>()).Select(c => new
                {
                    groupNo = c.GroupNo ?? 1, operandKey = c.OperandKey, operatorCode = c.OperatorCode, compareValue = c.CompareValue
                })));
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> ConsistencyRuleActionAsync(long ruleId, AssetConsistencyRuleActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_consistency_rule_action", "ruleId", command =>
        {
            command.CommandTimeout = 300;   // ACTIVATE / RETIRE re-evaluate the organization
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@rule_id",                 DbType.Int64,  ruleId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 12);
            AddParam(command, "@reason",                  DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public async Task<object> ListConsistencyFindingsAsync(long organizationId, string? status, string? severity, long? assetId, string? search,
        int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_consistency_findings");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@severity",        DbType.String, Blank(severity), 20);
        AddParam(command, "@asset_id",        DbType.Int64,  assetId);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        var counts = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize, counts };
    }

    public Task<AssetLifecycleResult> ConsistencyFindingActionAsync(long findingId, AssetConsistencyFindingActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_consistency_finding_action", "findingId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@finding_id",              DbType.Int64,  findingId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 12);
            AddParam(command, "@rationale",               DbType.String, Blank(request.Rationale), 1000);
            AddParam(command, "@evidence",                DbType.String, Blank(request.Evidence), 1000);
            AddParam(command, "@owner_employee_id",       DbType.Int64,  request.OwnerEmployeeId);
            AddParam(command, "@review_date",             DbType.Date,   request.ReviewDate?.Date);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RunConsistencyAsync(AssetConsistencyRunRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_consistency_run", "organizationId", command =>
        {
            command.CommandTimeout = 300;
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",        DbType.Int64,  request.AssetId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 448 -- Asset privacy
    // ----------------------------------------------------------------
    public async Task<object> ListPrivacyAssetsAsync(long organizationId, string? status, string? search, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_privacy_assets");
        command.CommandTimeout = 120;   // evaluates every asset of the organization
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@search",          DbType.String, Blank(search), 200);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        var counts = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize, counts };
    }

    public async Task<object?> GetPrivacyAssetAsync(long organizationId, long assetId, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_privacy_asset_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@asset_id",        DbType.Int64, assetId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var status     = await ReadRowsAsync(reader, ct);
            var gaps       = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var exceptions = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var reviews    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { status = status.Count > 0 ? status[0] : null, gaps, exceptions, reviews };
        }
        catch (SqlException ex) when (ex.Number == 53051) { return null; }
    }

    public async Task<object> ListPrivacyExceptionsAsync(long organizationId, string? status, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_privacy_exceptions");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 20);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> ListPrivacyReviewsAsync(long organizationId, string? status, string? kind, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_privacy_reviews");
        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@status",          DbType.String, Blank(status), 10);
        AddParam(command, "@kind",            DbType.String, Blank(kind), 10);
        AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> GetPrivacyRequirementsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_privacy_requirements");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var empty = new List<Dictionary<string, object?>>();
        var requirements = await ReadRowsAsync(reader, ct);
        var overrides    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var assetTypes   = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var employees    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { requirements, overrides, assetTypes, employees };
    }

    public Task<AssetLifecycleResult> SavePrivacySettingAsync(AssetPrivacySettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_privacy_setting_save", "settingId", command =>
        {
            AddParam(command, "@organization_id",    DbType.Int64,   request.OrganizationId);
            AddParam(command, "@asset_type_id",      DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@requirement_code",   DbType.String,  Blank(request.RequirementCode), 30);
            AddParam(command, "@enforcement",        DbType.String,  Blank(request.Enforcement), 10);
            AddParam(command, "@exception_allowed",  DbType.Boolean, request.ExceptionAllowed ?? true);
            AddParam(command, "@max_exception_days", DbType.Int32,   request.MaxExceptionDays);
            AddParam(command, "@actor",              DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RequestPrivacyExceptionAsync(AssetPrivacyExceptionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_privacy_exception_request", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",       DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",              DbType.Int64,  request.AssetId);
            AddParam(command, "@requirement_code",      DbType.String, Blank(request.RequirementCode), 30);
            AddParam(command, "@reason",                DbType.String, Blank(request.Reason), 1000);
            AddParam(command, "@compensating_controls", DbType.String, Blank(request.CompensatingControls), 1000);
            AddParam(command, "@owner_employee_id",     DbType.Int64,  request.OwnerEmployeeId);
            AddParam(command, "@expiry_date",           DbType.Date,   request.ExpiryDate?.Date);
            AddParam(command, "@actor_employee_id",     DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                 DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> PrivacyExceptionActionAsync(long exceptionId, AssetPrivacyExceptionActionRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_privacy_exception_action", "exceptionId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@exception_id",            DbType.Int64,  exceptionId);
            AddParam(command, "@action",                  DbType.String, Blank(request.Action), 12);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> CompletePrivacyReviewAsync(long reviewId, AssetPrivacyReviewCompleteRequest request, long? actorEmployeeId, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_privacy_review_complete", "reviewId", command =>
        {
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@review_id",               DbType.Int64,  reviewId);
            AddParam(command, "@outcome",                 DbType.String, Blank(request.Outcome), 12);
            AddParam(command, "@note",                    DbType.String, Blank(request.Note), 1000);
            AddParam(command, "@evidence",                DbType.String, Blank(request.Evidence), 1000);
            AddParam(command, "@next_date",               DbType.Date,   request.NextDate?.Date);
            AddParam(command, "@expected_record_version", DbType.Int64,  request.ExpectedRecordVersion);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  actorEmployeeId);
            AddParam(command, "@actor",                   DbType.String, actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> RunPrivacyAsync(AssetPrivacyRunRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_privacy_run", "organizationId", command =>
        {
            command.CommandTimeout = 300;
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",        DbType.Int64,  request.AssetId);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 450 -- Asset governance KPIs
    // ----------------------------------------------------------------
    public async Task<object?> GetGovernanceAsync(long organizationId, long? snapshotId, int trendDays, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_governance_get");
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@snapshot_id",     DbType.Int64, snapshotId);
            AddParam(command, "@trend_days",      DbType.Int32, trendDays);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var snapshot = await ReadRowsAsync(reader, ct);
            var kpis     = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var trend    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { snapshot = snapshot.Count > 0 ? snapshot[0] : null, kpis, trend };
        }
        catch (SqlException ex) when (ex.Number is 53080 or 53083) { return null; }
    }

    public async Task<object?> ListGovernanceItemsAsync(long organizationId, long snapshotId, string kpiCode, string? outcome, string? search,
        int pageNumber, int pageSize, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_governance_items");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@snapshot_id",     DbType.Int64,  snapshotId);
            AddParam(command, "@kpi_code",        DbType.String, Blank(kpiCode), 30);
            AddParam(command, "@outcome",         DbType.String, Blank(outcome), 8);
            AddParam(command, "@search",          DbType.String, Blank(search), 200);
            AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
            AddParam(command, "@page_size",       DbType.Int32,  pageSize);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            var totals = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
            return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize, totals };
        }
        catch (SqlException ex) when (ex.Number is 53080 or 53081 or 53083) { return null; }
    }

    public async Task<object> ListGovernanceSnapshotsAsync(long organizationId, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_governance_snapshots");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@page_number",     DbType.Int32, pageNumber);
        AddParam(command, "@page_size",       DbType.Int32, pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    public async Task<object> GetGovernanceSettingsAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_governance_settings");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var empty = new List<Dictionary<string, object?>>();
        var kpis              = await ReadRowsAsync(reader, ct);
        var overall           = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var relationshipRules = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var assetTypes        = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var relationshipTypes = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        var services          = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
        return new { kpis, overall = overall.Count > 0 ? overall[0] : null, relationshipRules, assetTypes, relationshipTypes,
                     services = services.Count > 0 ? services[0] : null };
    }

    public Task<AssetLifecycleResult> SaveGovernanceSettingAsync(AssetGovernanceSettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_governance_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@kpi_code",        DbType.String,  Blank(request.KpiCode), 30);
            AddParam(command, "@reset",           DbType.Boolean, request.Reset ?? false);
            AddParam(command, "@is_enabled",      DbType.Boolean, request.IsEnabled ?? true);
            AddParam(command, "@weight",          DbType.Int32,   request.Weight);
            AddParam(command, "@target_value",    DbType.Decimal, request.TargetValue);
            AddParam(command, "@warning_value",   DbType.Decimal, request.WarningValue);
            AddParam(command, "@period_days",     DbType.Int32,   request.PeriodDays);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveGovernanceOrgSettingAsync(AssetGovernanceOrgSettingRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_governance_org_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id",     DbType.Int64,   request.OrganizationId);
            AddParam(command, "@overall_target",      DbType.Decimal, request.OverallTarget);
            AddParam(command, "@overall_warning",     DbType.Decimal, request.OverallWarning);
            AddParam(command, "@item_retention_days", DbType.Int32,   request.ItemRetentionDays);
            AddParam(command, "@actor",               DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> SaveGovernanceRelationshipRuleAsync(AssetGovernanceRelationshipRuleRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_governance_relationship_rule_save", "ruleId", command =>
        {
            AddParam(command, "@organization_id",        DbType.Int64,   request.OrganizationId);
            AddParam(command, "@rule_id",                DbType.Int64,   request.RuleId);
            AddParam(command, "@asset_type_id",          DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@relationship_type_code", DbType.String,  Blank(request.RelationshipTypeCode), 30);
            AddParam(command, "@asset_side",             DbType.String,  Blank(request.AssetSide), 6);
            AddParam(command, "@min_count",              DbType.Int32,   request.MinCount ?? 1);
            AddParam(command, "@is_active",              DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@actor",                  DbType.String,  actor, 100);
        }, ct);

    public Task<AssetLifecycleResult> TakeGovernanceSnapshotAsync(AssetGovernanceSnapshotRequest request, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_governance_snapshot_take", "snapshotId", command =>
        {
            command.CommandTimeout = 600;   // every KPI over every record of the organization
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_code",     DbType.String, "MANUAL", 10);
            AddParam(command, "@actor",           DbType.String, actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 452 -- Report catalogue and exports (BRD 13.4 / 13.4.1)
    // ----------------------------------------------------------------
    /// <summary>Rows an export may carry; one more is read to detect an export that is too large (53107).</summary>
    private const int ReportExportRowLimit = 50000;

    public async Task<object?> GetReportCatalogueAsync(long organizationId, string? allowedAreas, bool canApprove, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_catalogue");
            AddParam(command, "@organization_id", DbType.Int64,   organizationId);
            AddParam(command, "@allowed_areas",   DbType.String,  Blank(allowedAreas), 2000);
            AddParam(command, "@can_approve",     DbType.Boolean, canApprove);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var reports       = await ReadRowsAsync(reader, ct);
            var assetStatuses = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var assetTypes    = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { reports, assetStatuses, assetTypes, exportRowLimit = ReportExportRowLimit };
        }
        catch (SqlException ex) when (ex.Number == 53100) { return null; }
    }

    public async Task<AssetReportResult> RunReportAsync(AssetReportRunRequest request, string? allowedAreas, bool canApprove, int pageNumber,
        int pageSize, CancellationToken ct)
    {
        try
        {
            var (columns, rows) = await ExecuteReportAsync(request, allowedAreas, canApprove, false, pageNumber, pageSize, ct);
            return new AssetReportResult(true, new { columns, rows, totalRows = TotalRows(rows), page = pageNumber, pageSize }, null, null);
        }
        catch (SqlException ex) when (ex.Number is >= 53100 and <= 53119)
        {
            logger.LogWarning(ex, "AssetConfigService report {Report} refused ({Number})", request.ReportCode, ex.Number);
            return new AssetReportResult(false, null, ex.Number, ex.Message);
        }
    }

    /// <summary>13.4.1: the rows are read with the export checks (policy, approver), the export is recorded (report,
    /// version, organization, filters, columns, row count, classification, user, time) and only then returned with the
    /// recorded heading, which the page writes at the top of the file.</summary>
    public async Task<AssetReportResult> ExportReportAsync(AssetReportRunRequest request, string? allowedAreas, bool canApprove, string actor,
        long? actorEmployeeId, CancellationToken ct)
    {
        try
        {
            string[] columns;
            List<Dictionary<string, object?>> rows;
            try
            {
                // 453: an export is a POST, and only GET reads get the caller View Data Scope (415, CallerViewScope);
                // the export applies the caller own so it carries exactly the rows the grid shows.
                Infrastructure.CallerViewScope.BeginRead(actorEmployeeId);
                (columns, rows) = await ExecuteReportAsync(request, allowedAreas, canApprove, true, 1, ReportExportRowLimit + 1, ct);
            }
            finally { Infrastructure.CallerViewScope.Clear(); }
            if (rows.Count > ReportExportRowLimit)
                return new AssetReportResult(false, null, 53107,
                    $"The export has more than {ReportExportRowLimit} rows. Narrow the filters and export again.");
            foreach (var row in rows) row.Remove("totalRows");
            var filters = System.Text.Json.JsonSerializer.Serialize(new
            {
                search = Blank(request.Search), status = Blank(request.Status), assetTypeId = request.AssetTypeId,
                dateFrom = request.DateFrom?.ToString("yyyy-MM-dd"), dateTo = request.DateTo?.ToString("yyyy-MM-dd"), days = request.Days
            });
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_export_log");
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@report_code",       DbType.String, Blank(request.ReportCode), 40);
            AddParam(command, "@filters_json",      DbType.String, filters, -1);
            AddParam(command, "@columns_json",      DbType.String, System.Text.Json.JsonSerializer.Serialize(columns), -1);
            AddParam(command, "@row_count",         DbType.Int32,  rows.Count);
            AddParam(command, "@actor",             DbType.String, actor, 100);
            AddParam(command, "@actor_employee_id", DbType.Int64,  actorEmployeeId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var heading = await ReadRowsAsync(reader, ct);
            return new AssetReportResult(true, new { export = heading.Count > 0 ? heading[0] : null, columns, rows }, null, null);
        }
        catch (SqlException ex) when (ex.Number is >= 53100 and <= 53119)
        {
            logger.LogWarning(ex, "AssetConfigService report export {Report} refused ({Number})", request.ReportCode, ex.Number);
            return new AssetReportResult(false, null, ex.Number, ex.Message);
        }
    }

    public async Task<object?> ListReportExportsAsync(long organizationId, string? allowedAreas, string? reportCode, int pageNumber, int pageSize,
        CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_exports");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@allowed_areas",   DbType.String, Blank(allowedAreas), 2000);
            AddParam(command, "@report_code",     DbType.String, Blank(reportCode), 40);
            AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
            AddParam(command, "@page_size",       DbType.Int32,  pageSize);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
        }
        catch (SqlException ex) when (ex.Number == 53100) { return null; }
    }

    public Task<AssetLifecycleResult> SaveReportSettingAsync(AssetReportSettingRequest request, string? allowedAreas, string actor, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_report_org_setting_save", "organizationId", command =>
        {
            AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
            AddParam(command, "@report_code",     DbType.String,  Blank(request.ReportCode), 40);
            AddParam(command, "@allowed_areas",   DbType.String,  Blank(allowedAreas), 2000);
            AddParam(command, "@is_enabled",      DbType.Boolean, request.IsEnabled ?? true);
            AddParam(command, "@classification",  DbType.String,  Blank(request.Classification), 20);
            AddParam(command, "@export_policy",   DbType.String,  Blank(request.ExportPolicy), 10);
            AddParam(command, "@actor",           DbType.String,  actor, 100);
        }, ct);

    // ----------------------------------------------------------------
    // 453 -- Report schedules, distribution and delivered files (13.4 / 13.4.1)
    // ----------------------------------------------------------------
    public async Task<object?> GetReportSchedulesAsync(long organizationId, string? allowedAreas, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_schedules");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@allowed_areas",   DbType.String, Blank(allowedAreas), 2000);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var empty = new List<Dictionary<string, object?>>();
            var schedules  = await ReadRowsAsync(reader, ct);
            var recipients = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var employees  = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            var roles      = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : empty;
            return new { schedules, recipients, employees, roles };
        }
        catch (SqlException ex) when (ex.Number == 53120) { return null; }
    }

    public Task<AssetLifecycleResult> SaveReportScheduleAsync(AssetReportScheduleRequest request, string? allowedAreas, string actor,
        long? actorEmployeeId, CancellationToken ct) =>
        ResultRowWriteAsync("grac_practice.sp_asset_report_schedule_save", "scheduleId", command =>
        {
            var recipients = System.Text.Json.JsonSerializer.Serialize((request.Recipients ?? Array.Empty<AssetReportScheduleRecipient>())
                .Select(r => new { kind = r.Kind, id = r.Id }));
            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@schedule_id",             DbType.Int64,   request.ScheduleId);
            AddParam(command, "@report_code",             DbType.String,  Blank(request.ReportCode), 40);
            AddParam(command, "@schedule_name",           DbType.String,  Blank(request.ScheduleName), 160);
            AddParam(command, "@search",                  DbType.String,  Blank(request.Search), 200);
            AddParam(command, "@status",                  DbType.String,  Blank(request.Status), 60);
            AddParam(command, "@asset_type_id",           DbType.Int32,   request.AssetTypeId);
            AddParam(command, "@days",                    DbType.Int32,   request.Days);
            AddParam(command, "@date_window_days",        DbType.Int32,   request.DateWindowDays);
            AddParam(command, "@frequency",               DbType.String,  Blank(request.Frequency), 10);
            AddParam(command, "@day_of_week",             DbType.Byte,    request.DayOfWeek is { } dw && dw is >= 0 and <= 255 ? (byte?)dw : null);
            AddParam(command, "@day_of_month",            DbType.Byte,    request.DayOfMonth is { } dm && dm is >= 0 and <= 255 ? (byte?)dm : null);
            AddParam(command, "@retention_days",          DbType.Int32,   request.RetentionDays);
            AddParam(command, "@is_active",               DbType.Boolean, request.IsActive ?? true);
            AddParam(command, "@recipients_json",         DbType.String,  recipients, -1);
            AddParam(command, "@expected_record_version", DbType.Int64,   request.ExpectedRecordVersion);
            AddParam(command, "@allowed_areas",           DbType.String,  Blank(allowedAreas), 2000);
            AddParam(command, "@actor",                   DbType.String,  actor, 100);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   actorEmployeeId);
        }, ct);

    public async Task<AssetReportResult> RunReportScheduleNowAsync(long organizationId, long scheduleId, string? allowedAreas, string actor,
        CancellationToken ct)
    {
        try
        {
            var pass = await DeliverReportsAsync(organizationId, scheduleId, allowedAreas, actor, ct);
            return new AssetReportResult(true, pass, null, null);
        }
        catch (SqlException ex) when (ex.Number is >= 53100 and <= 53139)
        {
            logger.LogWarning(ex, "AssetConfigService report schedule {Schedule} run refused ({Number})", scheduleId, ex.Number);
            return new AssetReportResult(false, null, ex.Number, ex.Message);
        }
    }

    public Task<AssetReportDeliveryPassResult> RunReportDeliveriesAsync(long? organizationId, CancellationToken ct) =>
        DeliverReportsAsync(organizationId, null, null, "scheduler", ct);

    /// <summary>13.4.1 scheduled delivery. sp_asset_report_delivery_start starts the deliveries and checks every recipient
    /// at delivery time; each recipient that passed gets the report produced under its own permissions (the report
    /// screens it may view, Asset Reports APPROVE) and its own View Data Scope (415), through sp_asset_report_run with the
    /// export checks; the columns and rows (or the reason it failed) are stored for that recipient. A failure stays with
    /// its recipient; the others are still delivered.</summary>
    private async Task<AssetReportDeliveryPassResult> DeliverReportsAsync(long? organizationId, long? scheduleId, string? allowedAreas,
        string actor, CancellationToken ct)
    {
        List<Dictionary<string, object?>> work, started;
        await using (var connection = await OpenAsync(ct))
        {
            await using var command = Proc(connection, "grac_practice.sp_asset_report_delivery_start");
            command.CommandTimeout = 300;
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@schedule_id",     DbType.Int64,  scheduleId);
            AddParam(command, "@trigger_code",    DbType.String, scheduleId is null ? "SCHEDULED" : "MANUAL", 10);
            AddParam(command, "@allowed_areas",   DbType.String, Blank(allowedAreas), 2000);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            await using var reader = await command.ExecuteReaderAsync(ct);
            work = await ReadRowsAsync(reader, ct);
            started = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        }

        int delivered = 0, failed = 0;
        foreach (var item in work)
        {
            var recipientId = Convert.ToInt64(item["deliveryRecipientId"]);
            var employeeId = Convert.ToInt64(item["employeeId"]);
            var request = new AssetReportRunRequest(Convert.ToInt64(item["organizationId"]), Convert.ToString(item["reportCode"]),
                item["search"] as string, item["status"] as string,
                item["assetTypeId"] is null ? null : Convert.ToInt32(item["assetTypeId"]),
                item["dateFrom"] as DateTime?, item["dateTo"] as DateTime?,
                item["days"] is null ? null : Convert.ToInt32(item["days"]));
            string status = "FAILED";
            string? reason = null, columnsJson = null, rowsJson = null;
            int? rowCount = null;
            try
            {
                Infrastructure.CallerViewScope.BeginRead(employeeId);   // the recipient View Data Scope (415)
                var (columns, rows) = await ExecuteReportAsync(request, item["allowedAreas"] as string,
                    Convert.ToBoolean(item["canApprove"] ?? false), true, 1, ReportExportRowLimit + 1, ct);
                if (rows.Count > ReportExportRowLimit)
                    reason = $"The report has more than {ReportExportRowLimit} rows. Narrow the schedule filters.";
                else
                {
                    foreach (var row in rows) row.Remove("totalRows");
                    columnsJson = System.Text.Json.JsonSerializer.Serialize(columns);
                    rowsJson = System.Text.Json.JsonSerializer.Serialize(rows);
                    rowCount = rows.Count;
                    status = "DELIVERED";
                }
            }
            catch (SqlException ex) when (ex.Number is >= 53100 and <= 53119)
            {
                reason = ex.Message;   // the run refused it for this recipient (screen, policy, filters)
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "Report delivery {Recipient} could not be produced", recipientId);
                reason = "The report could not be produced: " + ex.Message;
            }
            finally { Infrastructure.CallerViewScope.Clear(); }

            try
            {
                await using var connection = await OpenAsync(ct);
                await using var command = Proc(connection, "grac_practice.sp_asset_report_delivery_store");
                command.CommandTimeout = 300;
                AddParam(command, "@delivery_recipient_id", DbType.Int64,  recipientId);
                AddParam(command, "@status",                DbType.String, status, 10);
                AddParam(command, "@reason",                DbType.String, reason, 1000);
                AddParam(command, "@row_count",             DbType.Int32,  rowCount);
                AddParam(command, "@columns_json",          DbType.String, columnsJson, -1);
                AddParam(command, "@rows_json",             DbType.String, rowsJson, -1);
                await command.ExecuteNonQueryAsync(ct);
                if (status == "DELIVERED") delivered++; else failed++;
            }
            catch (SqlException ex)
            {
                // Left pending: the next pass marks it interrupted after 6 hours.
                logger.LogError(ex, "Report delivery {Recipient} result could not be stored ({Number})", recipientId, ex.Number);
            }
        }
        var skipped = started.Sum(d => d.TryGetValue("skippedCount", out var s) && s is not null ? Convert.ToInt32(s) : 0);
        return new AssetReportDeliveryPassResult(started.Count, delivered, failed, skipped);
    }

    public async Task<object?> ListReportDeliveriesAsync(long organizationId, string? allowedAreas, long? scheduleId, int pageNumber,
        int pageSize, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_deliveries");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@allowed_areas",   DbType.String, Blank(allowedAreas), 2000);
            AddParam(command, "@schedule_id",     DbType.Int64,  scheduleId);
            AddParam(command, "@page_number",     DbType.Int32,  pageNumber);
            AddParam(command, "@page_size",       DbType.Int32,  pageSize);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
        }
        catch (SqlException ex) when (ex.Number == 53120) { return null; }
    }

    public async Task<AssetReportResult> ListReportDeliveryRecipientsAsync(long organizationId, long deliveryId, string? allowedAreas,
        CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_delivery_recipients");
            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@delivery_id",     DbType.Int64,  deliveryId);
            AddParam(command, "@allowed_areas",   DbType.String, Blank(allowedAreas), 2000);
            await using var reader = await command.ExecuteReaderAsync(ct);
            return new AssetReportResult(true, new { rows = await ReadRowsAsync(reader, ct) }, null, null);
        }
        catch (SqlException ex) when (ex.Number is >= 53120 and <= 53139)
        {
            return new AssetReportResult(false, null, ex.Number, ex.Message);
        }
    }

    public async Task<object> ListMyReportDeliveriesAsync(long organizationId, long? employeeId, int pageNumber, int pageSize, CancellationToken ct)
    {
        // A session without an employee (the configured bootstrap sign-in) receives no deliveries.
        if (employeeId is null) return new { rows = new List<Dictionary<string, object?>>(), totalRows = 0, page = pageNumber, pageSize };
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_report_my_deliveries");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@employee_id",     DbType.Int64, employeeId);
        AddParam(command, "@page_number",     DbType.Int32, pageNumber);
        AddParam(command, "@page_size",       DbType.Int32, pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = await ReadRowsAsync(reader, ct);
        return new { rows, totalRows = TotalRows(rows), page = pageNumber, pageSize };
    }

    /// <summary>The recipient downloads a delivered file: checked again now, recorded as an export (452), and returned
    /// as the export heading with the stored columns and rows.</summary>
    public async Task<AssetReportResult> DownloadReportDeliveryAsync(long organizationId, long deliveryRecipientId, long? employeeId,
        string? allowedAreas, bool canApprove, string actor, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, "grac_practice.sp_asset_report_delivery_download");
            AddParam(command, "@organization_id",       DbType.Int64,   organizationId);
            AddParam(command, "@delivery_recipient_id", DbType.Int64,   deliveryRecipientId);
            AddParam(command, "@employee_id",           DbType.Int64,   employeeId);
            AddParam(command, "@allowed_areas",         DbType.String,  Blank(allowedAreas), 2000);
            AddParam(command, "@can_approve",           DbType.Boolean, canApprove);
            AddParam(command, "@actor",                 DbType.String,  actor, 100);
            await using var reader = await command.ExecuteReaderAsync(ct);
            var rows = await ReadRowsAsync(reader, ct);
            if (rows.Count == 0) return new AssetReportResult(false, null, 53126, "Delivered file not found.");
            var heading = rows[0];
            var columns = System.Text.Json.JsonDocument.Parse(Convert.ToString(heading["columnsJson"]) ?? "[]").RootElement.Clone();
            var data = System.Text.Json.JsonDocument.Parse(Convert.ToString(heading["rowsJson"]) ?? "[]").RootElement.Clone();
            heading.Remove("columnsJson");
            heading.Remove("rowsJson");
            return new AssetReportResult(true, new { export = heading, columns, rows = data }, null, null);
        }
        catch (SqlException ex) when (ex.Number is >= 53120 and <= 53139)
        {
            logger.LogWarning(ex, "AssetConfigService report delivery {Recipient} download refused ({Number})", deliveryRecipientId, ex.Number);
            return new AssetReportResult(false, null, ex.Number, ex.Message);
        }
    }

    /// <summary>Runs sp_asset_report_run and reads the one result set of the report: the column names (camelCase,
    /// without TotalRows -- also when there are no rows) and the rows.</summary>
    private async Task<(string[] Columns, List<Dictionary<string, object?>> Rows)> ExecuteReportAsync(AssetReportRunRequest request,
        string? allowedAreas, bool canApprove, bool forExport, int pageNumber, int pageSize, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_asset_report_run");
        command.CommandTimeout = 300;   // whole-organization reports (privacy, technology, coverage)
        AddParam(command, "@organization_id", DbType.Int64,   request.OrganizationId);
        AddParam(command, "@report_code",     DbType.String,  Blank(request.ReportCode), 40);
        AddParam(command, "@allowed_areas",   DbType.String,  Blank(allowedAreas), 2000);
        AddParam(command, "@can_approve",     DbType.Boolean, canApprove);
        AddParam(command, "@for_export",      DbType.Boolean, forExport);
        AddParam(command, "@search",          DbType.String,  Blank(request.Search), 200);
        AddParam(command, "@status",          DbType.String,  Blank(request.Status), 60);
        AddParam(command, "@asset_type_id",   DbType.Int32,   request.AssetTypeId);
        AddParam(command, "@date_from",       DbType.Date,    request.DateFrom?.Date);
        AddParam(command, "@date_to",         DbType.Date,    request.DateTo?.Date);
        AddParam(command, "@days",            DbType.Int32,   request.Days);
        AddParam(command, "@page_number",     DbType.Int32,   pageNumber);
        AddParam(command, "@page_size",       DbType.Int32,   pageSize);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var columns = Enumerable.Range(0, reader.FieldCount).Select(i => CamelCase(reader.GetName(i)))
                                .Where(n => n != "totalRows").ToArray();
        var rows = await ReadRowsAsync(reader, ct);
        return (columns, rows);
    }

    public async Task<object> GetBusinessServiceTreeAsync(long organizationId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = Proc(connection, "grac_practice.sp_business_service_tree");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var services = await ReadRowsAsync(reader, ct);
        var links = await reader.NextResultAsync(ct) ? await ReadRowsAsync(reader, ct) : new List<Dictionary<string, object?>>();
        return new { services, links };
    }

    /// <summary>The lifecycle (429) and technology (430) write procedures
    /// end with one row: the id column named <paramref name="idColumn"/>
    /// and, where there is one, Result. A refusal is raised and comes back
    /// as ErrorNumber.</summary>
    private async Task<AssetLifecycleResult> ResultRowWriteAsync(string procedure, string idColumn, Action<DbCommand> bind, CancellationToken ct)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, procedure);
            bind(command);
            List<Dictionary<string, object?>> rows;
            await using (var reader = await command.ExecuteReaderAsync(ct))
            {
                rows = await ReadRowsAsync(reader, ct);
            }
            var row = rows.Count > 0 ? rows[0] : new Dictionary<string, object?>();
            row.TryGetValue(idColumn, out var id);
            row.TryGetValue("result", out var result);
            return new AssetLifecycleResult(true, Convert.ToString(result) ?? "SAVED",
                id is null ? null : Convert.ToInt64(id), null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService {Procedure} refused ({Number})", procedure, ex.Number);
            return new AssetLifecycleResult(false, null, null, ex.Number, ex.Message);
        }
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------
    /// <summary>Runs a write procedure. <paramref name="bind"/> adds the
    /// parameters and returns the OUTPUT id parameter (or null when the
    /// procedure has none, in which case <paramref name="fixedId"/> is
    /// reported back). A SqlException becomes a failed result carrying the
    /// error number, so the controller can map 54202 to 404 and 54205 /
    /// 53520 to 409.</summary>
    private async Task<AssetConfigWriteResult> WriteAsync(string procedure, Func<DbCommand, DbParameter?> bind,
        CancellationToken ct, long? fixedId = null)
    {
        try
        {
            await using var connection = await OpenAsync(ct);
            await using var command = Proc(connection, procedure);
            var outId = bind(command);
            await command.ExecuteNonQueryAsync(ct);
            var id = outId?.Value is null or DBNull ? fixedId : Convert.ToInt64(outId.Value);
            return new AssetConfigWriteResult(true, id, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "AssetConfigService {Procedure} refused ({Number})", procedure, ex.Number);
            return new AssetConfigWriteResult(false, fixedId, ex.Number, ex.Message);
        }
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(Infrastructure.SqlConnectionStringResolver.Resolve(configuration));
        await connection.OpenAsync(ct);
        await Infrastructure.ViewScopeSession.ApplyAsync(connection, ct);   // 415: View Data Scope
        return connection;
    }

    private static DbCommand Proc(SqlConnection connection, string name)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = name;
        return command;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static DbParameter Output(DbCommand command, string name, DbType type)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        p.Direction = ParameterDirection.Output;
        command.Parameters.Add(p);
        return p;
    }

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static int TotalRows(List<Dictionary<string, object?>> rows) =>
        rows.Count > 0 && rows[0].TryGetValue("totalRows", out var t) && t is not null ? Convert.ToInt32(t) : 0;

    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbDataReader reader, CancellationToken ct)
    {
        var rows = new List<Dictionary<string, object?>>();
        var names = Enumerable.Range(0, reader.FieldCount).Select(i => CamelCase(reader.GetName(i))).ToArray();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(names.Length, StringComparer.Ordinal);
            for (var i = 0; i < names.Length; i++)
                row[names[i]] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

    private static string CamelCase(string name) =>
        string.IsNullOrEmpty(name) || char.IsLower(name[0]) ? name : char.ToLowerInvariant(name[0]) + name[1..];
}
