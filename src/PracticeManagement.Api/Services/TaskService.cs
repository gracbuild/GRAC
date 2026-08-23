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
//
// TASK CENTRE v2 (BRD 16 Aug 2026)
// --------------------------------
// The v2 methods are grouped below the original five. Two deliberate
// design points:
//
//   * The service adds NO business logic. Priority asymmetry, SLA
//     derivation, child inheritance and the completion gate all live in
//     the procedures (192-196), because the Gap Centre, sweeps and
//     Exception Centre must obey the same rules without going through
//     this API.
//
//   * Row mapping is COLUMN-TOLERANT. MapRow only reads a v2 column when
//     the result set actually carries it, so the Api tier keeps working
//     against a database where 195 has not been applied yet. That makes
//     the migration order (DB first, then app) non-breaking in either
//     direction.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ITaskService
{
    // ---- original contract (037/048) --------------------------------
    Task<TaskListResult> ListAsync(TaskListQuery query, CancellationToken cancellationToken);
    Task<TaskCommandResult> OpenAsync(TaskOpenRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> AssignAsync(TaskAssignRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> TransitionAsync(TaskTransitionRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> CloseAsync(TaskCloseRequest request, CancellationToken cancellationToken);

    // ---- Task Centre v2 (192-196) -----------------------------------
    Task<TaskCountsResult> CountsAsync(long? organizationId, CancellationToken cancellationToken);
    Task<TaskDetailResult?> GetAsync(long taskId, CancellationToken cancellationToken);
    Task<TaskCommandResult> ChangePriorityAsync(TaskPriorityChangeRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> RequestSlaExtensionAsync(TaskSlaExtensionRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> ApproveSlaExtensionAsync(TaskGovernanceApproveRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> ApprovePriorityReductionAsync(TaskGovernanceApproveRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> CreateChildAsync(TaskChildCreateRequest request, CancellationToken cancellationToken);
    Task<TaskCommandResult> CompleteAsync(TaskCompleteRequest request, CancellationToken cancellationToken);
    Task<TaskCompletionEligibility?> CompletionEligibilityAsync(long taskId, CancellationToken cancellationToken);
    Task<TaskCommandResult> AddActivityAsync(TaskActivityAddRequest request, CancellationToken cancellationToken);
    Task<TaskOwnerResolveResult> ResolveOwnerAsync(TaskOwnerResolveQuery query, CancellationToken cancellationToken);
    Task<IReadOnlyList<TaskSourceTaskRow>> SourceTasksAsync(string sourceTypeCode, long sourceRecordId, long? organizationId, CancellationToken cancellationToken);
    Task<TaskCommandResult> AddAttachmentAsync(long taskId, string fileName, string? contentType, byte[] fileData, string? evidenceDescription, long? uploadedByEmployeeId, CancellationToken cancellationToken);
    Task<TaskAttachmentContent?> GetAttachmentAsync(long taskAttachmentId, CancellationToken cancellationToken);
}

public sealed class TaskService(IConfiguration configuration, ILogger<TaskService> logger) : ITaskService
{
    // Delegates to SqlConnectionStringResolver — see PermissionService.

    // =================================================================
    // Original contract
    // =================================================================

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

        // v2 filters (195). Sent only when the proc understands them, so
        // an Api deployed ahead of migration 195 still works.
        if (await ProcHasParameterAsync(connection, "sp_task_list", "@include_children", cancellationToken))
        {
            AddParam(command, "@parent_task_id",   DbType.Int64,  (object?)query.ParentTaskId ?? DBNull.Value);
            AddParam(command, "@include_children", DbType.Boolean, query.IncludeChildren ?? false);
            AddParam(command, "@sla_status_code",  DbType.String, (object?)query.SlaStatusCode ?? DBNull.Value, 30);
            AddParam(command, "@source_type_code", DbType.String, (object?)query.SourceTypeCode ?? DBNull.Value, 40);
            AddParam(command, "@source_record_id", DbType.Int64,  (object?)query.SourceRecordId ?? DBNull.Value);
            AddParam(command, "@priority",         DbType.String, (object?)query.Priority ?? DBNull.Value, 30);
        }

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
            var cols = ColumnSet(reader);
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapRow(reader, cols));
        }

        return new TaskListResult(total, page, size, rows);
    }

    public async Task<TaskCommandResult> OpenAsync(TaskOpenRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.TaskTypeCode))      return Fail("TaskTypeCode is required.");
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
            AddParam(command, "@start_date",             DbType.DateTime2, (object?)request.StartDate ?? DBNull.Value);
            AddParam(command, "@target_date",            DbType.DateTime2, (object?)request.TargetDate ?? DBNull.Value);

            // v3 params (196). Owner resolution and SLA derivation happen
            // inside the proc so every caller — not just this API — gets
            // them (BRD §6, §8).
            if (await ProcHasParameterAsync(connection, "sp_task_open", "@source_type_code", cancellationToken))
            {
                AddParam(command, "@source_type_code", DbType.String, (object?)request.SourceTypeCode ?? DBNull.Value, 40);
                AddParam(command, "@source_record_id", DbType.Int64,  (object?)request.SourceRecordId ?? DBNull.Value);
                AddParam(command, "@source_reference", DbType.String, (object?)request.SourceReference ?? DBNull.Value, 200);
                AddParam(command, "@resolve_owner",    DbType.Boolean, request.ResolveOwner ?? true);
            }

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

            // BRD §6: "Owner reassignment is operational freedom. It
            // requires no Exception approval. Every reassignment must be
            // auditable." sp_task_assign already writes to
            // practice_audit_trace; this adds the human-readable entry to
            // the task's own activity feed (BRD §16). Best-effort: a
            // logging failure must not fail a completed reassignment.
            await TryLogActivityAsync(connection, request.TaskId, "Reassign",
                request.ReasonText, null, request.AssignedToEmployeeId.ToString(),
                request.ActorEmployeeId, cancellationToken);

            await TryStampOwnerSourceAsync(connection, request.TaskId, cancellationToken);

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

            await TryLogActivityAsync(connection, request.TaskId, "StatusChange",
                request.ReasonText, null, request.ToStatusCode,
                request.ActorEmployeeId, cancellationToken);

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

    // =================================================================
    // Task Centre v2
    // =================================================================

    public async Task<TaskCountsResult> CountsAsync(long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_center_counts";
        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return new TaskCountsResult(0, 0, 0, 0, 0, 0);

        var cols = ColumnSet(reader);
        return new TaskCountsResult(
            GapsCount:            GetLong(reader, cols, "GapsCount") ?? 0,
            ImplementationCount:  GetLong(reader, cols, "ImplementationCount") ?? 0,
            AssuranceCount:       GetLong(reader, cols, "AssuranceCount") ?? 0,
            CustomCount:          GetLong(reader, cols, "CustomCount") ?? 0,
            BreachedCount:        GetLong(reader, cols, "BreachedCount") ?? 0,
            PendingApprovalCount: GetLong(reader, cols, "PendingApprovalCount") ?? 0);
    }

    public async Task<TaskDetailResult?> GetAsync(long taskId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_get";
        AddParam(command, "@task_id", DbType.Int64, taskId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        // ---- 1. header ----
        TaskListRow? header = null;
        if (await reader.ReadAsync(cancellationToken))
        {
            var cols = ColumnSet(reader);
            header = MapRow(reader, cols);
        }
        if (header is null) return null;

        // ---- 2. activity ----
        var activity = new List<TaskActivityRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                activity.Add(new TaskActivityRow(
                    TaskActivityId:   Convert.ToInt64(reader["TaskActivityId"]),
                    TaskId:           Convert.ToInt64(reader["TaskId"]),
                    ActivityTypeCode: reader["ActivityTypeCode"]?.ToString() ?? "",
                    Remark:           reader["Remark"]           as string,
                    FromValue:        reader["FromValue"]        as string,
                    ToValue:          reader["ToValue"]          as string,
                    ActorEmployeeId:  reader["ActorEmployeeId"]  as long?,
                    ActorDisplayName: reader["ActorDisplayName"] as string,
                    EnteredDt:        Convert.ToDateTime(reader["EnteredDt"])));
        }

        // ---- 3. attachments (metadata only) ----
        var attachments = new List<TaskAttachmentRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                attachments.Add(new TaskAttachmentRow(
                    TaskAttachmentId:     Convert.ToInt64(reader["TaskAttachmentId"]),
                    FileName:             reader["FileName"]?.ToString() ?? "",
                    ContentType:          reader["ContentType"]          as string,
                    FileSizeBytes:        Convert.ToInt64(reader["FileSizeBytes"]),
                    EvidenceDescription:  reader["EvidenceDescription"]  as string,
                    UploadedByEmployeeId: reader["UploadedByEmployeeId"] as long?,
                    UploadedByName:       reader["UploadedByName"]       as string,
                    UploadedDt:           Convert.ToDateTime(reader["UploadedDt"])));
        }

        // ---- 4. children ----
        var children = new List<TaskChildRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                children.Add(new TaskChildRow(
                    TaskId:                 Convert.ToInt64(reader["TaskId"]),
                    TaskNumber:             reader["TaskNumber"]             as string,
                    SubjectTitle:           reader["SubjectTitle"]?.ToString() ?? "",
                    SubjectDescription:     reader["SubjectDescription"]     as string,
                    AssignedToEmployeeId:   reader["AssignedToEmployeeId"]   as long?,
                    AssignedToEmployeeName: reader["AssignedToEmployeeName"] as string,
                    Priority:               reader["Priority"]?.ToString() ?? "Medium",
                    IsMandatoryChild:       reader["IsMandatoryChild"] == DBNull.Value ? null : Convert.ToBoolean(reader["IsMandatoryChild"]),
                    ChildTargetDate:        reader["ChildTargetDate"]        as DateTime?,
                    SlaDueAt:               reader["SlaDueAt"]               as DateTime?,
                    SlaStatusCode:          reader["SlaStatusCode"]          as string,
                    CurrentStatusCode:      reader["CurrentStatusCode"]?.ToString() ?? "",
                    CurrentStatusName:      reader["CurrentStatusName"]?.ToString() ?? "",
                    ClosedAt:               reader["ClosedAt"]               as DateTime?,
                    CompletedDt:            reader["CompletedDt"]            as DateTime?));
        }

        // ---- 5. governance requests ----
        var requests = new List<TaskGovernanceRequestRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                requests.Add(new TaskGovernanceRequestRow(
                    ExceptionRequestId: Convert.ToInt64(reader["ExceptionRequestId"]),
                    RequestTypeCode:    reader["RequestTypeCode"]?.ToString() ?? "",
                    RequestTitle:       reader["RequestTitle"]?.ToString() ?? "",
                    RequestReason:      reader["RequestReason"]    as string,
                    StatusCode:         reader["StatusCode"]?.ToString() ?? "",
                    PriorityOriginal:   reader["PriorityOriginal"]  as string,
                    PriorityRequested:  reader["PriorityRequested"] as string,
                    DueAtOriginal:      reader["DueAtOriginal"]     as DateTime?,
                    DueAtRequested:     reader["DueAtRequested"]    as DateTime?,
                    RequestedOn:        reader["RequestedOn"]       as DateTime?,
                    RequestedByName:    reader["RequestedByName"]   as string,
                    ApprovedOn:         reader["ApprovedOn"]        as DateTime?,
                    ApprovedByName:     reader["ApprovedByName"]    as string,
                    RejectedOn:         reader["RejectedOn"]        as DateTime?,
                    RejectedByName:     reader["RejectedByName"]    as string,
                    RejectionReason:    reader["RejectionReason"]   as string));
        }

        return new TaskDetailResult(header, activity, attachments, children, requests);
    }

    public async Task<TaskCommandResult> ChangePriorityAsync(TaskPriorityChangeRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.NewPriority)) return Fail("NewPriority is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_priority_change";

            AddParam(command, "@task_id",           DbType.Int64,  request.TaskId);
            AddParam(command, "@new_priority",      DbType.String, request.NewPriority, 30);
            AddParam(command, "@reason",            DbType.String, (object?)request.Reason ?? DBNull.Value, -1);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCommandResult(true, request.TaskId);

            var cols = ColumnSet(reader);
            return new TaskCommandResult(
                Success:            true,
                TaskId:             request.TaskId,
                ExceptionRequestId: GetLong(reader, cols, "ExceptionRequestId"),
                StatusCode:         GetString(reader, cols, "StatusCode"));
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(ChangePriorityAsync));
        }
    }

    public async Task<TaskCommandResult> RequestSlaExtensionAsync(TaskSlaExtensionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ExtensionReason)) return Fail("ExtensionReason is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_sla_extension_request_create";

            AddParam(command, "@task_id",                  DbType.Int64,     request.TaskId);
            AddParam(command, "@requested_due_at",         DbType.DateTime2, request.RequestedDueAt);
            AddParam(command, "@extension_reason",         DbType.String,    request.ExtensionReason, -1);
            AddParam(command, "@requested_by_employee_id", DbType.Int64,     request.RequestedByEmployeeId);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCommandResult(true, request.TaskId);

            var cols = ColumnSet(reader);
            return new TaskCommandResult(
                Success:            true,
                TaskId:             request.TaskId,
                ExceptionRequestId: GetLong(reader, cols, "ExceptionRequestId"),
                StatusCode:         GetString(reader, cols, "StatusCode"));
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(RequestSlaExtensionAsync));
        }
    }

    public Task<TaskCommandResult> ApproveSlaExtensionAsync(TaskGovernanceApproveRequest request, CancellationToken cancellationToken)
        => ApproveGovernanceAsync("grac_practice.sp_task_sla_extension_approve", request, nameof(ApproveSlaExtensionAsync), cancellationToken);

    public Task<TaskCommandResult> ApprovePriorityReductionAsync(TaskGovernanceApproveRequest request, CancellationToken cancellationToken)
        => ApproveGovernanceAsync("grac_practice.sp_task_priority_reduction_approve", request, nameof(ApprovePriorityReductionAsync), cancellationToken);

    /// <summary>
    /// Both approval procs share an identical contract — one input pair,
    /// one summary row — so they share one implementation rather than two
    /// near-identical copies.
    /// </summary>
    private async Task<TaskCommandResult> ApproveGovernanceAsync(
        string procName, TaskGovernanceApproveRequest request, string op, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@exception_request_id",    DbType.Int64, request.ExceptionRequestId);
            AddParam(command, "@approved_by_employee_id", DbType.Int64, request.ApprovedByEmployeeId);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCommandResult(true, null, null, null, request.ExceptionRequestId, "Approved");

            var cols = ColumnSet(reader);
            return new TaskCommandResult(
                Success:            true,
                TaskId:             GetLong(reader, cols, "TaskId"),
                ExceptionRequestId: GetLong(reader, cols, "ExceptionRequestId"),
                StatusCode:         GetString(reader, cols, "StatusCode"));
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, op);
        }
    }

    public async Task<TaskCommandResult> CreateChildAsync(TaskChildCreateRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.SubjectTitle)) return Fail("SubjectTitle is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_child_create";

            AddParam(command, "@parent_task_id",          DbType.Int64,     request.ParentTaskId);
            AddParam(command, "@subject_title",           DbType.String,    request.SubjectTitle, 250);
            AddParam(command, "@subject_description",     DbType.String,    (object?)request.SubjectDescription ?? DBNull.Value, -1);
            AddParam(command, "@assigned_to_employee_id", DbType.Int64,     (object?)request.AssignedToEmployeeId ?? DBNull.Value);
            AddParam(command, "@is_mandatory",            DbType.Boolean,   request.IsMandatory ?? true);
            AddParam(command, "@child_target_date",       DbType.DateTime2, (object?)request.ChildTargetDate ?? DBNull.Value);
            AddParam(command, "@actor_employee_id",       DbType.Int64,     (object?)request.ActorEmployeeId ?? DBNull.Value);

            var childIdParam = command.CreateParameter();
            childIdParam.ParameterName = "@child_task_id";
            childIdParam.DbType        = DbType.Int64;
            childIdParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(childIdParam);

            // The proc returns a summary row AND sets the OUTPUT param;
            // the reader must be fully consumed before OUTPUT values are
            // populated by SqlClient.
            await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken)) { }
                while (await reader.NextResultAsync(cancellationToken)) { }
            }

            var childId = childIdParam.Value is long l ? l
                        : childIdParam.Value == DBNull.Value ? (long?)null
                        : Convert.ToInt64(childIdParam.Value);

            return new TaskCommandResult(true, childId, null, null, null, "Created");
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(CreateChildAsync));
        }
    }

    public async Task<TaskCommandResult> CompleteAsync(TaskCompleteRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_complete";

            AddParam(command, "@task_id",           DbType.Int64,  request.TaskId);
            AddParam(command, "@completion_remark", DbType.String, (object?)request.CompletionRemark ?? DBNull.Value, -1);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_role_code",   DbType.String, (object?)request.ActorRoleCode ?? DBNull.Value, 60);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCommandResult(true, request.TaskId, null, null, null, "Completed");

            var cols = ColumnSet(reader);
            return new TaskCommandResult(
                Success:    true,
                TaskId:     request.TaskId,
                StatusCode: GetString(reader, cols, "StatusCode"));
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(CompleteAsync));
        }
    }

    public async Task<TaskCompletionEligibility?> CompletionEligibilityAsync(long taskId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_completion_eligibility";
        AddParam(command, "@task_id", DbType.Int64, taskId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new TaskCompletionEligibility(
            TaskId:                       Convert.ToInt64(reader["TaskId"]),
            IsEligible:                   Convert.ToBoolean(reader["IsEligible"]),
            Reason:                       reader["Reason"]?.ToString() ?? "",
            ChildCount:                   Convert.ToInt32(reader["ChildCount"]),
            MandatoryChildCount:          Convert.ToInt32(reader["MandatoryChildCount"]),
            MandatoryChildCompletedCount: Convert.ToInt32(reader["MandatoryChildCompletedCount"]),
            MandatoryChildOpenCount:      Convert.ToInt32(reader["MandatoryChildOpenCount"]));
    }

    public async Task<TaskCommandResult> AddActivityAsync(TaskActivityAddRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ActivityTypeCode)) return Fail("ActivityTypeCode is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_activity_add";

            AddParam(command, "@task_id",            DbType.Int64,  request.TaskId);
            AddParam(command, "@activity_type_code", DbType.String, request.ActivityTypeCode, 40);
            AddParam(command, "@remark",             DbType.String, (object?)request.Remark ?? DBNull.Value, -1);
            AddParam(command, "@from_value",         DbType.String, (object?)request.FromValue ?? DBNull.Value, 400);
            AddParam(command, "@to_value",           DbType.String, (object?)request.ToValue ?? DBNull.Value, 400);
            AddParam(command, "@actor_employee_id",  DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new TaskCommandResult(true, request.TaskId);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(AddActivityAsync));
        }
    }

    public async Task<TaskOwnerResolveResult> ResolveOwnerAsync(TaskOwnerResolveQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_owner_resolve";

        AddParam(command, "@organization_id",            DbType.Int64,  query.OrganizationId);
        AddParam(command, "@source_type_code",           DbType.String, (object?)query.SourceTypeCode ?? DBNull.Value, 40);
        AddParam(command, "@source_record_id",           DbType.Int64,  (object?)query.SourceRecordId ?? DBNull.Value);
        AddParam(command, "@linked_practice_id",         DbType.Int64,  (object?)query.LinkedPracticeId ?? DBNull.Value);
        AddParam(command, "@linked_control_id",          DbType.Int64,  (object?)query.LinkedControlId ?? DBNull.Value);
        AddParam(command, "@linked_instance_id",         DbType.Int64,  (object?)query.LinkedInstanceId ?? DBNull.Value);
        AddParam(command, "@explicit_owner_employee_id", DbType.Int64,  (object?)query.ExplicitOwnerEmployeeId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return new TaskOwnerResolveResult(null, null, "MANUAL", "Manual assignment required");

        return new TaskOwnerResolveResult(
            OwnerEmployeeId:   reader["OwnerEmployeeId"]   as long?,
            OwnerEmployeeName: reader["OwnerEmployeeName"] as string,
            OwnerSourceCode:   reader["OwnerSourceCode"]?.ToString() ?? "MANUAL",
            OwnerSourceName:   reader["OwnerSourceName"]?.ToString() ?? "Manual assignment required");
    }

    public async Task<IReadOnlyList<TaskSourceTaskRow>> SourceTasksAsync(
        string sourceTypeCode, long sourceRecordId, long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_source_tasks";

        AddParam(command, "@source_type_code", DbType.String, sourceTypeCode, 40);
        AddParam(command, "@source_record_id", DbType.Int64,  sourceRecordId);
        AddParam(command, "@organization_id",  DbType.Int64,  (object?)organizationId ?? DBNull.Value);

        var rows = new List<TaskSourceTaskRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new TaskSourceTaskRow(
                TaskId:                 Convert.ToInt64(reader["TaskId"]),
                TaskNumber:             reader["TaskNumber"]             as string,
                SubjectTitle:           reader["SubjectTitle"]?.ToString() ?? "",
                TaskTypeCode:           reader["TaskTypeCode"]?.ToString() ?? "",
                TaskTypeName:           reader["TaskTypeName"]?.ToString() ?? "",
                AssignedToEmployeeId:   reader["AssignedToEmployeeId"]   as long?,
                AssignedToEmployeeName: reader["AssignedToEmployeeName"] as string,
                Priority:               reader["Priority"]?.ToString() ?? "Medium",
                StandardDueAt:          reader["StandardDueAt"]          as DateTime?,
                ApprovedExtendedDueAt:  reader["ApprovedExtendedDueAt"]  as DateTime?,
                SlaDueAt:               reader["SlaDueAt"]               as DateTime?,
                SlaStatusCode:          reader["SlaStatusCode"]          as string,
                CurrentStatusCode:      reader["CurrentStatusCode"]?.ToString() ?? "",
                CurrentStatusName:      reader["CurrentStatusName"]?.ToString() ?? "",
                IsChild:                Convert.ToBoolean(reader["IsChild"]),
                ParentTaskId:           reader["ParentTaskId"]           as long?,
                ChildCount:             Convert.ToInt32(reader["ChildCount"]),
                ClosedAt:               reader["ClosedAt"]               as DateTime?,
                CompletedDt:            reader["CompletedDt"]            as DateTime?));

        return rows;
    }

    public async Task<TaskCommandResult> AddAttachmentAsync(
        long taskId, string fileName, string? contentType, byte[] fileData,
        string? evidenceDescription, long? uploadedByEmployeeId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(fileName)) return Fail("fileName is required.");
        if (fileData is null || fileData.Length == 0) return Fail("File content is empty.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_attachment_add";

            AddParam(command, "@task_id",                 DbType.Int64,  taskId);
            AddParam(command, "@file_name",               DbType.String, fileName, 500);
            AddParam(command, "@content_type",            DbType.String, (object?)contentType ?? DBNull.Value, 200);
            AddParam(command, "@file_data",               DbType.Binary, fileData, -1);
            AddParam(command, "@evidence_description",    DbType.String, (object?)evidenceDescription ?? DBNull.Value, 1000);
            AddParam(command, "@uploaded_by_employee_id", DbType.Int64,  (object?)uploadedByEmployeeId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCommandResult(true, taskId);

            var cols = ColumnSet(reader);
            return new TaskCommandResult(
                Success:    true,
                TaskId:     GetLong(reader, cols, "TaskAttachmentId"),
                StatusCode: "Uploaded");
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(AddAttachmentAsync));
        }
    }

    public async Task<TaskAttachmentContent?> GetAttachmentAsync(long taskAttachmentId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_attachment_get";
        AddParam(command, "@task_attachment_id", DbType.Int64, taskAttachmentId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new TaskAttachmentContent(
            TaskAttachmentId: Convert.ToInt64(reader["TaskAttachmentId"]),
            TaskId:           Convert.ToInt64(reader["TaskId"]),
            FileName:         reader["FileName"]?.ToString() ?? "download",
            ContentType:      reader["ContentType"] as string,
            FileSizeBytes:    Convert.ToInt64(reader["FileSizeBytes"]),
            FileData:         (byte[])reader["FileData"]);
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

    /// <summary>
    /// Lets the Api tier stay deployable against a database that has not
    /// yet received a migration: v2 parameters are only bound when the
    /// procedure actually declares them. Cheap metadata query, and the
    /// alternative (a hard failure on "too many arguments specified") is
    /// far worse operationally.
    /// </summary>
    private static async Task<bool> ProcHasParameterAsync(
        DbConnection connection, string procName, string parameterName, CancellationToken cancellationToken)
    {
        await using var cmd = connection.CreateCommand();
        cmd.CommandType = CommandType.Text;
        cmd.CommandText = @"
            SELECT CASE WHEN EXISTS (
                       SELECT 1 FROM sys.parameters
                        WHERE object_id = OBJECT_ID('grac_practice.' + @proc)
                          AND name = @param)
                   THEN 1 ELSE 0 END;";
        AddParam(cmd, "@proc",  DbType.String, procName, 128);
        AddParam(cmd, "@param", DbType.String, parameterName, 128);

        var result = await cmd.ExecuteScalarAsync(cancellationToken);
        return result is not null && Convert.ToInt32(result) == 1;
    }

    /// <summary>Best-effort activity note. Never throws — the governing
    /// action has already committed by the time this runs.</summary>
    private async Task TryLogActivityAsync(
        DbConnection connection, long taskId, string activityTypeCode,
        string? remark, string? fromValue, string? toValue,
        long? actorEmployeeId, CancellationToken cancellationToken)
    {
        try
        {
            await using var cmd = connection.CreateCommand();
            cmd.CommandType = CommandType.StoredProcedure;
            cmd.CommandText = "grac_practice.sp_task_activity_add";
            AddParam(cmd, "@task_id",            DbType.Int64,  taskId);
            AddParam(cmd, "@activity_type_code", DbType.String, activityTypeCode, 40);
            AddParam(cmd, "@remark",             DbType.String, (object?)remark ?? DBNull.Value, -1);
            AddParam(cmd, "@from_value",         DbType.String, (object?)fromValue ?? DBNull.Value, 400);
            AddParam(cmd, "@to_value",           DbType.String, (object?)toValue ?? DBNull.Value, 400);
            AddParam(cmd, "@actor_employee_id",  DbType.Int64,  (object?)actorEmployeeId ?? DBNull.Value);
            await cmd.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogDebug(ex, "TaskService: activity log skipped for task {TaskId} ({Type}).", taskId, activityTypeCode);
        }
    }

    /// <summary>
    /// BRD §6: a manual reassignment supersedes whatever rung of the
    /// ownership ladder originally proposed the owner, so the provenance
    /// stamp becomes REASSIGNED. Best-effort for the same reason as
    /// TryLogActivityAsync.
    /// </summary>
    private async Task TryStampOwnerSourceAsync(DbConnection connection, long taskId, CancellationToken cancellationToken)
    {
        try
        {
            await using var cmd = connection.CreateCommand();
            cmd.CommandType = CommandType.Text;
            cmd.CommandText = @"
                IF COL_LENGTH('grac_practice.practice_task','owner_source_code') IS NOT NULL
                    UPDATE grac_practice.practice_task
                       SET owner_source_code = N'REASSIGNED'
                     WHERE task_id = @task_id;";
            AddParam(cmd, "@task_id", DbType.Int64, taskId);
            await cmd.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogDebug(ex, "TaskService: owner_source stamp skipped for task {TaskId}.", taskId);
        }
    }

    // ---- column-tolerant readers ------------------------------------
    private static HashSet<string> ColumnSet(DbDataReader reader)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < reader.FieldCount; i++) set.Add(reader.GetName(i));
        return set;
    }

    private static object? Raw(DbDataReader r, HashSet<string> cols, string name)
    {
        if (!cols.Contains(name)) return null;
        var v = r[name];
        return v == DBNull.Value ? null : v;
    }

    private static string?   GetString(DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n)?.ToString();
    private static long?     GetLong  (DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n) is { } v ? Convert.ToInt64(v)   : null;
    private static int?      GetInt   (DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n) is { } v ? Convert.ToInt32(v)   : null;
    private static bool      GetBool  (DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n) is { } v && Convert.ToBoolean(v);
    private static bool?     GetBoolN (DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n) is { } v ? Convert.ToBoolean(v) : null;
    private static DateTime? GetDate  (DbDataReader r, HashSet<string> c, string n) => Raw(r, c, n) is { } v ? Convert.ToDateTime(v): null;

    private static TaskListRow MapRow(DbDataReader reader, HashSet<string> c) => new(
        // ---- original columns (always present) ----
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
        ClosedAt:                   reader["closed_at"]    as DateTime?,

        // ---- v2 columns (present once 192/195 are applied) ----
        TaskNumber:                 GetString(reader, c, "task_number"),
        AssignedToEmployeeName:     GetString(reader, c, "assigned_to_employee_name"),
        OwnerSourceCode:            GetString(reader, c, "owner_source_code"),

        StandardSlaDays:            GetInt   (reader, c, "standard_sla_days"),
        StandardDueAt:              GetDate  (reader, c, "standard_due_at"),
        ApprovedExtendedDueAt:      GetDate  (reader, c, "approved_extended_due_at"),
        SlaSourceCode:              GetString(reader, c, "sla_source_code"),
        SlaMasterName:              GetString(reader, c, "sla_master_name"),
        ExtensionStatusCode:        GetString(reader, c, "extension_status_code"),
        RequestedDueAt:             GetDate  (reader, c, "requested_due_at"),
        ExtensionReason:            GetString(reader, c, "extension_reason"),
        IsExtended:                 GetBool  (reader, c, "is_extended"),

        SlaTimingCode:              GetString(reader, c, "sla_timing_code"),
        SlaStatusCode:              GetString(reader, c, "sla_status_code"),
        DaysToDue:                  GetInt   (reader, c, "days_to_due"),

        RequestedPriority:          GetString(reader, c, "requested_priority"),
        PriorityChangeStatusCode:   GetString(reader, c, "priority_change_status_code"),

        ParentTaskId:               GetLong  (reader, c, "parent_task_id"),
        ParentTaskNumber:           GetString(reader, c, "parent_task_number"),
        ParentTaskTitle:            GetString(reader, c, "parent_task_title"),
        IsChild:                    GetBool  (reader, c, "is_child"),
        IsMandatoryChild:           GetBoolN (reader, c, "is_mandatory_child"),
        ChildTargetDate:            GetDate  (reader, c, "child_target_date"),
        ChildCount:                 GetInt   (reader, c, "child_count") ?? 0,
        MandatoryChildCount:        GetInt   (reader, c, "mandatory_child_count") ?? 0,
        MandatoryChildOpenCount:    GetInt   (reader, c, "mandatory_child_open_count") ?? 0,
        IsEligibleForCompletion:    GetBool  (reader, c, "is_eligible_for_completion"),

        SourceTypeCode:             GetString(reader, c, "source_type_code"),
        SourceRecordId:             GetLong  (reader, c, "source_record_id"),
        SourceReference:            GetString(reader, c, "source_reference"),

        CompletedByEmployeeId:      GetLong  (reader, c, "completed_by_employee_id"),
        CompletedByEmployeeName:    GetString(reader, c, "completed_by_employee_name"),
        CompletedDt:                GetDate  (reader, c, "completed_dt"));

    private TaskCommandResult HandleSqlError(SqlException ex, string op)
    {
        // Map framework + Task Centre v2 error codes back to reason
        // strings the client can branch on. The HTTP status mapping lives
        // in TaskController.Respond.
        var reason = ex.Number switch
        {
            // state machine / two-gate (037, 035)
            53520 => "ILLEGAL_TRANSITION",
            53521 => "REASON_REQUIRED",
            53752 => "TWO_GATE_NOT_PASSED",

            // priority governance (193) — BRD §7
            55619 => "CHILD_PRIORITY_LOCKED",
            55620 => "REASON_REQUIRED",
            55621 => "ACTOR_REQUIRED",
            55622 => "PRIORITY_REQUEST_PENDING",

            // SLA extension (194) — BRD §8
            55656 => "CHILD_SLA_LOCKED",
            55657 => "EXTENSION_PENDING",
            55658 => "EXTENSION_NOT_LATER",

            // parent / child (194) — BRD §11
            55673 => "PARENT_COMPLETED",
            55674 => "CHILD_NESTING_NOT_ALLOWED",

            // completion (194) — BRD §12
            55692 => "ALREADY_COMPLETED",
            55693 => "COMPLETION_BLOCKED",

            // everything else in the Task Centre v2 ranges is a
            // validation failure rather than a server fault
            >= 55600 and <= 55799 => "VALIDATION_ERROR",

            _     => "SQL_ERROR"
        };
        logger.LogWarning(ex, "TaskService.{Op} failed with SQL error {Number}: {Message}", op, ex.Number, ex.Message);
        return new TaskCommandResult(false, null, ex.Message, reason);
    }

    private static TaskCommandResult Fail(string error) => new(false, null, error);
}
