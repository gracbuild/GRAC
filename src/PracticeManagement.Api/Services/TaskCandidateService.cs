// =====================================================================
// TaskCandidateService  (Task Centre v2, Phase 2)
//
// Façade over grac_practice.sp_task_candidate_* and the two source-panel
// procs from 199/200. Its own file per charter §5 — TaskService owns the
// task engine, this owns the validation gate in front of it.
//
// Wire-up: Api/Infrastructure/TaskCandidateServiceRegistration.cs
//     builder.Services.AddPracticeTaskCandidateService();
//
// As in TaskService, there is NO business logic here. Owner resolution,
// the SLA proposal and the approval gate all live in the procedures,
// because the Gap, Risk and Assurance modules raise candidates without
// ever passing through this API.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface ITaskCandidateService
{
    Task<TaskCandidateListResult> ListAsync(TaskCandidateListQuery query, CancellationToken cancellationToken);
    Task<TaskCandidateDetailResult?> GetAsync(long taskCandidateId, CancellationToken cancellationToken);
    Task<TaskCandidateCounts> CountsAsync(long? organizationId, CancellationToken cancellationToken);
    Task<TaskCandidateCommandResult> CreateAsync(TaskCandidateCreateRequest request, CancellationToken cancellationToken);
    Task<TaskCandidateCommandResult> ValidateAsync(TaskCandidateValidateRequest request, CancellationToken cancellationToken);
    Task<TaskCandidateCommandResult> ApproveAsync(TaskCandidateApproveRequest request, CancellationToken cancellationToken);
    Task<TaskCandidateCommandResult> DiscardAsync(TaskCandidateDiscardRequest request, CancellationToken cancellationToken);
    Task<IReadOnlyList<TaskSourceItemRow>> SourceItemsAsync(string sourceTypeCode, long sourceRecordId, long? organizationId, CancellationToken cancellationToken);
    Task<TaskSourceActionState?> SourceActionStateAsync(string sourceTypeCode, long sourceRecordId, CancellationToken cancellationToken);
}

public sealed class TaskCandidateService(IConfiguration configuration, ILogger<TaskCandidateService> logger) : ITaskCandidateService
{
    public async Task<TaskCandidateListResult> ListAsync(TaskCandidateListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_candidate_list";

        AddParam(command, "@organization_id",   DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",       DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@source_type_code",  DbType.String, (object?)query.SourceTypeCode ?? DBNull.Value, 40);
        AddParam(command, "@source_record_id",  DbType.Int64,  (object?)query.SourceRecordId ?? DBNull.Value);
        AddParam(command, "@owner_employee_id", DbType.Int64,  (object?)query.OwnerEmployeeId ?? DBNull.Value);
        AddParam(command, "@priority",          DbType.String, (object?)query.Priority ?? DBNull.Value, 30);
        AddParam(command, "@search",            DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",              DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",         DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

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

        var rows = new List<TaskCandidateRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapRow(reader));

        return new TaskCandidateListResult(total, page, size, rows);
    }

    public async Task<TaskCandidateDetailResult?> GetAsync(long taskCandidateId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_candidate_get";
        AddParam(command, "@task_candidate_id", DbType.Int64, taskCandidateId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        TaskCandidateDetail? header = null;
        if (await reader.ReadAsync(cancellationToken))
            header = new TaskCandidateDetail(
                TaskCandidateId:         Convert.ToInt64(reader["TaskCandidateId"]),
                CandidateNumber:         reader["CandidateNumber"]         as string,
                OrganizationId:          Convert.ToInt64(reader["OrganizationId"]),
                SourceTypeCode:          reader["SourceTypeCode"]?.ToString() ?? "",
                SourceRecordId:          Convert.ToInt64(reader["SourceRecordId"]),
                SourceReference:         reader["SourceReference"]         as string,
                SourceDedupeKey:         reader["SourceDedupeKey"]         as string,
                CandidateTitle:          reader["CandidateTitle"]?.ToString() ?? "",
                CandidateDescription:    reader["CandidateDescription"]    as string,
                TaskTypeCode:            reader["TaskTypeCode"]?.ToString() ?? "",
                LinkedReleaseId:         reader["LinkedReleaseId"]         as long?,
                LinkedControlId:         reader["LinkedControlId"]         as long?,
                LinkedPracticeId:        reader["LinkedPracticeId"]        as long?,
                LinkedInstanceId:        reader["LinkedInstanceId"]        as long?,
                ProposedOwnerEmployeeId: reader["ProposedOwnerEmployeeId"] as long?,
                ProposedOwnerName:       reader["ProposedOwnerName"]       as string,
                OwnerSourceCode:         reader["OwnerSourceCode"]         as string,
                ProposedPriority:        reader["ProposedPriority"]?.ToString() ?? "Medium",
                ProposedSlaDays:         reader["ProposedSlaDays"]         as int?,
                ProposedDueAt:           reader["ProposedDueAt"]           as DateTime?,
                SlaMasterId:             reader["SlaMasterId"]             as long?,
                SlaMasterName:           reader["SlaMasterName"]           as string,
                SlaSourceCode:           reader["SlaSourceCode"]           as string,
                StatusCode:              reader["StatusCode"]?.ToString() ?? "",
                ApprovedTaskId:          reader["ApprovedTaskId"]          as long?,
                ApprovedTaskNumber:      reader["ApprovedTaskNumber"]      as string,
                ValidatedDt:             reader["ValidatedDt"]             as DateTime?,
                ValidatedByName:         reader["ValidatedByName"]         as string,
                ApprovedDt:              reader["ApprovedDt"]              as DateTime?,
                ApprovedByName:          reader["ApprovedByName"]          as string,
                DiscardedDt:             reader["DiscardedDt"]             as DateTime?,
                DiscardedByName:         reader["DiscardedByName"]         as string,
                DiscardReason:           reader["DiscardReason"]           as string,
                IsReadyToApprove:        Convert.ToBoolean(reader["IsReadyToApprove"]),
                EnteredBy:               reader["EnteredBy"]               as string,
                EnteredDt:               Convert.ToDateTime(reader["EnteredDt"]));

        if (header is null) return null;

        var history = new List<TaskCandidateHistoryRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                history.Add(new TaskCandidateHistoryRow(
                    TaskCandidateHistoryId: Convert.ToInt64(reader["TaskCandidateHistoryId"]),
                    ActionCode:             reader["ActionCode"]?.ToString() ?? "",
                    FromStatusCode:         reader["FromStatusCode"]  as string,
                    ToStatusCode:           reader["ToStatusCode"]    as string,
                    Remark:                 reader["Remark"]          as string,
                    ActorEmployeeId:        reader["ActorEmployeeId"] as long?,
                    ActorDisplayName:       reader["ActorDisplayName"] as string,
                    EnteredDt:              Convert.ToDateTime(reader["EnteredDt"])));

        return new TaskCandidateDetailResult(header, history);
    }

    public async Task<TaskCandidateCounts> CountsAsync(long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_candidate_counts";
        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return new TaskCandidateCounts(0, 0, 0, 0, 0, 0);

        // SUM() over an empty table returns NULL, not 0.
        long Get(string name) => reader[name] == DBNull.Value ? 0 : Convert.ToInt64(reader[name]);

        return new TaskCandidateCounts(
            NewCount:       Get("NewCount"),
            ValidatedCount: Get("ValidatedCount"),
            OpenCount:      Get("OpenCount"),
            ApprovedCount:  Get("ApprovedCount"),
            DiscardedCount: Get("DiscardedCount"),
            UnownedCount:   Get("UnownedCount"));
    }

    public async Task<TaskCandidateCommandResult> CreateAsync(TaskCandidateCreateRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.SourceTypeCode)) return Fail("SourceTypeCode is required.");
        if (string.IsNullOrWhiteSpace(request.CandidateTitle)) return Fail("CandidateTitle is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_candidate_create";

            AddParam(command, "@organization_id",            DbType.Int64,  request.OrganizationId);
            AddParam(command, "@source_type_code",           DbType.String, request.SourceTypeCode, 40);
            AddParam(command, "@source_record_id",           DbType.Int64,  request.SourceRecordId);
            AddParam(command, "@candidate_title",            DbType.String, request.CandidateTitle, 250);
            AddParam(command, "@candidate_description",      DbType.String, (object?)request.CandidateDescription ?? DBNull.Value, -1);
            AddParam(command, "@source_reference",           DbType.String, (object?)request.SourceReference ?? DBNull.Value, 200);
            // Deliberately NOT exposed: @source_dedupe_key. A manual add
            // must never collide with an automatic generator's key — that
            // is what preserves BRD §15's one-source-many-tasks rule.
            AddParam(command, "@task_type_code",             DbType.String, (object?)request.TaskTypeCode ?? "Rectification", 60);
            AddParam(command, "@linked_release_id",          DbType.Int64,  (object?)request.LinkedReleaseId ?? DBNull.Value);
            AddParam(command, "@linked_control_id",          DbType.Int64,  (object?)request.LinkedControlId ?? DBNull.Value);
            AddParam(command, "@linked_practice_id",         DbType.Int64,  (object?)request.LinkedPracticeId ?? DBNull.Value);
            AddParam(command, "@linked_instance_id",         DbType.Int64,  (object?)request.LinkedInstanceId ?? DBNull.Value);
            AddParam(command, "@explicit_owner_employee_id", DbType.Int64,  (object?)request.ExplicitOwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@proposed_priority",          DbType.String, (object?)request.ProposedPriority ?? DBNull.Value, 30);
            AddParam(command, "@actor_employee_id",          DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            var idParam = command.CreateParameter();
            idParam.ParameterName = "@task_candidate_id";
            idParam.DbType        = DbType.Int64;
            idParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idParam);

            var createdParam = command.CreateParameter();
            createdParam.ParameterName = "@created";
            createdParam.DbType        = DbType.Boolean;
            createdParam.Direction     = ParameterDirection.Output;
            command.Parameters.Add(createdParam);

            await command.ExecuteNonQueryAsync(cancellationToken);

            var id = idParam.Value == DBNull.Value ? (long?)null : Convert.ToInt64(idParam.Value);
            var created = createdParam.Value != DBNull.Value && Convert.ToBoolean(createdParam.Value);

            return new TaskCandidateCommandResult(true, id, created ? "Created" : "AlreadyExists", null, null, null, created);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(CreateAsync));
        }
    }

    public async Task<TaskCandidateCommandResult> ValidateAsync(TaskCandidateValidateRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_candidate_validate_save";

            AddParam(command, "@task_candidate_id",          DbType.Int64,  request.TaskCandidateId);
            AddParam(command, "@proposed_owner_employee_id", DbType.Int64,  (object?)request.ProposedOwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@proposed_priority",          DbType.String, (object?)request.ProposedPriority ?? DBNull.Value, 30);
            AddParam(command, "@remark",                     DbType.String, (object?)request.Remark ?? DBNull.Value, -1);
            AddParam(command, "@actor_employee_id",          DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var status = await reader.ReadAsync(cancellationToken) ? reader["StatusCode"]?.ToString() : "Validated";
            return new TaskCandidateCommandResult(true, request.TaskCandidateId, status);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(ValidateAsync));
        }
    }

    public async Task<TaskCandidateCommandResult> ApproveAsync(TaskCandidateApproveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_candidate_approve";

            AddParam(command, "@task_candidate_id",       DbType.Int64,  request.TaskCandidateId);
            AddParam(command, "@approved_by_employee_id", DbType.Int64,  (object?)request.ApprovedByEmployeeId ?? DBNull.Value);
            AddParam(command, "@remark",                  DbType.String, (object?)request.Remark ?? DBNull.Value, -1);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return new TaskCandidateCommandResult(true, request.TaskCandidateId, "Approved");

            return new TaskCandidateCommandResult(
                Success:         true,
                TaskCandidateId: request.TaskCandidateId,
                StatusCode:      reader["StatusCode"]?.ToString(),
                ApprovedTaskId:  reader["ApprovedTaskId"] as long?);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(ApproveAsync));
        }
    }

    public async Task<TaskCandidateCommandResult> DiscardAsync(TaskCandidateDiscardRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.DiscardReason)) return Fail("DiscardReason is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_task_candidate_discard";

            AddParam(command, "@task_candidate_id",        DbType.Int64,  request.TaskCandidateId);
            AddParam(command, "@discard_reason",           DbType.String, request.DiscardReason, -1);
            AddParam(command, "@discarded_by_employee_id", DbType.Int64,  (object?)request.DiscardedByEmployeeId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var status = await reader.ReadAsync(cancellationToken) ? reader["StatusCode"]?.ToString() : "Discarded";
            return new TaskCandidateCommandResult(true, request.TaskCandidateId, status);
        }
        catch (SqlException ex)
        {
            return HandleSqlError(ex, nameof(DiscardAsync));
        }
    }

    public async Task<IReadOnlyList<TaskSourceItemRow>> SourceItemsAsync(
        string sourceTypeCode, long sourceRecordId, long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_source_items";

        AddParam(command, "@source_type_code", DbType.String, sourceTypeCode, 40);
        AddParam(command, "@source_record_id", DbType.Int64,  sourceRecordId);
        AddParam(command, "@organization_id",  DbType.Int64,  (object?)organizationId ?? DBNull.Value);

        var rows = new List<TaskSourceItemRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(new TaskSourceItemRow(
                ItemKind:        reader["ItemKind"]?.ToString() ?? "",
                ItemId:          Convert.ToInt64(reader["ItemId"]),
                ItemNumber:      reader["ItemNumber"]      as string,
                Title:           reader["Title"]?.ToString() ?? "",
                StatusCode:      reader["StatusCode"]?.ToString() ?? "",
                StatusName:      reader["StatusName"]      as string,
                OwnerEmployeeId: reader["OwnerEmployeeId"] as long?,
                OwnerName:       reader["OwnerName"]       as string,
                Priority:        reader["Priority"]?.ToString() ?? "Medium",
                DueAt:           reader["DueAt"]           as DateTime?,
                SlaStatusCode:   reader["SlaStatusCode"]   as string,
                IsChild:         reader["IsChild"] != DBNull.Value && Convert.ToBoolean(reader["IsChild"]),
                ParentTaskId:    reader["ParentTaskId"]    as long?,
                ChildCount:      reader["ChildCount"] == DBNull.Value ? 0 : Convert.ToInt32(reader["ChildCount"]),
                CompletedDt:     reader["CompletedDt"]     as DateTime?,
                RaisedDt:        Convert.ToDateTime(reader["RaisedDt"])));

        return rows;
    }

    public async Task<TaskSourceActionState?> SourceActionStateAsync(
        string sourceTypeCode, long sourceRecordId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_task_source_action_state_get";

        AddParam(command, "@source_type_code", DbType.String, sourceTypeCode, 40);
        AddParam(command, "@source_record_id", DbType.Int64,  sourceRecordId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        // No row simply means no task work has ever been raised for this
        // source — a normal state, not an error.
        if (!await reader.ReadAsync(cancellationToken)) return null;

        return new TaskSourceActionState(
            SourceTypeCode:      reader["SourceTypeCode"]?.ToString() ?? "",
            SourceRecordId:      Convert.ToInt64(reader["SourceRecordId"]),
            OrganizationId:      reader["OrganizationId"] as long?,
            TotalTasks:          Convert.ToInt32(reader["TotalTasks"]),
            OpenTasks:           Convert.ToInt32(reader["OpenTasks"]),
            CompletedTasks:      Convert.ToInt32(reader["CompletedTasks"]),
            OpenCandidates:      Convert.ToInt32(reader["OpenCandidates"]),
            ActionStatusCode:    reader["ActionStatusCode"]?.ToString() ?? "",
            FirstTaskDt:         reader["FirstTaskDt"]     as DateTime?,
            LastCompletedDt:     reader["LastCompletedDt"] as DateTime?,
            ActionStatusMessage: reader["ActionStatusMessage"]?.ToString() ?? "");
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

    private static TaskCandidateRow MapRow(DbDataReader r) => new(
        TaskCandidateId:         Convert.ToInt64(r["TaskCandidateId"]),
        CandidateNumber:         r["CandidateNumber"]         as string,
        OrganizationId:          Convert.ToInt64(r["OrganizationId"]),
        SourceTypeCode:          r["SourceTypeCode"]?.ToString() ?? "",
        SourceRecordId:          Convert.ToInt64(r["SourceRecordId"]),
        SourceReference:         r["SourceReference"]         as string,
        CandidateTitle:          r["CandidateTitle"]?.ToString() ?? "",
        CandidateDescription:    r["CandidateDescription"]    as string,
        TaskTypeCode:            r["TaskTypeCode"]?.ToString() ?? "",
        ProposedOwnerEmployeeId: r["ProposedOwnerEmployeeId"] as long?,
        ProposedOwnerName:       r["ProposedOwnerName"]       as string,
        OwnerSourceCode:         r["OwnerSourceCode"]         as string,
        ProposedPriority:        r["ProposedPriority"]?.ToString() ?? "Medium",
        ProposedSlaDays:         r["ProposedSlaDays"]         as int?,
        ProposedDueAt:           r["ProposedDueAt"]           as DateTime?,
        SlaMasterName:           r["SlaMasterName"]           as string,
        SlaSourceCode:           r["SlaSourceCode"]           as string,
        StatusCode:              r["StatusCode"]?.ToString() ?? "",
        ApprovedTaskId:          r["ApprovedTaskId"]          as long?,
        ApprovedTaskNumber:      r["ApprovedTaskNumber"]      as string,
        IsReadyToApprove:        Convert.ToBoolean(r["IsReadyToApprove"]),
        EnteredDt:               Convert.ToDateTime(r["EnteredDt"]),
        EnteredBy:               r["EnteredBy"]               as string);

    private TaskCandidateCommandResult HandleSqlError(SqlException ex, string op)
    {
        var reason = ex.Number switch
        {
            // validate (198)
            55818 => "NOT_EDITABLE",
            55819 => "OWNER_NOT_IN_ORG",

            // approve (198)
            55822 => "ALREADY_APPROVED",
            55823 => "DISCARDED",
            55824 => "OWNER_REQUIRED",

            // discard (198)
            55831 => "REASON_REQUIRED",
            55833 => "ALREADY_APPROVED",
            55834 => "ALREADY_DISCARDED",

            // everything else in the Phase 2 range is a validation failure
            >= 55800 and <= 55899 => "VALIDATION_ERROR",

            _ => "SQL_ERROR"
        };
        logger.LogWarning(ex, "TaskCandidateService.{Op} failed with SQL error {Number}: {Message}", op, ex.Number, ex.Message);
        return new TaskCandidateCommandResult(false, null, null, null, ex.Message, reason);
    }

    private static TaskCandidateCommandResult Fail(string error) =>
        new(false, null, null, null, error, "VALIDATION_ERROR");
}
