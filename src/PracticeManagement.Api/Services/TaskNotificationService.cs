// =====================================================================
// TaskNotificationService  (Task Centre v2, Phase 3 — BRD §13)
//
// Façade over grac_practice.sp_task_notification_*. Its own file per
// charter §5.
//
// Wire-up: Api/Infrastructure/TaskNotificationServiceRegistration.cs
//     builder.Services.AddPracticeTaskNotificationService();
//
// WHAT THIS IS NOT
// ----------------
// It is not a sender. Phase 3 records the OBLIGATION to notify — one
// outbox row per (task, threshold, recipient) — and stops there. There is
// no delivery infrastructure in this codebase to hand off to:
// PracticeEmailService lives in the Web tier and is registered in
// Web/Program.cs, so an Api-side sweeper cannot reach it without moving a
// working component. MarkAsync exists so that whatever dispatcher is
// eventually built can report outcomes back.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ITaskNotificationService
{
    /// <summary>Runs one sweep pass. Returns how many obligations were newly
    /// recorded — the sweep is idempotent, so a steady state returns 0.</summary>
    Task<TaskNotificationSweepResult> SweepAsync(long? organizationId, int batchSize, CancellationToken cancellationToken);

    Task<TaskNotificationListResult> ListAsync(TaskNotificationListQuery query, CancellationToken cancellationToken);
    Task<TaskNotificationCounts> CountsAsync(long? organizationId, long? recipientEmployeeId, CancellationToken cancellationToken);
    Task<TaskNotificationCommandResult> MarkAsync(TaskNotificationMarkRequest request, CancellationToken cancellationToken);

    /// <summary>
    /// Marks every Pending notification for ONE recipient as read.
    /// Deliberately has no all-recipients variant: clearing somebody
    /// else's unread state would destroy the only evidence that they had
    /// not seen it.
    /// </summary>
    Task<int> MarkAllAsync(long recipientEmployeeId, long? organizationId, string? notifyEventCode, CancellationToken cancellationToken);
}

public sealed class TaskNotificationService(IConfiguration configuration, ILogger<TaskNotificationService> logger) : ITaskNotificationService
{
    public async Task<TaskNotificationSweepResult> SweepAsync(long? organizationId, int batchSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_notification_sweep";

        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@batch_size",      DbType.Int32, Math.Clamp(batchSize, 1, 2000));

        var enqueued = command.CreateParameter();
        enqueued.ParameterName = "@enqueued_count";
        enqueued.DbType        = DbType.Int32;
        enqueued.Direction     = ParameterDirection.Output;
        command.Parameters.Add(enqueued);

        var scanned = command.CreateParameter();
        scanned.ParameterName = "@task_count";
        scanned.DbType        = DbType.Int32;
        scanned.Direction     = ParameterDirection.Output;
        command.Parameters.Add(scanned);

        await command.ExecuteNonQueryAsync(cancellationToken);

        return new TaskNotificationSweepResult(
            Enqueued:     enqueued.Value == DBNull.Value ? 0 : Convert.ToInt32(enqueued.Value),
            TasksScanned: scanned.Value  == DBNull.Value ? 0 : Convert.ToInt32(scanned.Value));
    }

    public async Task<TaskNotificationListResult> ListAsync(TaskNotificationListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_notification_list";

        AddParam(command, "@organization_id",       DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@recipient_employee_id", DbType.Int64,  (object?)query.RecipientEmployeeId ?? DBNull.Value);
        AddParam(command, "@task_id",               DbType.Int64,  (object?)query.TaskId ?? DBNull.Value);
        AddParam(command, "@status_code",           DbType.String, (object?)query.StatusCode ?? DBNull.Value, 20);
        AddParam(command, "@notify_event_code",     DbType.String, (object?)query.NotifyEventCode ?? DBNull.Value, 30);
        AddParam(command, "@page",                  DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",             DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  page  = query.Page;
        int  size  = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<TaskNotificationRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(new TaskNotificationRow(
                    TaskNotificationId:  Convert.ToInt64(reader["TaskNotificationId"]),
                    OrganizationId:      Convert.ToInt64(reader["OrganizationId"]),
                    TaskId:              Convert.ToInt64(reader["TaskId"]),
                    TaskNumber:          reader["TaskNumber"]          as string,
                    TaskTitle:           reader["TaskTitle"]           as string,
                    Priority:            reader["Priority"]            as string,
                    NotifyEventCode:     reader["NotifyEventCode"]?.ToString() ?? "",
                    RecipientEmployeeId: reader["RecipientEmployeeId"] as long?,
                    RecipientName:       reader["RecipientName"]       as string,
                    RecipientEmail:      reader["RecipientEmail"]      as string,
                    RoleId:              reader["RoleId"]              as long?,
                    RoleName:            reader["RoleName"]            as string,
                    RecipientReasonCode: reader["RecipientReasonCode"]?.ToString() ?? "",
                    Subject:             reader["Subject"]             as string,
                    BodyText:            reader["BodyText"]            as string,
                    SlaStatusCode:       reader["SlaStatusCode"]       as string,
                    DueAt:               reader["DueAt"]               as DateTime?,
                    StatusCode:          reader["StatusCode"]?.ToString() ?? "",
                    AttemptCount:        Convert.ToInt32(reader["AttemptCount"]),
                    LastAttemptDt:       reader["LastAttemptDt"]       as DateTime?,
                    FailureReason:       reader["FailureReason"]       as string,
                    SentDt:              reader["SentDt"]              as DateTime?,
                    EnteredDt:           Convert.ToDateTime(reader["EnteredDt"])));

        return new TaskNotificationListResult(total, page, size, rows);
    }

    public async Task<TaskNotificationCounts> CountsAsync(long? organizationId, long? recipientEmployeeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_notification_counts";

        AddParam(command, "@organization_id",       DbType.Int64, (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@recipient_employee_id", DbType.Int64, (object?)recipientEmployeeId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return new TaskNotificationCounts(0, 0, 0, 0, 0, 0, 0, 0);

        // SUM() over an empty set is NULL, not 0.
        long Get(string n) => reader[n] == DBNull.Value ? 0 : Convert.ToInt64(reader[n]);

        return new TaskNotificationCounts(
            PendingCount:    Get("PendingCount"),
            SentCount:       Get("SentCount"),
            FailedCount:     Get("FailedCount"),
            SuppressedCount: Get("SuppressedCount"),
            WarningCount:    Get("WarningCount"),
            BreachCount:     Get("BreachCount"),
            EscalationCount: Get("EscalationCount"),
            UnroutableCount: Get("UnroutableCount"));
    }

    public async Task<TaskNotificationCommandResult> MarkAsync(TaskNotificationMarkRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.StatusCode))
            return new TaskNotificationCommandResult(false, null, null, "StatusCode is required.", "VALIDATION_ERROR");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_notification_mark";

            AddParam(command, "@task_notification_id", DbType.Int64,  request.TaskNotificationId);
            AddParam(command, "@status_code",          DbType.String, request.StatusCode, 20);
            AddParam(command, "@failure_reason",       DbType.String, (object?)request.FailureReason ?? DBNull.Value, 1000);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var status = await reader.ReadAsync(cancellationToken) ? reader["StatusCode"]?.ToString() : request.StatusCode;

            return new TaskNotificationCommandResult(true, request.TaskNotificationId, status);
        }
        catch (SqlException ex)
        {
            var reason = ex.Number switch
            {
                55911 => "INVALID_STATUS",
                55912 => "NOT_FOUND",
                >= 55900 and <= 55999 => "VALIDATION_ERROR",
                _ => "SQL_ERROR"
            };
            logger.LogWarning(ex, "TaskNotificationService.MarkAsync failed with SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new TaskNotificationCommandResult(false, null, null, ex.Message, reason);
        }
    }

    public async Task<int> MarkAllAsync(long recipientEmployeeId, long? organizationId, string? notifyEventCode, CancellationToken cancellationToken)
    {
        if (recipientEmployeeId <= 0)
            throw new ArgumentOutOfRangeException(nameof(recipientEmployeeId),
                "Marking notifications read is always personal; a recipient is required.");

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_notification_mark_all";

        AddParam(command, "@recipient_employee_id", DbType.Int64,  recipientEmployeeId);
        AddParam(command, "@organization_id",       DbType.Int64,  (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@notify_event_code",     DbType.String, (object?)notifyEventCode ?? DBNull.Value, 30);

        var marked = command.CreateParameter();
        marked.ParameterName = "@marked_count";
        marked.DbType        = DbType.Int32;
        marked.Direction     = ParameterDirection.Output;
        command.Parameters.Add(marked);

        // The proc also returns a summary row; drain it so the OUTPUT
        // parameter is populated before it is read.
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken)) { }
            while (await reader.NextResultAsync(cancellationToken)) { }
        }

        return marked.Value == DBNull.Value ? 0 : Convert.ToInt32(marked.Value);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------
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
}
