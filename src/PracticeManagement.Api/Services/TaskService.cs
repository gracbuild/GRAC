// =====================================================================
// TaskService  (charter §12.1.3)
//
// Thin façade over grac_practice.sp_task_* procedures. Kept in a new
// file per charter §5 non-negotiable — do not extend
// PracticeRepositoryService.cs.
//
// Wire-up (extension method): Api/Infrastructure/TaskServiceRegistration.cs
// The reviewer adds the following ONE line to Program.cs (pending
// explicit approval per charter §5):
//     builder.Services.AddPracticeTaskService();
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ITaskService
{
    Task<TaskListResult> ListAsync(TaskListQuery query, CancellationToken cancellationToken);
    Task<TaskCommandResult> OpenAsync(TaskOpenRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> AssignAsync(TaskAssignRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> TransitionAsync(TaskTransitionRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> CloseAsync(TaskCloseRequest request, CancellationToken cancellationToken);
}

public sealed class TaskService(IConfiguration configuration, ILogger<TaskService> logger) : ITaskService
{
    // Delegates to SqlConnectionStringResolver — see PermissionService.

    public async Task<TaskListResult> ListAsync(TaskListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_list";

        AddParam(command, "@organization_id",         DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@assigned_to_employee_id", DbType.Int64,  (object?)query.AssignedToEmployeeId ?? DBNull.Value);
        AddParam(command, "@task_type_code",          DbType.String, (object?)query.TaskTypeCode ?? DBNull.Value, 60);
        AddParam(command, "@status_code",             DbType.String, (object?)query.StatusCode ?? DBNull.Value, 60);
        AddParam(command, "@overdue_only",            DbType.Boolean, query.OverdueOnly ?? false);
        AddParam(command, "@search",                  DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",                    DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",               DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

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

        var rows = new List<TaskListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapRow(reader));
        }

        return new TaskListResult(total, page, size, rows);
    }

    public async Task<TaskCommandResult> OpenAsync(TaskOpenRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.TaskTypeCode))     return Fail("TaskTypeCode is required.");
        if (string.IsNullOrWhiteSpace(request.SubjectEntityType)) return Fail("SubjectEntityType is required.");
        if (string.IsNullOrWhiteSpace(request.SubjectTitle))      return Fail("SubjectTitle is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_open";

            AddParam(command, "@organization_id",        DbType.Int64,  request.OrganizationId);
            AddParam(command, "@task_type_code",         DbType.String, request.TaskTypeCode, 60);
            AddParam(command, "@subject_entity_type",    DbType.String, request.SubjectEntityType, 60);
            AddParam(command, "@subject_entity_id",      DbType.Int64,  request.SubjectEntityId);
            AddParam(command, "@subject_title",          DbType.String, request.SubjectTitle, 250);
            AddParam(command, "@subject_description",    DbType.String, (object?)request.SubjectDescription ?? DBNull.Value, -1);
            AddParam(command, "@linked_release_id",      DbType.Int64,  (object?)request.LinkedReleaseId ?? DBNull.Value);
            AddParam(command, "@linked_control_id",      DbType.Int64,  (object?)request.LinkedControlId ?? DBNull.Value);
            AddParam(command, "@linked_practice_id",     DbType.Int64,  (object?)request.LinkedPracticeId ?? DBNull.Value);
            AddParam(command, "@linked_instance_id",     DbType.Int64,  (object?)request.LinkedInstanceId ?? DBNull.Value);
            AddParam(command, "@priority",               DbType.String, (object?)request.Priority ?? DBNull.Value, 30);
            AddParam(command, "@criticality",            DbType.String, (object?)request.Criticality ?? DBNull.Value, 30);
            AddParam(command, "@origin_code",            DbType.String, (object?)request.OriginCode ?? DBNull.Value, 30);
            AddParam(command, "@assigned_to_employee_id",DbType.Int64,  (object?)request.AssignedToEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_employee_id",      DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",        DbType.String, (object?)request.ActorRoleCode ?? DBNull.Value, 60);
            AddParam(command, "@correlation_id",         DbType.Guid,   (object?)request.CorrelationId ?? DBNull.Value);

            var taskIdParam = command.CreateParameter();
            taskIdParam.ParameterName = "@task_id";
            taskIdParam.DbType        = DbType.Int64;
            taskIdParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(taskIdParam);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var taskId = taskIdParam.Value is long l ? l : Convert.ToInt64(taskIdParam.Value);
            return new TaskCommandResult(true, taskId);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(OpenAsync));
        }
    }

    public async Task<TaskCommandResult> AssignAsync(TaskAssignRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_assign";

            AddParam(command, "@task_id",                DbType.Int64,  request.TaskId);
            AddParam(command, "@assigned_to_employee_id",DbType.Int64,  request.AssignedToEmployeeId);
            AddParam(command, "@actor_employee_id",      DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",        DbType.String, (object?)request.ActorRoleCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_code",            DbType.String, (object?)request.ReasonCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_text",            DbType.String, (object?)request.ReasonText ?? DBNull.Value, 1000);
            AddParam(command, "@correlation_id",         DbType.Guid,   (object?)request.CorrelationId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new TaskCommandResult(true, request.TaskId);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(AssignAsync));
        }
    }

    public async Task<TaskCommandResult> TransitionAsync(TaskTransitionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ToStatusCode)) return Fail("ToStatusCode is required.");
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_transition";

            AddParam(command, "@task_id",           DbType.Int64,  request.TaskId);
            AddParam(command, "@to_status_code",    DbType.String, request.ToStatusCode, 60);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",   DbType.String, (object?)request.ActorRoleCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_code",       DbType.String, (object?)request.ReasonCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_text",       DbType.String, (object?)request.ReasonText ?? DBNull.Value, 1000);
            AddParam(command, "@correlation_id",    DbType.Guid,   (object?)request.CorrelationId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new TaskCommandResult(true, request.TaskId);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(TransitionAsync));
        }
    }

    public async Task<TaskCommandResult> CloseAsync(TaskCloseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_close";

            AddParam(command, "@task_id",           DbType.Int64,  request.TaskId);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",   DbType.String, (object?)request.ActorRoleCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_code",       DbType.String, (object?)request.ReasonCode ?? DBNull.Value, 60);
            AddParam(command, "@reason_text",       DbType.String, (object?)request.ReasonText ?? DBNull.Value, 1000);
            AddParam(command, "@correlation_id",    DbType.Guid,   (object?)request.CorrelationId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new TaskCommandResult(true, request.TaskId);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(CloseAsync));
        }
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

    private static TaskListRow MapRow(DbDataReader reader) => new(
        TaskId:                     Convert.ToInt64(reader["task_id"]),
        OrganizationId:             Convert.ToInt64(reader["organization_id"]),
        TaskTypeCode:               reader["task_type_code"]?.ToString() ?? "",
        TaskTypeName:               reader["task_type_name"]?.ToString() ?? "",
        SubjectEntityType:          reader["subject_entity_type"]?.ToString() ?? "",
        SubjectEntityId:            Convert.ToInt64(reader["subject_entity_id"]),
        LinkedReleaseId:            reader["linked_release_id"]  as long?,
        LinkedControlId:            reader["linked_control_id"]  as long?,
        LinkedPracticeId:           reader["linked_practice_id"] as long?,
        LinkedInstanceId:           reader["linked_instance_id"] as long?,
        SubjectTitle:               reader["subject_title"]?.ToString() ?? "",
        SubjectDescription:         reader["subject_description"] as string,
        AssignedToEmployeeId:       reader["assigned_to_employee_id"] as long?,
        CurrentStatusCode:          reader["current_status_code"]?.ToString() ?? "",
        CurrentStatusName:          reader["current_status_name"]?.ToString() ?? "",
        CurrentStatusIsTerminal:    Convert.ToBoolean(reader["current_status_is_terminal"]),
        Priority:                   reader["priority"]?.ToString() ?? "Medium",
        Criticality:                reader["criticality"] as string,
        OriginCode:                 reader["origin_code"]  as string,
        SlaDueAt:                   reader["sla_due_at"]   as DateTime?,
        IsOverdue:                  reader["is_overdue"] is null || reader["is_overdue"] == DBNull.Value ? false : Convert.ToBoolean(reader["is_overdue"]),
        EscalatedAt:                reader["escalated_at"] as DateTime?,
        ReasonCode:                 reader["reason_code"]  as string,
        ReasonText:                 reader["reason_text"]  as string,
        ClosedAt:                   reader["closed_at"]    as DateTime?);

    private TaskCommandResult HandleSqlError(SqlException ex, string op)
    {
        // Map framework error codes back to reason strings for the client
        var reason = ex.Number switch
        {
            53520 => "ILLEGAL_TRANSITION",
            53521 => "REASON_REQUIRED",
            53752 => "TWO_GATE_NOT_PASSED",
            _     => "SQL_ERROR"
        };
        logger.LogWarning(ex, "TaskService.{Op} failed with SQL error {Number}: {Message}", op, ex.Number, ex.Message);
        return new TaskCommandResult(false, null, ex.Message, reason);
    }

    private static TaskCommandResult Fail(string error) => new(false, null, error);
}
