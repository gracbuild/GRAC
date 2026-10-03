// =====================================================================
// RepositoryChangeService  (statement subscription copy model, phase 3)
//
// Facade over the migration-395 procedures:
//   sp_repository_change_detect                 DetectAsync (worker)
//   sp_repository_change_list / _counts         review page, badge
//   sp_repository_change_apply                  DecideAsync
//   sp_repository_change_notification_list /
//   sp_repository_change_notification_mark_read Home
//
// Who may decide is enforced by sp_repository_change_apply itself (release
// owner or organization admin), so the rule holds for every caller.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IRepositoryChangeService
{
    Task<RepositoryChangeDetectResult> DetectAsync(long? organizationId, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListAsync(long organizationId, long? releaseId, string? status, int pageNumber, int pageSize, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> CountsAsync(long organizationId, CancellationToken cancellationToken);
    Task<RepositoryChangeDecisionResult> DecideAsync(long changeId, string decision, string? remark, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> NotificationsAsync(long recipientEmployeeId, long? organizationId, CancellationToken cancellationToken);
    Task<int> MarkNotificationsReadAsync(long recipientEmployeeId, long organizationId, CancellationToken cancellationToken);
}

public sealed class RepositoryChangeService(IConfiguration configuration) : IRepositoryChangeService
{
    public async Task<RepositoryChangeDetectResult> DetectAsync(long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_change_detect";
        // A full pass compares every copy with grac_new; allow more than
        // the 30-second default.
        command.CommandTimeout = 600;
        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@actor", DbType.String, "change-detect", 100);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken))
            return new RepositoryChangeDetectResult(
                reader["DetectionRunId"] as Guid?,
                Convert.ToInt32(reader["RaisedCount"]),
                Convert.ToInt32(reader["NotifiedCount"]));
        return new RepositoryChangeDetectResult(null, 0, 0);
    }

    public async Task<List<Dictionary<string, object?>>> ListAsync(long organizationId, long? releaseId, string? status, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_change_list";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@release_id", DbType.Int64, (object?)releaseId ?? DBNull.Value);
        // "All" means every status; the procedure reads NULL that way.
        AddParam(command, "@status", DbType.String,
            string.IsNullOrWhiteSpace(status) || status.Equals("All", StringComparison.OrdinalIgnoreCase)
                ? DBNull.Value : status.Trim(), 20);
        AddParam(command, "@page_number", DbType.Int32, Math.Max(1, pageNumber));
        AddParam(command, "@page_size", DbType.Int32, Math.Clamp(pageSize, 1, 200));
        return await ReadRowsAsync(command, cancellationToken);
    }

    public async Task<List<Dictionary<string, object?>>> CountsAsync(long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_change_counts";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        return await ReadRowsAsync(command, cancellationToken);
    }

    public async Task<RepositoryChangeDecisionResult> DecideAsync(long changeId, string decision, string? remark, long? callerEmployeeId, bool callerIsAdmin, string actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_repository_change_apply";
            command.CommandTimeout = 120;
            AddParam(command, "@change_id", DbType.Int64, changeId);
            AddParam(command, "@decision", DbType.String, decision, 20);
            AddParam(command, "@actor_employee_id", DbType.Int64, (object?)callerEmployeeId ?? DBNull.Value);
            AddParam(command, "@is_admin", DbType.Boolean, callerIsAdmin);
            AddParam(command, "@remark", DbType.String, (object?)remark ?? DBNull.Value, 1000);
            AddParam(command, "@actor", DbType.String, actor, 100);
            AddParam(command, "@suppress_result", DbType.Boolean, true);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new RepositoryChangeDecisionResult(changeId, true,
                decision.Equals("Approve", StringComparison.OrdinalIgnoreCase) ? "Approved" : "Rejected");
        }
        // 53920-53926: the procedure's own refusals (not found, already
        // decided, not allowed, remark missing, item gone). Their text is
        // written for the user.
        catch (SqlException ex) when (ex.Number is >= 53920 and <= 53926)
        {
            return new RepositoryChangeDecisionResult(changeId, false, ex.Message);
        }
    }

    public async Task<List<Dictionary<string, object?>>> NotificationsAsync(long recipientEmployeeId, long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_change_notification_list";
        AddParam(command, "@recipient_employee_id", DbType.Int64, recipientEmployeeId);
        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);
        return await ReadRowsAsync(command, cancellationToken);
    }

    public async Task<int> MarkNotificationsReadAsync(long recipientEmployeeId, long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_repository_change_notification_mark_read";
        AddParam(command, "@recipient_employee_id", DbType.Int64, recipientEmployeeId);
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is null or DBNull ? 0 : Convert.ToInt32(result);
    }

    // ------------------------------------------------------------------
    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbCommand command, CancellationToken cancellationToken)
    {
        var rows = new List<Dictionary<string, object?>>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var row = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

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

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
