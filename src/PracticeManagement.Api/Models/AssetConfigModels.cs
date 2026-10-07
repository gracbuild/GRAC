// =====================================================================
// AssetConfigModels  (migration 420 -- Asset & Contract Management,
// Phase 2 increment 1: field dictionary + asset form templates)
//
// Request DTOs for AssetConfigController. Reads are returned as row
// dictionaries (camelCase keys, one per procedure column) so that a
// procedure gaining a column does not need a DTO change -- the same
// approach PracticeRepositoryService takes for its generic rows.
//
// The acting employee is NEVER read from these bodies: the controller
// takes it from the X-PM-Caller-Employee-Id header the Web tier stamps
// from the session.
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record AssetTemplateCreateRequest(
    long    OrganizationId,
    int     AssetTypeId,
    string? TemplateName,
    string? ChangeReason,
    long?   TemplateOwnerEmployeeId);

public sealed record AssetTemplateNewVersionRequest(
    long    OrganizationId,
    string? ChangeReason);

public sealed record AssetTemplateHeaderSaveRequest(
    long      OrganizationId,
    string?   TemplateName,
    bool      ApprovalRequired,
    long?     TemplateOwnerEmployeeId,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    string?   ChangeReason,
    long?     ExpectedRecordVersion);

public sealed record AssetTemplateSectionSaveRequest(
    long    OrganizationId,
    long?   SectionId,
    string? SectionLabel,
    string? TabLabel,
    byte?   LayoutColumns,
    int?    DisplayOrder,
    bool?   IsActive);

public sealed record AssetTemplateFieldSaveRequest(
    long    OrganizationId,
    int     FieldDefinitionId,
    long    SectionId,
    int?    DisplayOrder,
    bool?   IsVisible,
    bool?   IsMandatory,
    bool?   IsReadOnly,
    string? DefaultValue,
    string? HelpText,
    string? PlaceholderText,
    string? HiddenValueBehavior,
    string? SensitivityOverride,
    bool?   IncludeInImportExport,
    bool?   IsSearchable,
    bool?   EvidenceRequired);

public sealed record AssetTemplateFieldRemoveRequest(
    long OrganizationId,
    int  FieldDefinitionId);

public sealed record AssetTemplateTransitionRequest(
    long    OrganizationId,
    string? ToStatusCode,
    string? ReasonText,
    long?   ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Conditional rules + preview (migration 421)
// ---------------------------------------------------------------------
public sealed record AssetTemplateRuleCondition(
    int?    GroupNo,
    int     SourceFieldDefinitionId,
    string? OperatorCode,
    string? CompareValue);

public sealed record AssetTemplateRuleSaveRequest(
    long    OrganizationId,
    long?   RuleId,
    string? RuleName,
    int     TargetFieldDefinitionId,
    string? ActionCode,
    bool?   IsActive,
    int?    DisplayOrder,
    IReadOnlyList<AssetTemplateRuleCondition>? Conditions);

public sealed record AssetTemplateRuleRemoveRequest(
    long OrganizationId,
    long RuleId);

/// <summary>Sample values keyed by dictionary field_key; a multi-value
/// field is a JSON array or a '|'-separated string.</summary>
public sealed record AssetTemplateEvaluateRequest(
    long OrganizationId,
    System.Text.Json.JsonElement? Values);

// ---------------------------------------------------------------------
// Asset valuation configuration (migration 422)
// ---------------------------------------------------------------------
public sealed record AssetValuationCreateRequest(
    long    OrganizationId,
    string? ConfigName,
    long?   SourceConfigId,
    string? ChangeReason);

public sealed record AssetValuationHeaderSaveRequest(
    long      OrganizationId,
    string?   ConfigName,
    string?   ValuationMethod,
    decimal   WeightC,
    decimal   WeightI,
    decimal   WeightA,
    byte      DecimalPlaces,
    string?   RoundingMode,
    bool      OverrideAllowed,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    string?   ChangeReason,
    long?     ExpectedRecordVersion);

/// <summary>One CIA level, value band or criticality level.
/// ItemKind: CIA_LEVEL | BAND | CRITICALITY. ItemId null adds; Remove deletes.</summary>
public sealed record AssetValuationItemSaveRequest(
    long     OrganizationId,
    string?  ItemKind,
    long?    ItemId,
    bool?    Remove,
    string?  DimensionCode,
    int?     Score,
    decimal? MinScore,
    decimal? MaxScore,
    string?  Label,
    string?  Description,
    int?     ReviewFrequencyMonths,
    int?     CriticalityMasterId,
    int?     DisplayOrder);

public sealed record AssetValuationTransitionRequest(
    long    OrganizationId,
    string? ToStatusCode,
    string? ReasonText,
    long?   ExpectedRecordVersion);

public sealed record AssetValuationCalculateRequest(
    long OrganizationId,
    int  Confidentiality,
    int  Integrity,
    int  Availability);

// ---------------------------------------------------------------------
// Organization option lists (migration 423)
// ---------------------------------------------------------------------
/// <summary>Add (OrgOptionId null) or edit one organization value of a list.
/// OptionValue is derived from the label when omitted on add; Status
/// Active | Inactive (retire).</summary>
public sealed record AssetOptionOrgSaveRequest(
    long    OrganizationId,
    long?   OrgOptionId,
    string? OptionValue,
    string? OptionLabel,
    string? ParentValue,
    int?    DisplayOrder,
    string? Status);

/// <summary>Relabel / reorder / hide a global default for one organization,
/// or Reset it back to the global value.</summary>
public sealed record AssetOptionOverrideRequest(
    long    OrganizationId,
    string? OptionValue,
    string? OptionLabel,
    int?    DisplayOrder,
    bool?   Hidden,
    bool?   Reset);

// ---------------------------------------------------------------------
// Asset taxonomy governance (migration 424). Category / subcategory /
// type are global masters (Id null adds); OrgDefaults are per organization.
// ---------------------------------------------------------------------
public sealed record AssetTaxonomyCategorySaveRequest(
    int?      CategoryId,
    string?   CategoryName,
    string?   Description,
    string?   Sector,
    string?   OwnerName,
    string?   Standards,
    int?      DefaultCriticalityId,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    bool?     IsActive,
    int?      DisplayOrder,
    long?     ExpectedRecordVersion);

public sealed record AssetTaxonomySubcategorySaveRequest(
    int?      SubcategoryId,
    int       CategoryId,
    int?      ParentSubcategoryId,
    string?   SubcategoryName,
    string?   Description,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    bool?     IsActive,
    int?      DisplayOrder,
    long?     ExpectedRecordVersion);

public sealed record AssetTaxonomyTypeSaveRequest(
    int?      AssetTypeId,
    int       SubcategoryId,
    string?   AssetTypeName,
    string?   Description,
    int?      DefaultCriticalityId,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    bool?     IsActive,
    int?      DisplayOrder,
    long?     ExpectedRecordVersion);

/// <summary>Both null clears the organization's defaults for the type.</summary>
public sealed record AssetTypeOrgDefaultSaveRequest(
    long  OrganizationId,
    long? BusinessOwnerRoleId,
    long? SupportTeamId);

// ---------------------------------------------------------------------
// Technology catalogue -- makes and models (migration 425). OrganizationId
// is the caller's organization; Shared = true is a shared-catalogue change
// (platform administrator only -- enforced by the Web proxy and checked
// against the row by the procedures).
// ---------------------------------------------------------------------
public sealed record AssetMakeSaveRequest(
    long      OrganizationId,
    bool?     Shared,
    int?      MakeId,
    string?   MakeName,
    string?   LegalName,
    string?   Aliases,
    string?   SupportPortalUrl,
    string?   SecurityAdvisoryUrl,
    string?   SupportContact,
    string?   SupportRegion,
    string?   OwnerName,
    string?   AuthoritativeSource,
    DateTime? VerifiedDate,
    string?   VerifiedBy,
    DateTime? EffectiveDate,
    string?   Status,
    int[]?    AssetTypeIds,
    long?     ExpectedRecordVersion);

public sealed record AssetModelSaveRequest(
    long      OrganizationId,
    bool?     Shared,
    long?     ModelId,
    int       MakeId,
    int       AssetTypeId,
    string?   ModelName,
    string?   ModelNumber,
    string?   FamilySeries,
    string?   Variant,
    string?   Sku,
    DateTime? AnnouncementDate,
    DateTime? ReleaseDate,
    DateTime? EndOfSaleDate,
    DateTime? EndStandardSupportDate,
    DateTime? EndSecuritySupportDate,
    DateTime? EndExtendedSupportDate,
    DateTime? EndOfLifeDate,
    string?   Architecture,
    string?   HardwareRevision,
    string?   Specifications,
    string?   SourceReference,
    DateTime? VerifiedDate,
    string?   VerifiedBy,
    int?      CriticalityId,
    int?      ReplacementLeadTimeDays,
    string?   LifecycleRisk,
    string?   Controls,
    string?   LifecycleStatus,
    string?   ChangeReason,
    long?     ExpectedRecordVersion);

/// <summary>Status move of a catalogue record: model (425), firmware
/// release (426) or OS release (427) -- one shape for all three.</summary>
public sealed record AssetCatalogTransitionRequest(
    long    OrganizationId,
    bool?   Shared,
    string? ToStatusCode,
    string? ReasonText,
    long?   ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Technology catalogue -- firmware (migration 426). Scope as 425.
// ---------------------------------------------------------------------
public sealed record AssetFirmwareProductSaveRequest(
    long    OrganizationId,
    bool?   Shared,
    int?    ProductId,
    int     PublisherMakeId,
    string? ProductName,
    string? Description,
    string? Status,
    long?   ExpectedRecordVersion);

public sealed record AssetFirmwareReleaseSaveRequest(
    long      OrganizationId,
    bool?     Shared,
    long?     ReleaseId,
    int       ProductId,
    string?   Version,
    string?   Build,
    string?   BranchTrain,
    string?   Edition,
    DateTime? ReleaseDate,
    DateTime? EngineeringSupportEndDate,
    DateTime? StandardSupportEndDate,
    DateTime? SecurityFixEndDate,
    DateTime? EndOfLifeDate,
    string?   KnownVulnerabilities,
    string?   MinimumSafeVersion,
    string?   UpgradeUrgency,
    string?   PackageLocation,
    string?   Checksum,
    string?   Signature,
    string?   ReleaseNotes,
    string?   SourceReference,
    DateTime? VerifiedDate,
    string?   Reviewer,
    string?   ChangeReason,
    long?     ExpectedRecordVersion);

public sealed record AssetFirmwareCompatSaveRequest(
    long      OrganizationId,
    bool?     Shared,
    long?     CompatId,
    long      ReleaseId,
    int       AssetTypeId,
    int?      MakeId,
    long?     ModelId,
    string?   HardwareRevision,
    string?   CompatStatus,
    string?   UpgradePath,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    string?   Evidence,
    string?   Reviewer,
    bool?     IsActive,
    long?     ExpectedRecordVersion);

/// <summary>Approval of a firmware (426) or OS (427) compatibility record.</summary>
public sealed record AssetCatalogApproveRequest(
    long  OrganizationId,
    bool? Shared,
    long? ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Technology catalogue -- operating systems (migration 427). Scope as 425;
// status moves use AssetCatalogTransitionRequest, compatibility approval
// AssetCatalogApproveRequest.
// ---------------------------------------------------------------------
public sealed record AssetOsProductSaveRequest(
    long    OrganizationId,
    bool?   Shared,
    int?    ProductId,
    int     PublisherMakeId,
    string? Family,
    string? ProductName,
    string? Description,
    string? Status,
    long?   ExpectedRecordVersion);

public sealed record AssetOsReleaseSaveRequest(
    long      OrganizationId,
    bool?     Shared,
    long?     ReleaseId,
    int       ProductId,
    string?   Edition,
    string?   Version,
    string?   Build,
    string?   Architecture,
    DateTime? ReleaseDate,
    DateTime? MainstreamSupportEndDate,
    DateTime? ExtendedSupportEndDate,
    DateTime? SecurityUpdateEndDate,
    DateTime? EndOfLifeDate,
    string?   ServicingChannel,
    string?   FeatureVersion,
    string?   PatchLevel,
    string?   LatestApprovedBuild,
    string?   MinimumCompliantBuild,
    string?   SourceReference,
    DateTime? VerifiedDate,
    string?   VerifiedBy,
    bool?     IsApprovedBaseline,
    string?   ExceptionNote,
    long?     ReplacementReleaseId,
    string?   ReplacementPath,
    string?   ChangeReason,
    long?     ExpectedRecordVersion);

public sealed record AssetOsCompatSaveRequest(
    long    OrganizationId,
    bool?   Shared,
    long?   CompatId,
    long    ReleaseId,
    int     AssetTypeId,
    int?    MakeId,
    long?   ModelId,
    string? ProcessorArchitecture,
    long?   MinFirmwareReleaseId,
    string? FirmwarePrerequisite,
    string? Exclusions,
    string? Evidence,
    string? Reviewer,
    bool?   IsActive,
    long?   ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Asset Register (migration 428)
// ---------------------------------------------------------------------
/// <summary>Values: { field_key: value } (dates yyyy-mm-dd, multi-select as
/// a JSON array, quantity as "number unit"); keys left out keep their stored
/// value. HiddenDecisions: { field_key: "RETAIN" | "CLEAR" }.</summary>
public sealed record AssetRegisterSaveRequest(
    long                          OrganizationId,
    long?                         AssetId,
    int?                          AssetTypeId,
    System.Text.Json.JsonElement? Values,
    System.Text.Json.JsonElement? HiddenDecisions,
    long?                         ExpectedRecordVersion);

/// <summary>Live rule evaluation for the register form (same engine as the
/// template Preview).</summary>
public sealed record AssetRegisterEvaluateRequest(
    long                          OrganizationId,
    long                          TemplateId,
    System.Text.Json.JsonElement? Values);

/// <summary>Result: SAVED | INVALID | NEEDS_DECISION | REFUSED. Issues are
/// the procedure's rows (severity, fieldKey, message).</summary>
public sealed record AssetRegisterSaveResult(
    string                                Result,
    long?                                 AssetId,
    List<Dictionary<string, object?>>     Issues,
    int?                                  ErrorNumber,
    string?                               Error);

// ---------------------------------------------------------------------
// Asset lifecycle transitions (migration 429)
// ---------------------------------------------------------------------
/// <summary>Move an asset to another BRD 5 status. ReasonText / ReferenceText
/// / EvidenceText are required when the transition's gate says so
/// (sp_asset_lifecycle_get lists the gates).</summary>
public sealed record AssetLifecycleTransitionRequest(
    long    OrganizationId,
    string? ToStatusCode,
    string? ReasonText,
    string? ReferenceText,
    string? EvidenceText,
    long?   ExpectedRecordVersion);

/// <summary>Decision on a change awaiting approval: APPROVE | REJECT (note
/// required) | CANCEL (requester only). 430 reuses it for technology
/// exceptions: APPROVE | REJECT | WITHDRAW (requester) | REVOKE (note).</summary>
public sealed record AssetLifecycleDecisionRequest(
    long    OrganizationId,
    string? Decision,
    string? DecisionNote,
    long?   ExpectedRecordVersion);

/// <summary>Result: COMPLETED | PENDING_APPROVAL (transition) or APPROVED |
/// REJECTED | CANCELLED (decision); on refusal the SQL error number + message.
/// 430 uses the same shape for installations and technology exceptions
/// (ChangeId = the installation / exception id).</summary>
public sealed record AssetLifecycleResult(bool Success, string? Result, long? ChangeId, int? ErrorNumber, string? Error);

// ---------------------------------------------------------------------
// Installed technology (migration 430)
// ---------------------------------------------------------------------
/// <summary>Record a firmware (Kind = FIRMWARE: Result SUCCESSFUL | FAILED,
/// RollbackNote) or OS (Kind = OS: BuildPatchLevel, LicenceReference)
/// installation; a successful one becomes the asset's current version.</summary>
public sealed record AssetTechInstallRequest(
    long      OrganizationId,
    string?   Kind,
    long      ReleaseId,
    DateTime? InstalledDate,
    string?   Source,
    string?   Result,
    string?   BuildPatchLevel,
    string?   RollbackNote,
    string?   LicenceReference,
    string?   EvidenceText,
    long?     ExpectedRecordVersion);

/// <summary>Request a technology exception (BRD 4.6) for this asset
/// (Scope = ASSET) or every asset of its model (Scope = MODEL).</summary>
public sealed record AssetTechExceptionRequest(
    long      OrganizationId,
    string?   Scope,
    string?   Kind,
    long      ReleaseId,
    string?   Reason,
    string?   CompensatingControls,
    long?     OwnerEmployeeId,
    DateTime? ExpiryDate,
    DateTime? ReviewDate);

// ---------------------------------------------------------------------
// Custody, acknowledgement and attestation (migration 431)
// ---------------------------------------------------------------------
/// <summary>Attestation profile (BRD 5.3.1) for one scope: ScopeKind
/// CATEGORY | SUBCATEGORY | ASSET_TYPE + ScopeId; Participant CUSTODIAN |
/// OWNER | BOTH; Frequency MONTHLY | QUARTERLY | HALF_YEARLY | ANNUAL |
/// CUSTOM (CustomIntervalDays); EvidenceRequirement NONE | OPTIONAL |
/// MANDATORY.</summary>
public sealed record AssetAttestationProfileSaveRequest(
    long    OrganizationId,
    long?   ProfileId,
    string? ScopeKind,
    int     ScopeId,
    bool?   AttestationRequired,
    string? Participant,
    string? Frequency,
    int?    CustomIntervalDays,
    int     DueWindowDays,
    string? EvidenceRequirement,
    bool?   ManagerApprovalRequired,
    bool?   IsActive,
    long?   ExpectedRecordVersion);

/// <summary>Periodic run (CampaignType PERIODIC) or ad-hoc campaign
/// (CAMPAIGN: CampaignName and DueDate required; AssetTypeId optional).</summary>
public sealed record AssetAttestationGenerateRequest(
    long      OrganizationId,
    string?   CampaignType,
    string?   CampaignName,
    int?      AssetTypeId,
    DateTime? DueDate);

/// <summary>Custodian / owner response (BRD 5.3.4): CONFIRM | DISAGREE,
/// the verification checks, condition, disagreement category, comments and
/// evidence.</summary>
public sealed record AssetAttestationRespondRequest(
    long    OrganizationId,
    string? Response,
    bool?   AssetExists,
    bool?   CustodyConfirmed,
    bool?   LocationVerified,
    bool?   TagVerified,
    bool?   SerialVerified,
    bool?   AssignedUserVerified,
    bool?   InformationCorrect,
    bool?   BusinessUseConfirmed,
    string? ConditionCode,
    string? DisagreementCategory,
    string? Comments,
    string? EvidenceText,
    long?   ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Asset verification exceptions (migration 432)
// ---------------------------------------------------------------------
/// <summary>Investigation action: START_REVIEW | AWAIT_EVIDENCE (Note) |
/// RESUME | RESOLVE (Outcome, Narrative, ClosureEvidence, Sec* = DONE | NA for
/// a lost asset) | APPROVE | REJECT (Note) | CLOSE | REASSIGN (Investigator =
/// E:id | T:id, Note) | CANCEL (Note).</summary>
public sealed record AssetVerificationActionRequest(
    long    OrganizationId,
    string? Action,
    string? Note,
    string? Outcome,
    string? Narrative,
    string? ClosureEvidence,
    string? SecRemoteLockWipe,
    string? SecCredentialReview,
    string? SecPrivacyAssessment,
    string? SecAccessRevocation,
    string? SecMonitoring,
    string? Investigator,
    long?   ExpectedRecordVersion);

/// <summary>Per-organization exception settings (asset administrator,
/// fallback team, escalation levels in overdue days).</summary>
public sealed record AssetVerificationSettingsSaveRequest(
    long  OrganizationId,
    long? AssetAdministratorEmployeeId,
    long? FallbackTeamId,
    int   EscalationLevel1Days,
    int   EscalationLevel2Days,
    int   EscalationLevel3Days,
    long? ExpectedRecordVersion);

/// <summary>Organization override of one disagreement category's
/// assignment / SLA rule; Reset = true returns to the BRD 5.3.8 default.</summary>
public sealed record AssetVerificationRuleSaveRequest(
    long    OrganizationId,
    string? Category,
    string? PrimaryAssignment,
    string? SupportingAssignment,
    int?    StartSlaDays,
    bool?   StartImmediate,
    int?    ResolutionSlaDays,
    bool?   ClosureApprovalRequired,
    bool?   ClosureEvidenceRequired,
    bool?   Reset);

// ---------------------------------------------------------------------
// Asset workflows (migration 433)
// ---------------------------------------------------------------------
/// <summary>Start OWNER_CHANGE (NewOwnerId), LOCATION_TRANSFER (DestLocationId,
/// DestBuilding / DestFloor / DestRoom, ReferenceText), BREAKDOWN or DISPOSAL
/// for an asset.</summary>
public sealed record AssetWorkflowStartRequest(
    long    OrganizationId,
    string? WorkflowCode,
    string? Reason,
    string? ReferenceText,
    long?   NewOwnerId,
    long?   DestLocationId,
    string? DestBuilding,
    string? DestFloor,
    string? DestRoom);

/// <summary>Act on the current step: COMPLETE (worker step), APPROVE / REJECT
/// (approver step), CONFIRM / DECLINE (owner step). Choice = QUARANTINE |
/// CONTROLLED_USE on the breakdown containment step.</summary>
public sealed record AssetWorkflowStepRequest(
    long    OrganizationId,
    string? Action,
    string? Note,
    string? EvidenceText,
    string? ReferenceText,
    string? Choice,
    long?   ExpectedRecordVersion);

/// <summary>Cancel an open case (the person who started it; reason required).</summary>
public sealed record AssetWorkflowCancelRequest(
    long    OrganizationId,
    string? Reason,
    long?   ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Contracts, contract versions and vendor contacts (migration 434)
// ---------------------------------------------------------------------
/// <summary>Create (ContractId null -- Version 1 is created as a Draft) or
/// edit a contract header. Vendor and type are fixed once a version is
/// approved.</summary>
public sealed record AssetContractSaveRequest(
    long    OrganizationId,
    long?   ContractId,
    string? ContractNumber,
    string? ContractName,
    string? ContractType,
    long?   ParentContractId,
    long?   VendorId,
    string? Description,
    long?   ExpectedRecordVersion);

/// <summary>New draft version: INITIAL (no approved version yet), RENEWAL,
/// AMENDMENT, EXTENSION, VARIATION, CORRECTION or TERMINATION.</summary>
public sealed record AssetContractVersionCreateRequest(
    long    OrganizationId,
    string? VersionType,
    string? ChangeSummary);

/// <summary>Edit a Draft version (BRD 7.2.1 / 7 dates, commercial, service).</summary>
public sealed record AssetContractVersionSaveRequest(
    long      OrganizationId,
    string?   VersionLabel,
    DateTime? EffectiveStart,
    DateTime? EffectiveEnd,
    DateTime? NoticeDate,
    DateTime? DecisionDate,
    DateTime? TerminationDate,
    decimal?  ContractValue,
    string?   CurrencyCode,
    string?   TaxDetails,
    string?   PaymentTerms,
    string?   PoReference,
    string?   InvoiceReference,
    string?   CostAllocation,
    string?   RenewalTerms,
    string?   ServiceScope,
    string?   SlaTerms,
    string?   SupportHours,
    string?   ResponseTime,
    string?   ResolutionTime,
    string?   ServiceVisits,
    long?     ContractOwnerId,
    long?     ProcurementOwnerId,
    string?   ChangeSummary,
    long?     ExpectedRecordVersion);

/// <summary>SUBMIT | REVIEW | RETURN | REJECT | APPROVE | WITHDRAW (Note
/// required for RETURN, REJECT and WITHDRAW).</summary>
public sealed record AssetContractVersionActionRequest(
    long    OrganizationId,
    string? Action,
    string? Note,
    long?   ExpectedRecordVersion);

/// <summary>Add (MappingId null) or edit a vendor contact mapping (BRD 7.4.2).
/// VersionId null = every version of the contract.</summary>
public sealed record AssetContractContactSaveRequest(
    long      OrganizationId,
    long?     MappingId,
    long?     VersionId,
    long?     EmployeeId,
    string?   RoleCode,
    bool?     IsPrimary,
    DateTime? EffectiveStart,
    DateTime? EffectiveEnd,
    string?   PreferredChannel,
    bool?     NotificationParticipation,
    string?   Notes,
    long?     ExpectedRecordVersion);

/// <summary>VALIDATE (another person) or END (EndDate, default today; Note required).</summary>
public sealed record AssetContractContactActionRequest(
    long      OrganizationId,
    string?   Action,
    DateTime? EndDate,
    string?   Note,
    long?     ExpectedRecordVersion);

/// <summary>Add a document reference to a version that is not yet approved.</summary>
public sealed record AssetContractDocumentRequest(
    long    OrganizationId,
    string? DocumentType,
    string? Title,
    string? ReferenceText);

/// <summary>Remove a document reference (Draft versions only; kept as Removed).</summary>
public sealed record AssetContractDocumentRemoveRequest(long OrganizationId);

// ---------------------------------------------------------------------
// Contract coverage and entitlements (migration 435)
// ---------------------------------------------------------------------
/// <summary>Add (EntitlementId null) or edit an entitlement of a Draft version.</summary>
public sealed record AssetContractEntitlementRequest(
    long      OrganizationId,
    long?     EntitlementId,
    string?   ProductSku,
    string?   Description,
    string?   CoverageType,
    decimal?  Quantity,
    string?   Unit,
    string?   ServiceLevel,
    string?   SupportHours,
    DateTime? StartDate,
    DateTime? EndDate,
    string?   Exclusions);

/// <summary>Add (CoverageId null) or edit one asset coverage line of a Draft
/// version. CoverageState = COVERED | EXCLUDED (ExclusionReason) | SUSPENDED.</summary>
public sealed record AssetContractCoverageRequest(
    long      OrganizationId,
    long?     CoverageId,
    long?     AssetId,
    string?   CoverageType,
    string?   CoverageState,
    long?     EntitlementId,
    DateTime? CoverageStart,
    DateTime? CoverageEnd,
    string?   ServiceLevel,
    string?   SupportHours,
    string?   VendorSupportReference,
    string?   ExclusionReason);

/// <summary>Cover several assets at once (Covered, version dates).</summary>
public sealed record AssetContractCoverageBulkRequest(
    long     OrganizationId,
    long[]?  AssetIds,
    string?  CoverageType,
    long?    EntitlementId);

/// <summary>Remove an entitlement or a coverage line (Draft versions only).</summary>
public sealed record AssetContractLineRemoveRequest(long OrganizationId);

/// <summary>Coverage requirement of an asset type (BRD 5.2.14).</summary>
public sealed record AssetCoverageRequirementRequest(
    long    OrganizationId,
    int     AssetTypeId,
    string? CoverageType,
    string? RequirementLevel,
    int?    MinimumPeriodMonths,
    string? LicenceHandling,
    string? MissingAction,
    string? Notes);

/// <summary>Organization coverage settings (expiring window in days).</summary>
public sealed record AssetCoverageSettingsRequest(long OrganizationId, int ExpiringWindowDays);

// ---------------------------------------------------------------------
// Contract renewal occurrences (migration 436)
// ---------------------------------------------------------------------
/// <summary>Start a renewal occurrence: RENEWAL | EXTENSION | REBID | REPLACEMENT | NON_RENEWAL.</summary>
public sealed record AssetContractRenewalStartRequest(long OrganizationId, string? RenewalType, string? Notes);

/// <summary>Edit an Open renewal (decision, new expiry, value, procurement references).</summary>
public sealed record AssetContractRenewalSaveRequest(
    long      OrganizationId,
    string?   RenewalType,
    DateTime? NewExpiry,
    decimal?  RenewalValue,
    string?   CurrencyCode,
    string?   QuotationReference,
    string?   PoReference,
    string?   InvoiceReference,
    string?   DecisionComments,
    string?   Notes,
    long?     ExpectedRecordVersion);

/// <summary>SUBMIT | APPROVE | RETURN | REOPEN | CREATE_VERSION | LINK_VERSION (VersionId) |
/// COMPLETE | CANCEL (Note required for RETURN, REOPEN and CANCEL).</summary>
public sealed record AssetContractRenewalActionRequest(
    long    OrganizationId,
    string? Action,
    string? Note,
    long?   VersionId,
    long?   ExpectedRecordVersion);

/// <summary>Resolve an unresolved reconciliation item: MAPPED | SEPARATELY_RENEWED |
/// REPLACED | UNINSTALLED | EXEMPTED | RETIRED.</summary>
public sealed record AssetContractRenewalResolveRequest(long OrganizationId, string? ResolutionCode, string? Note);

// ---------------------------------------------------------------------
// Notification profiles, escalation matrix, occurrences, scheduler (437)
// ---------------------------------------------------------------------
/// <summary>A recipient of a stage: a party code (ACTIVITY_OWNER, ASSET_OWNER, CONTRACT_OWNER,
/// MANAGER ...) or ROLE with the organization role.</summary>
public sealed record AssetNotificationRecipientRequest(string? RecipientCode, long? RoleId);

/// <summary>REMINDER (days before) | DUE | ESCALATION (days after, level 1-3); class
/// INFORMATIONAL | REMINDER | ESCALATION | CRITICAL.</summary>
public sealed record AssetNotificationStageRequest(
    string?                                           StageKind,
    int?                                              OffsetDays,
    int?                                              EscalationLevel,
    string?                                           NotificationClass,
    IReadOnlyList<AssetNotificationRecipientRequest>? Recipients);

/// <summary>Create (ProfileId null) or edit a notification profile with its stages (9.1.1).</summary>
public sealed record AssetNotificationProfileRequest(
    long                                          OrganizationId,
    long?                                         ProfileId,
    string?                                       ActivityCode,
    string?                                       ProfileName,
    string?                                       SeverityCode,
    long?                                         OwnerEmployeeId,
    DateTime?                                     EffectiveFrom,
    DateTime?                                     EffectiveTo,
    bool?                                         IsActive,
    string?                                       AckMode,
    bool?                                         ChannelInApp,
    bool?                                         ChannelEmail,
    bool?                                         ChannelWebhook,
    bool?                                         SnoozeAllowed,
    bool?                                         WorkingDaysOnly,
    IReadOnlyList<AssetNotificationStageRequest>? Stages,
    long?                                         ExpectedRecordVersion);

/// <summary>One escalation matrix entry: level 0-3 and a recipient.</summary>
public sealed record AssetEscalationEntryRequest(int? EscalationLevel, string? RecipientCode, long? RoleId);

/// <summary>Replace the escalation matrix entries of one severity (9.1.8).</summary>
public sealed record AssetEscalationMatrixRequest(long OrganizationId, string? SeverityCode, IReadOnlyList<AssetEscalationEntryRequest>? Entries);

/// <summary>Snooze / reschedule an occurrence to SnoozedUntil (null resumes); reason required.</summary>
public sealed record AssetNotificationSnoozeRequest(long OrganizationId, DateTime? SnoozedUntil, string? Reason, long? ExpectedRecordVersion);

/// <summary>A dispatcher reports a delivery: SENT, or FAILED with the reason.</summary>
public sealed record AssetNotificationDeliveryRequest(long OrganizationId, string? StatusCode, string? FailureReason);

/// <summary>Run the asset scheduler now for one organization.</summary>
public sealed record AssetSchedulerRunRequest(long OrganizationId);

/// <summary>The recipient's own action: READ | ACKNOWLEDGE (Note = action taken) | CONFIRM (manager).</summary>
public sealed record AssetNotificationMineActionRequest(string? Action, string? Note);

// ---------------------------------------------------------------------
// Recurring asset activities (migration 438)
// ---------------------------------------------------------------------
/// <summary>Organization settings of one activity template: active, task lead days,
/// due-soon days, INDIVIDUAL tasks or a monthly CAMPAIGN, campaign owner.
/// 439 adds the reviewer / approval requirements and the restricted-use policy
/// (null = the template default; RestrictOnOverdue ALL | NONE | CRITICAL,HIGH,...).</summary>
public sealed record AssetActivitySettingRequest(
    long    OrganizationId,
    string? TemplateCode,
    bool?   IsActive,
    int?    LeadDays,
    int?    DueSoonDays,
    string? GroupingMode,
    long?   CampaignOwnerEmployeeId,
    bool?   ResultReviewRequired = null,
    bool?   DispositionApprovalRequired = null,
    string? RestrictOnOverdue = null,
    bool?   RestrictOnFail = null);

/// <summary>Record the reconciliation of a flagged activity occurrence (BRD 7.1.5).</summary>
public sealed record AssetActivityReconcileRequest(long OrganizationId, string? Note, long? ExpectedRecordVersion);

/// <summary>439: save (Submit = false) or submit the result of an open activity occurrence.
/// Outcome PASS | FAIL (execution) or RENEWED | NOT_RENEWED (renewal); dates as yyyy-mm-dd.
/// ExpectedRecordVersion is the version of the result row (null for a first save).</summary>
public sealed record AssetActivityResultRequest(
    long      OrganizationId,
    string?   Outcome,
    DateTime? PerformedDate,
    string?   CertificateNumber,
    DateTime? CertificateExpiry,
    DateTime? NewExpiry,
    string?   EvidenceReference,
    string?   ResultNote,
    bool?     Submit,
    long?     ExpectedRecordVersion);

/// <summary>439: request RESCHEDULE (RevisedDueDate) | WAIVE | NOT_APPLICABLE | EXCEPTION
/// (ReviewDate) for an open occurrence, with a reason (BRD 7.1.5). ExpectedRecordVersion
/// is the version of the occurrence.</summary>
public sealed record AssetActivityDispositionRequest(
    long      OrganizationId,
    string?   DispositionType,
    string?   Reason,
    DateTime? RevisedDueDate,
    DateTime? ReviewDate,
    long?     ExpectedRecordVersion);

// ---------------------------------------------------------------------
// CMDB relationships (migration 440)
// ---------------------------------------------------------------------
/// <summary>Propose a relationship (RelationshipId null) or change one. Kinds: ASSET |
/// APPLICATION | PROCESS | VENDOR | LOCATION. Type and endpoints are fixed once proposed;
/// a change of an active critical relationship waits for approval (BRD 5.4.1 / 5.4.2).</summary>
public sealed record AssetRelationshipSaveRequest(
    long      OrganizationId,
    long?     RelationshipId,
    string?   RelationshipTypeCode,
    string?   SourceKind,
    long?     SourceId,
    string?   TargetKind,
    long?     TargetId,
    bool?     IsCritical,
    string?   DependencyCriticality,
    decimal?  ImpactWeight,
    DateTime? EffectiveFrom,
    DateTime? EffectiveTo,
    int?      ConfidencePct,
    long?     OwnerEmployeeId,
    long?     VerifierEmployeeId,
    string?   EvidenceReference,
    string?   ChangeReference,
    string?   Reason,
    long?     ExpectedRecordVersion,
    string?   ServiceRole = null);   // 441: role of the mapping ("primary database")

/// <summary>Relationship action: APPROVE | REJECT | WITHDRAW | DISPUTE | CONFIRM | RETIRE |
/// ACCEPT_RETIREMENT, with a note (required except for APPROVE / WITHDRAW).</summary>
public sealed record AssetRelationshipActionRequest(long OrganizationId, string? Action, string? Note, long? ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Business services (migration 441)
// ---------------------------------------------------------------------
/// <summary>One consumer of a service: DEPARTMENT | BUSINESS_FUNCTION | LOCATION (ConsumerRefId)
/// or EXTERNAL (ConsumerName).</summary>
public sealed record BusinessServiceConsumerItem(string? ConsumerKind, long? ConsumerRefId, string? ConsumerName, string? Note);

/// <summary>Create (ServiceId null, Draft) or change a business service (BRD 5.5). Consumers
/// null keeps the current list; an empty list clears it. Ratings 1-5; hours for RTO / RPO / MTPD.</summary>
public sealed record BusinessServiceSaveRequest(
    long      OrganizationId,
    long?     ServiceId,
    string?   ServiceCode,
    string?   ServiceName,
    string?   ServiceType,
    string?   Description,
    string?   CustomerOutcome,
    long?     BusinessOwnerEmployeeId,
    long?     ServiceManagerEmployeeId,
    long?     AccountableDepartmentId,
    int?      CriticalityId,
    byte?     ConfidentialityRating,
    byte?     IntegrityRating,
    byte?     AvailabilityRating,
    decimal?  RtoHours,
    decimal?  RpoHours,
    decimal?  MtpdHours,
    string?   ServiceHours,
    string?   SlaText,
    string?   DataClassification,
    string?   PrivacyClassification,
    DateTime? ReviewDate,
    List<BusinessServiceConsumerItem>? Consumers,
    long?     ExpectedRecordVersion);

/// <summary>Status change of a service; retiring from Retiring needs the consumer review and
/// contract assessment notes (BRD 5.5.1).</summary>
public sealed record BusinessServiceTransitionRequest(
    long    OrganizationId,
    string? ToStatus,
    string? Note,
    string? ConsumerReviewNote,
    string? ContractAssessmentNote,
    long?   ExpectedRecordVersion);

/// <summary>Organization settings: minimum active supporting relationships for activation and
/// whether a retirement needs another person approval.</summary>
public sealed record BusinessServiceSettingRequest(long OrganizationId, int? MinSupportingRelationships, bool? RetirementApprovalRequired);

// ---------------------------------------------------------------------
// Asset discovery and reconciliation (migration 442)
// ---------------------------------------------------------------------
/// <summary>Discovery source profile (BRD 5.6.1). SourceType DISCOVERY | ENDPOINT | IDENTITY | CLOUD |
/// NETWORK | SECURITY | ERP | BIOMEDICAL | FLEET | CUSTOM; CollectionMode POLLING | WEBHOOK | BATCH |
/// FILE | API. CredentialReference is a vault reference, never a secret.</summary>
public sealed record AssetDiscoverySourceRequest(
    long    OrganizationId,
    long?   SourceId,
    string? SourceCode,
    string? SourceName,
    string? SourceType,
    string? CollectionMode,
    string? ScopeText,
    string? MappingVersion,
    long?   OwnerEmployeeId,
    string? CredentialReference,
    int?    TrustLevel,
    int?    ExpectedIntervalHours,
    int?    RawRetentionDays,
    int?    ObservationRetentionDays,
    bool?   IsActive,
    long?   ExpectedRecordVersion);

/// <summary>Field precedence of a source: GOLDEN | CONTRIBUTING | IGNORED with a priority 1-999.</summary>
public sealed record AssetDiscoveryPriorityItem(string? FieldKey, string? SourceRole, int? Priority);
public sealed record AssetDiscoveryPrioritiesRequest(long OrganizationId, List<AssetDiscoveryPriorityItem>? Priorities);

/// <summary>Identification rule: comma list of dictionary field keys (or @source_key),
/// STRONG | SUPPORTING | WEAK, weight 1-100 (BRD 5.6.2).</summary>
public sealed record AssetIdentificationRuleRequest(
    long    OrganizationId,
    long?   RuleId,
    string? RuleName,
    string? AttributeKeys,
    string? Strength,
    int?    Weight,
    bool?   IsActive,
    int?    DisplayOrder);

public sealed record AssetDiscoverySettingRequest(
    long  OrganizationId,
    int?  AutoMatchScore,
    int?  SuggestedScore,
    int?  ManualReviewScore,
    int?  StaleMultiplier,
    int?  VerificationDays,
    bool? CreateConflictTasks);

/// <summary>A batch of observations: Records is the JSON array
/// [{"externalKey","observedAt","attributes":{fieldKey: value}}] passed to the procedure as is.
/// Channel UI | IMPORT | API; a repeated BatchReference returns the earlier batch.</summary>
public sealed record AssetDiscoveryIngestRequest(
    long                        OrganizationId,
    string?                     BatchReference,
    string?                     Channel,
    System.Text.Json.JsonElement? Records);

/// <summary>Reconciliation queue action: LINK | IGNORE | NOT_DUPLICATE | ACCEPT_OBSERVED | KEEP_CURRENT;
/// 443: REGISTER (new candidate / manual review -> the Draft asset just registered for it).</summary>
public sealed record AssetReconciliationResolveRequest(long OrganizationId, string? Action, long? AssetId, string? Note, long? ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Discovery follow-up: stale-asset review (migration 443)
// ---------------------------------------------------------------------
/// <summary>Aging rule: days without any source observation before an asset is stale (1-3650).</summary>
public sealed record AssetStaleSettingRequest(long OrganizationId, int? RetireAfterDays);
public sealed record AssetStaleReviewOpenRequest(long OrganizationId, long AssetId);
/// <summary>CONFIRM_SOURCE (SourceOutcome ABSENT | PRESENT) | REVIEW_DEPENDENCIES | DISMISS | REQUEST_DECOMMISSION; Note required.</summary>
public sealed record AssetStaleReviewActionRequest(long OrganizationId, string? Action, string? SourceOutcome, string? Note, long? ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Asset merge (migration 444)
// ---------------------------------------------------------------------
/// <summary>Draft merge: survivor, 1-10 duplicates, reason, field choices (field key -> duplicate asset id).</summary>
public sealed record AssetMergeSaveRequest(
    long                      OrganizationId,
    long?                     EventId,
    long                      SurvivorAssetId,
    List<long>?               DuplicateAssetIds,
    string?                   Reason,
    Dictionary<string, long>? FieldChoices,
    long?                     ExpectedRecordVersion);

/// <summary>SUBMIT | CANCEL | APPROVE | REJECT | EXECUTE | RECOVER (note required for CANCEL, REJECT, RECOVER).</summary>
public sealed record AssetMergeActionRequest(long OrganizationId, string? Action, string? Note, long? ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Asset split (migration 445) -- actions use AssetMergeActionRequest
// ---------------------------------------------------------------------
/// <summary>An item of the source for a resulting record. ObjectKind / ObjectId / ObjectKey as the split plan lists
/// them; FieldMode MOVE | COPY for ObjectKind FIELD (ObjectId = field definition).</summary>
public sealed record AssetSplitAllocationItem(string? ObjectKind, long? ObjectId, string? ObjectKey, long TargetAssetId, string? FieldMode);

/// <summary>Draft split: source, 1-5 resulting records (new Draft assets), reason, allocations.</summary>
public sealed record AssetSplitSaveRequest(
    long                            OrganizationId,
    long?                           EventId,
    long                            SourceAssetId,
    List<long>?                     ResultAssetIds,
    string?                         Reason,
    List<AssetSplitAllocationItem>? Allocations,
    long?                           ExpectedRecordVersion);

// ---------------------------------------------------------------------
// Asset Value per asset (migration 446)
// ---------------------------------------------------------------------
/// <summary>Recalculate one asset now. Reason required when the asset moves to a newer configuration version.</summary>
public sealed record AssetValuationRecalculateRequest(long OrganizationId, string? Reason);

/// <summary>Asset-level valuation method override: MAXIMUM | WEIGHTED_AVERAGE | SUMMATION, or null / the configured
/// method to remove it. Reason required.</summary>
public sealed record AssetValuationMethodRequest(long OrganizationId, string? Method, string? Reason);

/// <summary>Controlled recalculation run. ExpectedAffected is the affected-asset count the preview showed.</summary>
public sealed record AssetValuationRecalcRunRequest(long OrganizationId, string? Reason, int? ExpectedAffected);

// ---------------------------------------------------------------------
// CIA and criticality consistency rules (migration 447)
// ---------------------------------------------------------------------
/// <summary>One condition: conditions with the same GroupNo are ANDed, groups are ORed (421 semantics).
/// OperatorCode EQ | NEQ | IN | NOT_IN (values separated by |) | EMPTY | NOT_EMPTY | GT | GTE | LT | LTE |
/// DATE_BEFORE_TODAY | DATE_AFTER_TODAY | DATE_WITHIN_DAYS.</summary>
public sealed record AssetConsistencyConditionItem(int? GroupNo, string? OperandKey, string? OperatorCode, string? CompareValue);

/// <summary>New rule (RuleId null -> version 1 Draft) or a Draft change. ScopeKind TENANT | CATEGORY | SUBCATEGORY |
/// ASSET_TYPE | SERVICE (+ ScopeRefId); Severity INFO | WARNING | ERROR | APPROVAL_REQUIRED; ActionCode WARN |
/// REQUIRE_RATIONALE | CREATE_TASK | BLOCK_TRANSITION.</summary>
public sealed record AssetConsistencyRuleSaveRequest(
    long                                 OrganizationId,
    long?                                RuleId,
    string?                              RuleName,
    string?                              Description,
    string?                              ScopeKind,
    long?                                ScopeRefId,
    string?                              Severity,
    string?                              ActionCode,
    bool?                                OverrideAllowed,
    int?                                 MaxOverrideDays,
    DateTime?                            EffectiveFrom,
    DateTime?                            EffectiveTo,
    string?                              ChangeReason,
    List<AssetConsistencyConditionItem>? Conditions,
    long?                                ExpectedRecordVersion);

/// <summary>ACTIVATE | RETIRE (reason) | NEW_VERSION (reason) | DISCARD.</summary>
public sealed record AssetConsistencyRuleActionRequest(long OrganizationId, string? Action, string? Reason, long? ExpectedRecordVersion);

/// <summary>ACCEPT (rationale, owner, review date; evidence for Error / Approval Required) | WITHDRAW |
/// APPROVE | REJECT (note) | REVOKE (note).</summary>
public sealed record AssetConsistencyFindingActionRequest(
    long      OrganizationId,
    string?   Action,
    string?   Rationale,
    string?   Evidence,
    long?     OwnerEmployeeId,
    DateTime? ReviewDate,
    string?   Note,
    long?     ExpectedRecordVersion);

/// <summary>Re-evaluate one asset (AssetId) or the whole organization.</summary>
public sealed record AssetConsistencyRunRequest(long OrganizationId, long? AssetId);

// ---------------------------------------------------------------------
// Asset privacy (migration 448)
// ---------------------------------------------------------------------
/// <summary>Organization (AssetTypeId null) or asset-type setting of one privacy requirement. Enforcement OFF | WARN |
/// BLOCK; null removes the row (back to the organization / catalogue default).</summary>
public sealed record AssetPrivacySettingRequest(long OrganizationId, int? AssetTypeId, string? RequirementCode, string? Enforcement,
    bool? ExceptionAllowed, int? MaxExceptionDays);

/// <summary>Privacy exception for an open gap of one requirement: reason, compensating controls, owner, expiry.</summary>
public sealed record AssetPrivacyExceptionRequest(long OrganizationId, long AssetId, string? RequirementCode, string? Reason,
    string? CompensatingControls, long? OwnerEmployeeId, DateTime? ExpiryDate);

/// <summary>APPROVE | REJECT (note) | WITHDRAW | REVOKE (note).</summary>
public sealed record AssetPrivacyExceptionActionRequest(long OrganizationId, string? Action, string? Note, long? ExpectedRecordVersion);

/// <summary>Privacy review: REVIEWED with NextDate (next review). Retention review: DELETE / ARCHIVE (evidence),
/// LEGAL_HOLD (NextDate = next verification), EXTEND (note, NextDate = kept until; approver).</summary>
public sealed record AssetPrivacyReviewCompleteRequest(long OrganizationId, string? Outcome, string? Note, string? Evidence,
    DateTime? NextDate, long? ExpectedRecordVersion);

/// <summary>Refresh reviews and exception expiry for one asset or the organization.</summary>
public sealed record AssetPrivacyRunRequest(long OrganizationId, long? AssetId);

// ---------------------------------------------------------------------
// Asset governance KPIs (migration 450)
// ---------------------------------------------------------------------
/// <summary>One KPI of the organization: enabled, weight 0-100, target / warning 0-100 (higher-is-better: warning not
/// above target; lower-is-better: not below), period in days for KPIs that have one. Reset = back to the defaults.</summary>
public sealed record AssetGovernanceSettingRequest(long OrganizationId, string? KpiCode, bool? Reset, bool? IsEnabled, int? Weight,
    decimal? TargetValue, decimal? WarningValue, int? PeriodDays);

/// <summary>Overall score thresholds and how long record-level detail of a snapshot is kept (days).</summary>
public sealed record AssetGovernanceOrgSettingRequest(long OrganizationId, decimal? OverallTarget, decimal? OverallWarning,
    int? ItemRetentionDays);

/// <summary>Relationships an asset type requires (Relationship Completeness). New when RuleId is null: asset type,
/// relationship type and AssetSide (SOURCE | TARGET) are then required and fixed afterwards.</summary>
public sealed record AssetGovernanceRelationshipRuleRequest(long OrganizationId, long? RuleId, int? AssetTypeId,
    string? RelationshipTypeCode, string? AssetSide, int? MinCount, bool? IsActive);

/// <summary>Take a snapshot now (a new version of today only when the results changed).</summary>
public sealed record AssetGovernanceSnapshotRequest(long OrganizationId);

// ---------------------------------------------------------------------
// Asset & Contract report catalogue and exports (migration 452)
// ---------------------------------------------------------------------
/// <summary>Filters of one report run or export. The report definition decides which filters apply; the others are
/// ignored by sp_asset_report_run. Days empty = the report default.</summary>
public sealed record AssetReportRunRequest(long OrganizationId, string? ReportCode, string? Search, string? Status, int? AssetTypeId,
    DateTime? DateFrom, DateTime? DateTo, int? Days);

/// <summary>Organization setting of one report: enabled, classification (not below the default; empty = default),
/// export policy ALLOWED | APPROVER | DISABLED (empty = APPROVER for RESTRICTED, else ALLOWED).</summary>
public sealed record AssetReportSettingRequest(long OrganizationId, string? ReportCode, bool? IsEnabled, string? Classification,
    string? ExportPolicy);

/// <summary>Outcome of a report run or export: the data, or the refusal (53100-53119) of the procedures.</summary>
public sealed record AssetReportResult(bool Success, object? Data, int? ErrorNumber, string? Error);

// ---------------------------------------------------------------------
// Report schedules, distribution and delivered files (migration 453)
// ---------------------------------------------------------------------
/// <summary>A distribution list entry: Kind EMPLOYEE (Id = employee) or ROLE (Id = organization role; every active holder
/// at delivery time).</summary>
public sealed record AssetReportScheduleRecipient(string? Kind, long? Id);

/// <summary>A report schedule. New when ScheduleId is null; the report is fixed afterwards. Frequency DAILY | WEEKLY
/// (DayOfWeek 1 Monday - 7 Sunday) | MONTHLY (DayOfMonth 1-28). DateWindowDays: date-range reports cover the last N days
/// up to the run date. RetentionDays: how long delivered files are kept (1-3650, default 90).</summary>
public sealed record AssetReportScheduleRequest(long OrganizationId, long? ScheduleId, string? ReportCode, string? ScheduleName,
    string? Search, string? Status, int? AssetTypeId, int? Days, int? DateWindowDays, string? Frequency, int? DayOfWeek,
    int? DayOfMonth, int? RetentionDays, bool? IsActive, IReadOnlyList<AssetReportScheduleRecipient>? Recipients,
    long? ExpectedRecordVersion);

/// <summary>Run one schedule now, or download one delivered file (organization of the request).</summary>
public sealed record AssetReportOrganizationRequest(long OrganizationId);

/// <summary>What a delivery pass did: deliveries started, files delivered, recipients failed and skipped.</summary>
public sealed record AssetReportDeliveryPassResult(int Deliveries, int Delivered, int Failed, int Skipped);

/// <summary>Outcome of a write: Success, the new/affected id, and on
/// failure the SQL error number + message so the controller can pick the
/// HTTP status (404 not found, 409 conflict, 400 validation).</summary>
public sealed record AssetConfigWriteResult(bool Success, long? Id, int? ErrorNumber, string? Error);
