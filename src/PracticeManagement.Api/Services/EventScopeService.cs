// =====================================================================
// EventScopeService
//
// Thin facade over the migration-124 procedures:
//   sp_event_scope_mapping_list
//   sp_event_scope_coverage_list
//   sp_event_instance_raise_scoped
//   sp_event_raise_people_lifecycle
//   sp_event_raise_asset_lifecycle
//   sp_event_checklist_inbox_list
//   sp_event_instance_detail_get
//   sp_event_resolution_trace_list
//
// Kept in its own file rather than folded into the 905-line
// WorkflowService, matching that file's own stated reason: so it can be
// reviewed and wired independently. Registered via
// Infrastructure/EventScopeServiceRegistration.cs.
//
// Follows the WorkflowService pattern exactly:
//   * Single interface, single implementation
//   * DbType-typed AddParam helper
//   * OpenAsync resolves the connection string via SqlConnectionStringResolver
//   * All errors caught, logged, returned as (Success=false, Error)
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IEventScopeService
{
    Task<EventScopeMappingResult>    ListScopeMappingsAsync(EventScopeMappingQuery query, CancellationToken cancellationToken);
    Task<EventScopeCoverageResult>   ListScopeCoverageAsync(EventScopeCoverageQuery query, CancellationToken cancellationToken);

    Task<EventScopedRaiseResult>     RaiseScopedAsync(EventScopedRaiseRequest request, CancellationToken cancellationToken);
    Task<EventScopedRaiseResult>     RaisePeopleLifecycleAsync(PeopleLifecycleRaiseRequest request, CancellationToken cancellationToken);
    Task<EventScopedRaiseResult>     RaiseAssetLifecycleAsync(AssetLifecycleRaiseRequest request, CancellationToken cancellationToken);

    // Obligation-based scoping (127/128)
    Task<EventObligationMappingResult>  ListObligationMappingsAsync(EventObligationMappingQuery query, CancellationToken cancellationToken);
    Task<EventObligationApplicabilityCommandResult> SaveObligationApplicabilityAsync(EventObligationApplicabilitySaveRequest request, CancellationToken cancellationToken);
    Task<EventObligationCoverageResult> ListObligationCoverageAsync(long organizationId, string scopeDimension, long? eventTypeId, CancellationToken cancellationToken);

    // Checklists tab + View Mapped Profiles reverse lookup (migration 344)
    Task<EventDrivenChecklistResult> ListEventDrivenChecklistsAsync(EventDrivenChecklistQuery query, CancellationToken cancellationToken);
    Task<EventChecklistMappedProfilesResult> ListChecklistMappedProfilesAsync(EventChecklistMappedProfilesQuery query, CancellationToken cancellationToken);

    // Custom questions per scope + event (migration 136)
    Task<ScopeQuestionResult>        ListScopeQuestionsAsync(ScopeQuestionQuery query, CancellationToken cancellationToken);
    Task<ScopeQuestionCommandResult> SaveScopeQuestionAsync(ScopeQuestionSaveRequest request, CancellationToken cancellationToken);
    Task<ScopeQuestionCommandResult> DeleteScopeQuestionAsync(ScopeQuestionDeleteRequest request, CancellationToken cancellationToken);

    /// <summary>
    /// Turns pending grac_practice.event_autoraise_queue entries into event
    /// instances (migration 131). Safe to call repeatedly: the queue's
    /// filtered unique index and the raise procedures' own idempotency guards
    /// mean a second pass over the same subject creates nothing.
    /// </summary>
    Task<int> DrainAutoRaiseQueueAsync(long? organizationId, int maxRows, CancellationToken cancellationToken);

    Task<EventChecklistInboxResult>  ListInboxAsync(EventChecklistInboxQuery query, CancellationToken cancellationToken);
    Task<EventInstanceDetailResult>  GetInstanceDetailAsync(long organizationId, long eventInstanceId, CancellationToken cancellationToken);
    Task<(bool Success, string? Error)> SaveObligationResultAsync(EventInstanceObligationSaveRequest request, CancellationToken cancellationToken);
    Task<EventResolutionTraceResult> ListResolutionTraceAsync(EventResolutionTraceQuery query, CancellationToken cancellationToken);
}

public sealed class EventScopeService(IConfiguration configuration, ILogger<EventScopeService> logger) : IEventScopeService
{
    // ==============================================================
    // Mapping workspace
    // ==============================================================
    public async Task<EventScopeMappingResult> ListScopeMappingsAsync(
        EventScopeMappingQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_scope_mapping_list";

        AddParam(command, "@organization_id",         DbType.Int64,  query.OrganizationId);
        AddParam(command, "@event_definition_id",     DbType.Int64,  (object?)query.EventDefinitionId    ?? DBNull.Value);
        AddParam(command, "@scope_dimension",         DbType.String, (object?)query.ScopeDimension       ?? DBNull.Value, 40);
        AddParam(command, "@scope_role_id",           DbType.Int64,  (object?)query.ScopeRoleId          ?? DBNull.Value);
        AddParam(command, "@scope_asset_category_id", DbType.Int32,  (object?)query.ScopeAssetCategoryId ?? DBNull.Value);

        var rows = new List<EventScopeMappingRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add(MapScopeMapping(reader));
        return new EventScopeMappingResult(rows);
    }

    public async Task<EventScopeCoverageResult> ListScopeCoverageAsync(
        EventScopeCoverageQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_scope_coverage_list";

        AddParam(command, "@organization_id",     DbType.Int64,  query.OrganizationId);
        AddParam(command, "@scope_dimension",     DbType.String, query.ScopeDimension, 40);
        AddParam(command, "@event_definition_id", DbType.Int64,  (object?)query.EventDefinitionId ?? DBNull.Value);

        var rows = new List<EventScopeCoverageRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new EventScopeCoverageRow(
                ScopeDimension:     reader["ScopeDimension"]?.ToString() ?? "",
                ScopeValueId:       Convert.ToInt64(reader["ScopeValueId"]),
                ScopeValueName:     reader["ScopeValueName"]?.ToString() ?? "",
                TotalChecklists:    Convert.ToInt32(reader["TotalChecklists"]),
                MappedChecklists:   Convert.ToInt32(reader["MappedChecklists"]),
                UnmappedChecklists: Convert.ToInt32(reader["UnmappedChecklists"])));
        return new EventScopeCoverageResult(rows);
    }

    // ==============================================================
    // Raise
    // ==============================================================
    public async Task<EventScopedRaiseResult> RaiseScopedAsync(
        EventScopedRaiseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0)
            return new EventScopedRaiseResult(false, 0, "OrganizationId is required.");
        if (!EventSubjectEntities.IsValid(request.SubjectEntity))
            return new EventScopedRaiseResult(false, 0, "SubjectEntity must be EMPLOYEE or ASSET.");
        if (request.SubjectRecordId <= 0)
            return new EventScopedRaiseResult(false, 0, "SubjectRecordId is required.");
        if (request.EventDefinitionId is null or <= 0 && string.IsNullOrWhiteSpace(request.EventCode))
            return new EventScopedRaiseResult(false, 0, "Either EventDefinitionId or EventCode is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_instance_raise_scoped";

            AddParam(command, "@organization_id",     DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_definition_id", DbType.Int64,  (object?)request.EventDefinitionId ?? DBNull.Value);
            AddParam(command, "@event_code",          DbType.String, (object?)request.EventCode         ?? DBNull.Value, 60);
            AddParam(command, "@subject_entity",      DbType.String, request.SubjectEntity, 60);
            AddParam(command, "@subject_record_id",   DbType.Int64,  request.SubjectRecordId);
            AddParam(command, "@effective_date",      DbType.Date,   (object?)request.EffectiveDate     ?? DBNull.Value);
            AddParam(command, "@trigger_source",      DbType.String, (object?)request.TriggerSource     ?? "Manual", 60);
            AddParam(command, "@payload_json",        DbType.String, (object?)request.PayloadJson       ?? DBNull.Value);
            AddParam(command, "@actor_employee_id",   DbType.Int64,  (object?)request.ActorEmployeeId   ?? DBNull.Value);
            var raised = AddOutParam(command, "@out_raised_count", DbType.Int32);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventScopedRaiseResult(true, ToInt(raised.Value));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RaiseScopedAsync failed for org {OrganizationId} subject {SubjectEntity}:{SubjectRecordId}",
                request.OrganizationId, request.SubjectEntity, request.SubjectRecordId);
            return new EventScopedRaiseResult(false, 0, ex.Message);
        }
    }

    public async Task<EventScopedRaiseResult> RaisePeopleLifecycleAsync(
        PeopleLifecycleRaiseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0 || request.EmployeeId <= 0)
            return new EventScopedRaiseResult(false, 0, "OrganizationId and EmployeeId are required.");
        if (request.LifecycleAction is not (EventLifecycleActions.Onboard or EventLifecycleActions.Offboard))
            return new EventScopedRaiseResult(false, 0, "LifecycleAction must be ONBOARD or OFFBOARD.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_raise_people_lifecycle";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@employee_id",       DbType.Int64,  request.EmployeeId);
            AddParam(command, "@lifecycle_action",  DbType.String, request.LifecycleAction, 20);
            AddParam(command, "@effective_date",    DbType.Date,   (object?)request.EffectiveDate   ?? DBNull.Value);
            AddParam(command, "@event_code",        DbType.String, (object?)request.EventCode       ?? DBNull.Value, 60);
            AddParam(command, "@trigger_source",    DbType.String, (object?)request.TriggerSource   ?? "Manual", 60);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var raised = AddOutParam(command, "@out_raised_count", DbType.Int32);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventScopedRaiseResult(true, ToInt(raised.Value));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RaisePeopleLifecycleAsync failed for org {OrganizationId} employee {EmployeeId} action {Action}",
                request.OrganizationId, request.EmployeeId, request.LifecycleAction);
            return new EventScopedRaiseResult(false, 0, ex.Message);
        }
    }

    public async Task<EventScopedRaiseResult> RaiseAssetLifecycleAsync(
        AssetLifecycleRaiseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0 || request.AssetId <= 0)
            return new EventScopedRaiseResult(false, 0, "OrganizationId and AssetId are required.");
        if (request.LifecycleAction is not (EventLifecycleActions.Commission or EventLifecycleActions.Decommission))
            return new EventScopedRaiseResult(false, 0, "LifecycleAction must be COMMISSION or DECOMMISSION.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_raise_asset_lifecycle";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@asset_id",          DbType.Int64,  request.AssetId);
            AddParam(command, "@lifecycle_action",  DbType.String, request.LifecycleAction, 20);
            AddParam(command, "@effective_date",    DbType.Date,   (object?)request.EffectiveDate   ?? DBNull.Value);
            AddParam(command, "@event_code",        DbType.String, (object?)request.EventCode       ?? DBNull.Value, 60);
            AddParam(command, "@trigger_source",    DbType.String, (object?)request.TriggerSource   ?? "Manual", 60);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var raised = AddOutParam(command, "@out_raised_count", DbType.Int32);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventScopedRaiseResult(true, ToInt(raised.Value));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RaiseAssetLifecycleAsync failed for org {OrganizationId} asset {AssetId} action {Action}",
                request.OrganizationId, request.AssetId, request.LifecycleAction);
            return new EventScopedRaiseResult(false, 0, ex.Message);
        }
    }

    // ==============================================================
    // Obligation-based scoping (127/128)
    // ==============================================================
    public async Task<EventObligationMappingResult> ListObligationMappingsAsync(
        EventObligationMappingQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_obligation_mapping_list";

        AddParam(command, "@organization_id",         DbType.Int64,   query.OrganizationId);
        AddParam(command, "@event_type_id",           DbType.Int64,   (object?)query.EventTypeId          ?? DBNull.Value);
        AddParam(command, "@event_type_code",         DbType.String,  (object?)query.EventTypeCode        ?? DBNull.Value, 60);
        AddParam(command, "@scope_dimension",         DbType.String,  query.ScopeDimension, 40);
        AddParam(command, "@scope_role_id",           DbType.Int64,   (object?)query.ScopeRoleId          ?? DBNull.Value);
        AddParam(command, "@scope_asset_category_id", DbType.Int32,   (object?)query.ScopeAssetCategoryId ?? DBNull.Value);
        AddParam(command, "@include_unsubscribed",    DbType.Boolean, query.IncludeUnsubscribed);
        AddParam(command, "@profile_id",              DbType.Int64,   (object?)query.ProfileId            ?? DBNull.Value);

        var rows = new List<EventObligationMappingRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add(MapObligationMapping(reader));
        return new EventObligationMappingResult(rows);
    }

    public async Task<EventObligationApplicabilityCommandResult> SaveObligationApplicabilityAsync(
        EventObligationApplicabilitySaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        // Migration 343: an obligation's identity is now one of three
        // columns, never obligation_id alone -- a catalog obligation has no
        // local identity, a custom one has no GRAC_New id. Mirrors the
        // procedure's own THROW 67322.
        var identityCount = (request.ObligationId is > 0 ? 1 : 0)
                           + (request.LocalPracticeObligationId is > 0 ? 1 : 0)
                           + (request.LocalInstanceObligationId is > 0 ? 1 : 0);
        if (request.OrganizationId <= 0 || request.EventTypeId <= 0 || identityCount != 1)
            return new EventObligationApplicabilityCommandResult(false, null,
                "OrganizationId and EventTypeId are required, and exactly one of ObligationId, "
                + "LocalPracticeObligationId or LocalInstanceObligationId must be set.");
        if (!EventScopeDimensions.IsConcrete(request.ScopeDimension))
            return new EventObligationApplicabilityCommandResult(false, null,
                "ScopeDimension must be ORG_ROLE, ASSET_CATEGORY or PROFILE.");
        // Checked here as well as in the procedure so the screen gets a
        // sentence instead of a THROW number.
        if (request.ScopeDimension == EventScopeDimensions.Profile && request.ProfileId is null or <= 0)
            return new EventObligationApplicabilityCommandResult(false, null,
                "ProfileId is required when ScopeDimension is PROFILE.");
        // Mirrors the proc and the CHECK constraint: an exclusion without a
        // reason is not auditable, so reject it here with a readable message.
        if (!request.IsApplicable && string.IsNullOrWhiteSpace(request.Rationale))
            return new EventObligationApplicabilityCommandResult(false, null,
                "A rationale is required when marking an obligation not applicable.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_obligation_applicability_save";

            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@obligation_id",           DbType.Int64,   (object?)request.ObligationId               ?? DBNull.Value);
            AddParam(command, "@local_practice_obligation_id", DbType.Int64, (object?)request.LocalPracticeObligationId ?? DBNull.Value);
            AddParam(command, "@local_instance_obligation_id", DbType.Int64, (object?)request.LocalInstanceObligationId ?? DBNull.Value);
            AddParam(command, "@event_type_id",           DbType.Int64,   request.EventTypeId);
            AddParam(command, "@scope_dimension",         DbType.String,  request.ScopeDimension, 40);
            AddParam(command, "@scope_role_id",           DbType.Int64,   (object?)request.ScopeRoleId          ?? DBNull.Value);
            AddParam(command, "@scope_asset_category_id", DbType.Int32,   (object?)request.ScopeAssetCategoryId ?? DBNull.Value);
            AddParam(command, "@is_applicable",           DbType.Boolean, request.IsApplicable);
            AddParam(command, "@rationale",               DbType.String,  (object?)request.Rationale     ?? DBNull.Value, 1000);
            AddParam(command, "@owner_role_id",           DbType.Int64,   (object?)request.OwnerRoleId    ?? DBNull.Value);
            AddParam(command, "@due_days",                DbType.Int32,   (object?)request.DueDays        ?? DBNull.Value);
            AddParam(command, "@status",                  DbType.String,  (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id",       DbType.Int64,   (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@profile_id",              DbType.Int64,   (object?)request.ProfileId       ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_applicability_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is null || idParam.Value == DBNull.Value
                ? (long?)null : Convert.ToInt64(idParam.Value);
            return new EventObligationApplicabilityCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveObligationApplicabilityAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventObligationApplicabilityCommandResult(false, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "SaveObligationApplicabilityAsync failed for org {OrganizationId} obligation {ObligationId}",
                request.OrganizationId, request.ObligationId);
            return new EventObligationApplicabilityCommandResult(false, null, ex.Message);
        }
    }

    public async Task<EventObligationCoverageResult> ListObligationCoverageAsync(
        long organizationId, string scopeDimension, long? eventTypeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_obligation_coverage_list";

        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@scope_dimension", DbType.String, scopeDimension, 40);
        AddParam(command, "@event_type_id",   DbType.Int64,  (object?)eventTypeId ?? DBNull.Value);

        var rows = new List<EventObligationCoverageRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new EventObligationCoverageRow(
                ScopeDimension:        reader["ScopeDimension"]?.ToString() ?? "",
                ScopeValueId:          Convert.ToInt64(reader["ScopeValueId"]),
                ScopeValueName:        reader["ScopeValueName"]?.ToString() ?? "",
                TotalObligations:      Convert.ToInt32(reader["TotalObligations"]),
                DecidedObligations:    Convert.ToInt32(reader["DecidedObligations"]),
                UndecidedObligations:  Convert.ToInt32(reader["UndecidedObligations"]),
                // Migration 130 added these. Read defensively so the API keeps
                // working against a database where 130 has not been applied yet
                // -- a deploy order mismatch should degrade, not 500.
                ApplicableObligations: HasColumn(reader, "ApplicableObligations")
                                           ? Convert.ToInt32(reader["ApplicableObligations"]) : 0,
                ExcludedObligations:   HasColumn(reader, "ExcludedObligations")
                                           ? Convert.ToInt32(reader["ExcludedObligations"]) : 0));
        return new EventObligationCoverageResult(rows);
    }

    // ==============================================================
    // Checklists tab + View Mapped Profiles reverse lookup (migration 344)
    // ==============================================================
    public async Task<EventDrivenChecklistResult> ListEventDrivenChecklistsAsync(
        EventDrivenChecklistQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        var page = query.PageNumber <= 0 ? 1  : query.PageNumber;
        var size = query.PageSize   <= 0 ? 25 : query.PageSize;

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_driven_checklist_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@event_type_id",   DbType.Int64,  (object?)query.EventTypeId ?? DBNull.Value);
        AddParam(command, "@search",          DbType.String, (object?)query.Search      ?? DBNull.Value, 200);
        AddParam(command, "@page_number",     DbType.Int32,  page);
        AddParam(command, "@page_size",       DbType.Int32,  size);

        var rows  = new List<EventDrivenChecklistRow>();
        var total = 0;

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            // TotalRows is COUNT(*) OVER (), identical on every row --
            // docs/grid-and-pagination-standard.md, same convention
            // sp_event_profile_list's own reader follows.
            if (rows.Count == 0) total = ToInt(reader["TotalRows"]);

            rows.Add(new EventDrivenChecklistRow(
                ObligationId:              reader["ObligationId"] as long?,
                LocalPracticeObligationId: reader["LocalPracticeObligationId"] as long?,
                LocalInstanceObligationId: reader["LocalInstanceObligationId"] as long?,
                ObligationKind:            reader["ObligationKind"]?.ToString() ?? "Catalog",
                ObligationName:            reader["ObligationName"] as string,
                PracticeInstanceId:        reader["PracticeInstanceId"] as long?,
                PracticeInstanceCode:      reader["PracticeInstanceCode"] as string,
                PracticeInstanceName:      reader["PracticeInstanceName"] as string,
                PracticeId:                reader["PracticeId"] as long?,
                PracticeCode:              reader["PracticeCode"] as string,
                PracticeName:              reader["PracticeName"] as string,
                PracticeInstanceDisplay:   reader["PracticeInstanceDisplay"] as string,
                EventTypeId:               Convert.ToInt64(reader["EventTypeId"]),
                EventTypeCode:             reader["EventTypeCode"] as string,
                EventTypeName:             reader["EventTypeName"] as string,
                EventDomainName:           reader["EventDomainName"] as string));
        }

        return new EventDrivenChecklistResult(rows, total, page, size);
    }

    public async Task<EventChecklistMappedProfilesResult> ListChecklistMappedProfilesAsync(
        EventChecklistMappedProfilesQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_checklist_mapped_profiles_list";

        AddParam(command, "@organization_id",              DbType.Int64, query.OrganizationId);
        AddParam(command, "@event_type_id",                DbType.Int64, query.EventTypeId);
        AddParam(command, "@obligation_id",                DbType.Int64, (object?)query.ObligationId               ?? DBNull.Value);
        AddParam(command, "@local_practice_obligation_id", DbType.Int64, (object?)query.LocalPracticeObligationId ?? DBNull.Value);
        AddParam(command, "@local_instance_obligation_id", DbType.Int64, (object?)query.LocalInstanceObligationId ?? DBNull.Value);

        var rows = new List<EventChecklistMappedProfileRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new EventChecklistMappedProfileRow(
                ProfileId:        Convert.ToInt64(reader["ProfileId"]),
                ProfileCode:      reader["ProfileCode"]?.ToString() ?? "",
                ProfileName:      reader["ProfileName"]?.ToString() ?? "",
                Description:      reader["Description"] as string,
                Status:           reader["Status"]?.ToString() ?? "Active",
                CriteriaSummary:  reader["CriteriaSummary"] as string,
                ApplicabilityId:  reader["ApplicabilityId"] as long?,
                DueDays:          reader["DueDays"] as int?,
                OwnerRoleId:      reader["OwnerRoleId"] as long?,
                OwnerRoleName:    reader["OwnerRoleName"] as string));
        return new EventChecklistMappedProfilesResult(rows);
    }

    public async Task<int> DrainAutoRaiseQueueAsync(
        long? organizationId, int maxRows, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_autoraise_drain";
        // The proc walks a cursor and raises per entry; a tight default
        // timeout would abort mid-queue and leave entries half-attempted.
        command.CommandTimeout = 180;

        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@max_rows",        DbType.Int32, Math.Clamp(maxRows, 1, 1000));
        var processed = AddOutParam(command, "@out_processed", DbType.Int32);

        await command.ExecuteNonQueryAsync(cancellationToken);
        return ToInt(processed.Value);
    }

    // ==============================================================
    // Custom questions per scope + event (migration 136)
    // ==============================================================
    public async Task<ScopeQuestionResult> ListScopeQuestionsAsync(
        ScopeQuestionQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_scope_question_list";

        AddParam(command, "@organization_id",         DbType.Int64,  query.OrganizationId);
        AddParam(command, "@scope_dimension",         DbType.String, query.ScopeDimension, 40);
        AddParam(command, "@scope_role_id",           DbType.Int64,  (object?)query.ScopeRoleId          ?? DBNull.Value);
        AddParam(command, "@scope_asset_category_id", DbType.Int32,  (object?)query.ScopeAssetCategoryId ?? DBNull.Value);
        AddParam(command, "@event_type_code",         DbType.String, query.EventTypeCode, 60);

        var rows = new List<ScopeQuestionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new ScopeQuestionRow(
                ChecklistItemId:  Convert.ToInt64(reader["ChecklistItemId"]),
                ChecklistId:      Convert.ToInt64(reader["ChecklistId"]),
                SortOrder:        Convert.ToInt32(reader["SortOrder"]),
                QuestionText:     reader["QuestionText"]?.ToString() ?? "",
                ItemType:         reader["ItemType"]?.ToString() ?? "Manual",
                IsMandatory:      reader["IsMandatory"] is bool m && m,
                EvidenceRequired: reader["EvidenceRequired"] is bool e && e,
                ResponsibleRole:  reader["ResponsibleRole"] as string,
                Status:           reader["Status"]?.ToString() ?? "Active"));
        return new ScopeQuestionResult(rows);
    }

    public async Task<ScopeQuestionCommandResult> SaveScopeQuestionAsync(
        ScopeQuestionSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0 || string.IsNullOrWhiteSpace(request.EventTypeCode))
            return new ScopeQuestionCommandResult(false, null, "OrganizationId and EventTypeCode are required.");
        if (request.ScopeDimension is not (EventScopeDimensions.OrgRole or EventScopeDimensions.AssetCategory))
            return new ScopeQuestionCommandResult(false, null, "ScopeDimension must be ORG_ROLE or ASSET_CATEGORY.");
        if (string.IsNullOrWhiteSpace(request.QuestionText))
            return new ScopeQuestionCommandResult(false, null, "The checklist text is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_scope_question_save";

            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@scope_dimension",         DbType.String,  request.ScopeDimension, 40);
            AddParam(command, "@scope_role_id",           DbType.Int64,   (object?)request.ScopeRoleId          ?? DBNull.Value);
            AddParam(command, "@scope_asset_category_id", DbType.Int32,   (object?)request.ScopeAssetCategoryId ?? DBNull.Value);
            AddParam(command, "@event_type_code",         DbType.String,  request.EventTypeCode, 60);
            AddParam(command, "@checklist_item_id",       DbType.Int64,   (object?)request.ChecklistItemId      ?? DBNull.Value);
            AddParam(command, "@question_text",           DbType.String,  request.QuestionText, 500);
            AddParam(command, "@is_mandatory",            DbType.Boolean, request.IsMandatory);
            AddParam(command, "@evidence_required",       DbType.Boolean, request.EvidenceRequired);
            AddParam(command, "@responsible_role",        DbType.String,  (object?)request.ResponsibleRole      ?? DBNull.Value, 100);
            AddParam(command, "@sort_order",              DbType.Int32,   (object?)request.SortOrder            ?? DBNull.Value);
            AddParam(command, "@actor",                   DbType.String,  (object?)request.ActorEmployeeId?.ToString() ?? "api", 100);
            var idParam = AddOutParam(command, "@out_checklist_item_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is null || idParam.Value == DBNull.Value
                ? (long?)null : Convert.ToInt64(idParam.Value);
            return new ScopeQuestionCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            // 52400-52413 are this feature's own validation THROWs; their
            // message is written for the person filling the form.
            logger.LogWarning(ex, "SaveScopeQuestionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new ScopeQuestionCommandResult(false, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "SaveScopeQuestionAsync failed for org {OrganizationId} event {EventTypeCode}",
                request.OrganizationId, request.EventTypeCode);
            return new ScopeQuestionCommandResult(false, null, ex.Message);
        }
    }

    public async Task<ScopeQuestionCommandResult> DeleteScopeQuestionAsync(
        ScopeQuestionDeleteRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0 || request.ChecklistItemId <= 0)
            return new ScopeQuestionCommandResult(false, null, "OrganizationId and ChecklistItemId are required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_scope_question_delete";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@checklist_item_id", DbType.Int64,  request.ChecklistItemId);
            AddParam(command, "@actor",             DbType.String, (object?)request.ActorEmployeeId?.ToString() ?? "api", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new ScopeQuestionCommandResult(true, request.ChecklistItemId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DeleteScopeQuestionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new ScopeQuestionCommandResult(false, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DeleteScopeQuestionAsync failed for org {OrganizationId} item {ItemId}",
                request.OrganizationId, request.ChecklistItemId);
            return new ScopeQuestionCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Inbox / detail / trace
    // ==============================================================
    public async Task<EventChecklistInboxResult> ListInboxAsync(
        EventChecklistInboxQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_checklist_inbox_list";

        AddParam(command, "@organization_id",   DbType.Int64,   query.OrganizationId);
        AddParam(command, "@owner_employee_id", DbType.Int64,   (object?)query.OwnerEmployeeId ?? DBNull.Value);
        AddParam(command, "@subject_entity",    DbType.String,  (object?)query.SubjectEntity   ?? DBNull.Value, 60);
        AddParam(command, "@status_filter",     DbType.String,  (object?)query.StatusFilter    ?? DBNull.Value, 200);
        AddParam(command, "@overdue_only",      DbType.Boolean, query.OverdueOnly);

        var rows = new List<EventChecklistInboxRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add(MapInboxRow(reader));
        return new EventChecklistInboxResult(rows);
    }

    public async Task<EventInstanceDetailResult> GetInstanceDetailAsync(
        long organizationId, long eventInstanceId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_instance_detail_get";

        AddParam(command, "@organization_id",   DbType.Int64, organizationId);
        AddParam(command, "@event_instance_id", DbType.Int64, eventInstanceId);

        EventInstanceDetailHeader? header = null;
        var items = new List<EventInstanceDetailItem>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken)) header = MapDetailHeader(reader);
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) items.Add(MapDetailItem(reader));

        return new EventInstanceDetailResult(header, items);
    }

    public async Task<(bool Success, string? Error)> SaveObligationResultAsync(
        EventInstanceObligationSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0 || request.EventInstanceObligationId <= 0)
            return (false, "OrganizationId and EventInstanceObligationId are required.");
        // Mirrored client-side too, but the proc is the authority -- this only
        // saves a round trip and gives a cleaner message.
        if (request.ItemStatus == "NotApplicable" && string.IsNullOrWhiteSpace(request.NaJustification))
            return (false, "A justification is required to mark an obligation Not Applicable.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_instance_obligation_save";

            AddParam(command, "@organization_id",              DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_instance_obligation_id", DbType.Int64,  request.EventInstanceObligationId);
            AddParam(command, "@item_status",                  DbType.String, request.ItemStatus, 30);
            AddParam(command, "@evidence_url",                 DbType.String, (object?)request.EvidenceUrl     ?? DBNull.Value, 1000);
            AddParam(command, "@remarks",                      DbType.String, (object?)request.Remarks         ?? DBNull.Value);
            AddParam(command, "@na_justification",             DbType.String, (object?)request.NaJustification ?? DBNull.Value, 2000);
            AddParam(command, "@actor_employee_id",            DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return (true, null);
        }
        catch (SqlException ex)
        {
            // 67400-67407 are this feature's own validation THROWs -- surface
            // their message rather than a generic failure.
            logger.LogWarning(ex, "SaveObligationResultAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return (false, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "SaveObligationResultAsync failed for org {OrganizationId} row {RowId}",
                request.OrganizationId, request.EventInstanceObligationId);
            return (false, ex.Message);
        }
    }

    public async Task<EventResolutionTraceResult> ListResolutionTraceAsync(
        EventResolutionTraceQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_resolution_trace_list";

        AddParam(command, "@organization_id",   DbType.Int64,   query.OrganizationId);
        AddParam(command, "@subject_entity",    DbType.String,  (object?)query.SubjectEntity    ?? DBNull.Value, 60);
        AddParam(command, "@subject_record_id", DbType.Int64,   (object?)query.SubjectRecordId  ?? DBNull.Value);
        AddParam(command, "@event_instance_id", DbType.Int64,   (object?)query.EventInstanceId  ?? DBNull.Value);
        AddParam(command, "@gaps_only",         DbType.Boolean, query.GapsOnly);

        // The proc returns ONE result set whose shape depends on @gaps_only.
        var rows = new List<EventResolutionTraceRow>();
        var gaps = new List<EventResolutionGapRow>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (query.GapsOnly)
            while (await reader.ReadAsync(cancellationToken)) gaps.Add(MapGapRow(reader));
        else
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapTraceRow(reader));

        return new EventResolutionTraceResult(rows, gaps);
    }

    // ==============================================================
    // Infrastructure helpers -- identical to WorkflowService
    // ==============================================================
    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
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

    private static DbParameter AddOutParam(DbCommand command, string name, DbType type)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        p.Direction = ParameterDirection.Output;
        command.Parameters.Add(p);
        return p;
    }

    private static int ToInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);

    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    // ==============================================================
    // Mappers
    // ==============================================================
    private static EventScopeMappingRow MapScopeMapping(DbDataReader r) => new(
        ChecklistId:          Convert.ToInt64(r["ChecklistId"]),
        ChecklistCode:        r["ChecklistCode"]?.ToString() ?? "",
        ChecklistName:        r["ChecklistName"]?.ToString() ?? "",
        ChecklistVersion:     r["ChecklistVersion"]?.ToString() ?? "",
        EventDefinitionId:    Convert.ToInt64(r["EventDefinitionId"]),
        EventCode:            r["EventCode"]?.ToString() ?? "",
        EventName:            r["EventName"]?.ToString() ?? "",
        MappingId:            r["MappingId"] as long?,
        EntityTypeId:         r["EntityTypeId"] as long?,
        ScopeDimension:       r["ScopeDimension"] as string,
        ScopeRoleId:          r["ScopeRoleId"] as long?,
        ScopeAssetCategoryId: r["ScopeAssetCategoryId"] as int?,
        ReleaseId:            r["ReleaseId"] as long?,
        DefaultOwnerRoleId:   r["DefaultOwnerRoleId"] as long?,
        DefaultOwnerRoleName: r["DefaultOwnerRoleName"] as string,
        DefaultDuePeriodDays: r["DefaultDuePeriodDays"] as int?,
        MappingStatus:        r["MappingStatus"] as string,
        MappingState:         r["MappingState"]?.ToString() ?? "Unmapped",
        ActiveItemCount:      Convert.ToInt32(r["ActiveItemCount"]));

    private static EventObligationMappingRow MapObligationMapping(DbDataReader r) => new(
        // Migration 343: ObligationId is NULL on a custom-obligation row, so
        // this can no longer be Convert.ToInt64 (throws on DBNull). The three
        // new columns are read defensively via HasColumn, matching this
        // file's own established pattern (see ListObligationCoverageAsync's
        // ApplicableObligations/ExcludedObligations) so the API keeps working
        // against a database where 343 has not been applied yet.
        ObligationId:              r["ObligationId"] as long?,
        LocalPracticeObligationId: HasColumn(r, "LocalPracticeObligationId") ? r["LocalPracticeObligationId"] as long? : null,
        LocalInstanceObligationId: HasColumn(r, "LocalInstanceObligationId") ? r["LocalInstanceObligationId"] as long? : null,
        ObligationKind:            HasColumn(r, "ObligationKind") ? r["ObligationKind"] as string : null,
        ObligationLabel:          r["ObligationLabel"] as string,
        ObligationText:           r["ObligationText"] as string,
        PracticeId:               r["PracticeId"] as long?,
        PracticeCode:             r["PracticeCode"] as string,
        PracticeName:             r["PracticeName"] as string,
        RequirementCode:          r["RequirementCode"] as string,
        RequirementName:          r["RequirementName"] as string,
        EventTypeId:              Convert.ToInt64(r["EventTypeId"]),
        EventTypeCode:            r["EventTypeCode"] as string,
        EventTypeName:            r["EventTypeName"] as string,
        SubjectEntity:            r["SubjectEntity"] as string,
        ReleaseId:                r["ReleaseId"] as long?,
        IsSubscribed:             r["IsSubscribed"] is bool s && s,
        PracticeApplicability:    r["PracticeApplicability"] as string,
        RequirementApplicability: r["RequirementApplicability"] as string,
        ApplicabilityId:          r["ApplicabilityId"] as long?,
        IsApplicable:             r["IsApplicable"] as bool?,
        Rationale:                r["Rationale"] as string,
        OwnerRoleId:              r["OwnerRoleId"] as long?,
        OwnerRoleName:            r["OwnerRoleName"] as string,
        DueDays:                  r["DueDays"] as int?,
        MappingStatus:            r["MappingStatus"] as string,
        MappingState:             r["MappingState"]?.ToString() ?? "Unmapped");

    private static EventChecklistInboxRow MapInboxRow(DbDataReader r) => new(
        EventInstanceId:        Convert.ToInt64(r["EventInstanceId"]),
        EventCode:              r["EventCode"]?.ToString() ?? "",
        EventName:              r["EventName"]?.ToString() ?? "",
        SubjectEntity:          r["SubjectEntity"] as string,
        SubjectRecordId:        r["SubjectRecordId"] as long?,
        SubjectLabel:           r["SubjectLabel"] as string,
        ScopeRoleId:            r["ScopeRoleId"] as long?,
        ScopeRoleName:          r["ScopeRoleName"] as string,
        ScopeAssetCategoryId:   r["ScopeAssetCategoryId"] as int?,
        ScopeAssetCategoryName: r["ScopeAssetCategoryName"] as string,
        ChecklistId:            r["ChecklistId"] as long?,
        ChecklistName:          r["ChecklistName"] as string,
        OwnerEmployeeId:        r["OwnerEmployeeId"] as long?,
        OwnerEmployeeName:      r["OwnerEmployeeName"] as string,
        EffectiveDate:          r["EffectiveDate"] as DateTime?,
        DueDate:                r["DueDate"] as DateTime?,
        InstanceStatus:         r["InstanceStatus"]?.ToString() ?? "Pending",
        IsOverdue:              r["IsOverdue"] is bool o && o,
        DaysOverdue:            r["DaysOverdue"] as int?,
        ItemCount:              Convert.ToInt32(r["ItemCount"]),
        ItemsDone:              Convert.ToInt32(r["ItemsDone"]));

    private static EventInstanceDetailHeader MapDetailHeader(DbDataReader r) => new(
        EventInstanceId:        Convert.ToInt64(r["EventInstanceId"]),
        EventCode:              r["EventCode"]?.ToString() ?? "",
        EventName:              r["EventName"]?.ToString() ?? "",
        SubjectEntity:          r["SubjectEntity"] as string,
        SubjectRecordId:        r["SubjectRecordId"] as long?,
        SubjectLabel:           r["SubjectLabel"] as string,
        ScopeRoleId:            r["ScopeRoleId"] as long?,
        ScopeRoleName:          r["ScopeRoleName"] as string,
        ScopeAssetCategoryId:   r["ScopeAssetCategoryId"] as int?,
        ScopeAssetCategoryName: r["ScopeAssetCategoryName"] as string,
        ReleaseId:              r["ReleaseId"] as long?,
        SourceMappingId:        r["SourceMappingId"] as long?,
        ChecklistId:            r["ChecklistId"] as long?,
        ChecklistName:          r["ChecklistName"] as string,
        ChecklistVersion:       r["ChecklistVersion"] as string,
        OwnerEmployeeId:        r["OwnerEmployeeId"] as long?,
        OwnerEmployeeName:      r["OwnerEmployeeName"] as string,
        EffectiveDate:          r["EffectiveDate"] as DateTime?,
        DueDate:                r["DueDate"] as DateTime?,
        InstanceStatus:         r["InstanceStatus"]?.ToString() ?? "Pending",
        CompletedDt:            r["CompletedDt"] as DateTime?,
        Comments:               r["Comments"] as string);

    private static EventInstanceDetailItem MapDetailItem(DbDataReader r) => new(
        ItemOrigin:          r["ItemOrigin"]?.ToString() ?? EventItemOrigins.Checklist,
        ItemId:              Convert.ToInt64(r["ItemId"]),
        SourceId:            Convert.ToInt64(r["SourceId"]),
        ItemSequence:        Convert.ToInt32(r["ItemSequence"]),
        ItemText:            r["ItemText"]?.ToString() ?? "",
        ItemType:            r["ItemType"]?.ToString() ?? "Manual",
        IsMandatory:         r["IsMandatory"] is bool m && m,
        EvidenceRequired:    r["EvidenceRequired"] is bool e && e,
        AttachmentRequired:  r["AttachmentRequired"] is bool a && a,
        ApprovalRequired:    r["ApprovalRequired"] is bool p && p,
        ResponsibleRole:     r["ResponsibleRole"] as string,
        ItemStatus:          r["ItemStatus"]?.ToString() ?? "Pending",
        EvidenceUrl:         r["EvidenceUrl"] as string,
        Remarks:             r["Remarks"] as string,
        NaJustification:     r["NaJustification"] as string,
        CompletedBy:         r["CompletedBy"] as string,
        CompletedDt:         r["CompletedDt"] as DateTime?);

    private static EventResolutionTraceRow MapTraceRow(DbDataReader r) => new(
        ResolutionId:           Convert.ToInt64(r["ResolutionId"]),
        EventDefinitionId:      Convert.ToInt64(r["EventDefinitionId"]),
        EventCode:              r["EventCode"]?.ToString() ?? "",
        EventName:              r["EventName"]?.ToString() ?? "",
        SubjectEntity:          r["SubjectEntity"]?.ToString() ?? "",
        SubjectRecordId:        Convert.ToInt64(r["SubjectRecordId"]),
        SubjectLabel:           r["SubjectLabel"] as string,
        EffectiveDate:          r["EffectiveDate"] as DateTime?,
        MappingId:              r["MappingId"] as long?,
        ChecklistId:            r["ChecklistId"] as long?,
        ChecklistName:          r["ChecklistName"] as string,
        ScopeDimension:         r["ScopeDimension"] as string,
        ScopeRoleId:            r["ScopeRoleId"] as long?,
        ScopeRoleName:          r["ScopeRoleName"] as string,
        ScopeAssetCategoryId:   r["ScopeAssetCategoryId"] as int?,
        ScopeAssetCategoryName: r["ScopeAssetCategoryName"] as string,
        ReleaseId:              r["ReleaseId"] as long?,
        Decision:               r["Decision"]?.ToString() ?? "",
        ReasonCode:             r["ReasonCode"]?.ToString() ?? "",
        ReasonDetail:           r["ReasonDetail"] as string,
        EventInstanceId:        r["EventInstanceId"] as long?,
        EnteredBy:              r["EnteredBy"]?.ToString() ?? "",
        EnteredDt:              Convert.ToDateTime(r["EnteredDt"]));

    private static EventResolutionGapRow MapGapRow(DbDataReader r) => new(
        ReasonCode:             r["ReasonCode"]?.ToString() ?? "",
        EventDefinitionId:      Convert.ToInt64(r["EventDefinitionId"]),
        EventCode:              r["EventCode"]?.ToString() ?? "",
        SubjectEntity:          r["SubjectEntity"]?.ToString() ?? "",
        ScopeRoleId:            r["ScopeRoleId"] as long?,
        ScopeRoleName:          r["ScopeRoleName"] as string,
        ScopeAssetCategoryId:   r["ScopeAssetCategoryId"] as int?,
        ScopeAssetCategoryName: r["ScopeAssetCategoryName"] as string,
        OccurrenceCount:        Convert.ToInt32(r["OccurrenceCount"]),
        FirstSeenDt:            Convert.ToDateTime(r["FirstSeenDt"]),
        LastSeenDt:             Convert.ToDateTime(r["LastSeenDt"]));
}
