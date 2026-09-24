// =====================================================================
// PracticeConfigureService
//
// Facade over the migration-139 procedures:
//   grac_practice.sp_practice_detail_get
//   grac_practice.sp_practice_team_option_list
//   grac_practice.sp_practice_instance_configure
//
// Same shape as EventScopeService: single interface, DbType-typed
// AddParam, connection string via SqlConnectionStringResolver, every
// error caught and returned rather than thrown at the controller.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IPracticeConfigureService
{
    /// <summary>
    /// Either identifier resolves the practice. The Organization Practices
    /// grid is one row per organization_requirement and does not reliably
    /// carry a practice id, so the page can hand over whichever it has.
    /// </summary>
    Task<PracticeDetailResult>     GetPracticeDetailAsync(long? practiceId, long? organizationId, long? organizationRequirementId, CancellationToken cancellationToken);
    Task<PracticeTeamOptionResult> ListTeamOptionsAsync(long organizationId, long? practiceId, CancellationToken cancellationToken);
    Task<PracticeConfigureResult>  ConfigureInstancesAsync(PracticeConfigureRequest request, CancellationToken cancellationToken);
}

public sealed class PracticeConfigureService(
    IConfiguration configuration,
    ILogger<PracticeConfigureService> logger) : IPracticeConfigureService
{
    public async Task<PracticeDetailResult> GetPracticeDetailAsync(
        long? practiceId, long? organizationId, long? organizationRequirementId,
        CancellationToken cancellationToken)
    {
        if (practiceId is not > 0 && organizationRequirementId is not > 0)
            return new PracticeDetailResult(false, null,
                "Either PracticeId or OrganizationRequirementId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_detail_get";

            AddParam(command, "@practice_id",                 DbType.Int64,
                     practiceId is > 0 ? practiceId : DBNull.Value);
            AddParam(command, "@organization_id",             DbType.Int64, (object?)organizationId ?? DBNull.Value);
            AddParam(command, "@organization_requirement_id", DbType.Int64,
                     organizationRequirementId is > 0 ? organizationRequirementId : DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new PracticeDetailResult(false, null, "Practice not found.");

            return new PracticeDetailResult(true, new PracticeDetail(
                PracticeId:                Convert.ToInt64(reader["PracticeId"]),
                OrganizationId:            Convert.ToInt64(reader["OrganizationId"]),
                OrganizationName:          reader["OrganizationName"]?.ToString() ?? "",
                PracticeCode:              reader["PracticeCode"]?.ToString() ?? "",
                PracticeName:              reader["PracticeName"]?.ToString() ?? "",
                Description:               reader["Description"] as string,
                OriginType:                reader["OriginType"] as string,
                PracticeOwner:             reader["PracticeOwner"] as string,
                PracticeOwnerId:           reader["PracticeOwnerId"] as long?,
                ApplicabilityStatus:       reader["ApplicabilityStatus"] as string,
                ExclusionJustification:    reader["ExclusionJustification"] as string,
                Status:                    reader["Status"]?.ToString() ?? "",
                OrganizationRequirementId: reader["OrganizationRequirementId"] as long?,
                RequirementCode:           reader["RequirementCode"] as string,
                RequirementName:           reader["RequirementName"] as string,
                ActiveInstanceCount:       ToInt(reader["ActiveInstanceCount"]),
                // Migration 301. Read through HasColumn because the app and the
                // database deploy separately: against a database still on the
                // 218 procedure the column is absent, and reader["..."] would
                // throw IndexOutOfRange, land in the catch below, and answer the
                // page with "could not be loaded". An unapplied migration must
                // cost the Frameworks row, not the whole Practice View.
                MappedFrameworksJson:      HasColumn(reader, "MappedFrameworksJson")
                                               ? reader["MappedFrameworksJson"] as string
                                               : null,
                // Migration 303, read through HasColumn for the same reason as
                // the line above: against a pre-303 database the column is
                // absent and reader["..."] would throw, turning a missing
                // header row into "this practice could not be loaded".
                PracticeImplementationStatus: HasColumn(reader, "PracticeImplementationStatus")
                                               ? reader["PracticeImplementationStatus"] as string
                                               : null,
                // Migration 316, same HasColumn guard and the same reason: a
                // database still on 303 does not return this column at all.
                MappedSourceStatementsJson: HasColumn(reader, "MappedSourceStatementsJson")
                                               ? reader["MappedSourceStatementsJson"] as string
                                               : null));
        }
        catch (Exception ex)
        {
            logger.LogError(ex,
                "sp_practice_detail_get failed for practice {PracticeId} / requirement {RequirementId}.",
                practiceId, organizationRequirementId);
            return new PracticeDetailResult(false, null, ex.Message);
        }
    }

    public async Task<PracticeTeamOptionResult> ListTeamOptionsAsync(
        long organizationId, long? practiceId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0)
            return new PracticeTeamOptionResult(false, [], "OrganizationId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_team_option_list";

            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@practice_id",     DbType.Int64, (object?)practiceId ?? DBNull.Value);

            var rows = new List<PracticeTeamOption>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new PracticeTeamOption(
                    TeamId:               Convert.ToInt64(reader["TeamId"]),
                    TeamName:             reader["TeamName"]?.ToString() ?? "",
                    TeamManagerId:        reader["TeamManagerId"] as long?,
                    TeamManagerName:      reader["TeamManagerName"] as string,
                    HasManager:           reader["HasManager"] is bool hm && hm,
                    DepartmentName:       reader["DepartmentName"] as string,
                    DepartmentId:         reader["DepartmentId"] as long?,
                    AlreadyConfigured:    reader["AlreadyConfigured"] is bool ac && ac,
                    ExistingInstanceCode: reader["ExistingInstanceCode"] as string));

            return new PracticeTeamOptionResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_practice_team_option_list failed for organization {OrganizationId}.", organizationId);
            return new PracticeTeamOptionResult(false, [], ex.Message);
        }
    }

    public async Task<PracticeConfigureResult> ConfigureInstancesAsync(
        PracticeConfigureRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.OrganizationId <= 0 || request.PracticeId <= 0)
            return new PracticeConfigureResult(false, [], "OrganizationId and PracticeId are required.");

        // Distinct + positive: the procedure keys its work table on TeamId,
        // so a duplicated id would otherwise be a primary key violation
        // rather than the harmless no-op the caller intends.
        var teamIds = (request.TeamIds ?? []).Where(id => id > 0).Distinct().ToArray();
        if (teamIds.Length == 0)
            return new PracticeConfigureResult(false, [], "Select at least one team.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_instance_configure";
            // One instance per team, each with a dependency and a resolution;
            // a large selection is several writes per team.
            command.CommandTimeout = 120;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@practice_id",     DbType.Int64,  request.PracticeId);
            AddParam(command, "@team_ids_json",   DbType.String, JsonSerializer.Serialize(teamIds));
            AddParam(command, "@actor",           DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            var outcomes = new List<PracticeConfigureOutcome>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                outcomes.Add(new PracticeConfigureOutcome(
                    TeamId:             Convert.ToInt64(reader["TeamId"]),
                    TeamName:           reader["TeamName"]?.ToString() ?? "",
                    Outcome:            reader["Outcome"]?.ToString() ?? "",
                    PracticeInstanceId: reader["PracticeInstanceId"] as long?,
                    InstanceCode:       reader["InstanceCode"] as string,
                    InstanceName:       reader["InstanceName"] as string,
                    OwnerName:          reader["OwnerName"] as string,
                    HasOwner:           reader["HasOwner"] is bool ho && ho));

            return new PracticeConfigureResult(true, outcomes);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_practice_instance_configure failed for practice {PracticeId}.", request.PracticeId);
            return new PracticeConfigureResult(false, [], ex.Message);
        }
    }

    // ==============================================================
    // Infrastructure helpers -- identical to EventScopeService
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

    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }
}
