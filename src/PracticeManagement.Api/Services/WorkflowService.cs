// =====================================================================
// WorkflowService
//
// Thin facade over grac_practice.sp_workflow_* / sp_event_* /
// sp_checklist_* / sp_entity_type_* / sp_event_gap_* procedures
// (Workflow & Event-Driven Assurance Engine per BRD v1.0).
//
// Kept in its own file so it can be reviewed / wired independently of
// other services. Registered via
// Infrastructure/WorkflowServiceRegistration.cs.
//
// Follows the CustomGapService pattern:
//   * Single interface, single implementation
//   * DbType-typed parameter helper
//   * OpenAsync helper resolves connection string via
//     SqlConnectionStringResolver
//   * All errors caught, logged, and returned as (Success=false, Error)
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IWorkflowService
{
    // Workflow
    Task<WorkflowListResult>       ListWorkflowsAsync(WorkflowListQuery query, CancellationToken cancellationToken);
    Task<WorkflowCommandResult>    SaveWorkflowAsync(WorkflowSaveRequest request, CancellationToken cancellationToken);

    // Workflow Stage
    Task<IReadOnlyList<WorkflowStageRow>> ListWorkflowStagesAsync(long workflowId, CancellationToken cancellationToken);
    Task<WorkflowStageCommandResult>      SaveWorkflowStageAsync(WorkflowStageSaveRequest request, CancellationToken cancellationToken);

    // Entity Type
    Task<IReadOnlyList<EntityTypeRow>>    ListEntityTypesAsync(long? organizationId, string? statusCode, CancellationToken cancellationToken);
    Task<EntityTypeCommandResult>         SaveEntityTypeAsync(EntityTypeSaveRequest request, CancellationToken cancellationToken);

    // Event Definition
    Task<EventDefinitionListResult>       ListEventDefinitionsAsync(EventDefinitionListQuery query, CancellationToken cancellationToken);
    Task<EventDefinitionCommandResult>    SaveEventDefinitionAsync(EventDefinitionSaveRequest request, CancellationToken cancellationToken);

    // Checklist
    Task<ChecklistListResult>             ListChecklistsAsync(ChecklistListQuery query, CancellationToken cancellationToken);
    Task<ChecklistCommandResult>          SaveChecklistAsync(ChecklistSaveRequest request, CancellationToken cancellationToken);
    Task<IReadOnlyList<ChecklistItemRow>> ListChecklistItemsAsync(long checklistId, CancellationToken cancellationToken);
    Task<ChecklistItemCommandResult>      SaveChecklistItemAsync(ChecklistItemSaveRequest request, CancellationToken cancellationToken);

    // Event-Checklist Mapping
    Task<EventChecklistMappingListResult>   ListEventChecklistMappingsAsync(EventChecklistMappingListQuery query, CancellationToken cancellationToken);
    Task<EventChecklistMappingCommandResult> SaveEventChecklistMappingAsync(EventChecklistMappingSaveRequest request, CancellationToken cancellationToken);

    // Event Instance
    Task<EventInstanceListResult>         ListEventInstancesAsync(EventInstanceListQuery query, CancellationToken cancellationToken);
    Task<EventInstanceCommandResult>      TriggerEventAsync(EventInstanceTriggerRequest request, CancellationToken cancellationToken);
    Task<EventInstanceCommandResult>      CompleteEventInstanceAsync(EventInstanceCompleteRequest request, CancellationToken cancellationToken);
    Task<EventInstanceCommandResult>      SaveEventInstanceItemAsync(EventInstanceItemSaveRequest request, CancellationToken cancellationToken);

    // Event Gap
    Task<EventGapListResult>              ListEventGapsAsync(EventGapListQuery query, CancellationToken cancellationToken);
    Task<EventGapCommandResult>           OpenEventGapAsync(EventGapOpenRequest request, CancellationToken cancellationToken);
    Task<EventGapCommandResult>           CloseEventGapAsync(EventGapCloseRequest request, CancellationToken cancellationToken);

    // Dashboard
    Task<WorkflowDashboardCounts>         GetDashboardCountsAsync(long? organizationId, CancellationToken cancellationToken);
}

public sealed class WorkflowService(IConfiguration configuration, ILogger<WorkflowService> logger) : IWorkflowService
{
    // ==============================================================
    // Workflow
    // ==============================================================
    public async Task<WorkflowListResult> ListWorkflowsAsync(WorkflowListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_workflow_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode     ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)query.Search         ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<WorkflowListRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapWorkflow(reader));
        return new WorkflowListResult(total, page, size, rows);
    }

    public async Task<WorkflowCommandResult> SaveWorkflowAsync(WorkflowSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)                       return new WorkflowCommandResult(false, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.WorkflowCode))   return new WorkflowCommandResult(false, null, "WorkflowCode is required.");
        if (string.IsNullOrWhiteSpace(request.WorkflowName))   return new WorkflowCommandResult(false, null, "WorkflowName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_workflow_save";

            AddParam(command, "@workflow_id",            DbType.Int64,  (object?)request.WorkflowId ?? DBNull.Value);
            AddParam(command, "@organization_id",        DbType.Int64,  request.OrganizationId);
            AddParam(command, "@workflow_code",          DbType.String, request.WorkflowCode, 60);
            AddParam(command, "@workflow_name",          DbType.String, request.WorkflowName, 200);
            AddParam(command, "@description",            DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@applicable_entity_type", DbType.String, (object?)request.ApplicableEntityType ?? DBNull.Value, 100);
            AddParam(command, "@version",                DbType.String, (object?)(request.Version ?? "1.0"), 20);
            AddParam(command, "@owner_employee_id",      DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@status",                 DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@is_default_template",    DbType.Boolean, (object?)(request.IsDefaultTemplate ?? false));
            AddParam(command, "@actor_employee_id",      DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_workflow_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new WorkflowCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveWorkflowAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new WorkflowCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Workflow Stage
    // ==============================================================
    public async Task<IReadOnlyList<WorkflowStageRow>> ListWorkflowStagesAsync(long workflowId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_workflow_stage_list";
        AddParam(command, "@workflow_id", DbType.Int64, workflowId);

        var list = new List<WorkflowStageRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) list.Add(MapStage(reader));
        return list;
    }

    public async Task<WorkflowStageCommandResult> SaveWorkflowStageAsync(WorkflowStageSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.WorkflowId <= 0)                        return new WorkflowStageCommandResult(false, null, "WorkflowId is required.");
        if (string.IsNullOrWhiteSpace(request.StageCode))   return new WorkflowStageCommandResult(false, null, "StageCode is required.");
        if (string.IsNullOrWhiteSpace(request.StageName))   return new WorkflowStageCommandResult(false, null, "StageName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_workflow_stage_save";

            AddParam(command, "@workflow_stage_id",   DbType.Int64,  (object?)request.WorkflowStageId ?? DBNull.Value);
            AddParam(command, "@workflow_id",         DbType.Int64,  request.WorkflowId);
            AddParam(command, "@stage_code",          DbType.String, request.StageCode, 60);
            AddParam(command, "@stage_name",          DbType.String, request.StageName, 200);
            AddParam(command, "@description",         DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@stage_sequence",      DbType.Int32,  (object?)(request.StageSequence ?? 1));
            AddParam(command, "@previous_stage_id",   DbType.Int64,  (object?)request.PreviousStageId ?? DBNull.Value);
            AddParam(command, "@next_stage_id",       DbType.Int64,  (object?)request.NextStageId     ?? DBNull.Value);
            AddParam(command, "@allowed_transitions", DbType.String, (object?)request.AllowedTransitions ?? DBNull.Value, 1000);
            AddParam(command, "@status",              DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id",   DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_workflow_stage_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new WorkflowStageCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveWorkflowStageAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new WorkflowStageCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Entity Type
    // ==============================================================
    public async Task<IReadOnlyList<EntityTypeRow>> ListEntityTypesAsync(long? organizationId, string? statusCode, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_entity_type_list";
        AddParam(command, "@organization_id", DbType.Int64,  (object?)organizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)statusCode ?? DBNull.Value, 30);

        var list = new List<EntityTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) list.Add(MapEntityType(reader));
        return list;
    }

    public async Task<EntityTypeCommandResult> SaveEntityTypeAsync(EntityTypeSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)                         return new EntityTypeCommandResult(false, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.EntityTypeCode))   return new EntityTypeCommandResult(false, null, "EntityTypeCode is required.");
        if (string.IsNullOrWhiteSpace(request.EntityTypeName))   return new EntityTypeCommandResult(false, null, "EntityTypeName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_entity_type_save";

            AddParam(command, "@entity_type_id",    DbType.Int64,  (object?)request.EntityTypeId ?? DBNull.Value);
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@entity_type_code",  DbType.String, request.EntityTypeCode, 60);
            AddParam(command, "@entity_type_name",  DbType.String, request.EntityTypeName, 200);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@entity_category",   DbType.String, (object?)request.EntityCategory ?? DBNull.Value, 60);
            AddParam(command, "@status",            DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_entity_type_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new EntityTypeCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveEntityTypeAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EntityTypeCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Event Definition
    // ==============================================================
    public async Task<EventDefinitionListResult> ListEventDefinitionsAsync(EventDefinitionListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_definition_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@entity_category", DbType.String, (object?)query.EntityCategory ?? DBNull.Value, 60);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<EventDefinitionRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapEventDefinition(reader));
        return new EventDefinitionListResult(total, page, size, rows);
    }

    public async Task<EventDefinitionCommandResult> SaveEventDefinitionAsync(EventDefinitionSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)                    return new EventDefinitionCommandResult(false, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.EventCode))   return new EventDefinitionCommandResult(false, null, "EventCode is required.");
        if (string.IsNullOrWhiteSpace(request.EventName))   return new EventDefinitionCommandResult(false, null, "EventName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_definition_save";

            AddParam(command, "@event_definition_id", DbType.Int64,  (object?)request.EventDefinitionId ?? DBNull.Value);
            AddParam(command, "@organization_id",     DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_code",          DbType.String, request.EventCode, 60);
            AddParam(command, "@event_name",          DbType.String, request.EventName, 200);
            AddParam(command, "@description",         DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@entity_category",     DbType.String, (object?)request.EntityCategory ?? DBNull.Value, 60);
            AddParam(command, "@workflow_id",         DbType.Int64,  (object?)request.WorkflowId ?? DBNull.Value);
            AddParam(command, "@workflow_stage_id",   DbType.Int64,  (object?)request.WorkflowStageId ?? DBNull.Value);
            AddParam(command, "@trigger_source",      DbType.String, (object?)request.TriggerSource ?? DBNull.Value, 60);
            AddParam(command, "@status",              DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id",   DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_event_definition_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new EventDefinitionCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveEventDefinitionAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventDefinitionCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Checklist
    // ==============================================================
    public async Task<ChecklistListResult> ListChecklistsAsync(ChecklistListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_checklist_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<ChecklistRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapChecklist(reader));
        return new ChecklistListResult(total, page, size, rows);
    }

    public async Task<ChecklistCommandResult> SaveChecklistAsync(ChecklistSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)                        return new ChecklistCommandResult(false, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.ChecklistCode))   return new ChecklistCommandResult(false, null, "ChecklistCode is required.");
        if (string.IsNullOrWhiteSpace(request.ChecklistName))   return new ChecklistCommandResult(false, null, "ChecklistName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_checklist_save";

            AddParam(command, "@checklist_id",      DbType.Int64,  (object?)request.ChecklistId ?? DBNull.Value);
            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@checklist_code",    DbType.String, request.ChecklistCode, 60);
            AddParam(command, "@checklist_name",    DbType.String, request.ChecklistName, 200);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@version",           DbType.String, (object?)(request.Version ?? "1.0"), 20);
            AddParam(command, "@status",            DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_checklist_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new ChecklistCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveChecklistAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new ChecklistCommandResult(false, null, ex.Message);
        }
    }

    public async Task<IReadOnlyList<ChecklistItemRow>> ListChecklistItemsAsync(long checklistId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_checklist_item_list";
        AddParam(command, "@checklist_id", DbType.Int64, checklistId);

        var list = new List<ChecklistItemRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) list.Add(MapChecklistItem(reader));
        return list;
    }

    public async Task<ChecklistItemCommandResult> SaveChecklistItemAsync(ChecklistItemSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ChecklistId <= 0)                     return new ChecklistItemCommandResult(false, null, "ChecklistId is required.");
        if (string.IsNullOrWhiteSpace(request.ItemText)) return new ChecklistItemCommandResult(false, null, "ItemText is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_checklist_item_save";

            AddParam(command, "@checklist_item_id",     DbType.Int64,   (object?)request.ChecklistItemId ?? DBNull.Value);
            AddParam(command, "@checklist_id",          DbType.Int64,   request.ChecklistId);
            AddParam(command, "@item_sequence",         DbType.Int32,   (object?)(request.ItemSequence ?? 1));
            AddParam(command, "@item_text",             DbType.String,  request.ItemText, 500);
            AddParam(command, "@item_type",             DbType.String,  (object?)(request.ItemType ?? "Manual"), 60);
            AddParam(command, "@is_mandatory",          DbType.Boolean, (object?)(request.IsMandatory ?? true));
            AddParam(command, "@evidence_required",     DbType.Boolean, (object?)(request.EvidenceRequired ?? false));
            AddParam(command, "@attachment_required",   DbType.Boolean, (object?)(request.AttachmentRequired ?? false));
            AddParam(command, "@approval_required",     DbType.Boolean, (object?)(request.ApprovalRequired ?? false));
            AddParam(command, "@responsible_role",      DbType.String,  (object?)request.ResponsibleRole ?? DBNull.Value, 100);
            AddParam(command, "@due_period_days",       DbType.Int32,   (object?)request.DuePeriodDays ?? DBNull.Value);
            AddParam(command, "@escalation_rules",      DbType.String,  (object?)request.EscalationRules ?? DBNull.Value, -1);
            AddParam(command, "@status",                DbType.String,  (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id",     DbType.Int64,   (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_checklist_item_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new ChecklistItemCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveChecklistItemAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new ChecklistItemCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Event-Checklist Mapping
    // ==============================================================
    public async Task<EventChecklistMappingListResult> ListEventChecklistMappingsAsync(EventChecklistMappingListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_checklist_mapping_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<EventChecklistMappingRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapMapping(reader));
        return new EventChecklistMappingListResult(total, page, size, rows);
    }

    public async Task<EventChecklistMappingCommandResult> SaveEventChecklistMappingAsync(EventChecklistMappingSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0 || request.EntityTypeId <= 0
            || request.EventDefinitionId <= 0 || request.ChecklistId <= 0)
            return new EventChecklistMappingCommandResult(false, null,
                "OrganizationId, EntityTypeId, EventDefinitionId and ChecklistId are required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_checklist_mapping_save";

            AddParam(command, "@mapping_id",              DbType.Int64,  (object?)request.MappingId ?? DBNull.Value);
            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@entity_type_id",          DbType.Int64,  request.EntityTypeId);
            AddParam(command, "@event_definition_id",     DbType.Int64,  request.EventDefinitionId);
            AddParam(command, "@checklist_id",            DbType.Int64,  request.ChecklistId);
            AddParam(command, "@default_owner_role",      DbType.String, (object?)request.DefaultOwnerRole ?? DBNull.Value, 100);
            AddParam(command, "@default_due_period_days", DbType.Int32,  (object?)request.DefaultDuePeriodDays ?? DBNull.Value);
            AddParam(command, "@status",                  DbType.String, (object?)(request.Status ?? "Active"), 30);
            AddParam(command, "@actor_employee_id",       DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            // Migration 124 scope parameters. Omitted values leave the proc on
            // its pre-124 path, producing an unscoped mapping.
            AddParam(command, "@scope_dimension",         DbType.String, (object?)request.ScopeDimension       ?? DBNull.Value, 40);
            AddParam(command, "@scope_role_id",           DbType.Int64,  (object?)request.ScopeRoleId          ?? DBNull.Value);
            AddParam(command, "@scope_asset_category_id", DbType.Int32,  (object?)request.ScopeAssetCategoryId ?? DBNull.Value);
            AddParam(command, "@release_id",              DbType.Int64,  (object?)request.ReleaseId            ?? DBNull.Value);
            AddParam(command, "@default_owner_role_id",   DbType.Int64,  (object?)request.DefaultOwnerRoleId   ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_mapping_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new EventChecklistMappingCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveEventChecklistMappingAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventChecklistMappingCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Event Instance
    // ==============================================================
    public async Task<EventInstanceListResult> ListEventInstancesAsync(EventInstanceListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_instance_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@search",          DbType.String, (object?)query.Search ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<EventInstanceRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapEventInstance(reader));
        return new EventInstanceListResult(total, page, size, rows);
    }

    public async Task<EventInstanceCommandResult> TriggerEventAsync(EventInstanceTriggerRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0) return new EventInstanceCommandResult(false, null, "OrganizationId is required.");
        if (request.EventDefinitionId is null or <= 0 && string.IsNullOrWhiteSpace(request.EventCode))
            return new EventInstanceCommandResult(false, null, "Either EventDefinitionId or EventCode is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_instance_trigger";

            AddParam(command, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_definition_id",  DbType.Int64,  (object?)request.EventDefinitionId ?? DBNull.Value);
            AddParam(command, "@event_code",           DbType.String, (object?)request.EventCode ?? DBNull.Value, 60);
            AddParam(command, "@entity_type_id",       DbType.Int64,  (object?)request.EntityTypeId ?? DBNull.Value);
            AddParam(command, "@entity_reference",     DbType.String, (object?)request.EntityReference ?? DBNull.Value, 200);
            AddParam(command, "@entity_display_name",  DbType.String, (object?)request.EntityDisplayName ?? DBNull.Value, 300);
            AddParam(command, "@trigger_source",       DbType.String, (object?)(request.TriggerSource ?? "Manual"), 60);
            AddParam(command, "@payload_json",         DbType.String, (object?)request.PayloadJson ?? DBNull.Value, -1);
            AddParam(command, "@owner_employee_id",    DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@actor_employee_id",    DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_event_instance_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new EventInstanceCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "TriggerEventAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventInstanceCommandResult(false, null, ex.Message);
        }
    }

    public async Task<EventInstanceCommandResult> CompleteEventInstanceAsync(EventInstanceCompleteRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.EventInstanceId <= 0) return new EventInstanceCommandResult(false, null, "EventInstanceId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_instance_complete";
            AddParam(command, "@event_instance_id", DbType.Int64,  request.EventInstanceId);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@comments",          DbType.String, (object?)request.Comments ?? DBNull.Value, -1);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventInstanceCommandResult(true, request.EventInstanceId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "CompleteEventInstanceAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventInstanceCommandResult(false, null, ex.Message);
        }
    }

    public async Task<EventInstanceCommandResult> SaveEventInstanceItemAsync(EventInstanceItemSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.EventInstanceItemId <= 0)                return new EventInstanceCommandResult(false, null, "EventInstanceItemId is required.");
        if (string.IsNullOrWhiteSpace(request.ItemStatus))   return new EventInstanceCommandResult(false, null, "ItemStatus is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_instance_item_save";
            AddParam(command, "@event_instance_item_id", DbType.Int64,  request.EventInstanceItemId);
            AddParam(command, "@item_status",            DbType.String, request.ItemStatus, 30);
            AddParam(command, "@evidence_url",           DbType.String, (object?)request.EvidenceUrl ?? DBNull.Value, 1000);
            AddParam(command, "@remarks",                DbType.String, (object?)request.Remarks ?? DBNull.Value, -1);
            AddParam(command, "@actor_employee_id",      DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventInstanceCommandResult(true, request.EventInstanceItemId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "SaveEventInstanceItemAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventInstanceCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Event Gap
    // ==============================================================
    public async Task<EventGapListResult> ListEventGapsAsync(EventGapListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_event_gap_list";

        AddParam(command, "@organization_id", DbType.Int64,  (object?)query.OrganizationId ?? DBNull.Value);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 30);
        AddParam(command, "@severity",        DbType.String, (object?)query.Severity ?? DBNull.Value, 30);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        long total = 0; int page = query.Page, size = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }
        var rows = new List<EventGapRow>();
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken)) rows.Add(MapEventGap(reader));
        return new EventGapListResult(total, page, size, rows);
    }

    public async Task<EventGapCommandResult> OpenEventGapAsync(EventGapOpenRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)                    return new EventGapCommandResult(false, null, "OrganizationId is required.");
        if (request.EventInstanceId <= 0)                   return new EventGapCommandResult(false, null, "EventInstanceId is required.");
        if (string.IsNullOrWhiteSpace(request.Title))       return new EventGapCommandResult(false, null, "Title is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_gap_open";

            AddParam(command, "@organization_id",   DbType.Int64,  request.OrganizationId);
            AddParam(command, "@event_instance_id", DbType.Int64,  request.EventInstanceId);
            AddParam(command, "@checklist_item_id", DbType.Int64,  (object?)request.ChecklistItemId ?? DBNull.Value);
            AddParam(command, "@entity_reference",  DbType.String, (object?)request.EntityReference ?? DBNull.Value, 200);
            AddParam(command, "@title",             DbType.String, request.Title, 250);
            AddParam(command, "@description",       DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@severity",          DbType.String, (object?)(request.Severity ?? "Medium"), 30);
            AddParam(command, "@owner_employee_id", DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@due_date",          DbType.Date,   (object?)request.DueDate ?? DBNull.Value);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            var idParam = AddOutParam(command, "@out_event_gap_id", DbType.Int64);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idParam.Value is long l ? l : Convert.ToInt64(idParam.Value);
            return new EventGapCommandResult(true, id);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OpenEventGapAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventGapCommandResult(false, null, ex.Message);
        }
    }

    public async Task<EventGapCommandResult> CloseEventGapAsync(EventGapCloseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.EventGapId <= 0) return new EventGapCommandResult(false, null, "EventGapId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_event_gap_close";
            AddParam(command, "@event_gap_id",      DbType.Int64,  request.EventGapId);
            AddParam(command, "@actor_employee_id", DbType.Int64,  (object?)request.ActorEmployeeId ?? DBNull.Value);
            AddParam(command, "@remarks",           DbType.String, (object?)request.Remarks ?? DBNull.Value, 1000);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new EventGapCommandResult(true, request.EventGapId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "CloseEventGapAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new EventGapCommandResult(false, null, ex.Message);
        }
    }

    // ==============================================================
    // Dashboard
    // ==============================================================
    public async Task<WorkflowDashboardCounts> GetDashboardCountsAsync(long? organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_workflow_dashboard_counts";
        AddParam(command, "@organization_id", DbType.Int64, (object?)organizationId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken))
        {
            return new WorkflowDashboardCounts(
                EventsReceived:     Convert.ToInt64(reader["EventsReceived"]),
                AssuranceGenerated: Convert.ToInt64(reader["AssuranceGenerated"]),
                PendingAssurance:   Convert.ToInt64(reader["PendingAssurance"]),
                OverdueAssurance:   Convert.ToInt64(reader["OverdueAssurance"]),
                FailedAssurance:    Convert.ToInt64(reader["FailedAssurance"]),
                OpenGaps:           Convert.ToInt64(reader["OpenGaps"]),
                ActiveWorkflows:    Convert.ToInt64(reader["ActiveWorkflows"]),
                ActiveEvents:       Convert.ToInt64(reader["ActiveEvents"]),
                ActiveChecklists:   Convert.ToInt64(reader["ActiveChecklists"]));
        }
        return new WorkflowDashboardCounts(0,0,0,0,0,0,0,0,0);
    }

    // ==============================================================
    // Helpers
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

    private static WorkflowListRow MapWorkflow(DbDataReader r) => new(
        WorkflowId:           Convert.ToInt64(r["workflow_id"]),
        OrganizationId:       Convert.ToInt64(r["organization_id"]),
        WorkflowCode:         r["workflow_code"]?.ToString() ?? "",
        WorkflowName:         r["workflow_name"]?.ToString() ?? "",
        Description:          r["description"] as string,
        ApplicableEntityType: r["applicable_entity_type"] as string,
        Version:              r["version"]?.ToString() ?? "1.0",
        OwnerEmployeeId:      r["owner_employee_id"] as long?,
        Status:               r["status"]?.ToString() ?? "Active",
        IsDefaultTemplate:    r["is_default_template"] is bool b && b,
        EnteredDt:            Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:            r["entered_by"]?.ToString() ?? "");

    private static WorkflowStageRow MapStage(DbDataReader r) => new(
        WorkflowStageId:     Convert.ToInt64(r["workflow_stage_id"]),
        WorkflowId:          Convert.ToInt64(r["workflow_id"]),
        StageCode:           r["stage_code"]?.ToString() ?? "",
        StageName:           r["stage_name"]?.ToString() ?? "",
        Description:         r["description"] as string,
        StageSequence:       Convert.ToInt32(r["stage_sequence"]),
        PreviousStageId:     r["previous_stage_id"] as long?,
        NextStageId:         r["next_stage_id"] as long?,
        AllowedTransitions:  r["allowed_transitions"] as string,
        Status:              r["status"]?.ToString() ?? "Active");

    private static EntityTypeRow MapEntityType(DbDataReader r) => new(
        EntityTypeId:    Convert.ToInt64(r["entity_type_id"]),
        OrganizationId:  Convert.ToInt64(r["organization_id"]),
        EntityTypeCode:  r["entity_type_code"]?.ToString() ?? "",
        EntityTypeName:  r["entity_type_name"]?.ToString() ?? "",
        Description:     r["description"] as string,
        EntityCategory:  r["entity_category"] as string,
        Status:          r["status"]?.ToString() ?? "Active");

    private static EventDefinitionRow MapEventDefinition(DbDataReader r) => new(
        EventDefinitionId: Convert.ToInt64(r["event_definition_id"]),
        OrganizationId:    Convert.ToInt64(r["organization_id"]),
        EventCode:         r["event_code"]?.ToString() ?? "",
        EventName:         r["event_name"]?.ToString() ?? "",
        Description:       r["description"] as string,
        EntityCategory:    r["entity_category"] as string,
        WorkflowId:        r["workflow_id"] as long?,
        WorkflowStageId:   r["workflow_stage_id"] as long?,
        TriggerSource:     r["trigger_source"] as string,
        Status:            r["status"]?.ToString() ?? "Active",
        EnteredDt:         Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:         r["entered_by"]?.ToString() ?? "");

    private static ChecklistRow MapChecklist(DbDataReader r) => new(
        ChecklistId:    Convert.ToInt64(r["checklist_id"]),
        OrganizationId: Convert.ToInt64(r["organization_id"]),
        ChecklistCode:  r["checklist_code"]?.ToString() ?? "",
        ChecklistName:  r["checklist_name"]?.ToString() ?? "",
        Description:    r["description"] as string,
        Version:        r["version"]?.ToString() ?? "1.0",
        Status:         r["status"]?.ToString() ?? "Active",
        ItemCount:      Convert.ToInt32(r["item_count"]),
        EnteredDt:      Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:      r["entered_by"]?.ToString() ?? "");

    private static ChecklistItemRow MapChecklistItem(DbDataReader r) => new(
        ChecklistItemId:    Convert.ToInt64(r["checklist_item_id"]),
        ChecklistId:        Convert.ToInt64(r["checklist_id"]),
        ItemSequence:       Convert.ToInt32(r["item_sequence"]),
        ItemText:           r["item_text"]?.ToString() ?? "",
        ItemType:           r["item_type"]?.ToString() ?? "Manual",
        IsMandatory:        r["is_mandatory"] is bool a && a,
        EvidenceRequired:   r["evidence_required"] is bool b && b,
        AttachmentRequired: r["attachment_required"] is bool c && c,
        ApprovalRequired:   r["approval_required"] is bool d && d,
        ResponsibleRole:    r["responsible_role"] as string,
        DuePeriodDays:      r["due_period_days"] as int?,
        EscalationRules:    r["escalation_rules"] as string,
        Status:             r["status"]?.ToString() ?? "Active");

    private static EventChecklistMappingRow MapMapping(DbDataReader r) => new(
        MappingId:            Convert.ToInt64(r["mapping_id"]),
        OrganizationId:       Convert.ToInt64(r["organization_id"]),
        EntityTypeId:         Convert.ToInt64(r["entity_type_id"]),
        EntityTypeName:       r["entity_type_name"]?.ToString() ?? "",
        EventDefinitionId:    Convert.ToInt64(r["event_definition_id"]),
        EventCode:            r["event_code"]?.ToString() ?? "",
        EventName:            r["event_name"]?.ToString() ?? "",
        ChecklistId:          Convert.ToInt64(r["checklist_id"]),
        ChecklistName:        r["checklist_name"]?.ToString() ?? "",
        DefaultOwnerRole:     r["default_owner_role"] as string,
        DefaultDuePeriodDays: r["default_due_period_days"] as int?,
        Status:               r["status"]?.ToString() ?? "Active");

    private static EventInstanceRow MapEventInstance(DbDataReader r) => new(
        EventInstanceId:    Convert.ToInt64(r["event_instance_id"]),
        OrganizationId:     Convert.ToInt64(r["organization_id"]),
        EventDefinitionId:  Convert.ToInt64(r["event_definition_id"]),
        EventCode:          r["event_code"]?.ToString() ?? "",
        EventName:          r["event_name"]?.ToString() ?? "",
        EntityTypeId:       r["entity_type_id"] as long?,
        EntityTypeName:     r["entity_type_name"] as string,
        EntityReference:    r["entity_reference"] as string,
        EntityDisplayName:  r["entity_display_name"] as string,
        ChecklistId:        r["checklist_id"] as long?,
        ChecklistName:      r["checklist_name"] as string,
        TriggerSource:      r["trigger_source"] as string,
        OwnerEmployeeId:    r["owner_employee_id"] as long?,
        DueDate:            r["due_date"] as DateTime?,
        Status:             r["status"]?.ToString() ?? "Received",
        CompletedDt:        r["completed_dt"] as DateTime?,
        EnteredDt:          Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:          r["entered_by"]?.ToString() ?? "");

    private static EventGapRow MapEventGap(DbDataReader r) => new(
        EventGapId:      Convert.ToInt64(r["event_gap_id"]),
        OrganizationId:  Convert.ToInt64(r["organization_id"]),
        EventInstanceId: Convert.ToInt64(r["event_instance_id"]),
        ChecklistItemId: r["checklist_item_id"] as long?,
        EntityReference: r["entity_reference"] as string,
        Title:           r["title"]?.ToString() ?? "",
        Description:     r["description"] as string,
        Severity:        r["severity"]?.ToString() ?? "Medium",
        OwnerEmployeeId: r["owner_employee_id"] as long?,
        DueDate:         r["due_date"] as DateTime?,
        Status:          r["status"]?.ToString() ?? "Open",
        LinkedTaskId:    r["linked_task_id"] as long?,
        EnteredDt:       Convert.ToDateTime(r["entered_dt"]),
        EnteredBy:       r["entered_by"]?.ToString() ?? "");
}
