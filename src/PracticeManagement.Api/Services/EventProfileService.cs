// =====================================================================
// EventProfileService
//
// Facade over the migration-330 procedures:
//   sp_event_profile_dimension_list
//   sp_event_profile_dimension_values
//   sp_event_profile_list
//   sp_event_profile_get
//   sp_event_profile_save
//   sp_event_profile_set_status
//   sp_event_profile_delete
//   sp_event_profile_preview_members
//
// Its own file rather than more methods on the 1000-line
// EventScopeService, for that file's own stated reason: so it can be
// reviewed and wired independently. Registered via
// Infrastructure/EventProfileServiceRegistration.cs.
//
// Follows EventScopeService exactly:
//   * Single interface, single implementation
//   * DbType-typed AddParam helper
//   * OpenAsync resolves the connection string via SqlConnectionStringResolver
//   * All errors caught, logged, returned as (Success=false, Error)
//
// The criteria tree is sent to sp_event_profile_save as JSON, matching
// sp_org_assurance_scope_save (074). A table-valued parameter would need
// two user-defined types for one nested shape, and every other tree in
// this module already travels as JSON.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IEventProfileService
{
    Task<EventProfileDimensionResult>      ListDimensionsAsync(string? subjectEntity, CancellationToken cancellationToken);
    Task<EventProfileDimensionValueResult> ListDimensionValuesAsync(long organizationId, string dimensionCode, string? search, int pageSize, CancellationToken cancellationToken);

    Task<EventProfileListResult>   ListAsync(EventProfileListQuery query, CancellationToken cancellationToken);
    Task<EventProfileDetail?>      GetAsync(long organizationId, long profileId, CancellationToken cancellationToken);
    Task<EventProfileCommandResult> SaveAsync(EventProfileSaveRequest request, CancellationToken cancellationToken);
    Task<EventProfileCommandResult> SetStatusAsync(long organizationId, long profileId, string status, long? actorEmployeeId, CancellationToken cancellationToken);
    Task<EventProfileCommandResult> DeleteAsync(long organizationId, long profileId, long? actorEmployeeId, CancellationToken cancellationToken);

    Task<EventProfilePreviewResult> PreviewMembersAsync(long organizationId, long? profileId, int sampleSize, CancellationToken cancellationToken);
}

public sealed class EventProfileService(IConfiguration configuration, ILogger<EventProfileService> logger) : IEventProfileService
{
    // ==============================================================
    // Criterion dimensions
    // ==============================================================
    public async Task<EventProfileDimensionResult> ListDimensionsAsync(
        string? subjectEntity, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_profile_dimension_list";

        AddParam(command, "@subject_entity", DbType.String,
                 (object?)(subjectEntity ?? EventSubjectEntities.Employee), 60);

        var rows = new List<EventProfileDimensionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new EventProfileDimensionRow(
                DimensionId:    Convert.ToInt32(reader["DimensionId"]),
                DimensionCode:  reader["DimensionCode"]?.ToString() ?? "",
                DimensionName:  reader["DimensionName"]?.ToString() ?? "",
                SubjectEntity:  reader["SubjectEntity"]?.ToString() ?? EventSubjectEntities.Employee,
                ValueKind:      reader["ValueKind"]?.ToString() ?? "ID",
                IsMultiValued:  reader["IsMultiValued"] is bool m && m,
                HasValueSource: reader["HasValueSource"] is bool h && h,
                DisplayOrder:   Convert.ToInt32(reader["DisplayOrder"])));

        return new EventProfileDimensionResult(rows);
    }

    public async Task<EventProfileDimensionValueResult> ListDimensionValuesAsync(
        long organizationId, string dimensionCode, string? search, int pageSize,
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_profile_dimension_values";

        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@dimension_code",  DbType.String, dimensionCode, 40);
        AddParam(command, "@search",          DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(command, "@page_size",       DbType.Int32,  pageSize <= 0 ? 200 : pageSize);

        var rows = new List<EventProfileDimensionValueRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new EventProfileDimensionValueRow(
                Id:        reader["Id"] as long?,
                TextValue: reader["TextValue"] as string,
                Name:      reader["Name"] as string));

        return new EventProfileDimensionValueResult(rows);
    }

    // ==============================================================
    // Grid
    // ==============================================================
    public async Task<EventProfileListResult> ListAsync(
        EventProfileListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        var page = query.PageNumber <= 0 ? 1  : query.PageNumber;
        var size = query.PageSize   <= 0 ? 25 : query.PageSize;

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_profile_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@subject_entity",  DbType.String, (object?)(query.SubjectEntity ?? EventSubjectEntities.Employee), 60);
        AddParam(command, "@status",          DbType.String, (object?)query.Status ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page_number",     DbType.Int32,  page);
        AddParam(command, "@page_size",       DbType.Int32,  size);

        var rows  = new List<EventProfileRow>();
        var total = 0;

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            // TotalRows is COUNT(*) OVER (), identical on every row --
            // docs/grid-and-pagination-standard.md. Read once; a grid that
            // guesses from rows.Count is wrong on the exact boundary where
            // the last page is full.
            if (rows.Count == 0) total = ToInt(reader["TotalRows"]);

            rows.Add(new EventProfileRow(
                ProfileId:                 Convert.ToInt64(reader["ProfileId"]),
                OrganizationId:            Convert.ToInt64(reader["OrganizationId"]),
                ProfileCode:               reader["ProfileCode"]?.ToString() ?? "",
                ProfileName:               reader["ProfileName"]?.ToString() ?? "",
                Description:               reader["Description"] as string,
                SubjectEntity:             reader["SubjectEntity"]?.ToString() ?? EventSubjectEntities.Employee,
                Status:                    reader["Status"]?.ToString() ?? "Active",
                CriteriaSummary:           reader["CriteriaSummary"] as string,
                MappedObligationCount:     ToInt(reader["MappedObligationCount"]),
                ApplicableObligationCount: ToInt(reader["ApplicableObligationCount"]),
                CriteriaCount:             ToInt(reader["CriteriaCount"]),
                EnteredBy:                 reader["EnteredBy"] as string,
                EnteredDate:               reader["EnteredDate"] as DateTime?,
                UpdatedBy:                 reader["UpdatedBy"] as string,
                UpdatedDate:               reader["UpdatedDate"] as DateTime?));
        }

        return new EventProfileListResult(rows, total, page, size);
    }

    // ==============================================================
    // One profile
    // ==============================================================
    public async Task<EventProfileDetail?> GetAsync(
        long organizationId, long profileId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_profile_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@profile_id",      DbType.Int64, profileId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        if (!await reader.ReadAsync(cancellationToken)) return null;

        var code        = reader["ProfileCode"]?.ToString() ?? "";
        var name        = reader["ProfileName"]?.ToString() ?? "";
        var description = reader["Description"] as string;
        var subject     = reader["SubjectEntity"]?.ToString() ?? EventSubjectEntities.Employee;
        var status      = reader["Status"]?.ToString() ?? "Active";
        var enteredBy   = reader["EnteredBy"] as string;
        var enteredDt   = reader["EnteredDate"] as DateTime?;
        var updatedBy   = reader["UpdatedBy"] as string;
        var updatedDt   = reader["UpdatedDate"] as DateTime?;

        // Second result set: one row per criterion VALUE, with the criterion
        // repeated. A match_all criterion returns a single row with a NULL
        // value -- that is how "All" stays distinguishable from "not
        // configured", so the grouping below must keep it.
        var criteria = new List<EventProfileCriteria>();

        if (await reader.NextResultAsync(cancellationToken))
        {
            var byCriteria = new Dictionary<long, (EventProfileCriteria Header, List<EventProfileCriteriaValue> Values)>();
            var order      = new List<long>();

            while (await reader.ReadAsync(cancellationToken))
            {
                var criteriaId = Convert.ToInt64(reader["CriteriaId"]);

                if (!byCriteria.ContainsKey(criteriaId))
                {
                    byCriteria[criteriaId] = (new EventProfileCriteria(
                        CriteriaId:    criteriaId,
                        DimensionId:   Convert.ToInt32(reader["DimensionId"]),
                        DimensionCode: reader["DimensionCode"]?.ToString() ?? "",
                        DimensionName: reader["DimensionName"] as string,
                        ValueKind:     reader["ValueKind"] as string,
                        DisplayOrder:  ToInt(reader["DisplayOrder"]),
                        MatchAll:      reader["MatchAll"] is bool ma && ma,
                        Values:        Array.Empty<EventProfileCriteriaValue>()),
                        new List<EventProfileCriteriaValue>());
                    order.Add(criteriaId);
                }

                if (reader["CriteriaValueId"] is not null && reader["CriteriaValueId"] != DBNull.Value)
                    byCriteria[criteriaId].Values.Add(new EventProfileCriteriaValue(
                        CriteriaValueId: reader["CriteriaValueId"] as long?,
                        ValueId:         reader["ValueId"] as long?,
                        ValueText:       reader["ValueText"] as string,
                        ValueLabel:      reader["ValueLabel"] as string));
            }

            foreach (var id in order)
            {
                var (header, values) = byCriteria[id];
                criteria.Add(header with { Values = values });
            }
        }

        return new EventProfileDetail(
            ProfileId:      profileId,
            OrganizationId: organizationId,
            ProfileCode:    code,
            ProfileName:    name,
            Description:    description,
            SubjectEntity:  subject,
            Status:         status,
            EnteredBy:      enteredBy,
            EnteredDate:    enteredDt,
            UpdatedBy:      updatedBy,
            UpdatedDate:    updatedDt,
            Criteria:       criteria);
    }

    // ==============================================================
    // Save
    // ==============================================================
    public async Task<EventProfileCommandResult> SaveAsync(
        EventProfileSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0)
            return new EventProfileCommandResult(false, null, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.ProfileName))
            return new EventProfileCommandResult(false, null, null, "A profile name is required.");
        // Checked here as well as in the procedure so the screen gets a
        // sentence rather than a THROW number, and so a malformed payload
        // never opens a transaction.
        if (request.Criteria is null || request.Criteria.Count == 0)
            return new EventProfileCommandResult(false, null, null,
                "At least one criterion is required. A profile with no criteria cannot be told apart from an unfinished one.");

        var emptyConstrained = request.Criteria
            .FirstOrDefault(c => !c.MatchAll && (c.Values is null || c.Values.Count == 0));
        if (emptyConstrained is not null)
            return new EventProfileCommandResult(false, null, null,
                $"Criterion \"{emptyConstrained.DimensionCode}\" is not set to All, so it needs at least one value.");

        var payload = JsonSerializer.Serialize(new
        {
            profileId     = request.ProfileId ?? 0,
            profileCode   = request.ProfileCode,
            profileName   = request.ProfileName,
            description   = request.Description,
            subjectEntity = request.SubjectEntity ?? EventSubjectEntities.Employee,
            status        = request.Status ?? "Active",
            criteria      = request.Criteria.Select(c => new
            {
                dimensionCode = c.DimensionCode,
                matchAll      = c.MatchAll,
                // Values are dropped for a match_all criterion by the
                // procedure too; sending none keeps the payload honest
                // about what was actually chosen.
                values = c.MatchAll || c.Values is null
                    ? Array.Empty<object>()
                    : c.Values.Select(v => new
                      {
                          valueId    = v.ValueId,
                          valueText  = v.ValueText,
                          valueLabel = v.ValueLabel
                      }).Cast<object>().ToArray()
            })
        });

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_profile_save";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@profile_json",    DbType.String, payload);
            AddParam(command, "@actor",           DbType.String,
                     (object?)(request.ActorEmployeeId?.ToString() ?? "api"), 100);
            var idParam = AddOutParam(command, "@out_profile_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);

            var id = idParam.Value is null || idParam.Value == DBNull.Value
                ? (long?)null : Convert.ToInt64(idParam.Value);
            return new EventProfileCommandResult(true, id, request.ProfileCode);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "EventProfileService.SaveAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EventProfileService.SaveAsync failed for org {OrganizationId}", request.OrganizationId);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
    }

    // ==============================================================
    // Activate / Deactivate
    // ==============================================================
    public async Task<EventProfileCommandResult> SetStatusAsync(
        long organizationId, long profileId, string status, long? actorEmployeeId,
        CancellationToken cancellationToken)
    {
        if (status is not ("Active" or "Inactive"))
            return new EventProfileCommandResult(false, null, null, "Status must be Active or Inactive.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_profile_set_status";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@profile_id",      DbType.Int64,  profileId);
            AddParam(command, "@status",          DbType.String, status, 30);
            AddParam(command, "@actor",           DbType.String,
                     (object?)(actorEmployeeId?.ToString() ?? "api"), 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventProfileCommandResult(true, profileId, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "EventProfileService.SetStatusAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EventProfileService.SetStatusAsync failed for profile {ProfileId}", profileId);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
    }

    // ==============================================================
    // Delete -- the procedure refuses once the profile has been used.
    // ==============================================================
    public async Task<EventProfileCommandResult> DeleteAsync(
        long organizationId, long profileId, long? actorEmployeeId,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_profile_delete";

            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@profile_id",      DbType.Int64, profileId);
            AddParam(command, "@actor",           DbType.String,
                     (object?)(actorEmployeeId?.ToString() ?? "api"), 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventProfileCommandResult(true, profileId, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "EventProfileService.DeleteAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EventProfileService.DeleteAsync failed for profile {ProfileId}", profileId);
            return new EventProfileCommandResult(false, null, null, ex.Message);
        }
    }

    // ==============================================================
    // Preview
    // ==============================================================
    public async Task<EventProfilePreviewResult> PreviewMembersAsync(
        long organizationId, long? profileId, int sampleSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_profile_preview_members";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@profile_id",      DbType.Int64, (object?)profileId ?? DBNull.Value);
        AddParam(command, "@sample_size",     DbType.Int32, sampleSize <= 0 ? 10 : sampleSize);

        var matched = 0;
        var total   = 0;
        var sample  = new List<EventProfileMemberRow>();

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        if (await reader.ReadAsync(cancellationToken))
        {
            matched = ToInt(reader["MatchedCount"]);
            total   = ToInt(reader["TotalActiveEmployees"]);
        }

        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                sample.Add(new EventProfileMemberRow(
                    EmployeeId:   Convert.ToInt64(reader["EmployeeId"]),
                    EmployeeCode: reader["EmployeeCode"] as string,
                    EmployeeName: reader["EmployeeName"] as string,
                    Designation:  reader["Designation"] as string));

        return new EventProfilePreviewResult(matched, total, sample);
    }

    // ==============================================================
    // Infrastructure -- identical to EventScopeService's helpers.
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
}
