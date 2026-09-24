// =====================================================================
// PracticeObligationService
//
// Facade over the migration-307 procedures:
//   sp_practice_obligation_list
//   sp_practice_obligation_save     (fans out inline)
//   sp_practice_obligation_fan_out  (reconcile)
//
// Same shape as ResolveWorkspaceService / PracticeConfigureService:
// single interface, DbType-typed AddParam, connection via
// SqlConnectionStringResolver, every error caught and returned rather
// than thrown at the controller.
//
// The infrastructure helpers at the bottom are the sibling services'
// helpers, copied as they are throughout this project -- four small
// static methods per service, in exchange for no base class every one of
// them would have to agree on.
// =====================================================================
using System.Data;
using System.Data.Common;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IPracticeObligationService
{
    Task<PracticeObligationListResult> ListAsync(
        long practiceId, long? organizationId, bool includeRetired, CancellationToken cancellationToken);

    Task<PracticeObligationSaveResult> SaveAsync(
        PracticeObligationSaveRequest request, CancellationToken cancellationToken);

    /// <summary>
    /// Brings one instance (or every instance of a practice) in line with
    /// the practice's definitions. Idempotent, so it is safe on every
    /// load -- which is how an instance created after a definition
    /// existed picks its copies up. Migration 304 established that a read
    /// that repairs is preferable to asking the operator to press Save.
    /// </summary>
    Task<PracticeObligationFanOutResult> FanOutAsync(
        long? practiceId, long? practiceObligationId, long? practiceInstanceId,
        string? actor, CancellationToken cancellationToken);
}

public sealed class PracticeObligationService(
    IConfiguration configuration,
    ILogger<PracticeObligationService> logger) : IPracticeObligationService
{
    // ==============================================================
    // List
    // ==============================================================
    public async Task<PracticeObligationListResult> ListAsync(
        long practiceId, long? organizationId, bool includeRetired, CancellationToken cancellationToken)
    {
        if (practiceId <= 0)
            return new PracticeObligationListResult(false, [], "PracticeId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_obligation_list";

            AddParam(command, "@practice_id",     DbType.Int64,   practiceId);
            AddParam(command, "@organization_id", DbType.Int64,   organizationId is > 0 ? organizationId : DBNull.Value);
            AddParam(command, "@include_retired", DbType.Boolean, includeRetired);

            var rows = new List<PracticeObligationRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new PracticeObligationRow(
                    PracticeObligationId:  Convert.ToInt64(reader["PracticeObligationId"]),
                    OrganizationId:        Convert.ToInt64(reader["OrganizationId"]),
                    PracticeId:            Convert.ToInt64(reader["PracticeId"]),
                    ObligationName:        reader["ObligationName"] as string,
                    ObligationDescription: reader["ObligationDescription"] as string,
                    ObligationTypeCode:    reader["ObligationTypeCode"] as string,
                    TypeName:              reader["TypeName"] as string,
                    TypedDetailJson:       reader["TypedDetailJson"] as string,
                    ExecutionFrequencyId:  OptionalInt32(reader, "ExecutionFrequencyId"),
                    ExecutionFrequency:    reader["ExecutionFrequency"] as string,
                    Responsibility:        reader["Responsibility"] as string,
                    ApprovalAuthority:     reader["ApprovalAuthority"] as string,
                    AssuranceType:         reader["AssuranceType"] as string,
                    Remarks:               reader["Remarks"] as string,
                    EvidenceJson:          reader["EvidenceJson"] as string,
                    // Status_ in the procedure: `status` is a reserved-ish
                    // name in enough places that the projection renames it.
                    Status:                OptionalString(reader, "Status_") ?? OptionalString(reader, "Status"),
                    EnteredBy:             OptionalString(reader, "EnteredBy"),
                    EnteredDt:             OptionalDateTime(reader, "EnteredDt"),
                    InstanceCount:         ToInt(reader["InstanceCount"])));

            return new PracticeObligationListResult(true, rows);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_practice_obligation_list failed for practice {PracticeId}.", practiceId);
            return new PracticeObligationListResult(false, [], ex.Message);
        }
    }

    // ==============================================================
    // Save -- add, edit or retire, and fan out
    // ==============================================================
    public async Task<PracticeObligationSaveResult> SaveAsync(
        PracticeObligationSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (request.PracticeId <= 0)
            return new PracticeObligationSaveResult(false, null, Error: "PracticeId is required.");

        // The procedure refuses these too. Catching them here turns a SQL
        // error into a sentence the form can put next to the field.
        if (!request.Retire)
        {
            if (string.IsNullOrWhiteSpace(request.ObligationName))
                return new PracticeObligationSaveResult(false, null, Error: "Obligation name is required.");
            if (string.IsNullOrWhiteSpace(request.ObligationTypeCode))
                return new PracticeObligationSaveResult(false, null, Error: "Obligation type is required.");
        }
        else if (request.PracticeObligationId <= 0)
        {
            return new PracticeObligationSaveResult(false, null,
                Error: "An obligation must be identified before it can be removed.");
        }

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_obligation_save";

            AddParam(command, "@practice_id",            DbType.Int64, request.PracticeId);
            AddParam(command, "@organization_id",        DbType.Int64,
                     request.OrganizationId is > 0 ? request.OrganizationId : DBNull.Value);
            AddParam(command, "@practice_obligation_id", DbType.Int64, request.PracticeObligationId);
            AddParam(command, "@obligation_name",        DbType.String, Text(request.ObligationName), 500);
            AddParam(command, "@obligation_description", DbType.String, Text(request.ObligationDescription));
            AddParam(command, "@obligation_type_code",   DbType.String, Text(request.ObligationTypeCode), 60);
            AddParam(command, "@typed_detail_json",      DbType.String, Text(request.TypedDetailJson));
            AddParam(command, "@execution_frequency_id", DbType.Int32,
                     (object?)request.ExecutionFrequencyId ?? DBNull.Value);
            AddParam(command, "@execution_frequency",    DbType.String, Text(request.ExecutionFrequency), 120);
            AddParam(command, "@responsibility",         DbType.String, Text(request.Responsibility), 300);
            AddParam(command, "@approval_authority",     DbType.String, Text(request.ApprovalAuthority), 300);
            AddParam(command, "@assurance_type",         DbType.String, Text(request.AssuranceType), 40);
            AddParam(command, "@remarks",                DbType.String, Text(request.Remarks));
            // Null, not "[]" -- the procedure reads NULL as "no opinion"
            // and leaves the stored evidence list alone. An empty array
            // is how the form says "none".
            AddParam(command, "@evidence_json",          DbType.String,
                     request.Evidence is null ? DBNull.Value : JsonSerializer.Serialize(request.Evidence));
            AddParam(command, "@retire",                 DbType.Boolean, request.Retire);
            AddParam(command, "@actor",                  DbType.String,
                     string.IsNullOrWhiteSpace(request.Actor) ? "system" : request.Actor, 100);

            string? message = null;
            long?   savedId = null;
            int     created = 0, updated = 0, retired = 0, evidence = 0;

            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                // Advance to the result set that carries the outcome. The
                // procedure emits exactly one and the fan-out it calls
                // emits none (migration 233's rule), but a future
                // procedure growing a diagnostic SELECT must not be able
                // to make a successful save read as a failure -- which is
                // precisely the fault 233 was written to repair. Same
                // loop SaveLocalObligationAsync uses.
                while (!HasColumn(reader, "Message") && await reader.NextResultAsync(cancellationToken))
                {
                }

                if (HasColumn(reader, "Message") && await reader.ReadAsync(cancellationToken))
                {
                    message  = reader["Message"] as string;
                    savedId  = OptionalInt64(reader, "PracticeObligationId");
                    created  = OptionalInt32(reader, "CopiesCreated")  ?? 0;
                    updated  = OptionalInt32(reader, "CopiesUpdated")  ?? 0;
                    retired  = OptionalInt32(reader, "CopiesRetired")  ?? 0;
                    evidence = OptionalInt32(reader, "EvidenceSynced") ?? 0;
                }
            }

            return new PracticeObligationSaveResult(
                true, savedId,
                Message: message ?? "Saved.",
                CopiesCreated: created, CopiesUpdated: updated,
                CopiesRetired: retired, EvidenceSynced: evidence);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_practice_obligation_save failed for practice {PracticeId}, obligation {ObligationId}.",
                request.PracticeId, request.PracticeObligationId);
            // The id goes back on the failure path too, so a retry updates
            // the row already written instead of adding a second one --
            // the rule migration 233 paid for the hard way.
            return new PracticeObligationSaveResult(false,
                request.PracticeObligationId > 0 ? request.PracticeObligationId : null,
                Error: ex.Message);
        }
    }

    // ==============================================================
    // Fan out -- reconcile
    // ==============================================================
    public async Task<PracticeObligationFanOutResult> FanOutAsync(
        long? practiceId, long? practiceObligationId, long? practiceInstanceId,
        string? actor, CancellationToken cancellationToken)
    {
        if (practiceId is not > 0 && practiceObligationId is not > 0 && practiceInstanceId is not > 0)
            return new PracticeObligationFanOutResult(false,
                Error: "Name a practice, a definition or an instance.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_obligation_fan_out";

            AddParam(command, "@practice_id",            DbType.Int64, practiceId is > 0 ? practiceId : DBNull.Value);
            AddParam(command, "@practice_obligation_id", DbType.Int64, practiceObligationId is > 0 ? practiceObligationId : DBNull.Value);
            AddParam(command, "@practice_instance_id",   DbType.Int64, practiceInstanceId is > 0 ? practiceInstanceId : DBNull.Value);
            AddParam(command, "@actor",                  DbType.String,
                     string.IsNullOrWhiteSpace(actor) ? "system" : actor, 100);

            var created  = OutParam(command, "@copies_created");
            var updated  = OutParam(command, "@copies_updated");
            var retired  = OutParam(command, "@copies_retired");
            var evidence = OutParam(command, "@evidence_synced");

            // ExecuteNonQuery, not a reader: the procedure returns no
            // result set at all (migration 233's rule, which is what lets
            // sp_practice_obligation_save compose it).
            await command.ExecuteNonQueryAsync(cancellationToken);

            return new PracticeObligationFanOutResult(
                true,
                CopiesCreated:  ToInt(created.Value),
                CopiesUpdated:  ToInt(updated.Value),
                CopiesRetired:  ToInt(retired.Value),
                EvidenceSynced: ToInt(evidence.Value));
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "sp_practice_obligation_fan_out failed (practice {PracticeId}, instance {InstanceId}).",
                practiceId, practiceInstanceId);
            return new PracticeObligationFanOutResult(false, Error: ex.Message);
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

    private static DbParameter OutParam(DbCommand command, string name)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType        = DbType.Int32;
        p.Direction     = ParameterDirection.Output;
        p.Value         = 0;
        command.Parameters.Add(p);
        return p;
    }

    /// <summary>Empty string means "not answered", which is DBNull here.</summary>
    private static object Text(string? value)
        => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value;

    private static int ToInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);

    // A column a migration added, read from a result set that may predate
    // it. reader["Missing"] throws, so asking first is the cheap way to
    // let one feature degrade instead of taking the whole read down.
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

    private static DateTime? OptionalDateTime(DbDataReader reader, string name)
        => HasColumn(reader, name) && reader[name] is { } v && v != DBNull.Value
            ? Convert.ToDateTime(v)
            : null;
}
