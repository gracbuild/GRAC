// =====================================================================
// PracticeInstanceWorkflowService  (Q13/Q14/Q15)
//
// Thin façade over sp_practice_instance_open_implementation_task. Kept
// in a new file per charter §5 — never extend PracticeRepositoryService.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;

namespace PracticeManagement.Api.Services;

public sealed record OpenImplementationTaskRequest(
    long PracticeInstanceId,
    string SubjectTitle,
    string? SubjectDescription,
    long? AssignedToEmployeeId,
    DateTime? TargetDate,
    string? Priority,
    string? Remarks,
    long? ActorEmployeeId,
    string? ActorRoleCode,
    Guid? CorrelationId);

public sealed record OpenImplementationTaskResult(
    bool Success,
    long? TaskId = null,
    string? Error = null,
    string? ReasonCode = null);

public sealed record PracticeInstanceContext(
    long PracticeInstanceId,
    string InstanceCode,
    string InstanceName,
    long? PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long? OrganizationId,
    string? OrganizationName,
    string? ImplementationStatusCode,
    string? ImplementationStatusName);

public sealed record UpdateImplementationStatusRequest(
    long PracticeInstanceId,
    string NewStatusCode,
    string? Remarks,
    DateTime? EffectiveDate,
    long? ActorEmployeeId);

public sealed record UpdateImplementationStatusResult(
    bool Success,
    string? NewStatusCode = null,
    int? NewStatusId = null,
    string? Error = null,
    string? ReasonCode = null);

public sealed record ImplementationStatusOption(
    int StatusId,
    string StatusCode,
    string StatusName,
    int DisplayOrder);

public sealed record InstanceEmployeeOption(
    long EmployeeId,
    string EmployeeCode,
    string EmployeeName,
    string? Email,
    string? Designation,
    string? Department);

public interface IPracticeInstanceWorkflowService
{
    Task<OpenImplementationTaskResult> OpenImplementationTaskAsync(
        OpenImplementationTaskRequest request, CancellationToken cancellationToken);

    Task<PracticeInstanceContext?> GetContextAsync(
        long practiceInstanceId, CancellationToken cancellationToken);

    Task<UpdateImplementationStatusResult> UpdateImplementationStatusAsync(
        UpdateImplementationStatusRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<ImplementationStatusOption>> GetImplementationStatusOptionsAsync(
        CancellationToken cancellationToken);

    Task<IReadOnlyList<InstanceEmployeeOption>> GetInstanceEmployeesAsync(
        long practiceInstanceId, CancellationToken cancellationToken);
}

public sealed class PracticeInstanceWorkflowService(
    IConfiguration configuration,
    ILogger<PracticeInstanceWorkflowService> logger) : IPracticeInstanceWorkflowService
{
    // Delegates to SqlConnectionStringResolver — see PermissionService.

    public async Task<OpenImplementationTaskResult> OpenImplementationTaskAsync(
        OpenImplementationTaskRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0)
            return new OpenImplementationTaskResult(false, null, "PracticeInstanceId is required.", "BAD_REQUEST");
        if (string.IsNullOrWhiteSpace(request.SubjectTitle))
            return new OpenImplementationTaskResult(false, null, "SubjectTitle is required.", "BAD_REQUEST");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_instance_open_implementation_task";

            AddParam(command, "@practice_instance_id",   DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@subject_title",          DbType.String,  request.SubjectTitle, 250);
            AddParam(command, "@subject_description",    DbType.String,  (object?)request.SubjectDescription ?? DBNull.Value, -1);
            AddParam(command, "@assigned_to_employee_id",DbType.Int64,   (object?)request.AssignedToEmployeeId ?? DBNull.Value);
            AddParam(command, "@target_date",            DbType.DateTime2, (object?)request.TargetDate ?? DBNull.Value);
            AddParam(command, "@priority",               DbType.String,  (object?)request.Priority ?? DBNull.Value, 30);
            AddParam(command, "@remarks",                DbType.String,  (object?)request.Remarks ?? DBNull.Value, 1000);
            AddParam(command, "@actor_employee_id",      DbType.Int64,   (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",        DbType.String,  (object?)request.ActorRoleCode ?? DBNull.Value, 60);
            AddParam(command, "@correlation_id",         DbType.Guid,    (object?)request.CorrelationId ?? DBNull.Value);

            var taskIdParam = command.CreateParameter();
            taskIdParam.ParameterName = "@task_id";
            taskIdParam.DbType        = DbType.Int64;
            taskIdParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(taskIdParam);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var taskId = taskIdParam.Value is long l ? l : Convert.ToInt64(taskIdParam.Value);
            return new OpenImplementationTaskResult(true, taskId);
        }
        catch (SqlException ex)
        {
            var reason = ex.Number switch
            {
                54301 => "INSTANCE_NOT_FOUND",
                54302 => "STATE_NOT_ALLOWED",
                54303 => "BAD_REQUEST",
                53520 => "ILLEGAL_TRANSITION",
                53521 => "REASON_REQUIRED",
                _     => "SQL_ERROR"
            };
            logger.LogWarning(ex, "OpenImplementationTaskAsync failed with SQL {Number}: {Message}", ex.Number, ex.Message);
            return new OpenImplementationTaskResult(false, null, ex.Message, reason);
        }
    }

    public async Task<PracticeInstanceContext?> GetContextAsync(long practiceInstanceId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0) return null;

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_practice_instance_get_context";

        var p = command.CreateParameter();
        p.ParameterName = "@practice_instance_id";
        p.DbType = DbType.Int64;
        p.Value = practiceInstanceId;
        command.Parameters.Add(p);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new PracticeInstanceContext(
            PracticeInstanceId:       Convert.ToInt64(reader["PracticeInstanceId"]),
            InstanceCode:             reader["InstanceCode"]?.ToString() ?? "",
            InstanceName:             reader["InstanceName"]?.ToString() ?? "",
            PracticeId:               reader["PracticeId"]              as long?,
            PracticeCode:             reader["PracticeCode"]             as string,
            PracticeName:             reader["PracticeName"]             as string,
            OrganizationId:           reader["OrganizationId"]          as long?,
            OrganizationName:         reader["OrganizationName"]         as string,
            ImplementationStatusCode: reader["ImplementationStatusCode"] as string,
            ImplementationStatusName: reader["ImplementationStatusName"] as string);
    }

    public async Task<UpdateImplementationStatusResult> UpdateImplementationStatusAsync(
        UpdateImplementationStatusRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.PracticeInstanceId <= 0)
            return new UpdateImplementationStatusResult(false, null, null, "PracticeInstanceId is required.", "BAD_REQUEST");
        if (string.IsNullOrWhiteSpace(request.NewStatusCode))
            return new UpdateImplementationStatusResult(false, null, null, "NewStatusCode is required.", "BAD_REQUEST");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_practice_instance_update_implementation_status";

            AddParam(command, "@practice_instance_id", DbType.Int64,   request.PracticeInstanceId);
            AddParam(command, "@new_status_code",      DbType.String,  request.NewStatusCode, 60);
            AddParam(command, "@remarks",              DbType.String,  (object?)request.Remarks ?? DBNull.Value, 2000);
            AddParam(command, "@effective_date",       DbType.DateTime2, (object?)request.EffectiveDate ?? DBNull.Value);
            AddParam(command, "@actor_employee_id",    DbType.Int64,   (object?)request.ActorEmployeeId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new UpdateImplementationStatusResult(true, request.NewStatusCode, null);

            var newCode = reader["ImplementationStatus"]?.ToString();
            var newId   = reader["ImplementationStatusId"] as int?;
            return new UpdateImplementationStatusResult(true, newCode, newId);
        }
        catch (SqlException ex)
        {
            var reason = ex.Number switch
            {
                54501 => "INSTANCE_NOT_FOUND",
                54502 => "UNKNOWN_STATUS",
                54503 => "BAD_REQUEST",
                54504 => "BAD_REQUEST",
                _     => "SQL_ERROR"
            };
            logger.LogWarning(ex, "UpdateImplementationStatusAsync failed with SQL {Number}", ex.Number);
            return new UpdateImplementationStatusResult(false, null, null, ex.Message, reason);
        }
    }

    public async Task<IReadOnlyList<ImplementationStatusOption>> GetImplementationStatusOptionsAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandText = @"SELECT implementation_status_id AS StatusId,
                                       status_code             AS StatusCode,
                                       status_name             AS StatusName,
                                       display_order           AS DisplayOrder
                                FROM grac_practice.implementation_status_master
                                WHERE is_active = 1
                                ORDER BY display_order, status_name;";

        var list = new List<ImplementationStatusOption>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new ImplementationStatusOption(
                StatusId:     Convert.ToInt32(reader["StatusId"]),
                StatusCode:   reader["StatusCode"]?.ToString()   ?? "",
                StatusName:   reader["StatusName"]?.ToString()   ?? "",
                DisplayOrder: Convert.ToInt32(reader["DisplayOrder"])));
        }
        return list;
    }

    public async Task<IReadOnlyList<InstanceEmployeeOption>> GetInstanceEmployeesAsync(
        long practiceInstanceId, CancellationToken cancellationToken)
    {
        if (practiceInstanceId <= 0) return Array.Empty<InstanceEmployeeOption>();

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_practice_instance_get_employees";

        var p = command.CreateParameter();
        p.ParameterName = "@practice_instance_id";
        p.DbType = DbType.Int64;
        p.Value  = practiceInstanceId;
        command.Parameters.Add(p);

        var list = new List<InstanceEmployeeOption>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new InstanceEmployeeOption(
                EmployeeId:   Convert.ToInt64(reader["EmployeeId"]),
                EmployeeCode: reader["EmployeeCode"]?.ToString() ?? "",
                EmployeeName: reader["EmployeeName"]?.ToString() ?? "",
                Email:        reader["Email"]       as string,
                Designation:  reader["Designation"] as string,
                Department:   reader["Department"]  as string));
        }
        return list;
    }

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
