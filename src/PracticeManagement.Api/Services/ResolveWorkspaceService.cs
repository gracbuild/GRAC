// =====================================================================
// ResolveWorkspaceService
//
// Facade over the migration-141 procedures:
//   sp_resolve_instance_list      sp_resolve_instance_detail
//   sp_resolve_obligation_list    sp_resolve_obligation_adopt
//   sp_resolve_dependency_list    sp_resolve_dependency_save
//
// Same shape as EventScopeService / PracticeConfigureService: single
// interface, DbType-typed AddParam, connection via
// SqlConnectionStringResolver, every error caught and returned.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IResolveWorkspaceService
{
    Task<ResolveInstanceResult>        ListInstancesAsync(ResolveInstanceQuery query, CancellationToken cancellationToken);
    Task<ResolveInstanceDetailResult>  GetInstanceAsync(long practiceInstanceId, long? organizationId, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveObligationResult>      ListObligationsAsync(long practiceInstanceId, bool includeUnsubscribed, CancellationToken cancellationToken);
    Task<ResolveObligationAdoptResult> AdoptObligationsAsync(ResolveObligationAdoptRequest request, CancellationToken cancellationToken);
    Task<ResolveDependencyResult>      ListDependenciesAsync(long practiceInstanceId, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         SaveDependencyAsync(ResolveDependencySaveRequest request, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         RemoveDependencyAsync(ResolveDependencyRemoveRequest request, CancellationToken cancellationToken);
    // Migration 238: complete-set sync per category. Used by the
    // Operationalize page's dependency table -- one call per row.
    Task<ResolveCommandResult>         SyncDependencyCategoryAsync(ResolveDependencyCategorySyncRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    // SaveFrequencyAsync retired; per-obligation frequency now covers it.
    Task<ResolveCommandResult>         SaveProfileAsync(ResolveProfileSaveRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         RetireInstanceAsync(ResolveInstanceRetireRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         RestoreInstanceAsync(ResolveInstanceRestoreRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveDependencyTypeResult>  ListDependencyTypesAsync(long practiceInstanceId, CancellationToken cancellationToken);
    Task<ResolveObligationTypeListResult>  ListObligationTypesAsync(CancellationToken cancellationToken);
    Task<ResolveObligationTypeFieldResult> ListObligationTypeFieldsAsync(string typeCode, CancellationToken cancellationToken);
    Task<ResolveObligationFieldRuleResult> ListObligationFieldRulesAsync(string typeCode, CancellationToken cancellationToken);
    Task<ResolveObligationVocabularyResult> GetObligationVocabularyAsync(CancellationToken cancellationToken);
    Task<ResolveCommandResult>         SaveLocalObligationAsync(ResolveLocalObligationSaveRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveDependencyTypeSaveResult> SaveDependencyTypesAsync(ResolveDependencyTypeSaveRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveEvidenceResult>        ListEvidenceAsync(long practiceInstanceId, long? obligationId, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         SaveEvidenceAsync(ResolveEvidenceSaveRequest request, CancellationToken cancellationToken);
    // Migration 473: files attached to one-time evidence at implementation.
    // organizationId: the organisation the Web tier checked the caller
    // against; when given, the instance must belong to it (null = no check).
    Task<ResolveEvidenceAttachmentResult>   ListEvidenceAttachmentsAsync(long practiceInstanceId, long? organizationId, CancellationToken cancellationToken);
    // Migration 499: metadata is the Evidence Center description the
    // shared upload dialog captured. Optional and last, so every existing
    // caller is unchanged.
    Task<ResolveCommandResult>              AddEvidenceAttachmentAsync(long practiceInstanceId, long evidenceId, string fileName, string? contentType,
                                                                       byte[] fileData, string? description, long? uploadedByEmployeeId,
                                                                       long? organizationId, string? actor, bool callerIsAdmin, CancellationToken cancellationToken,
                                                                       EvidenceUploadMetadata? metadata = null);
    Task<ResolveEvidenceAttachmentContent?> GetEvidenceAttachmentAsync(long practiceInstanceId, long evidenceAttachmentId, long? organizationId, CancellationToken cancellationToken);
    Task<ResolveCommandResult>              RemoveEvidenceAttachmentAsync(ResolveEvidenceAttachmentRemoveRequest request, CancellationToken cancellationToken);
    // Migration 476: Select from Evidence Center / newer version.
    Task<ResolveEvidenceLinkCandidateResult> ListEvidenceLinkCandidatesAsync(long practiceInstanceId, long evidenceId, long organizationId,
                                                                        long? callerEmployeeId, bool callerIsAdmin, string? search,
                                                                        int? evidenceTypeId, int pageNumber, int pageSize,
                                                                        CancellationToken cancellationToken);
    Task<ResolveCommandResult>              LinkEvidenceItemAsync(ResolveEvidenceLinkRequest request, long? callerEmployeeId, bool callerIsAdmin,
                                                                  string actor, CancellationToken cancellationToken);
    Task<ResolveCommandResult>              RefreshEvidenceLinkAsync(ResolveEvidenceLinkRefreshRequest request, string actor,
                                                                     CancellationToken cancellationToken);
}

public sealed class ResolveWorkspaceService(
    IConfiguration configuration,
    ILogger<ResolveWorkspaceService> logger) : IResolveWorkspaceService
{
    // ==============================================================
    // Instance list
    // ==============================================================
    public async Task<ResolveInstanceResult> ListInstancesAsync(
        ResolveInstanceQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        if (query.OrganizationId <= 0)
            return new ResolveInstanceResult(false, [], "OrganizationId is required.");
        // The procedure refuses this too. Catching it here turns a SQL
        // error into a sentence, and makes the rule visible in one place.
        if (!query.IsAdmin && query.CallerEmployeeId is not > 0)
            return new ResolveInstanceResult(false, [],
                "Your account is not linked to an employee record, so the instances you own cannot be identified.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_instance_list";

            AddParam(command, "@organization_id",    DbType.Int64,   query.OrganizationId);
            AddParam(command, "@caller_employee_id", DbType.Int64,   query.CallerEmployeeId is > 0 ? query.CallerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",           DbType.Boolean, query.IsAdmin);
            AddParam(command, "@search",             DbType.String,  query.Search ?? "", 200);
            AddParam(command, "@page_number",        DbType.Int32,   query.PageNumber);
            AddParam(command, "@page_size",          DbType.Int32,   query.PageSize);
            AddParam(command, "@include_retired",    DbType.Boolean, query.IncludeRetired);
            AddParam(command, "@practice_id",        DbType.Int64,
                     query.PracticeId is > 0 ? query.PracticeId : DBNull.Value);
            AddParam(command, "@organization_requirement_id", DbType.Int64,
                     query.OrganizationRequirementId is > 0 ? query.OrganizationRequirementId : DBNull.Value);
            // 315. Operationalize's Owner / Status filters. Sent
            // unconditionally, same as every other optional filter above --
            // deployment order (migration before API) is what every other
            // parameter here already relies on.
            AddParam(command, "@owner_employee_id", DbType.Int64,
                     query.OwnerEmployeeId is > 0 ? query.OwnerEmployeeId : DBNull.Value);
            AddParam(command, "@implementation_status", DbType.String,
                     string.IsNullOrWhiteSpace(query.ImplementationStatus) ? DBNull.Value : query.ImplementationStatus, 100);
            // 465. Operationalize Framework filter. Sent unconditionally like
            // every other optional filter above. SIGNED (negative = Custom
            // release, -1 * subscription_id), so 0/NULL -- not "<= 0" -- is
            // the "no opinion" sentinel; a real negative value must pass.
            AddParam(command, "@release_id", DbType.Int64,
                     query.ReleaseId is not null && query.ReleaseId != 0 ? query.ReleaseId : DBNull.Value);

            var rows = new List<ResolveInstanceRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            // TotalRows arrives with migration 290. Guarded because an API
            // deployed ahead of its migration would otherwise throw on
            // every load and take the whole screen down over a column
            // that only drives the pager label. Absent, it stays 0 --
            // which pm-grid already treats as "no total available" and
            // degrades to a "Page N" label (see
            // docs/grid-and-pagination-standard.md, "Degrading").
            //
            // Tested once before the loop rather than per row: the column
            // list cannot change between rows of one result set.
            var hasTotal = HasColumn(reader, "TotalRows");

            long totalRows = 0;
            while (await reader.ReadAsync(cancellationToken))
            {
                if (hasTotal && reader["TotalRows"] != DBNull.Value)
                    totalRows = Convert.ToInt64(reader["TotalRows"]);
                rows.Add(new ResolveInstanceRow(
                    PracticeInstanceId:   Convert.ToInt64(reader["PracticeInstanceId"]),
                    InstanceCode:         reader["InstanceCode"]?.ToString() ?? "",
                    InstanceName:         reader["InstanceName"]?.ToString() ?? "",
                    PracticeId:           reader["PracticeId"] as long?,
                    PracticeCode:         reader["PracticeCode"] as string,
                    PracticeName:         reader["PracticeName"] as string,
                    OwnerEmployeeId:      reader["OwnerEmployeeId"] as long?,
                    OwnerName:            reader["OwnerName"] as string,
                    Department:           reader["Department"] as string,
                    Criticality:          reader["Criticality"] as string,
                    ImplementationStatus: reader["ImplementationStatus"] as string,
                    Status:               reader["Status"] as string,
                    TotalObligations:     ToInt(reader["TotalObligations"]),
                    AdoptedObligations:   ToInt(reader["AdoptedObligations"]),
                    TotalDependencies:    ToInt(reader["TotalDependencies"]),
                    ResolvedDependencies: ToInt(reader["ResolvedDependencies"])));
            }

            // 315. Owner and Status filter options -- result sets 2 and 3.
            // Guarded the same way TotalRows (290) is: NextResultAsync()
            // simply returns false against a database that has not run
            // migration 315 yet, so an API deployed ahead of its
            // migration degrades to empty option lists (the two new
            // <select>s render with nothing to choose beyond "All") rather
            // than throwing and taking the whole grid down.
            var owners = new List<ResolveInstanceOwnerOption>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    var ownerId = reader["OwnerEmployeeId"] as long?;
                    if (ownerId is not > 0) continue;
                    owners.Add(new ResolveInstanceOwnerOption(
                        OwnerEmployeeId: ownerId.Value,
                        OwnerName:       reader["OwnerName"]?.ToString() ?? ""));
                }
            }

            var statuses = new List<ResolveInstanceStatusOption>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    var statusName = reader["ImplementationStatus"] as string;
                    if (string.IsNullOrWhiteSpace(statusName)) continue;
                    statuses.Add(new ResolveInstanceStatusOption(statusName));
                }
            }

            return new ResolveInstanceResult(true, rows, null, totalRows, owners, statuses);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_list failed for organization {OrganizationId}.", query.OrganizationId);
            return new ResolveInstanceResult(false, [], ex.Message);
        }
    }

    // ==============================================================
    // Instance detail
    // ==============================================================
    public async Task<ResolveInstanceDetailResult> GetInstanceAsync(
        long practiceInstanceId, long? organizationId, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveInstanceDetailResult(false, null, "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_instance_detail";

            AddParam(command, "@practice_instance_id", DbType.Int64,   practiceInstanceId);
            AddParam(command, "@organization_id",      DbType.Int64,   (object?)organizationId ?? DBNull.Value);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveInstanceDetailResult(false, null, "Practice instance not found.");

            return new ResolveInstanceDetailResult(true, new ResolveInstanceDetail(
                PracticeInstanceId:   Convert.ToInt64(reader["PracticeInstanceId"]),
                OrganizationId:       Convert.ToInt64(reader["OrganizationId"]),
                OrganizationName:     reader["OrganizationName"] as string,
                InstanceCode:         reader["InstanceCode"]?.ToString() ?? "",
                InstanceName:         reader["InstanceName"]?.ToString() ?? "",
                PracticeId:           reader["PracticeId"] as long?,
                PracticeCode:         reader["PracticeCode"] as string,
                PracticeName:         reader["PracticeName"] as string,
                OwnerEmployeeId:      reader["OwnerEmployeeId"] as long?,
                OwnerName:            reader["OwnerName"] as string,
                Department:           reader["Department"] as string,
                // ExecutionFrequency / AssuranceFrequency: retired by
                // migration 236 -- the detail procedure no longer projects
                // them, and the model dropped the corresponding fields.
                AssuranceMode:        reader["AssuranceMode"] as string,
                Criticality:          reader["Criticality"] as string,
                ImplementationStatus: reader["ImplementationStatus"] as string,
                Status:               reader["Status"] as string,
                // Migration 222 added these three. Read defensively: the
                // app and the database ship separately, and reader["..."]
                // on an absent column throws IndexOutOfRange, which would
                // take the whole workspace header down rather than just
                // hiding the profile editor. Same rule
                // PracticeAuthenticationService applies to
                // force_password_change.
                OwnerDepartmentId:    OptionalInt64(reader, "OwnerDepartmentId"),
                BusinessFunctionId:   OptionalInt64(reader, "BusinessFunctionId"),
                BusinessFunction:     OptionalString(reader, "BusinessFunction"),
                // The column's presence, not its value: BusinessFunctionId
                // is null both when 222 is missing and when the instance
                // has no business function, so only the schema can say
                // whether the editors have procedures to post to.
                ProfileEditable:      HasColumn(reader, "BusinessFunctionId")));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_detail failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveInstanceDetailResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Obligations
    // ==============================================================
    public async Task<ResolveObligationResult> ListObligationsAsync(
        long practiceInstanceId, bool includeUnsubscribed, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveObligationResult(false, [], "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);

            // Migration 304. Create any evidence row an adopted obligation
            // should have and does not, BEFORE listing -- so the cards render
            // evidence in its real state instead of asking the operator to
            // press Save to repair state they did not break.
            //
            // A read that writes, deliberately, and the pattern this codebase
            // already uses: QuerySubscribedFrameworksAsync and
            // QueryReleaseStatementsAsync both sync before they query. The
            // procedure is idempotent -- its INSERT carries the same NOT
            // EXISTS guard it has always had -- so the second load of the
            // same instance writes nothing.
            await ReconcileEvidenceForInstanceAsync(connection, practiceInstanceId, null, cancellationToken);

            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_list";

            AddParam(command, "@practice_instance_id", DbType.Int64,   practiceInstanceId);
            AddParam(command, "@include_unsubscribed", DbType.Boolean, includeUnsubscribed);

            var rows = new List<ResolveObligationRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new ResolveObligationRow(
                    // 0 for an organisation-defined obligation (migration
                    // 227): it has no row in GRAC_New, so obligation_id is
                    // NULL. RowKey is the card's identity — this stays a
                    // long so the published side and every existing caller
                    // are untouched.
                    ObligationId:                reader["ObligationId"] is { } oid && oid != DBNull.Value
                                                     ? Convert.ToInt64(oid) : 0L,
                    ObligationName:              reader["ObligationName"]?.ToString() ?? "",
                    ObligationText:              reader["ObligationText"] as string,
                    TypeCode:                    reader["TypeCode"] as string,
                    TypeName:                    reader["TypeName"] as string,
                    ReleaseId:                   reader["ReleaseId"] as long?,
                    FrameworkRelease:            reader["FrameworkRelease"] as string,
                    IsSubscribed:                reader["IsSubscribed"] is bool sub && sub,
                    PublishedExecutionFrequency: reader["PublishedExecutionFrequency"] as string,
                    PublishedResponsibility:     reader["PublishedResponsibility"] as string,
                    PublishedApprovalAuthority:  reader["PublishedApprovalAuthority"] as string,
                    PublishedRetention:          reader["PublishedRetention"] as string,
                    AdoptionId:                  reader["AdoptionId"] as long?,
                    IsAdopted:                   reader["IsAdopted"] is bool ad && ad,
                    OrganizationModified:        reader["OrganizationModified"] is bool om && om,
                    ExecutionFrequencyId:        reader["ExecutionFrequencyId"] as int?,
                    ExecutionFrequency:          reader["ExecutionFrequency"] as string,
                    AssuranceFrequencyId:        reader["AssuranceFrequencyId"] as int?,
                    AssuranceFrequency:          reader["AssuranceFrequency"] as string,
                    // Migration 234. Optional* so a database still on 231
                    // loads the workspace unchanged -- absent column means
                    // no override, same reading as a NULL column value.
                    EventTypeId:                 OptionalInt64(reader, "EventTypeId"),
                    SlaValue:                    OptionalInt32(reader, "SlaValue"),
                    SlaUnit:                     OptionalString(reader, "SlaUnit"),
                    // Migration 242: per-obligation implementation status.
                    // Optional so a database still on 234 loads the workspace
                    // unchanged; absent column reads as "no status stored".
                    ImplementationStatusId:      OptionalInt32(reader, "ImplementationStatusId"),
                    // Migration 244: connection payload for Automated
                    // assurance. Optional so a database still on 242 loads
                    // unchanged; the UI only surfaces the two inputs when
                    // assuranceType is Automated, so missing values here
                    // reads as "not configured".
                    ConnectionTypeId:            OptionalInt32(reader, "ConnectionTypeId"),
                    ConnectionUrl:               OptionalString(reader, "ConnectionUrl"),
                    Responsibility:              reader["Responsibility"] as string,
                    ApprovalAuthority:           reader["ApprovalAuthority"] as string,
                    RetentionPeriod:             reader["RetentionPeriod"] as string,
                    Remarks:                     reader["Remarks"] as string,
                    AdoptedBy:                   reader["AdoptedBy"] as string,
                    AdoptedDt:                   reader["AdoptedDt"] as DateTime?,
                    PublishedEvidenceCount:      ToInt(reader["PublishedEvidenceCount"]),
                    ResolvedEvidenceCount:       ToInt(reader["ResolvedEvidenceCount"]),
                    // Migration 224. OptionalJson checks HasColumn first
                    // and falls back to "[]", so a database that has not
                    // run 224 loads the workspace unchanged and the card
                    // shows the published four fields instead of the
                    // typed detail.
                    ObligationDescription:  OptionalString(reader, "ObligationDescription"),
                    StateRulesJson:         OptionalJson(reader, "StateRulesJson"),
                    ExecutionSpecsJson:     OptionalJson(reader, "ExecutionSpecsJson"),
                    AssuranceSpecsJson:     OptionalJson(reader, "AssuranceSpecsJson"),
                    EventResponsesJson:     OptionalJson(reader, "EventResponsesJson"),
                    ConstraintRulesJson:    OptionalJson(reader, "ConstraintRulesJson"),
                    RetentionSpecsJson:     OptionalJson(reader, "RetentionSpecsJson"),
                    PublishedEvidenceJson:  OptionalJson(reader, "PublishedEvidenceJson"),
                    AdoptedAssuranceType:   OptionalString(reader, "AdoptedAssuranceType"),
                    TypedDetailAvailable:   HasColumn(reader, "StateRulesJson"),
                    AssuranceTypeAvailable: HasColumn(reader, "AdoptedAssuranceType"),
                    // Migration 227. Falls back to the published key on a
                    // database without it, so the browser always has a
                    // usable card identity.
                    RowKey:                 OptionalString(reader, "RowKey")
                                            ?? $"p{Convert.ToInt64(reader["ObligationId"])}",
                    IsOrganizationDefined:  HasColumn(reader, "IsOrganizationDefined")
                                            && reader["IsOrganizationDefined"] is bool od && od,
                    // Migration 396. Optional: absent column = not retired.
                    RepositoryLifecycleStatus: OptionalString(reader, "RepositoryLifecycleStatus"),
                    // Migration 412. Optional so a database without 412
                    // still loads (the Owner picker then shows Unassigned).
                    OwnerEmployeeId:           OptionalInt64(reader, "OwnerEmployeeId"),
                    // Migration 457. Optional: absent column = no date shown.
                    FirstOccurrenceDate:       HasColumn(reader, "FirstOccurrenceDate")
                                               && reader["FirstOccurrenceDate"] is DateTime firstOcc
                                                   ? firstOcc.ToString("yyyy-MM-dd")
                                                   : null,
                    // Migration 473. Optional: absent column = the card
                    // shows the description read-only, as before.
                    PublishedObligationDescription: OptionalString(reader, "PublishedObligationDescription"),
                    IsDescriptionOverridden:   HasColumn(reader, "IsDescriptionOverridden")
                                               && reader["IsDescriptionOverridden"] is bool dov && dov));

            // "Adopted by" shows the employee's NAME (2026-10-15). adopted_by
            // stores the actor stamp the controller passes ("employee:37");
            // the stored value is unchanged, only what the card receives.
            await reader.CloseAsync();
            var names = await ResolveActorNamesAsync(connection, rows.Select(r => r.AdoptedBy), cancellationToken);
            // An id with no employee row shows no line rather than the id.
            rows = rows.Select(r => ActorEmployeeId(r.AdoptedBy) is { } id
                    ? r with { AdoptedBy = names.TryGetValue(id, out var name) ? name : null }
                    : r)
                .ToList();

            return new ResolveObligationResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_obligation_list failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveObligationResult(false, [], ex.Message);
        }
    }

    public async Task<ResolveObligationAdoptResult> AdoptObligationsAsync(
        ResolveObligationAdoptRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveObligationAdoptResult(false, [], "PracticeInstanceId is required.");

        // Distinct on obligation id: the procedure keys its work table on
        // it, so a duplicate would be a primary key violation rather than
        // the harmless last-wins the caller intends.
        var decisions = (request.Obligations ?? [])
            .Where(o => o.ObligationId > 0)
            .GroupBy(o => o.ObligationId)
            .Select(g => g.Last())
            .ToArray();

        if (decisions.Length == 0)
            return new ResolveObligationAdoptResult(false, [], "Select at least one obligation.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_adopt";
            // Adopting also creates evidence rows, so a large selection is
            // several writes per obligation.
            command.CommandTimeout = 120;

            var payload = JsonSerializer.Serialize(decisions.Select(d => new
            {
                obligationId         = d.ObligationId,
                isAdopted            = d.IsAdopted,
                executionFrequencyId = d.ExecutionFrequencyId,
                executionFrequency   = d.ExecutionFrequency,
                assuranceFrequencyId = d.AssuranceFrequencyId,
                assuranceFrequency   = d.AssuranceFrequency,
                responsibility       = d.Responsibility,
                approvalAuthority    = d.ApprovalAuthority,
                retentionPeriod      = d.RetentionPeriod,
                // assuranceType was added to the record in 226 and read by
                // the procedure since 226, but the anonymous payload here
                // was never updated -- so the UI's choice was silently
                // dropped between the API and SQL. Included now.
                assuranceType        = d.AssuranceType,
                remarks              = d.Remarks,
                // Migration 234: EventDriven-Assurance overrides. Passing
                // null keeps the authority's value, per the procedure's
                // COALESCE-onto-existing rule.
                eventTypeId          = d.EventTypeId,
                slaValue             = d.SlaValue,
                slaUnit              = d.SlaUnit,
                // Migration 242: per-obligation implementation status.
                // Null preserves the stored value.
                implementationStatusId = d.ImplementationStatusId,
                // Migration 244: connection payload for Automated assurance.
                // Same "null preserves stored" contract; the procedure
                // COALESCEs onto the target column.
                connectionTypeId       = d.ConnectionTypeId,
                connectionUrl          = d.ConnectionUrl,
                // Migration 412: owner employee. Null keeps the stored
                // owner; 0 clears it; > 0 sets it (Functional User only).
                ownerEmployeeId        = d.OwnerEmployeeId
            }));

            AddParam(command, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@payload_json",         DbType.String, payload);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            // Migration 336-338: per-obligation first-occurrence anchors for
            // the schedule sync that runs after adoption. Only obligations
            // being adopted with a stated date contribute; the rest keep
            // whatever anchor they already have (or default to today when a
            // stream is first created). Built here so it rides the same
            // request the adopt payload came from.
            var anchors = decisions
                .Where(d => d.IsAdopted && d.FirstOccurrenceDate.HasValue)
                .Select(d => new
                {
                    obligationId        = d.ObligationId,
                    firstOccurrenceDate = d.FirstOccurrenceDate!.Value.ToString("yyyy-MM-dd")
                })
                .ToArray();
            var anchorsJson = anchors.Length > 0 ? JsonSerializer.Serialize(anchors) : null;

            var outcomes = new List<ResolveObligationOutcome>();
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                    outcomes.Add(new ResolveObligationOutcome(
                        ObligationId:          Convert.ToInt64(reader["ObligationId"]),
                        ObligationName:        reader["ObligationName"] as string,
                        Outcome:               reader["Outcome"]?.ToString() ?? "",
                        OrganizationModified:  reader["OrganizationModified"] is bool om && om,
                        NotSubscribed:         reader["NotSubscribed"] is bool ns && ns,
                        EvidenceRows:          ToInt(reader["EvidenceRows"]),
                        UnmappedEvidenceTypes: ToInt(reader["UnmappedEvidenceTypes"])));
            }

            // Migration 473: the description edits, for the obligations this
            // request adopts or keeps adopted. NOT best-effort like the two
            // syncs below: the operator typed this text, so a failure is
            // reported. The adopt itself is already committed, and saying so
            // lets the operator press Save again without redoing anything.
            var descriptions = decisions
                .Where(d => d.IsAdopted && d.ObligationDescription is not null)
                .Select(d => new { obligationId = d.ObligationId, description = d.ObligationDescription })
                .ToArray();
            string? descriptionError = null;
            if (descriptions.Length > 0)
            {
                try
                {
                    await using var descCommand = connection.CreateCommand();
                    descCommand.CommandType = CommandType.StoredProcedure;
                    descCommand.CommandText = "grac_practice.sp_resolve_obligation_description_save";
                    AddParam(descCommand, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
                    AddParam(descCommand, "@payload_json",         DbType.String, JsonSerializer.Serialize(descriptions));
                    AddParam(descCommand, "@actor",                DbType.String,
                             string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);
                    var saved = descCommand.CreateParameter();
                    saved.ParameterName = "@saved";
                    saved.DbType        = DbType.Int32;
                    saved.Direction     = ParameterDirection.Output;
                    descCommand.Parameters.Add(saved);
                    await descCommand.ExecuteNonQueryAsync(cancellationToken);
                }
                catch (Exception ex)
                {
                    // Reported AFTER the two syncs below: the adopt is
                    // committed, so the gap tables and the schedule streams
                    // (with this request's first-occurrence anchors) must
                    // still follow it.
                    logger.LogError(ex, "sp_resolve_obligation_description_save failed for instance {InstanceId}.", request.PracticeInstanceId);
                    descriptionError = "The obligation was saved, but its description could not be: " + ex.Message;
                }
            }

            // Migration 245: reconcile the persistent gap tables against
            // whatever the obligation rows now say. Best-effort -- a sync
            // failure does not undo the save (the obligation update is
            // already committed), it only leaves Task Center a beat
            // behind until the next save.
            await SyncGapForInstanceAsync(connection, request.PracticeInstanceId,
                request.Actor, cancellationToken);

            // Migration 336-338: create / update / retire the calendar
            // schedule streams for this instance's schedulable obligations.
            // Best-effort, same reasoning as the gap sync above -- the
            // adoption is already committed; a sync failure only leaves the
            // calendar a beat behind until the next save or a manual
            // reconcile (sp_pm_sync_instance_schedule_rules is safe to run
            // on its own).
            await SyncScheduleRulesForInstanceAsync(connection, request.PracticeInstanceId,
                request.Actor, anchorsJson, cancellationToken);

            return descriptionError is null
                ? new ResolveObligationAdoptResult(true, outcomes)
                : new ResolveObligationAdoptResult(false, outcomes, descriptionError);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_obligation_adopt failed for instance {InstanceId}.", request.PracticeInstanceId);
            return new ResolveObligationAdoptResult(false, [], ex.Message);
        }
    }

    /// <summary>
    /// Migration 304: creates the evidence rows an adopted obligation should
    /// have and does not. Called by ListObligationsAsync so the workspace no
    /// longer depends on a save to show evidence.
    ///
    /// FAILS SOFT, like SyncGapForInstanceAsync below. This runs on the read
    /// path, and the obligations themselves do not depend on it: if the
    /// reconcile cannot run, the operator should still get the workspace,
    /// with whatever evidence rows already exist. A hard failure here would
    /// turn a missing evidence row into a blank page, which is a strictly
    /// worse outcome than the message this migration exists to remove.
    ///
    /// sp_resolve_obligation_adopt calls the same procedure inside its own
    /// transaction, so there is one copy of the rule and adopt keeps
    /// behaving exactly as it does today.
    /// </summary>
    private async Task ReconcileEvidenceForInstanceAsync(DbConnection connection, long practiceInstanceId,
        string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_reconcile_for_instance";
            AddParam(command, "@practice_instance_id", DbType.Int64, practiceInstanceId);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);
            // The procedure returns no result set, so ExecuteNonQuery leaves
            // the connection clean for the list query that follows.
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            // Includes 2812 "could not find stored procedure" on a database
            // that has not run 304 yet. The app and the database deploy
            // separately; an unapplied migration must cost the reconcile,
            // not the workspace.
            logger.LogWarning(ex,
                "Could not reconcile evidence for instance {InstanceId}; listing obligations with the rows that exist.",
                practiceInstanceId);
        }
    }

    // Migration 245: gap-tables sync helper. Reused by AdoptObligationsAsync
    // and SaveLocalObligationAsync so both entry points -- bulk adopt AND
    // single local-obligation save -- keep the persistent gap consistent.
    // The procedure is idempotent (reads current state), so a concurrent
    // second call is a no-op; that lets us keep this outside the main
    // transaction without racing correctness away.
    private async Task SyncGapForInstanceAsync(DbConnection connection, long practiceInstanceId,
        string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var syncCommand = connection.CreateCommand();
            syncCommand.CommandType = CommandType.StoredProcedure;
            syncCommand.CommandText = "grac_practice.sp_practice_gap_sync_for_instance";
            AddParam(syncCommand, "@practice_instance_id", DbType.Int64, practiceInstanceId);
            AddParam(syncCommand, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);
            // Small result set; drain it so the connection is clean before
            // the next caller reuses it.
            await using var reader = await syncCommand.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) { }
        }
        catch (Exception ex)
        {
            // 52720 / 52721 are "instance not found" -- treat as warning
            // rather than error so a save on a soft-deleted instance
            // still surfaces its own error path.
            logger.LogWarning(ex, "sp_practice_gap_sync_for_instance failed for instance {InstanceId}.", practiceInstanceId);
        }
    }

    // Migration 336-338: schedule-stream sync helper. Mirrors
    // SyncGapForInstanceAsync -- reused by AdoptObligationsAsync and
    // SaveLocalObligationAsync so both save paths keep the calendar's
    // per-obligation schedule rules in step. sp_pm_sync_instance_schedule_rules
    // is idempotent (reads vw_pm_instance_schedulable_obligations and upserts),
    // so running it outside the main transaction cannot race correctness away.
    // @anchors_json is the per-obligation first-occurrence dates from the save;
    // null when the caller has none, in which case anchors already on record
    // stand and a brand-new stream starts today.
    private async Task SyncScheduleRulesForInstanceAsync(DbConnection connection, long practiceInstanceId,
        string? actor, string? anchorsJson, CancellationToken cancellationToken)
    {
        try
        {
            await using var syncCommand = connection.CreateCommand();
            syncCommand.CommandType = CommandType.StoredProcedure;
            syncCommand.CommandText = "grac_practice.sp_pm_sync_instance_schedule_rules";
            AddParam(syncCommand, "@practice_instance_id", DbType.Int64, practiceInstanceId);
            AddParam(syncCommand, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);
            AddParam(syncCommand, "@anchors_json",         DbType.String, (object?)anchorsJson ?? DBNull.Value);
            // No result set -- ExecuteNonQuery leaves the connection clean for
            // whatever reuses it.
            await syncCommand.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            // 2812 "could not find stored procedure" on a database that has
            // not run 338 yet is expected -- app and DB deploy separately, and
            // an unapplied migration must cost the sync, not the save.
            logger.LogWarning(ex, "sp_pm_sync_instance_schedule_rules failed for instance {InstanceId}.", practiceInstanceId);
        }
    }

    // ==============================================================
    // Dependencies
    // ==============================================================
    public async Task<ResolveDependencyResult> ListDependenciesAsync(
        long practiceInstanceId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveDependencyResult(false, [], [], "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_list";

            AddParam(command, "@practice_instance_id", DbType.Int64, practiceInstanceId);

            var categories  = new List<ResolveDependencyCategory>();
            var resolutions = new List<ResolveDependencyItem>();

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                categories.Add(new ResolveDependencyCategory(
                    DependencyTypeId:   ToInt(reader["DependencyTypeId"]),
                    DependencyCategory: reader["DependencyCategory"]?.ToString() ?? "",
                    DependencyId:       reader["DependencyId"] as long?,
                    ResolvedCount:      ToInt(reader["ResolvedCount"]),
                    ResolvedNames:      reader["ResolvedNames"] as string,
                    IsResolved:         reader["IsResolved"] is bool r && r));

            // Second result set: the individual resolutions.
            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    resolutions.Add(new ResolveDependencyItem(
                        ResolutionId:           Convert.ToInt64(reader["ResolutionId"]),
                        DependencyTypeId:       ToInt(reader["DependencyTypeId"]),
                        ResolvedDependencyId:   Convert.ToInt64(reader["ResolvedDependencyId"]),
                        ResolvedDependencyName: reader["ResolvedDependencyName"]?.ToString() ?? "",
                        ResolutionOwnerId:      reader["ResolutionOwnerId"] as long?,
                        ResolutionOwnerName:    reader["ResolutionOwnerName"] as string,
                        Remarks:                reader["Remarks"] as string,
                        ResolutionStatus:       reader["ResolutionStatus"] as string));

            return new ResolveDependencyResult(true, categories, resolutions);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_list failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveDependencyResult(false, [], [], ex.Message);
        }
    }

    public async Task<ResolveCommandResult> SaveDependencyAsync(
        ResolveDependencySaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0 || request.DependencyTypeId <= 0)
            return new ResolveCommandResult(false, null,
                "Practice instance and dependency category are both required.");

        // Distinct on id: the picker is a multi-select, and a repeated id
        // would be a primary key violation in the procedure rather than the
        // harmless duplicate tick the user actually made.
        var objects = (request.Objects ?? [])
            .Where(o => o.Id > 0 && !string.IsNullOrWhiteSpace(o.Name))
            .GroupBy(o => o.Id)
            .Select(g => g.First())
            .ToArray();

        if (objects.Length == 0)
            return new ResolveCommandResult(false, null, "Pick at least one object to resolve against.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_save";

            AddParam(command, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@dependency_type_id",   DbType.Int32,  request.DependencyTypeId);
            AddParam(command, "@objects_json",         DbType.String,
                     JsonSerializer.Serialize(objects.Select(o => new { id = o.Id, name = o.Name })));
            AddParam(command, "@resolution_owner_id",  DbType.Int64,  (object?)request.ResolutionOwnerId ?? DBNull.Value);
            AddParam(command, "@remarks",              DbType.String, (object?)request.Remarks ?? DBNull.Value);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Resolved.");

            var saved = ToInt(reader["SavedCount"]);
            var total = ToInt(reader["CategoryResolvedCount"]);
            return new ResolveCommandResult(true,
                $"{saved} object{(saved == 1 ? "" : "s")} resolved; this category now has {total}.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_save failed for instance {InstanceId}.", request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Dependency category sync  (migration 238)
    //
    // Complete-set semantics: whatever is in Objects becomes the desired
    // set for this category on this instance. The procedure retires
    // absent rows and reactivates or adds the rest, and the API returns
    // its Message row unchanged.
    // ==============================================================
    public async Task<ResolveCommandResult> SyncDependencyCategoryAsync(
        ResolveDependencyCategorySyncRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveCommandResult(false, null, "PracticeInstanceId is required.");
        if (request.DependencyTypeId <= 0)
            return new ResolveCommandResult(false, null, "DependencyTypeId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_category_sync";

            // Null-safe serialisation. An empty list means "clear the
            // category"; a null Objects (older callers) is treated the
            // same as an empty list rather than "no opinion" -- this
            // procedure exists to state the whole set explicitly.
            var payload = JsonSerializer.Serialize(
                (request.Objects ?? []).Select(o => new
                {
                    id      = o.Id,
                    name    = o.Name
                }));

            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@dependency_type_id",   DbType.Int32,   request.DependencyTypeId);
            AddParam(command, "@objects_json",         DbType.String,  payload);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Saved.");

            var success = reader["Success"] is bool s && s;
            var message = reader["Message"] as string ?? "Saved.";
            return success
                ? new ResolveCommandResult(true, message)
                : new ResolveCommandResult(false, null, message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_category_sync failed for instance {InstanceId} category {DependencyTypeId}.",
                request.PracticeInstanceId, request.DependencyTypeId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    public async Task<ResolveCommandResult> RemoveDependencyAsync(
        ResolveDependencyRemoveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0 || request.ResolutionId <= 0)
            return new ResolveCommandResult(false, null, "Practice instance and resolution are both required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_remove";

            AddParam(command, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@resolution_id",        DbType.Int64,  request.ResolutionId);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(false, null, "The resolution could not be removed.");

            // The procedure reports a miss rather than pretending: a
            // resolution id from another instance simply matches nothing.
            var success = reader["Success"] is bool s && s;
            var message = reader["Message"]?.ToString();
            return success
                ? new ResolveCommandResult(true, message)
                : new ResolveCommandResult(false, null, message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_remove failed for instance {InstanceId}.", request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // SaveFrequencyAsync retired -- see the controller comment. The
    // procedure it called (sp_resolve_instance_frequency_save) is dropped
    // in migration 235. Per-obligation frequency lives on the obligation
    // row itself and is saved through the adoption / local-obligation
    // paths above.

    // ==============================================================
    // Instance profile  (migration 222)
    //
    // Practice Type, Criticality, Business Function and -- for an admin
    // only -- the Owner. The four the Practice Instance form was still
    // the sole home for; see docs/practice-instance-form-slimming.md.
    //
    // Null is passed through as DBNull and read by the procedure as "no
    // opinion", so a caller that sends one field does not blank the rest.
    // ==============================================================
    public async Task<ResolveCommandResult> SaveProfileAsync(
        ResolveProfileSaveRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveCommandResult(false, null, "PracticeInstanceId is required.");

        // The procedure refuses this too (52673). Catching it here turns a
        // SQL error into a sentence and keeps the rule visible on this side
        // of the wire as well.
        if (request.PrimaryOwnerId is > 0 && !isAdmin)
            return new ResolveCommandResult(false, null,
                "Only an administrator can change the owner of a practice instance.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_instance_profile_save";

            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@assurance_mode",       DbType.String,
                     string.IsNullOrWhiteSpace(request.AssuranceMode) ? DBNull.Value : request.AssuranceMode, 40);
            AddParam(command, "@criticality",          DbType.String,
                     string.IsNullOrWhiteSpace(request.Criticality) ? DBNull.Value : request.Criticality, 30);
            AddParam(command, "@business_function_id", DbType.Int64,   (object?)request.BusinessFunctionId ?? DBNull.Value);
            AddParam(command, "@primary_owner_id",     DbType.Int64,   (object?)request.PrimaryOwnerId ?? DBNull.Value);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Profile saved.");

            var owner = reader["OwnerName"] as string;
            var mode  = reader["AssuranceMode"] as string;
            var crit  = reader["Criticality"] as string;
            return new ResolveCommandResult(true,
                $"Saved. {mode ?? "Practice type not set"}, {crit ?? "criticality not set"}, owner {owner ?? "unassigned"}.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_profile_save failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Retire  (migration 222)
    //
    // The act migration 139 reserved for the Practice Instances screen.
    // Not a delete: practice_instance_id is a foreign key in roughly
    // twenty tables, so the row stays and its status changes.
    // ==============================================================
    public async Task<ResolveCommandResult> RetireInstanceAsync(
        ResolveInstanceRetireRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveCommandResult(false, null, "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_instance_retire";

            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);
            // 355 -- the procedure throws 52815 when this is blank, so an
            // empty string is sent through as-is rather than DBNull: a
            // caller who bypasses the UI's own required-field check still
            // gets the procedure's refusal, not a silent NULL that reads as
            // "no opinion" the way @assurance_mode's NULL does elsewhere.
            AddParam(command, "@remark",               DbType.String,
                     request.Remark ?? (object)DBNull.Value, 1000);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Practice instance retired.");

            return new ResolveCommandResult(true, reader["Message"] as string ?? "Practice instance retired.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_retire failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Restore  (migration 287)
    //
    // Retire's inverse, and deliberately its mirror image: same
    // ownership test in the procedure, same "already in that state"
    // refusal, same result shape. Retirement only ever changed status
    // and record_status_id -- obligations, evidence and tasks were left
    // alone -- so restoring only has to put those two back.
    // ==============================================================
    public async Task<ResolveCommandResult> RestoreInstanceAsync(
        ResolveInstanceRestoreRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveCommandResult(false, null, "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_instance_restore";

            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);
            // 355 -- same reasoning as retire's @remark above.
            AddParam(command, "@remark",               DbType.String,
                     request.Remark ?? (object)DBNull.Value, 1000);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Practice instance restored.");

            return new ResolveCommandResult(true, reader["Message"] as string ?? "Practice instance restored.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_restore failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Dependency categories  (migration 222)
    // ==============================================================
    public async Task<ResolveDependencyTypeResult> ListDependencyTypesAsync(
        long practiceInstanceId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveDependencyTypeResult(false, [], "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_type_list";

            AddParam(command, "@practice_instance_id", DbType.Int64, practiceInstanceId);

            var rows = new List<ResolveDependencyTypeRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(ReadDependencyTypeRow(reader));

            return new ResolveDependencyTypeResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_type_list failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveDependencyTypeResult(false, [], ex.Message);
        }
    }

    /// <summary>
    /// The id list is the complete desired set. Categories that still hold
    /// resolved objects are kept and returned in
    /// <see cref="ResolveDependencyTypeSaveResult.Blocked"/> rather than
    /// undeclared — those are rows in practice_dependency_resolution, not
    /// a tick, and migration 142 is explicit that nothing is deactivated
    /// implicitly.
    /// </summary>
    public async Task<ResolveDependencyTypeSaveResult> SaveDependencyTypesAsync(
        ResolveDependencyTypeSaveRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveDependencyTypeSaveResult(false, Error: "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_dependency_type_save";

            AddParam(command, "@practice_instance_id", DbType.Int64, request.PracticeInstanceId);
            AddParam(command, "@dependency_type_ids",  DbType.String,
                     JsonSerializer.Serialize(request.DependencyTypeIds ?? Array.Empty<int>()));
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",             DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            var message = "Dependency categories saved.";
            var added   = 0;
            var removed = 0;
            if (await reader.ReadAsync(cancellationToken))
            {
                message = reader["Message"] as string ?? message;
                added   = ToInt(reader["AddedCount"]);
                removed = ToInt(reader["RemovedCount"]);
            }

            // Second result set: the categories that could not be cleared.
            var blocked = new List<ResolveDependencyTypeRow>();
            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    blocked.Add(ReadDependencyTypeRow(reader, declaredFallback: true));

            return new ResolveDependencyTypeSaveResult(true, message, added, removed, blocked);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_dependency_type_save failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveDependencyTypeSaveResult(false, Error: ex.Message);
        }
    }

    // The list and the blocked set share three columns; the blocked set
    // has no IsDeclared column because every row in it is, by definition,
    // still declared.
    private static ResolveDependencyTypeRow ReadDependencyTypeRow(DbDataReader reader, bool declaredFallback = false)
        => new(
            DependencyTypeId:   ToInt(reader["DependencyTypeId"]),
            DependencyCategory: reader["DependencyCategory"] as string ?? "",
            IsDeclared:         HasColumn(reader, "IsDeclared")
                                    ? reader["IsDeclared"] is bool b && b
                                    : declaredFallback,
            ResolvedCount:      ToInt(reader["ResolvedCount"]));

    // ==============================================================
    // Organisation-defined obligations  (migration 227)
    // ==============================================================

    /// <summary>
    /// The obligation types the add form can offer. Its own procedure
    /// rather than a key on the shared lookups feed — that feed lives in
    /// a 1580-line dispatcher, and one more UNION branch there means
    /// re-issuing the whole thing.
    /// </summary>
    public async Task<ResolveObligationTypeListResult> ListObligationTypesAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_type_list";

            var rows = new List<ResolveObligationType>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new ResolveObligationType(
                    ObligationTypeId: ToInt(reader["ObligationTypeId"]),
                    TypeCode:         reader["TypeCode"]?.ToString() ?? "",
                    TypeName:         reader["TypeName"] as string,
                    DisplayOrder:     ToInt(reader["DisplayOrder"])));

            return new ResolveObligationTypeListResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_obligation_type_list failed.");
            return new ResolveObligationTypeListResult(false, [], ex.Message);
        }
    }

    /// <summary>
    /// The rule fields of one obligation type, read from the Control
    /// Management table that type's detail lives in. An unknown type, or
    /// a type CM keeps no detail for, returns an empty list rather than
    /// an error — the form then asks only for name, description and the
    /// adoption parameters, which is the correct shape for it.
    /// </summary>
    public async Task<ResolveObligationTypeFieldResult> ListObligationTypeFieldsAsync(
        string typeCode, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(typeCode))
            return new ResolveObligationTypeFieldResult(false, [], "typeCode is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_type_fields";

            AddParam(command, "@type_code", DbType.String, typeCode, 60);

            var fields = new List<ResolveObligationTypeField>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                fields.Add(new ResolveObligationTypeField(
                    TableName:   reader["TableName"] as string,
                    ColumnName:  reader["ColumnName"]?.ToString() ?? "",
                    DataType:    reader["DataType"] as string,
                    MaxLength:   ToInt(reader["MaxLength"]),
                    IsNullable:  reader["IsNullable"] is bool n && n,
                    Ordinal:     ToInt(reader["Ordinal"]),
                    IsReference: reader["IsReference"] is bool r && r));

            return new ResolveObligationTypeFieldResult(true, fields);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_obligation_type_fields failed for type {TypeCode}.", typeCode);
            return new ResolveObligationTypeFieldResult(false, [], ex.Message);
        }
    }

    /// <summary>
    /// The driver-value to visible-field rules for one type (migration
    /// 228). An empty list means "no rule was learned" — the form then
    /// shows every field, which is the safe direction.
    /// </summary>
    public async Task<ResolveObligationFieldRuleResult> ListObligationFieldRulesAsync(
        string typeCode, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(typeCode))
            return new ResolveObligationFieldRuleResult(false, [], "typeCode is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_type_field_rules";

            AddParam(command, "@type_code", DbType.String, typeCode, 60);

            var rules = new List<ResolveObligationFieldRule>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rules.Add(new ResolveObligationFieldRule(
                    DriverColumn:  reader["DriverColumn"]?.ToString() ?? "",
                    DriverValue:   reader["DriverValue"]?.ToString() ?? "",
                    VisibleColumn: reader["VisibleColumn"]?.ToString() ?? "",
                    SampleRows:    ToInt(reader["SampleRows"])));

            // Second result set (migration 229): the values the driver can
            // take. Absent on a 228-only database, in which case the form
            // falls back to a free-text box rather than a dropdown built
            // from whichever values happened to have rules.
            var values = new List<ResolveObligationDriverValue>();
            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    values.Add(new ResolveObligationDriverValue(
                        DriverColumn: reader["DriverColumn"]?.ToString() ?? "",
                        DriverValue:  reader["DriverValue"]?.ToString() ?? "",
                        SampleRows:   ToInt(reader["SampleRows"]),
                        HasRule:      reader["HasRule"] is bool h && h));

            return new ResolveObligationFieldRuleResult(true, rules, null, values);
        }
        catch (Exception ex)
        {
            // Migration 228 not applied is the common case; the form shows
            // every field rather than failing.
            logger.LogWarning(ex, "sp_resolve_obligation_type_field_rules unavailable for type {TypeCode}.", typeCode);
            return new ResolveObligationFieldRuleResult(true, []);
        }
    }

    /// <summary>
    /// Trigger modes and the event type tree (migration 230). Empty lists
    /// rather than an error when Control Management 033 is not applied
    /// here — the form then falls back to the inferred rules from
    /// 228/229, which is what it used before 230 existed.
    /// </summary>
    public async Task<ResolveObligationVocabularyResult> GetObligationVocabularyAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_vocabulary";

            var modes  = new List<ResolveTriggerMode>();
            var events = new List<ResolveEventType>();

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                modes.Add(new ResolveTriggerMode(
                    TriggerMode:      reader["TriggerMode"]?.ToString() ?? "",
                    TriggerModeLabel: reader["TriggerModeLabel"] as string,
                    DisplayOrder:     ToInt(reader["DisplayOrder"])));

            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    events.Add(new ResolveEventType(
                        EventTypeId:       Convert.ToInt64(reader["EventTypeId"]),
                        ParentEventTypeId: reader["ParentEventTypeId"] as long?,
                        EventCode:         reader["EventCode"] as string,
                        EventName:         reader["EventName"] as string,
                        Description:       reader["Description"] as string,
                        IsDomain:          reader["IsDomain"] is bool d && d,
                        DisplayOrder:      ToInt(reader["DisplayOrder"])));

            return new ResolveObligationVocabularyResult(true, modes, events);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "sp_resolve_obligation_vocabulary unavailable.");
            return new ResolveObligationVocabularyResult(true, [], []);
        }
    }

    public async Task<ResolveCommandResult> SaveLocalObligationAsync(
        ResolveLocalObligationSaveRequest request, long? callerEmployeeId, bool isAdmin,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0)
            return new ResolveCommandResult(false, null, "PracticeInstanceId is required.");

        // The procedure refuses these too. Catching them here turns a SQL
        // error into a sentence the form can put next to the field.
        if (!request.Retire)
        {
            if (string.IsNullOrWhiteSpace(request.ObligationName))
                return new ResolveCommandResult(false, null, "Obligation name is required.");
            if (string.IsNullOrWhiteSpace(request.ObligationTypeCode))
                return new ResolveCommandResult(false, null, "Obligation type is required.");
        }

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_local_obligation_save";

            AddParam(command, "@practice_instance_id",            DbType.Int64, request.PracticeInstanceId);
            AddParam(command, "@practice_instance_obligation_id", DbType.Int64, request.PracticeInstanceObligationId);
            AddParam(command, "@obligation_name",        DbType.String, Text(request.ObligationName), 500);
            AddParam(command, "@obligation_description", DbType.String, Text(request.ObligationDescription));
            AddParam(command, "@obligation_type_code",   DbType.String, Text(request.ObligationTypeCode), 60);
            AddParam(command, "@typed_detail_json",      DbType.String, Text(request.TypedDetailJson));
            AddParam(command, "@execution_frequency_id", DbType.Int32,  (object?)request.ExecutionFrequencyId ?? DBNull.Value);
            AddParam(command, "@execution_frequency",    DbType.String, Text(request.ExecutionFrequency), 120);
            AddParam(command, "@responsibility",         DbType.String, Text(request.Responsibility), 300);
            // Migration 412: owner employee (null keep / 0 clear / > 0 set).
            AddParam(command, "@owner_employee_id",      DbType.Int64,
                     (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@approval_authority",     DbType.String, Text(request.ApprovalAuthority), 300);
            AddParam(command, "@assurance_type",         DbType.String, Text(request.AssuranceType), 40);
            AddParam(command, "@remarks",                DbType.String, Text(request.Remarks));
            // Migration 242: per-obligation implementation status. Null
            // leaves what is stored -- the procedure COALESCEs it.
            AddParam(command, "@implementation_status_id", DbType.Int32,
                     (object?)request.ImplementationStatusId ?? DBNull.Value);
            // Migration 244: connection payload for Automated assurance.
            // Same COALESCE-preserves-stored contract.
            AddParam(command, "@connection_type_id",     DbType.Int32,
                     (object?)request.ConnectionTypeId ?? DBNull.Value);
            AddParam(command, "@connection_url",         DbType.String,
                     Text(request.ConnectionUrl), 500);
            AddParam(command, "@retire",                 DbType.Boolean, request.Retire);
            // Null, not "[]" — the procedure reads NULL as "no opinion"
            // and leaves the obligation's evidence alone.
            AddParam(command, "@evidence_json",           DbType.String,
                     request.Evidence is null ? DBNull.Value : JsonSerializer.Serialize(request.Evidence));
            AddParam(command, "@caller_employee_id",     DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",               DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                  DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            string? message = null;
            long?   savedObligationId = null;
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                // Advance to the result set that actually carries the outcome.
                //
                // Migration 232 ended the evidence-sync procedure with a SELECT,
                // and a SELECT inside a called procedure becomes a result set of
                // the CALLER -- arriving first, ahead of the save's own row. The
                // read below then threw looking for [Message], on a save that had
                // already committed, so the screen was told a successful save had
                // failed and the next click inserted a second obligation.
                //
                // 233 removed that SELECT. This loop means a database still on
                // 232 degrades to "saved" instead of repeating the fault, and any
                // future procedure that grows a diagnostic SELECT cannot cause it
                // again.
                while (!HasColumn(reader, "Message") && await reader.NextResultAsync(cancellationToken))
                {
                }

                if (HasColumn(reader, "Message") && await reader.ReadAsync(cancellationToken))
                {
                    message           = reader["Message"] as string;
                    savedObligationId = OptionalInt64(reader, "PracticeInstanceObligationId");
                }
            }

            // Migration 245: sync the persistent gap tables so a local
            // obligation moving to / out of Not Implemented / Partially
            // Implemented is reflected on Task Center's gap list right
            // away. Best-effort -- see AdoptObligationsAsync for the
            // reasoning.
            await SyncGapForInstanceAsync(connection, request.PracticeInstanceId,
                request.Actor, cancellationToken);

            // Migration 336-338: a local obligation can be Execution or
            // Assurance, so keep its calendar schedule stream in step too.
            // No anchors flow through this path today -- a first occurrence
            // is set on the adopt path; here a new stream simply starts
            // today and an existing one keeps its anchor.
            await SyncScheduleRulesForInstanceAsync(connection, request.PracticeInstanceId,
                request.Actor, null, cancellationToken);

            return new ResolveCommandResult(
                true,
                message ?? "Obligation saved.",
                null,
                savedObligationId);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_local_obligation_save failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // Blank is not a value here — the procedures read NULL as "no
    // opinion" and an empty string as a deliberate blanking.
    private static object Text(string? value)
        => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;

    // ==============================================================
    // Evidence
    // ==============================================================
    public async Task<ResolveEvidenceResult> ListEvidenceAsync(
        long practiceInstanceId, long? obligationId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveEvidenceResult(false, [], "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_list";

            AddParam(command, "@practice_instance_id", DbType.Int64, practiceInstanceId);
            AddParam(command, "@obligation_id",        DbType.Int64, obligationId is > 0 ? obligationId : DBNull.Value);

            var rows = new List<ResolveEvidenceRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new ResolveEvidenceRow(
                    EvidenceId:              Convert.ToInt64(reader["EvidenceId"]),
                    SourceObligationId:      reader["SourceObligationId"] as long?,
                    // 231/232 — read defensively so a database without
                    // them still loads the evidence section.
                    SourcePracticeInstanceObligationId:
                                             OptionalInt64(reader, "SourcePracticeInstanceObligationId"),
                    // 254 — same defensive read: null on a database that
                    // has not run the migration, so the evidence section
                    // still loads and simply shows no name.
                    EvidenceName:            OptionalString(reader, "EvidenceName"),
                    EvidenceTypeId:          ToInt(reader["EvidenceTypeId"]),
                    EvidenceType:            reader["EvidenceType"] as string,
                    // 306 — the published remark, read the same defensive
                    // way: null on a pre-306 database, and the workspace
                    // simply shows the row without its instruction.
                    EvidenceRemarks:         OptionalString(reader, "EvidenceRemarks"),
                    IsMandatory:             reader["IsMandatory"] is bool m && m,
                    CollectionMethodId:      reader["CollectionMethodId"] as int?,
                    CollectionMethod:        reader["CollectionMethod"] as string,
                    CollectionFrequencyId:   reader["CollectionFrequencyId"] as int?,
                    CollectionFrequency:     reader["CollectionFrequency"] as string,
                    AssuranceTypeId:         reader["AssuranceTypeId"] as int?,
                    AssuranceType:           reader["AssuranceType"] as string,
                    RetentionPeriod:         reader["RetentionPeriod"] as string,
                    EvidenceOwner:           reader["EvidenceOwner"] as string,
                    EvidenceDescription:     reader["EvidenceDescription"] as string,
                    EvidenceLocation:        reader["EvidenceLocation"] as string,
                    EvidenceLocator:         reader["EvidenceLocator"] as string,
                    AlignmentStatusId:       reader["AlignmentStatusId"] as int?,
                    AlignmentStatus:         reader["AlignmentStatus"] as string,
                    InheritedFromRepository: reader["InheritedFromRepository"] is bool i && i,
                    OrganizationModified:    reader["OrganizationModified"] is bool om && om,
                    IsResolved:              reader["IsResolved"] is bool r && r,
                    // 473 -- defensive like the others: null / 0 on a
                    // database without it, and the row shows no cadence.
                    EvidenceCadence:         OptionalString(reader, "EvidenceCadence"),
                    EvidenceCadenceLabel:    OptionalString(reader, "EvidenceCadenceLabel"),
                    EvidenceCadenceSource:   OptionalString(reader, "EvidenceCadenceSource"),
                    AttachmentCount:         OptionalInt32(reader, "AttachmentCount") ?? 0,
                    // 481 -- null on a database without it.
                    EvidenceSource:          OptionalString(reader, "EvidenceSource")));

            return new ResolveEvidenceResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_list failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveEvidenceResult(false, [], ex.Message);
        }
    }

    public async Task<ResolveCommandResult> SaveEvidenceAsync(
        ResolveEvidenceSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeInstanceId <= 0 || request.EvidenceId <= 0)
            return new ResolveCommandResult(false, null, "Practice instance and evidence row are both required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_save";

            // Null stays null: the procedure reads it as "leave alone", so an
            // untouched field must not arrive as an empty string.
            object? OrNull(string? s) => string.IsNullOrWhiteSpace(s) ? DBNull.Value : s;

            AddParam(command, "@practice_instance_id",    DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@evidence_id",             DbType.Int64,   request.EvidenceId);
            AddParam(command, "@is_mandatory",            DbType.Boolean, (object?)request.IsMandatory ?? DBNull.Value);
            AddParam(command, "@collection_method_id",    DbType.Int32,   (object?)request.CollectionMethodId ?? DBNull.Value);
            AddParam(command, "@collection_frequency_id", DbType.Int32,   (object?)request.CollectionFrequencyId ?? DBNull.Value);
            AddParam(command, "@assurance_type_id",       DbType.Int32,   (object?)request.AssuranceTypeId ?? DBNull.Value);
            AddParam(command, "@retention_period",        DbType.String,  OrNull(request.RetentionPeriod), 120);
            AddParam(command, "@owner_employee_id",       DbType.Int64,   request.OwnerEmployeeId is > 0 ? request.OwnerEmployeeId : DBNull.Value);
            AddParam(command, "@clear_owner",             DbType.Boolean, request.ClearOwner);
            AddParam(command, "@evidence_description",    DbType.String,  OrNull(request.EvidenceDescription));
            AddParam(command, "@evidence_location",       DbType.String,  OrNull(request.EvidenceLocation), 500);
            AddParam(command, "@evidence_locator",        DbType.String,  OrNull(request.EvidenceLocator), 500);
            // Migration 254. OrNull keeps the "absent means unchanged"
            // contract -- an empty box does not blank a stored name.
            AddParam(command, "@evidence_name",           DbType.String,  OrNull(request.EvidenceName), 300);
            AddParam(command, "@actor",                   DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);
            // Migration 473. Bound only when asked for AND declared, so a
            // database without 473 still saves (the clear is then lost,
            // which is the pre-473 behaviour) instead of failing with
            // "too many arguments".
            if (request.ClearEvidenceDescription
                && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                       connection, "sp_resolve_evidence_save", "@clear_evidence_description", cancellationToken))
                AddParam(command, "@clear_evidence_description", DbType.Boolean, true);
            // Migration 481: Direct Upload / Evidence Center Reference /
            // External Evidence Reference. Same "bound only when declared"
            // rule, so the API still saves against a database without 481.
            if (!string.IsNullOrWhiteSpace(request.EvidenceSource)
                && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                       connection, "sp_resolve_evidence_save", "@evidence_source", cancellationToken))
                AddParam(command, "@evidence_source", DbType.String, request.EvidenceSource.Trim(), 30);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Evidence saved.");

            var resolved = reader["IsResolved"] is bool r && r;
            var onInstance = ToInt(reader["ResolvedOnInstance"]);
            // 481: what is still missing depends on the option chosen.
            var source = OptionalString(reader, "EvidenceSource");
            var missing = source switch
            {
                "External"       => "Saved. A location and a locator are both needed before it counts as resolved.",
                "DirectUpload"   => "Saved. Attach a file before it counts as resolved.",
                "EvidenceCenter" => "Saved. Select evidence from the Evidence Center before it counts as resolved.",
                _                => "Saved. Attach a file, or enter a location and a locator, before it counts as resolved."
            };
            return new ResolveCommandResult(true,
                resolved
                    ? $"Evidence resolved; {onInstance} resolved on this instance."
                    : missing);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_save failed for evidence {EvidenceId}.", request.EvidenceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Evidence attachments (migration 473) -- a file attached to a
    // ONE-TIME evidence row at implementation. Same contract shape as
    // the Task Centre evidence (TaskService.AddAttachmentAsync /
    // GetAttachmentAsync); the procedures scope every call to the
    // practice instance.
    // ==============================================================
    public async Task<ResolveEvidenceAttachmentResult> ListEvidenceAttachmentsAsync(
        long practiceInstanceId, long? organizationId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0)
            return new ResolveEvidenceAttachmentResult(false, [], "PracticeInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_attachment_list";
            AddParam(command, "@practice_instance_id", DbType.Int64, practiceInstanceId);
            AddParam(command, "@organization_id",      DbType.Int64, organizationId is > 0 ? organizationId : DBNull.Value);

            var rows = new List<ResolveEvidenceAttachmentRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new ResolveEvidenceAttachmentRow(
                    EvidenceAttachmentId:  Convert.ToInt64(reader["EvidenceAttachmentId"]),
                    EvidenceId:            Convert.ToInt64(reader["EvidenceId"]),
                    FileName:              reader["FileName"]?.ToString() ?? "",
                    ContentType:           reader["ContentType"] as string,
                    FileSizeBytes:         reader["FileSizeBytes"] is { } sz && sz != DBNull.Value ? Convert.ToInt64(sz) : 0L,
                    AttachmentDescription: reader["AttachmentDescription"] as string,
                    UploadedByEmployeeId:  reader["UploadedByEmployeeId"] as long?,
                    UploadedByName:        reader["UploadedByName"] as string,
                    UploadedDt:            reader["UploadedDt"] as DateTime?,
                    // 476 -- absent before the migration.
                    EvidenceItemId:        OptionalInt64(reader, "EvidenceItemId"),
                    EvidenceTitle:         OptionalString(reader, "EvidenceTitle"),
                    EvidenceItemStatus:    OptionalString(reader, "EvidenceItemStatus"),
                    VersionNo:             OptionalInt32(reader, "VersionNo"),
                    CurrentVersionNo:      OptionalInt32(reader, "CurrentVersionNo"),
                    NewerVersionAvailable: HasColumn(reader, "NewerVersionAvailable") && reader["NewerVersionAvailable"] is bool nv && nv,
                    ValidTo:               HasColumn(reader, "ValidTo") ? reader["ValidTo"] as DateTime? : null,
                    ValidityState:         OptionalString(reader, "ValidityState"),
                    LinkedByName:          OptionalString(reader, "LinkedByName"),
                    LinkedDt:              HasColumn(reader, "LinkedDt") ? reader["LinkedDt"] as DateTime? : null));

            return new ResolveEvidenceAttachmentResult(true, rows);
        }
        catch (SqlException ex) when (ex.Number == 2812)
        {
            // A database without 473: no attachments, not a broken workspace.
            logger.LogWarning(ex, "sp_resolve_evidence_attachment_list is not installed (run 473).");
            return new ResolveEvidenceAttachmentResult(true, []);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_attachment_list failed for instance {InstanceId}.", practiceInstanceId);
            return new ResolveEvidenceAttachmentResult(false, [], ex.Message);
        }
    }

    public async Task<ResolveCommandResult> AddEvidenceAttachmentAsync(
        long practiceInstanceId, long evidenceId, string fileName, string? contentType,
        byte[] fileData, string? description, long? uploadedByEmployeeId,
        long? organizationId, string? actor, bool callerIsAdmin, CancellationToken cancellationToken,
        EvidenceUploadMetadata? metadata = null)
    {
        if (practiceInstanceId <= 0 || evidenceId <= 0)
            return new ResolveCommandResult(false, null, "Practice instance and evidence row are both required.");
        if (string.IsNullOrWhiteSpace(fileName))
            return new ResolveCommandResult(false, null, "A file name is required.");
        if (fileData is null || fileData.Length == 0)
            return new ResolveCommandResult(false, null, "The file is empty.");

        try
        {
            // 476: the file becomes an Evidence Center item, or links the
            // identical one the uploader can already see. "Can see" reads
            // practice_instance under View Data Scope, so this POST runs
            // with the uploader as the reader (the middleware only sets
            // one for GETs).
            Infrastructure.CallerViewScope.BeginRead(uploadedByEmployeeId);

            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_attachment_add";

            AddParam(command, "@practice_instance_id",    DbType.Int64,  practiceInstanceId);
            AddParam(command, "@evidence_id",             DbType.Int64,  evidenceId);
            AddParam(command, "@file_name",               DbType.String, fileName, 500);
            AddParam(command, "@content_type",            DbType.String, Text(contentType), 200);
            AddParam(command, "@file_data",               DbType.Binary, fileData, -1);
            AddParam(command, "@attachment_description",  DbType.String, Text(description), 1000);
            AddParam(command, "@uploaded_by_employee_id", DbType.Int64,  uploadedByEmployeeId is > 0 ? uploadedByEmployeeId : DBNull.Value);
            AddParam(command, "@actor",                   DbType.String,
                     string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);
            AddParam(command, "@organization_id",         DbType.Int64,  organizationId is > 0 ? organizationId : DBNull.Value);
            // Migration 476. Bound only when declared, so a database
            // without 476 still attaches (the 473 way).
            if (await Infrastructure.ProcParameterProbe.HasParameterAsync(
                    connection, "sp_resolve_evidence_attachment_add", "@caller_is_admin", cancellationToken))
                AddParam(command, "@caller_is_admin",     DbType.Boolean, callerIsAdmin);

            // Migration 499: the Evidence Center metadata the upload dialog
            // captured. 499 adds all eight parameters together, so one probe
            // answers for the set -- the same "bound only when declared"
            // guard 476 applies above, so this Api still attaches against a
            // database where 499 has not been run.
            if (metadata is not null
                && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                       connection, "sp_resolve_evidence_attachment_add", "@evidence_title", cancellationToken))
            {
                AddParam(command, "@evidence_title",       DbType.String, Text(metadata.EvidenceTitle), 300);
                AddParam(command, "@evidence_type_id",     DbType.Int32,
                         metadata.EvidenceTypeId is > 0 ? metadata.EvidenceTypeId : DBNull.Value);
                AddParam(command, "@evidence_description", DbType.String, Text(metadata.EvidenceDescription), 2000);
                AddParam(command, "@owner_employee_id",    DbType.Int64,
                         metadata.OwnerEmployeeId is > 0 ? metadata.OwnerEmployeeId : DBNull.Value);
                AddParam(command, "@valid_from",           DbType.Date, (object?)metadata.ValidFrom ?? DBNull.Value);
                AddParam(command, "@valid_to",             DbType.Date, (object?)metadata.ValidTo ?? DBNull.Value);
                AddParam(command, "@classification",       DbType.String, Text(metadata.Classification), 30);
                AddParam(command, "@tags",                 DbType.String, Text(metadata.Tags), 500);
            }

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            long? id = null;
            string? message = null;
            if (await reader.ReadAsync(cancellationToken))
            {
                if (HasColumn(reader, "EvidenceAttachmentId"))
                    id = Convert.ToInt64(reader["EvidenceAttachmentId"]);
                message = OptionalString(reader, "Message");   // 476
            }

            return new ResolveCommandResult(true, message ?? "Evidence attached.", null, id);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_attachment_add failed for evidence {EvidenceId}.", evidenceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    public async Task<ResolveEvidenceAttachmentContent?> GetEvidenceAttachmentAsync(
        long practiceInstanceId, long evidenceAttachmentId, long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_resolve_evidence_attachment_get";
        AddParam(command, "@practice_instance_id",   DbType.Int64, practiceInstanceId);
        AddParam(command, "@evidence_attachment_id", DbType.Int64, evidenceAttachmentId);
        AddParam(command, "@organization_id",        DbType.Int64, organizationId is > 0 ? organizationId : DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new ResolveEvidenceAttachmentContent(
            EvidenceAttachmentId: Convert.ToInt64(reader["EvidenceAttachmentId"]),
            EvidenceId:           Convert.ToInt64(reader["EvidenceId"]),
            FileName:             reader["FileName"]?.ToString() ?? "download",
            ContentType:          reader["ContentType"] as string,
            FileSizeBytes:        Convert.ToInt64(reader["FileSizeBytes"]),
            FileData:             (byte[])reader["FileData"]);
    }

    public async Task<ResolveCommandResult> RemoveEvidenceAttachmentAsync(
        ResolveEvidenceAttachmentRemoveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0 || request.EvidenceAttachmentId <= 0)
            return new ResolveCommandResult(false, null, "Practice instance and attachment are both required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_evidence_attachment_remove";
            AddParam(command, "@practice_instance_id",   DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@evidence_attachment_id", DbType.Int64,  request.EvidenceAttachmentId);
            AddParam(command, "@actor",                  DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);
            AddParam(command, "@organization_id",        DbType.Int64,
                     request.OrganizationId is > 0 ? request.OrganizationId : DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var message = await reader.ReadAsync(cancellationToken) && HasColumn(reader, "Message")
                ? reader["Message"] as string
                : null;
            return new ResolveCommandResult(true, message ?? "Attachment removed.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_attachment_remove failed for attachment {AttachmentId}.", request.EvidenceAttachmentId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Migration 476 -- Select from Evidence Center. The procedures check
    // the evidence row (one-time, on this instance, this organisation),
    // the item (Active, unexpired, visible to the caller) and pin the
    // current version; refresh moves a link to the latest version.
    // ==============================================================
    public async Task<ResolveEvidenceLinkCandidateResult> ListEvidenceLinkCandidatesAsync(
        long practiceInstanceId, long evidenceId, long organizationId,
        long? callerEmployeeId, bool callerIsAdmin, string? search,
        int? evidenceTypeId, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0 || evidenceId <= 0 || organizationId <= 0)
            return new ResolveEvidenceLinkCandidateResult(false, [], 0, "Organization, practice instance and evidence row are all required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_link_candidates";
            AddParam(command, "@organization_id",      DbType.Int64,   organizationId);
            AddParam(command, "@practice_instance_id", DbType.Int64,   practiceInstanceId);
            AddParam(command, "@evidence_id",          DbType.Int64,   evidenceId);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",      DbType.Boolean, callerIsAdmin);
            AddParam(command, "@search",               DbType.String,  Text(search), 200);
            AddParam(command, "@evidence_type_id",     DbType.Int32,   evidenceTypeId is > 0 ? evidenceTypeId : DBNull.Value);
            AddParam(command, "@page_number",          DbType.Int32,   pageNumber);
            AddParam(command, "@page_size",            DbType.Int32,   pageSize);

            var rows = new List<Dictionary<string, object?>>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < reader.FieldCount; i++)
                    row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                rows.Add(row);
            }
            var total = rows.Count > 0 && rows[0]["TotalRows"] is { } t ? Convert.ToInt32(t) : 0;
            return new ResolveEvidenceLinkCandidateResult(true, rows, total);
        }
        catch (SqlException ex) when (ex.Number == 2812)
        {
            logger.LogWarning(ex, "sp_evidence_link_candidates is not installed (run 476).");
            return new ResolveEvidenceLinkCandidateResult(false, [], 0, "The Evidence Center is not installed yet (database migration 476).");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_evidence_link_candidates failed for evidence {EvidenceId}.", evidenceId);
            return new ResolveEvidenceLinkCandidateResult(false, [], 0, ex.Message);
        }
    }

    public async Task<ResolveCommandResult> LinkEvidenceItemAsync(
        ResolveEvidenceLinkRequest request, long? callerEmployeeId, bool callerIsAdmin, string actor,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0 || request.EvidenceId <= 0 || request.EvidenceItemId <= 0
            || request.OrganizationId is not > 0)
            return new ResolveCommandResult(false, null, "Organization, practice instance, evidence row and evidence item are all required.");

        try
        {
            // Visibility of the item is part of the rule (see AddEvidenceAttachmentAsync).
            Infrastructure.CallerViewScope.BeginRead(callerEmployeeId);

            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_link_add";
            AddParam(command, "@organization_id",      DbType.Int64,   request.OrganizationId);
            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@evidence_id",          DbType.Int64,   request.EvidenceId);
            AddParam(command, "@evidence_item_id",     DbType.Int64,   request.EvidenceItemId);
            AddParam(command, "@link_note",            DbType.String,  Text(request.LinkNote), 1000);
            AddParam(command, "@caller_employee_id",   DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@caller_is_admin",      DbType.Boolean, callerIsAdmin);
            AddParam(command, "@actor",                DbType.String,  string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            long? id = null;
            string? message = null;
            if (await reader.ReadAsync(cancellationToken))
            {
                id      = OptionalInt64(reader, "EvidenceAttachmentId");
                message = OptionalString(reader, "Message");
            }
            return new ResolveCommandResult(true, message ?? "Evidence linked.", null, id);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_evidence_link_add failed for evidence {EvidenceId}.", request.EvidenceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    public async Task<ResolveCommandResult> RefreshEvidenceLinkAsync(
        ResolveEvidenceLinkRefreshRequest request, string actor, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0 || request.EvidenceAttachmentId <= 0 || request.OrganizationId is not > 0)
            return new ResolveCommandResult(false, null, "Organization, practice instance and attachment are all required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_evidence_link_refresh";
            AddParam(command, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(command, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@evidence_link_id",     DbType.Int64,  request.EvidenceAttachmentId);
            AddParam(command, "@actor",                DbType.String, string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var message = await reader.ReadAsync(cancellationToken) ? OptionalString(reader, "Message") : null;
            return new ResolveCommandResult(true, message ?? "Updated to the latest version.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_evidence_link_refresh failed for link {LinkId}.", request.EvidenceAttachmentId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Infrastructure helpers -- identical to the sibling services
    // ==============================================================
    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
        return connection;
    }

    // ==============================================================
    // Actor stamps. The controllers stamp writes as "employee:{id}"
    // (ResolveWorkspaceController.Actor); a screen should show the person.
    // ActorEmployeeId parses the stamp (null for "system" or anything
    // else); ResolveActorNamesAsync looks the ids up in one query.
    // ==============================================================
    private static long? ActorEmployeeId(string? actor) =>
        actor is not null
        && actor.StartsWith("employee:", StringComparison.OrdinalIgnoreCase)
        && long.TryParse(actor["employee:".Length..], out var id) && id > 0
            ? id : null;

    private static async Task<Dictionary<long, string>> ResolveActorNamesAsync(
        DbConnection connection, IEnumerable<string?> actors, CancellationToken cancellationToken)
    {
        var ids = actors.Select(ActorEmployeeId).OfType<long>().Distinct().ToList();
        var names = new Dictionary<long, string>();
        if (ids.Count == 0) return names;

        await using var command = connection.CreateCommand();
        var placeholders = new List<string>();
        for (var i = 0; i < ids.Count; i++)
        {
            placeholders.Add("@id" + i);
            AddParam(command, "@id" + i, DbType.Int64, ids[i]);
        }
        command.CommandText =
            "SELECT employee_id, employee_name FROM grac_practice.organization_employee WHERE employee_id IN ("
            + string.Join(",", placeholders) + ");";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            names[Convert.ToInt64(reader["employee_id"])] = Convert.ToString(reader["employee_name"]) ?? "";
        return names;
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

    private static int ToInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);

    // ==============================================================
    // Columns a migration added, read from a result set that may predate
    // it. reader["Missing"] throws IndexOutOfRangeException, so a column
    // introduced by a migration the deployed database has not run yet
    // would take down the whole read rather than degrade the one feature
    // that needs it. GetOrdinal-by-name over the schema is the cheap way
    // to ask first.
    // ==============================================================
    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static long? OptionalInt64(DbDataReader reader, string name)
        => HasColumn(reader, name) && reader[name] is { } v && v != DBNull.Value
            ? Convert.ToInt64(v)
            : null;

    private static int? OptionalInt32(DbDataReader reader, string name)
        => HasColumn(reader, name) && reader[name] is { } v && v != DBNull.Value
            ? Convert.ToInt32(v)
            : null;

    private static string? OptionalString(DbDataReader reader, string name)
        => HasColumn(reader, name) ? reader[name] as string : null;

    /// <summary>
    /// A FOR JSON column, defaulting to an empty array rather than null.
    /// The browser then does JSON.parse unconditionally instead of
    /// guarding every one of the seven, and a database without migration
    /// 224 reads as "this obligation has no typed detail" — which is
    /// exactly how it should render.
    /// </summary>
    private static string OptionalJson(DbDataReader reader, string name)
    {
        if (!HasColumn(reader, name)) return "[]";
        var value = reader[name] as string;
        return string.IsNullOrWhiteSpace(value) ? "[]" : value;
    }
}
