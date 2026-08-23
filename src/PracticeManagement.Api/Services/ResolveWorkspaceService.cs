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
    Task<ResolveCommandResult>         SaveFrequencyAsync(ResolveFrequencySaveRequest request, long? callerEmployeeId, bool isAdmin, CancellationToken cancellationToken);
    Task<ResolveEvidenceResult>        ListEvidenceAsync(long practiceInstanceId, long? obligationId, CancellationToken cancellationToken);
    Task<ResolveCommandResult>         SaveEvidenceAsync(ResolveEvidenceSaveRequest request, CancellationToken cancellationToken);
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

            var rows = new List<ResolveInstanceRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
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

            return new ResolveInstanceResult(true, rows);
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
                ExecutionFrequency:   reader["ExecutionFrequency"] as string,
                AssuranceFrequency:   reader["AssuranceFrequency"] as string,
                AssuranceMode:        reader["AssuranceMode"] as string,
                Criticality:          reader["Criticality"] as string,
                ImplementationStatus: reader["ImplementationStatus"] as string,
                Status:               reader["Status"] as string));
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
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_resolve_obligation_list";

            AddParam(command, "@practice_instance_id", DbType.Int64,   practiceInstanceId);
            AddParam(command, "@include_unsubscribed", DbType.Boolean, includeUnsubscribed);

            var rows = new List<ResolveObligationRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new ResolveObligationRow(
                    ObligationId:                Convert.ToInt64(reader["ObligationId"]),
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
                    Responsibility:              reader["Responsibility"] as string,
                    ApprovalAuthority:           reader["ApprovalAuthority"] as string,
                    RetentionPeriod:             reader["RetentionPeriod"] as string,
                    Remarks:                     reader["Remarks"] as string,
                    AdoptedBy:                   reader["AdoptedBy"] as string,
                    AdoptedDt:                   reader["AdoptedDt"] as DateTime?,
                    PublishedEvidenceCount:      ToInt(reader["PublishedEvidenceCount"]),
                    ResolvedEvidenceCount:       ToInt(reader["ResolvedEvidenceCount"])));

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
                remarks              = d.Remarks
            }));

            AddParam(command, "@practice_instance_id", DbType.Int64,  request.PracticeInstanceId);
            AddParam(command, "@payload_json",         DbType.String, payload);
            AddParam(command, "@actor",                DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            var outcomes = new List<ResolveObligationOutcome>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                outcomes.Add(new ResolveObligationOutcome(
                    ObligationId:          Convert.ToInt64(reader["ObligationId"]),
                    ObligationName:        reader["ObligationName"] as string,
                    Outcome:               reader["Outcome"]?.ToString() ?? "",
                    OrganizationModified:  reader["OrganizationModified"] is bool om && om,
                    NotSubscribed:         reader["NotSubscribed"] is bool ns && ns,
                    EvidenceRows:          ToInt(reader["EvidenceRows"]),
                    UnmappedEvidenceTypes: ToInt(reader["UnmappedEvidenceTypes"])));

            return new ResolveObligationAdoptResult(true, outcomes);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_obligation_adopt failed for instance {InstanceId}.", request.PracticeInstanceId);
            return new ResolveObligationAdoptResult(false, [], ex.Message);
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

    // ==============================================================
    // Instance frequency
    // ==============================================================
    public async Task<ResolveCommandResult> SaveFrequencyAsync(
        ResolveFrequencySaveRequest request, long? callerEmployeeId, bool isAdmin,
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
            command.CommandText = "grac_practice.sp_resolve_instance_frequency_save";

            AddParam(command, "@practice_instance_id",   DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@execution_frequency_id", DbType.Int32,   (object?)request.ExecutionFrequencyId ?? DBNull.Value);
            AddParam(command, "@assurance_frequency_id", DbType.Int32,   (object?)request.AssuranceFrequencyId ?? DBNull.Value);
            AddParam(command, "@caller_employee_id",     DbType.Int64,   callerEmployeeId is > 0 ? callerEmployeeId : DBNull.Value);
            AddParam(command, "@is_admin",               DbType.Boolean, isAdmin);
            AddParam(command, "@actor",                  DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Frequency saved.");

            var exec  = reader["ExecutionFrequency"] as string;
            var assur = reader["AssuranceFrequency"] as string;
            return new ResolveCommandResult(true,
                $"Saved. Execution {exec ?? "not set"}, assurance {assur ?? "not set"}.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_instance_frequency_save failed for instance {InstanceId}.",
                request.PracticeInstanceId);
            return new ResolveCommandResult(false, null, ex.Message);
        }
    }

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
                    EvidenceTypeId:          ToInt(reader["EvidenceTypeId"]),
                    EvidenceType:            reader["EvidenceType"] as string,
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
                    IsResolved:              reader["IsResolved"] is bool r && r));

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
            AddParam(command, "@actor",                   DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new ResolveCommandResult(true, "Evidence saved.");

            var resolved = reader["IsResolved"] is bool r && r;
            var onInstance = ToInt(reader["ResolvedOnInstance"]);
            return new ResolveCommandResult(true,
                resolved
                    ? $"Evidence resolved; {onInstance} resolved on this instance."
                    : "Saved. A location and a locator are both needed before it counts as resolved.");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_resolve_evidence_save failed for evidence {EvidenceId}.", request.EvidenceId);
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

    private static int ToInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);
}
