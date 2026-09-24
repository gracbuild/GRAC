// =====================================================================
// ResolveWorkspaceModels
//
// Shapes for the rebuilt Resolve screens (migrations 140/141): the
// owner-scoped instance list, and the per-instance workspace carrying
// obligations and dependencies.
//
// Property names match the procedures' result aliases exactly, so the
// readers stay a straight lookup with nothing to drift.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- grac_practice.sp_resolve_instance_list ----------
public sealed record ResolveInstanceQuery(
    long    OrganizationId,
    long?   CallerEmployeeId,
    bool    IsAdmin,
    string? Search,
    int     PageNumber = 1,
    int     PageSize   = 25,
    // 287. Mirrors @include_retired's own default: the Operationalize
    // list is a work queue, and one that silently started including
    // retired rows would be worse than one that could not show them.
    bool    IncludeRetired = false,
    // 287. Drill-down from Practices / Organization Requirements. Both
    // null = no opinion, which is what the plain list passes.
    long?   PracticeId = null,
    long?   OrganizationRequirementId = null,
    // 315. Operationalize's Owner / Status filters. Both null = no
    // opinion, matching every other optional predicate on this query.
    // OwnerEmployeeId narrows to one owner (never widens whose rows a
    // non-admin sees -- the ownership test in the procedure still runs
    // first, independently); ImplementationStatus matches the same
    // free-text value the grid's Status badge already renders.
    long?   OwnerEmployeeId = null,
    string? ImplementationStatus = null);

public sealed record ResolveInstanceRow(
    long    PracticeInstanceId,
    string  InstanceCode,
    string  InstanceName,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long?   OwnerEmployeeId,
    string? OwnerName,
    string? Department,
    string? Criticality,
    string? ImplementationStatus,
    string? Status,
    int     TotalObligations,
    int     AdoptedObligations,
    int     TotalDependencies,
    int     ResolvedDependencies);

// 315. The Owner and Status filters' own dropdown options -- computed by
// the procedure over the same organisation/ownership/drill-down scope as
// the row set, but independent of @search, @owner_employee_id and
// @implementation_status themselves, so a dropdown always offers every
// value the caller could pick rather than only the ones the current
// filter selection leaves standing. See sp_resolve_instance_list result
// sets 2 and 3 (315_operationalize_owner_status_filters.sql).
public sealed record ResolveInstanceOwnerOption(
    long    OwnerEmployeeId,
    string  OwnerName);

public sealed record ResolveInstanceStatusOption(
    string  ImplementationStatus);

// TotalRows is the count the procedure's WHERE clause matched, before
// OFFSET/FETCH trimmed it to a page -- added by migration 290 so the
// Operationalize grid can draw a row range and disable Next on the exact
// boundary. Defaulted, and last, so the two existing construction sites
// (the two failure returns) keep compiling unchanged; 0 is also what the
// UI treats as "no total available" and degrades on.
//
// Owners / Statuses (315) default to an empty list for the same reason:
// a caller built against a pre-315 database, or a failure return that
// never reached the second/third result set, still constructs cleanly.
public sealed record ResolveInstanceResult(
    bool Success, IReadOnlyList<ResolveInstanceRow> Rows, string? Error = null,
    long TotalRows = 0,
    IReadOnlyList<ResolveInstanceOwnerOption>? Owners = null,
    IReadOnlyList<ResolveInstanceStatusOption>? Statuses = null);

// ---------- grac_practice.sp_resolve_instance_detail ----------
public sealed record ResolveInstanceDetail(
    long    PracticeInstanceId,
    long    OrganizationId,
    string? OrganizationName,
    string  InstanceCode,
    string  InstanceName,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long?   OwnerEmployeeId,
    string? OwnerName,
    string? Department,
    // ExecutionFrequency / AssuranceFrequency removed with migration 236 --
    // frequency is a property of an obligation now, not of the instance.
    string? AssuranceMode,
    string? Criticality,
    string? ImplementationStatus,
    string? Status,
    // Migration 222. The profile editor needs an id to select by --
    // Department is a display name and no use as one. Null on a database
    // that has not run 222; the editor hides itself rather than saving a
    // blank over a real value.
    long?   OwnerDepartmentId = null,
    long?   BusinessFunctionId = null,
    string? BusinessFunction = null,
    /// <summary>
    /// True when the detail result set carried the 222 columns — i.e. the
    /// deployed database has run migration 222 and the profile / retire /
    /// dependency-category procedures exist.
    ///
    /// The nullable fields above cannot answer this: BusinessFunctionId is
    /// null both when 222 is missing and when the instance simply has no
    /// business function. The workspace hides those editors unless this is
    /// true, because an editor whose Save can only fail is worse than no
    /// editor.
    /// </summary>
    bool    ProfileEditable = false);

public sealed record ResolveInstanceDetailResult(
    bool Success, ResolveInstanceDetail? Instance, string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_list ----------
public sealed record ResolveObligationRow(
    long    ObligationId,
    string  ObligationName,
    string? ObligationText,
    string? TypeCode,
    string? TypeName,
    long?   ReleaseId,
    string? FrameworkRelease,
    bool    IsSubscribed,
    // As published by the authority.
    string? PublishedExecutionFrequency,
    string? PublishedResponsibility,
    string? PublishedApprovalAuthority,
    string? PublishedRetention,
    // As adopted here; null until the organization adopts it.
    long?   AdoptionId,
    bool    IsAdopted,
    bool    OrganizationModified,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    int?    AssuranceFrequencyId,
    string? AssuranceFrequency,
    // EventDriven-Assurance overrides, migration 234. NULL on rows that
    // have not been overridden; the UI reads that as "use the authority's
    // value" and shows nothing next to the field.
    long?   EventTypeId,
    int?    SlaValue,
    string? SlaUnit,
    // Migration 242: per-obligation implementation status id. NULL until
    // the organisation records one. The label comes from the existing
    // implementation-status master lookup on the UI side.
    int?    ImplementationStatusId,
    // Migration 244: connection payload for an Assurance obligation whose
    // assurance_type is Automated. Both NULL for Manual assurance, and for
    // any obligation type where "how do we reach the system" is not a
    // meaningful question. The connection-type label is looked up from
    // connection_type_master on the UI side.
    int?    ConnectionTypeId,
    string? ConnectionUrl,
    string? Responsibility,
    string? ApprovalAuthority,
    string? RetentionPeriod,
    string? Remarks,
    string? AdoptedBy,
    DateTime? AdoptedDt,
    int     PublishedEvidenceCount,
    int     ResolvedEvidenceCount,

    // ---- Typed obligation detail (migration 224) ----
    //
    // Control Management's seven-type taxonomy gives each obligation type
    // its own fields — a State rule has attribute/operator/value, an
    // Event Response has trigger/SLA/escalation — and the admin module
    // captures them accordingly. The four Published* strings above are
    // the pre-taxonomy flat shape, and they read as four dashes on a
    // State obligation.
    //
    // Each of these is a JSON array from grac_practice.vw_pm_obligation_typed_detail,
    // "[]" when the obligation is not of that type or has no active
    // detail rows. Passed through as strings rather than deserialised:
    // the API adds nothing to them, and re-parsing into records here
    // would be a third place that has to learn about an eighth type.
    /// <summary>The published statement, for the card's Description block.</summary>
    string? ObligationDescription = null,
    string  StateRulesJson        = "[]",
    string  ExecutionSpecsJson    = "[]",
    string  AssuranceSpecsJson    = "[]",
    string  EventResponsesJson    = "[]",
    string  ConstraintRulesJson   = "[]",
    string  RetentionSpecsJson    = "[]",
    string  PublishedEvidenceJson = "[]",
    /// <summary>
    /// The Manual/Automated answer recorded at adoption (migration 226).
    /// Null on a database without 226, and on obligations adopted before
    /// it — the form then shows "Not set" rather than inventing one.
    /// </summary>
    string? AdoptedAssuranceType  = null,
    /// <summary>
    /// False when the result set had no typed columns — migration 224 is
    /// not applied. The card then shows the published four fields, which
    /// is the honest rendering rather than seven empty sections.
    /// </summary>
    bool    TypedDetailAvailable  = false,
    /// <summary>
    /// False when the result set had no AdoptedAssuranceType column —
    /// migration 226 is not applied. The form hides the control rather
    /// than offering a choice the save would silently drop.
    /// </summary>
    bool    AssuranceTypeAvailable = false,

    // ---- Organisation-defined obligations (migration 227) ----
    /// <summary>
    /// The card's identity. A locally added obligation has no
    /// ObligationId — it has no row in GRAC_New at all — so the browser
    /// keys its checkbox, its expanded state and its dirty bag on this
    /// instead: "p{obligationId}" or "l{adoptionId}".
    /// </summary>
    string? RowKey = null,
    /// <summary>
    /// True for an obligation this organisation added itself. Such a row
    /// has no published side to compare against, is always adopted, and
    /// can be edited and removed rather than only adopted.
    /// </summary>
    bool    IsOrganizationDefined = false);

public sealed record ResolveObligationResult(
    bool Success, IReadOnlyList<ResolveObligationRow> Obligations, string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_type_list ----------
public sealed record ResolveObligationType(
    int     ObligationTypeId,
    string  TypeCode,
    string? TypeName,
    int     DisplayOrder);

public sealed record ResolveObligationTypeListResult(
    bool Success, IReadOnlyList<ResolveObligationType> Types, string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_vocabulary ----------
/// <summary>
/// The two vocabularies the mirrored Assurance panel needs (migration
/// 230). Both live in GRAC_New and belong to Control Management; this
/// module only reads them.
/// </summary>
public sealed record ResolveTriggerMode(
    string  TriggerMode,
    string? TriggerModeLabel,
    int     DisplayOrder);

/// <summary>
/// Flat, with the parent id — the form builds the domain to event
/// cascade from ParentEventTypeId, the same way Control Management's own
/// obligation form does, so one call serves both levels.
/// </summary>
public sealed record ResolveEventType(
    long    EventTypeId,
    long?   ParentEventTypeId,
    string? EventCode,
    string? EventName,
    string? Description,
    bool    IsDomain,
    int     DisplayOrder);

public sealed record ResolveObligationVocabularyResult(
    bool Success,
    IReadOnlyList<ResolveTriggerMode> TriggerModes,
    IReadOnlyList<ResolveEventType>   EventTypes,
    string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_type_field_rules ----------
/// <summary>
/// Which field of a type applies for which value of its driver column
/// (migration 228) — the Assurance trigger being the case that prompted
/// it: event driven wants the event fields, scheduled wants a frequency.
///
/// INFERRED FROM CONTROL MANAGEMENT'S OWN ROWS, not declared. A driver
/// value nobody has used yet produces no rule, so the form treats a
/// missing rule as "show everything": an over-full form is a nuisance, a
/// form missing the field you need is a dead end.
/// </summary>
public sealed record ResolveObligationFieldRule(
    string DriverColumn,
    string DriverValue,
    string VisibleColumn,
    int    SampleRows);

/// <summary>
/// One value the driver column can take (migration 229), and whether
/// anything was learned about which fields it governs.
///
/// Kept separate from the rules because they answer different questions:
/// the rules say what the DATA shows, this says what the column ALLOWS.
/// Deriving the list from the rules is how the form ended up offering
/// only EventDriven — the one value three existing rows happened to use.
/// </summary>
public sealed record ResolveObligationDriverValue(
    string DriverColumn,
    string DriverValue,
    int    SampleRows,
    bool   HasRule);

public sealed record ResolveObligationFieldRuleResult(
    bool Success,
    IReadOnlyList<ResolveObligationFieldRule> Rules,
    string? Error = null,
    IReadOnlyList<ResolveObligationDriverValue>? DriverValues = null);

// ---------- grac_practice.sp_resolve_obligation_type_fields ----------
/// <summary>
/// One rule field of one obligation type, read straight from the Control
/// Management table that type's detail lives in (migration 227). The add
/// form builds its inputs from these, so it asks for exactly what CM's
/// own obligation form asks for — and a column CM adds appears here with
/// no Practice Management change, the same discipline migration 225
/// applied to the display side.
/// </summary>
public sealed record ResolveObligationTypeField(
    string? TableName,
    string  ColumnName,
    string? DataType,
    int     MaxLength,
    bool    IsNullable,
    int     Ordinal,
    /// <summary>Column name ends in _id — a lookup, not free text.</summary>
    bool    IsReference);

public sealed record ResolveObligationTypeFieldResult(
    bool Success, IReadOnlyList<ResolveObligationTypeField> Fields, string? Error = null);

// ---------- grac_practice.sp_resolve_local_obligation_save ----------
/// <summary>
/// Add, edit or retire one organisation-defined obligation on a practice
/// instance (migration 227).
///
/// <see cref="PracticeInstanceObligationId"/> 0 adds; anything else
/// edits, and only a row that belongs to this instance and has
/// obligation_id NULL — an adopted published obligation is not editable
/// through this door.
///
/// <see cref="TypedDetailJson"/> is the same JSON array shape
/// vw_pm_obligation_typed_detail emits for the published side, so the
/// card renders both identically.
/// </summary>
public sealed record ResolveLocalObligationSaveRequest(
    long    PracticeInstanceId,
    long    PracticeInstanceObligationId,
    string? ObligationName,
    string? ObligationDescription,
    string? ObligationTypeCode,
    string? TypedDetailJson,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? AssuranceType,
    string? Remarks,
    bool    Retire,
    string? Actor,
    // Migration 242: per-obligation implementation status. Optional so an
    // older payload still binds; the procedure COALESCEs NULL onto the
    // stored value, leaving it alone.
    int?    ImplementationStatusId = null,
    // Migration 244: connection payload for Automated assurance. Same
    // "absent means keep what's stored" contract as the fields above.
    int?    ConnectionTypeId       = null,
    string? ConnectionUrl          = null,
    /// <summary>
    /// The COMPLETE evidence set for this obligation (migration 232), or
    /// null for "no opinion" — an older caller, or an edit that did not
    /// touch evidence, must not silently retire it. An explicit empty
    /// list is how you say "none".
    ///
    /// Scope is narrow: only rows carrying this obligation's
    /// source_practice_instance_obligation_id are touched, so evidence
    /// belonging to a published obligation is never in range. A row
    /// somebody has already located or assigned an owner to is kept even
    /// when its type is dropped from the list.
    /// </summary>
    IReadOnlyList<ResolveLocalEvidenceItem>? Evidence = null);

public sealed record ResolveLocalEvidenceItem(
    int     EvidenceTypeId,
    bool    IsMandatory,
    string? RetentionPeriod,
    string? Remarks);

// ---------- grac_practice.sp_resolve_obligation_adopt ----------
/// <summary>
/// One decision per obligation. Leave a parameter null to take the
/// published value; the procedure derives OrganizationModified from what
/// actually differs, so nothing here asserts it.
/// </summary>
public sealed record ResolveObligationDecision(
    long    ObligationId,
    bool    IsAdopted,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    int?    AssuranceFrequencyId,
    string? AssuranceFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? RetentionPeriod,
    string? Remarks,
    /// <summary>
    /// Manual or Automated, migration 226. Same two values and the same
    /// meaning as practice_instance.assurance_mode ("Practice type" on
    /// the instance profile) — this is the per-obligation answer.
    ///
    /// Optional and last so an older caller's payload still binds. The
    /// procedure COALESCEs an absent value to what is stored rather than
    /// blanking it.
    /// </summary>
    string? AssuranceType = null,
    /// <summary>
    /// EventDriven-Assurance overrides, migration 234. NULL means "use the
    /// authority's value" -- the store on practice_instance_obligation is
    /// itself NULL for a row that has not been overridden, so passing null
    /// preserves the published event and SLA.
    ///
    /// Optional and last for the same reason AssuranceType is: an older
    /// payload's binding is unchanged.
    /// </summary>
    long?   EventTypeId = null,
    int?    SlaValue    = null,
    string? SlaUnit     = null,
    /// <summary>
    /// Migration 242: per-obligation implementation status. Optional and
    /// last for the same reason above -- absent key means "no opinion"
    /// and the procedure keeps the stored value. The operationalize UI
    /// picks an id from the implementation-status master lookup.
    /// </summary>
    int?    ImplementationStatusId = null,
    /// <summary>
    /// Migration 244: connection details for an Assurance obligation whose
    /// assurance_type is Automated. Both optional -- an absent key means
    /// "no opinion" and the procedure keeps whatever is stored. The UI
    /// only sends these when Assurance type is Automated; the connection
    /// type id is picked from connection_type_master.
    /// </summary>
    int?    ConnectionTypeId = null,
    string? ConnectionUrl    = null,
    /// <summary>
    /// Migration 336-338: first occurrence date for a schedulable
    /// (Execution / Assurance) obligation. The cadence comes from the
    /// obligation's own frequency; this is the one thing the calendar
    /// cannot derive -- WHEN the recurring schedule starts. Optional and
    /// last so an older payload still binds. Null leaves an existing
    /// stream's anchor as-is; a new stream with no date anchors to today.
    /// Carried to sp_pm_sync_instance_schedule_rules after adoption, not
    /// to sp_resolve_obligation_adopt.
    /// </summary>
    DateTime? FirstOccurrenceDate = null);

public sealed record ResolveObligationAdoptRequest(
    long PracticeInstanceId,
    long? OrganizationId,
    IReadOnlyList<ResolveObligationDecision> Obligations,
    string? Actor);

public sealed record ResolveObligationOutcome(
    long    ObligationId,
    string? ObligationName,
    string  Outcome,
    bool    OrganizationModified,
    bool    NotSubscribed,
    int     EvidenceRows,
    int     UnmappedEvidenceTypes);

public sealed record ResolveObligationAdoptResult(
    bool Success,
    IReadOnlyList<ResolveObligationOutcome> Outcomes,
    string? Error = null)
{
    public int AdoptedCount => Outcomes.Count(o => o.Outcome == "Adopted");
    public int RemovedCount => Outcomes.Count(o => o.Outcome == "Removed");
    /// <summary>
    /// Published evidence types with no practice-side equivalent. Those
    /// rows were not created, and the screen says so rather than letting
    /// the count quietly disagree with the obligation.
    /// </summary>
    public int UnmappedEvidenceTypes => Outcomes.Sum(o => o.UnmappedEvidenceTypes);
}

// ---------- grac_practice.sp_resolve_dependency_list ----------
public sealed record ResolveDependencyCategory(
    int     DependencyTypeId,
    string  DependencyCategory,
    long?   DependencyId,
    int     ResolvedCount,
    string? ResolvedNames,
    bool    IsResolved);

public sealed record ResolveDependencyItem(
    long    ResolutionId,
    int     DependencyTypeId,
    long    ResolvedDependencyId,
    string  ResolvedDependencyName,
    long?   ResolutionOwnerId,
    string? ResolutionOwnerName,
    string? Remarks,
    string? ResolutionStatus);

public sealed record ResolveDependencyResult(
    bool Success,
    IReadOnlyList<ResolveDependencyCategory> Categories,
    IReadOnlyList<ResolveDependencyItem> Resolutions,
    string? Error = null);

// ---------- grac_practice.sp_resolve_dependency_save ----------
public sealed record ResolveDependencyObject(long Id, string Name);

/// <summary>
/// Several objects per category, in one call. Nothing is deactivated
/// implicitly: sending A and B does not retire C. Removing is the
/// separate, explicit act below, because "one more" and "only these"
/// are different intentions a tick list cannot distinguish.
/// </summary>
public sealed record ResolveDependencySaveRequest(
    long    PracticeInstanceId,
    long?   OrganizationId,
    int     DependencyTypeId,
    IReadOnlyList<ResolveDependencyObject> Objects,
    long?   ResolutionOwnerId,
    string? Remarks,
    string? Actor);

public sealed record ResolveDependencyRemoveRequest(
    long    PracticeInstanceId,
    long    ResolutionId,
    string? Actor);

// ---------- grac_practice.sp_resolve_dependency_category_sync ----------
/// <summary>
/// The complete-set counterpart of ResolveDependencySaveRequest: whatever
/// is in <see cref="Objects"/> IS the desired set for this category on
/// this instance. Anything already resolved that is not in the list is
/// retired, and any object in the list that isn't yet resolved is added.
///
/// This is what the Operationalize page's dependency table sends on its
/// per-row Save. The single-object save (SaveDependencyAsync) stays for
/// the older "one more" flow.
/// </summary>
public sealed record ResolveDependencyCategorySyncRequest(
    long    PracticeInstanceId,
    int     DependencyTypeId,
    IReadOnlyList<ResolveDependencyObject> Objects,
    string? Actor);

/// <param name="SavedId">
/// The row the command wrote, when it has one. Optional and neutral on
/// purpose -- most commands leave it null. It exists so a caller that
/// failed AFTER the write can retry against the same row instead of
/// creating a second one.
/// </param>
public sealed record ResolveCommandResult(
    bool Success, string? Message = null, string? Error = null, long? SavedId = null);

// ResolveFrequencySaveRequest retired. Instance-level frequency was
// removed from the UI; per-obligation frequency (Execution and Assurance
// types only) is what the organisation edits now. See migration 235.

// ---------- grac_practice.sp_resolve_instance_profile_save ----------
/// <summary>
/// The instance's own profile — the part of it that is not owned by the
/// obligations. Migration 222; see docs/practice-instance-form-slimming.md.
///
/// Null means "no opinion" here: a caller that sends only Criticality
/// must not blank the other three. (This differed from the retired
/// ResolveFrequencySaveRequest, which sent all frequencies together and
/// treated null as an explicit clear.)
///
/// <see cref="PrimaryOwnerId"/> is honoured only for an admin caller. A
/// non-admin who sends a different owner is refused (52673) rather than
/// ignored — every Resolve procedure scopes a non-admin to the instances
/// they own, so a self-reassignment would lock them out of the instance
/// they just edited.
/// </summary>
public sealed record ResolveProfileSaveRequest(
    long    PracticeInstanceId,
    string? AssuranceMode,
    string? Criticality,
    long?   BusinessFunctionId,
    long?   PrimaryOwnerId,
    string? Actor);

// ---------- grac_practice.sp_resolve_instance_retire ----------
/// <summary>
/// The explicit retirement act migration 139 reserved for the Practice
/// Instances screen. Sets status to Inactive; never deletes — the row is
/// a foreign key in roughly twenty tables.
///
/// <see cref="Remark"/> is required as of migration 355: the procedure
/// throws 52815 when it is null/blank. It is asked for on the same page
/// the Retire button lives on, not as a follow-up popup after the act.
/// </summary>
public sealed record ResolveInstanceRetireRequest(
    long    PracticeInstanceId,
    string? Actor,
    string? Remark = null);

// 287. Same shape as the retire request because it is the same act in
// reverse -- one id, an actor and (355) a required remark. A separate
// record rather than a reused one so the two endpoints cannot be called
// with each other's payload by accident.
public sealed record ResolveInstanceRestoreRequest(
    long    PracticeInstanceId,
    string? Actor,
    string? Remark = null);

// ---------- grac_practice.sp_resolve_dependency_type_list ----------
public sealed record ResolveDependencyTypeRow(
    int    DependencyTypeId,
    string DependencyCategory,
    bool   IsDeclared,
    /// <summary>
    /// Active resolutions against this category. Non-zero means the tick
    /// cannot be cleared until the objects are removed on the dependency
    /// card — the procedure refuses it and reports the category back.
    /// </summary>
    int    ResolvedCount);

public sealed record ResolveDependencyTypeResult(
    bool Success, IReadOnlyList<ResolveDependencyTypeRow> Rows, string? Error = null);

// ---------- grac_practice.sp_resolve_dependency_type_save ----------
/// <summary>
/// <see cref="DependencyTypeIds"/> is the COMPLETE desired set, not a
/// delta: the picker is a full-set control, so it carries the "these are
/// now the only ones" intention that migration 142 warned a partial
/// payload does not.
/// </summary>
public sealed record ResolveDependencyTypeSaveRequest(
    long              PracticeInstanceId,
    IReadOnlyList<int> DependencyTypeIds,
    string?           Actor);

public sealed record ResolveDependencyTypeSaveResult(
    bool Success,
    string? Message = null,
    int AddedCount = 0,
    int RemovedCount = 0,
    IReadOnlyList<ResolveDependencyTypeRow>? Blocked = null,
    string? Error = null);

// ---------- grac_practice.sp_resolve_evidence_list ----------
public sealed record ResolveEvidenceRow(
    long    EvidenceId,
    long?   SourceObligationId,
    /// <summary>
    /// Which organisation-defined obligation this row belongs to
    /// (migrations 231/232). Null for published-obligation evidence and
    /// for rows added by hand — those have no local owner.
    /// </summary>
    long?   SourcePracticeInstanceObligationId,
    /// <summary>
    /// Migration 254. The organisation's own label for this evidence row
    /// on this instance — "Q3 firewall ruleset export", as against
    /// EvidenceType, which is the shared catalogue name. Null when the
    /// row has not been named; the screen falls back to the type.
    /// </summary>
    string? EvidenceName,
    int     EvidenceTypeId,
    string? EvidenceType,
    /// <summary>
    /// Migration 306. What the authority published as the instruction for
    /// this evidence (GRAC_New.requirement_obligation_evidence.remarks),
    /// read live rather than copied — Control Management can edit it after
    /// the obligation was adopted. Read-only here: it is published data,
    /// so sp_resolve_evidence_save neither accepts nor stores it. Null
    /// when nothing is published, or on a pre-306 database.
    /// </summary>
    string? EvidenceRemarks,
    bool    IsMandatory,
    int?    CollectionMethodId,
    string? CollectionMethod,
    int?    CollectionFrequencyId,
    string? CollectionFrequency,
    int?    AssuranceTypeId,
    string? AssuranceType,
    string? RetentionPeriod,
    string? EvidenceOwner,
    string? EvidenceDescription,
    string? EvidenceLocation,
    string? EvidenceLocator,
    int?    AlignmentStatusId,
    string? AlignmentStatus,
    bool    InheritedFromRepository,
    bool    OrganizationModified,
    /// <summary>
    /// Location and locator both present -- the same test assurance
    /// eligibility applies, so this cannot say ready where assurance
    /// would then refuse.
    /// </summary>
    bool    IsResolved);

public sealed record ResolveEvidenceResult(
    bool Success, IReadOnlyList<ResolveEvidenceRow> Evidence, string? Error = null);

// ---------- grac_practice.sp_resolve_evidence_save ----------
/// <summary>
/// Null means "leave as it is", so a screen can save one field without
/// resending what it did not touch. ClearOwner is the explicit way to
/// blank an owner, since null cannot mean both "unchanged" and "remove".
/// </summary>
public sealed record ResolveEvidenceSaveRequest(
    long    PracticeInstanceId,
    long    EvidenceId,
    bool?   IsMandatory,
    int?    CollectionMethodId,
    int?    CollectionFrequencyId,
    int?    AssuranceTypeId,
    string? RetentionPeriod,
    long?   OwnerEmployeeId,
    bool    ClearOwner,
    string? EvidenceDescription,
    string? EvidenceLocation,
    string? EvidenceLocator,
    /// <summary>Migration 254. Null means "unchanged", as above.</summary>
    string? EvidenceName,
    string? Actor);
