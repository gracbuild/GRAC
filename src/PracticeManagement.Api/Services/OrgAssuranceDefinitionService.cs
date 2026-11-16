// =====================================================================
// OrgAssuranceDefinitionService
//
// Phase 2 Assurance Management -- Stage 1 service facade.
//
// Thin wrapper over the sp_org_assurance_definition_* stored procedures
// (migration 070). Follows the exact TaskService conventions:
//   * Primary-constructor injection
//   * SqlConnectionStringResolver.Resolve for the connection string
//   * AddParam helper + snake_case @-parameter names matching the SPs
//   * Structured Result records (Success / ReasonCode / Error) so the
//     controller stays thin
//
// Wire-up: Infrastructure/OrgAssuranceDefinitionServiceRegistration.cs
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceDefinitionService
{
    Task<IReadOnlyList<OrgAssuranceStatusRow>> ListStatusesAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<OrgAssuranceAdminCategoryRow>> ListAdminCategoriesAsync(CancellationToken cancellationToken);

    // 560
    Task<IReadOnlyList<OrgAssuranceMasterRow>> ListApproachesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMandatesAsync(CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionListResult> ListAsync(
        OrgAssuranceDefinitionListQuery query, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionDetail?> GetAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionSaveResult> SaveAsync(
        OrgAssuranceDefinitionSaveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionTransitionResult> SubmitAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionTransitionResult> ApproveAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionTransitionResult> ActivateAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceDefinitionTransitionResult> RetireAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<OrgAssuranceDefinitionHistoryRow>> ListHistoryAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken);

    Task<IReadOnlyList<OrgAssuranceDefinitionVersionRow>> ListVersionsAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken);

    // ---------- Scope Builder (Stage 2) ----------
    Task<IReadOnlyList<OrgAssuranceScopeDimensionRow>> ListScopeDimensionsAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<OrgAssuranceScopeDimensionValueRow>> ListScopeDimensionValuesAsync(
        long organizationId, string dimensionCode, string? search, int pageSize, CancellationToken cancellationToken);

    // 534 -- the Source Statements tree for the Scope Builder.
    Task<IReadOnlyList<OrgAssuranceScopeStatementTreeRow>> ListScopeStatementTreeAsync(
        long organizationId, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeTree?> GetScopeAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    // 562: Scope Builder Step 2 -- discovery and the category flags.
    Task<OrgAssuranceScopeDiscovery?> GetScopeDiscoveryAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeSaveResult> SaveScopeCategoriesAsync(
        OrgAssuranceScopeCategorySaveRequest request, CancellationToken cancellationToken);

    // 564 -- Control and Practice Mapping
    Task<OrgAssuranceMappingOptions> GetMappingOptionsAsync(long organizationId, CancellationToken cancellationToken);
    Task<OrgAssuranceMappingResult?> GetMappingAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);
    Task<OrgAssuranceMappingSaveResult> SaveMappingAsync(
        OrgAssuranceMappingSaveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeSaveResult> SaveScopeAsync(
        OrgAssuranceScopeSaveRequest request, CancellationToken cancellationToken);

    // ---------- Evidence Types (question Evidence Type lookup) ----------
    // Evidence Configuration (collection methods, frequencies, per-version
    // evidence config) removed by 536 -- evidence is set per question.
    Task<IReadOnlyList<OrgAssuranceEvidenceLookupRow>> ListEvidenceTypesAsync(CancellationToken cancellationToken);
    // ---------- Workflow Configuration (Stage 2 -- BRD Sec 6) ----------
    Task<IReadOnlyList<OrgAssuranceAdminWorkflowTemplateRow>> ListAdminWorkflowTemplatesAsync(CancellationToken cancellationToken);
    Task<OrgAssuranceAdminWorkflowTemplateDetail?>             GetAdminWorkflowTemplateAsync(long templateId, CancellationToken cancellationToken);   // 538
    Task<IReadOnlyList<OrgAssuranceWorkflowStageTypeRow>>     ListWorkflowStageTypesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceOrganizationRoleRow>>      ListOrganizationRolesAsync(long organizationId, CancellationToken cancellationToken);

    Task<OrgAssuranceWorkflowResult?> GetWorkflowAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceWorkflowSaveResult> SaveWorkflowAsync(
        OrgAssuranceWorkflowSaveRequest request, CancellationToken cancellationToken);

    // ---------- Scoring Configuration (Stage 2 -- BRD Sec 7) ----------
    Task<IReadOnlyList<OrgAssuranceAdminScoringModelRow>>  ListAdminScoringModelsAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceScoringModelTypeRow>>   ListScoringModelTypesAsync(CancellationToken cancellationToken);

    Task<OrgAssuranceScoringResult?> GetScoringAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceScoringSaveResult> SaveScoringAsync(
        OrgAssuranceScoringSaveRequest request, CancellationToken cancellationToken);

    // ---------- Trigger Configuration (Stage 3 -- BRD Sec 9) ----------
    Task<IReadOnlyList<OrgAssuranceTriggerTypeRow>>          ListTriggerTypesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceScheduleFrequencyRow>>    ListScheduleFrequenciesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceEventCodeRow>>            ListEventCodesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceContinuousSourceRow>>     ListContinuousSourcesAsync(CancellationToken cancellationToken);

    Task<OrgAssuranceTriggerListResult?> ListTriggersAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceTriggerSaveResult> SaveTriggerAsync(
        OrgAssuranceTriggerSaveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceTriggerCommandResult> DeleteTriggerAsync(
        long organizationId, long triggerId, string? actor, CancellationToken cancellationToken);

    // ---------- Scope Resolution Engine (Stage 3 -- BRD Sec 3) ----------
    Task<OrgAssuranceScopeResolveResult> ResolveScopeAsync(
        OrgAssuranceScopeResolveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeResolutionListResult> ListScopeResolutionsAsync(
        long organizationId, long definitionId, long? versionId, int page, int pageSize, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeResolutionDetail?> GetScopeResolutionAsync(
        long organizationId, long resolutionId, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeResolutionEntityListResult> ListScopeResolutionEntitiesAsync(
        long organizationId, long resolutionId, string? dimensionCode, string? search, int page, int pageSize, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceDefinitionService(
    IConfiguration configuration,
    ILogger<OrgAssuranceDefinitionService> logger) : IOrgAssuranceDefinitionService
{
    // -----------------------------------------------------------------
    // List statuses
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceStatusRow>> ListStatusesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_status_list";

        var rows = new List<OrgAssuranceStatusRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceStatusRow(
                Convert.ToInt32(reader["StatusId"]),
                reader["StatusCode"]?.ToString() ?? "",
                reader["StatusName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                Convert.ToBoolean(reader["IsTerminal"])));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // List Admin-published assurance categories (grac_new)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceAdminCategoryRow>> ListAdminCategoriesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_admin_category_list";

        var rows = new List<OrgAssuranceAdminCategoryRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceAdminCategoryRow(
                ReadLongOrNull(reader, "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // 560: Assurance Approaches (grac_practice.org_assurance_approach_master)
    // -----------------------------------------------------------------
    public Task<IReadOnlyList<OrgAssuranceMasterRow>> ListApproachesAsync(CancellationToken cancellationToken) =>
        ListMasterAsync("grac_practice.sp_org_assurance_approach_list", cancellationToken);

    // 560: Audit Mandates (grac_practice.org_assurance_mandate_master)
    public Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMandatesAsync(CancellationToken cancellationToken) =>
        ListMasterAsync("grac_practice.sp_org_assurance_mandate_list", cancellationToken);

    // One reader for the Definition masters -- each list proc returns Id, Code, Name, Description.
    private async Task<IReadOnlyList<OrgAssuranceMasterRow>> ListMasterAsync(string procName, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procName;

        var rows = new List<OrgAssuranceMasterRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceMasterRow(
                ReadLongOrNull(reader, "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // List definitions (paginated)
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceDefinitionListResult> ListAsync(
        OrgAssuranceDefinitionListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_list";

        AddParam(command, "@organization_id", DbType.Int64,  query.OrganizationId);
        AddParam(command, "@status_code",     DbType.String, (object?)query.StatusCode ?? DBNull.Value, 60);
        AddParam(command, "@search",          DbType.String, (object?)query.Search     ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

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

        var rows = new List<OrgAssuranceDefinitionListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapListRow(reader));
        }

        return new OrgAssuranceDefinitionListResult(total, page, size, rows);
    }

    // -----------------------------------------------------------------
    // Get single definition detail
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceDefinitionDetail?> GetAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        var detail = MapDetailRow(reader);

        // 560: second result set -- the current version's Applicable Frameworks;
        // third -- its Audit Mandates (both absent before 560 is run: empty lists).
        var frameworks = new List<OrgAssuranceDefinitionFrameworkRow>();
        var mandates   = new List<OrgAssuranceDefinitionMandateRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                frameworks.Add(new OrgAssuranceDefinitionFrameworkRow(
                    ReadLongOrNull(reader, "DefinitionFrameworkId"),
                    ReadLongOrNull(reader, "ReleaseId"),
                    reader["FrameworkName"]?.ToString() ?? "",
                    ReadIntOrNull(reader, "DisplayOrder") ?? 0));
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                    mandates.Add(new OrgAssuranceDefinitionMandateRow(
                        ReadLongOrNull(reader, "DefinitionMandateId"),
                        Convert.ToInt64(reader["AuditMandateId"]),
                        reader["MandateCode"]?.ToString() ?? "",
                        reader["MandateName"]?.ToString() ?? "",
                        ReadIntOrNull(reader, "DisplayOrder") ?? 0));
            }
        }
        return detail with { ApplicableFrameworks = frameworks, AuditMandates = mandates };
    }

    // -----------------------------------------------------------------
    // Save
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceDefinitionSaveResult> SaveAsync(
        OrgAssuranceDefinitionSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.DefinitionCode))
            return new OrgAssuranceDefinitionSaveResult(false, Error: "DefinitionCode is required.");
        if (string.IsNullOrWhiteSpace(request.DefinitionName))
            return new OrgAssuranceDefinitionSaveResult(false, Error: "DefinitionName is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_definition_save";

            AddParam(command, "@organization_id",         DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",           DbType.Int64,  (object?)request.DefinitionId ?? DBNull.Value);
            AddParam(command, "@definition_code",         DbType.String, request.DefinitionCode.Trim(), 80);
            AddParam(command, "@definition_name",         DbType.String, request.DefinitionName.Trim(), 240);
            // 119 hybrid role+employee Owner -- SP auto-resolves whichever side is missing.
            AddParam(command, "@owner_role_id",           DbType.Int64,  (object?)request.OwnerRoleId ?? DBNull.Value);
            AddParam(command, "@owner_role_name",         DbType.String, (object?)request.OwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@owner_employee_id",       DbType.Int64,  (object?)request.OwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@owner_display_name",      DbType.String, (object?)request.OwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@description",             DbType.String, (object?)request.Description ?? DBNull.Value, -1);
            AddParam(command, "@objective",               DbType.String, (object?)request.Objective   ?? DBNull.Value, -1);
            AddParam(command, "@effective_date",          DbType.Date,   (object?)request.EffectiveDate ?? DBNull.Value);
            AddParam(command, "@assurance_category_id",   DbType.Int64,  (object?)request.AssuranceCategoryId ?? DBNull.Value);
            AddParam(command, "@assurance_category_code", DbType.String, (object?)request.AssuranceCategoryCode ?? DBNull.Value, 120);
            AddParam(command, "@assurance_category_name", DbType.String, (object?)request.AssuranceCategoryName ?? DBNull.Value, 200);
            // 560: Assurance Approach, Audit Mandate, Applicable Frameworks (JSON; null = unchanged).
            AddParam(command, "@assurance_approach_id",   DbType.Int64,  (object?)request.AssuranceApproachId ?? DBNull.Value);
            AddParam(command, "@audit_mandate_ids_json",  DbType.String,
                request.AuditMandateIds is null
                    ? (object)DBNull.Value
                    : System.Text.Json.JsonSerializer.Serialize(request.AuditMandateIds), -1);
            AddParam(command, "@applicable_frameworks_json", DbType.String,
                request.ApplicableFrameworks is null
                    ? (object)DBNull.Value
                    : System.Text.Json.JsonSerializer.Serialize(request.ApplicableFrameworks
                        .Where(f => !string.IsNullOrWhiteSpace(f.Name))
                        .Select(f => new { releaseId = f.ReleaseId, name = f.Name!.Trim() })), -1);
            AddParam(command, "@actor",                   DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var defIdOut = command.CreateParameter();
            defIdOut.ParameterName = "@definition_id_out";
            defIdOut.DbType        = DbType.Int64;
            defIdOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(defIdOut);

            var verIdOut = command.CreateParameter();
            verIdOut.ParameterName = "@definition_version_id_out";
            verIdOut.DbType        = DbType.Int64;
            verIdOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(verIdOut);

            await command.ExecuteNonQueryAsync(cancellationToken);

            var defId = defIdOut.Value is long dl ? dl : Convert.ToInt64(defIdOut.Value);
            var verId = verIdOut.Value is long vl ? vl : Convert.ToInt64(verIdOut.Value);

            return new OrgAssuranceDefinitionSaveResult(true, defId, verId);
        }
        catch (SqlException ex)
        {
            return HandleSqlErrorAsSave(ex, nameof(SaveAsync));
        }
    }

    // -----------------------------------------------------------------
    // Lifecycle transitions
    // -----------------------------------------------------------------
    public Task<OrgAssuranceDefinitionTransitionResult> SubmitAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken) =>
        TransitionAsync("grac_practice.sp_org_assurance_definition_submit",   request, cancellationToken);

    public Task<OrgAssuranceDefinitionTransitionResult> ApproveAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken) =>
        TransitionAsync("grac_practice.sp_org_assurance_definition_approve",  request, cancellationToken);

    public Task<OrgAssuranceDefinitionTransitionResult> ActivateAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken) =>
        TransitionAsync("grac_practice.sp_org_assurance_definition_activate", request, cancellationToken);

    public Task<OrgAssuranceDefinitionTransitionResult> RetireAsync(
        OrgAssuranceDefinitionTransitionRequest request, CancellationToken cancellationToken) =>
        TransitionAsync("grac_practice.sp_org_assurance_definition_retire",   request, cancellationToken);

    private async Task<OrgAssuranceDefinitionTransitionResult> TransitionAsync(
        string procName,
        OrgAssuranceDefinitionTransitionRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.DefinitionId <= 0)
            return new OrgAssuranceDefinitionTransitionResult(false, Error: "DefinitionId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@reason_text",     DbType.String, (object?)request.ReasonText ?? DBNull.Value, 1000);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor      ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceDefinitionTransitionResult(true, request.DefinitionId);
        }
        catch (SqlException ex)
        {
            return HandleSqlErrorAsTransition(ex, procName);
        }
    }

    // -----------------------------------------------------------------
    // History + Versions
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceDefinitionHistoryRow>> ListHistoryAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_history_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);

        var rows = new List<OrgAssuranceDefinitionHistoryRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapHistoryRow(reader));
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceDefinitionVersionRow>> ListVersionsAsync(
        long organizationId, long definitionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_definition_version_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);

        var rows = new List<OrgAssuranceDefinitionVersionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapVersionRow(reader));
        return rows;
    }

    // -----------------------------------------------------------------
    // Scope Builder (Stage 2 -- BRD Part 2 Sec 2)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceScopeDimensionRow>> ListScopeDimensionsAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_dimension_list";

        var rows = new List<OrgAssuranceScopeDimensionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceScopeDimensionRow(
                Convert.ToInt32(reader["DimensionId"]),
                reader["DimensionCode"]?.ToString() ?? "",
                reader["DimensionName"]?.ToString() ?? "",
                reader["Category"]?.ToString() ?? "",
                Convert.ToBoolean(reader["IsPickable"]),
                Convert.ToInt32(reader["DisplayOrder"]),
                HasColumn(reader, "DependencyTypeId") ? ReadLongOrNull(reader, "DependencyTypeId") : null));   // 562
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceScopeDimensionValueRow>> ListScopeDimensionValuesAsync(
        long organizationId, string dimensionCode, string? search, int pageSize, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(dimensionCode))
            return Array.Empty<OrgAssuranceScopeDimensionValueRow>();

        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_dimension_values";

        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@dimension_code",  DbType.String, dimensionCode, 60);
        AddParam(command, "@search",          DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(pageSize, 1, 500));

        var rows = new List<OrgAssuranceScopeDimensionValueRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceScopeDimensionValueRow(
                ReadLongOrNull(reader,  "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name")));
        }
        return rows;
    }

    // 534 -- sp_org_assurance_scope_statement_tree: every selectable source
    // statement with its framework / release / structure and the number of
    // practice instances it resolves to.
    public async Task<IReadOnlyList<OrgAssuranceScopeStatementTreeRow>> ListScopeStatementTreeAsync(
        long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_statement_tree";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<OrgAssuranceScopeStatementTreeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceScopeStatementTreeRow(
                reader["FrameworkKey"]?.ToString()  ?? "",
                reader["FrameworkName"]?.ToString() ?? "",
                reader["ReleaseKey"]?.ToString()    ?? "",
                reader["ReleaseName"]?.ToString()   ?? "",
                reader["StructureKey"]?.ToString()  ?? "",
                reader["StructureName"]?.ToString() ?? "",
                Convert.ToInt64(reader["StatementId"]),
                ReadStringOrNull(reader, "StatementCode"),
                ReadStringOrNull(reader, "StatementName"),
                ReadIntOrNull(reader, "InstanceCount") ?? 0));
        }
        return rows;
    }

    public async Task<OrgAssuranceScopeTree?> GetScopeAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        try
        {
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            // 1) header
            if (!await reader.ReadAsync(cancellationToken)) return null;
            var header = new OrgAssuranceScopeHeader(
                Convert.ToInt64(reader["DefinitionId"]),
                Convert.ToInt64(reader["VersionId"]),
                ReadLongOrNull(reader, "CurrentVersionId"),
                reader["CurrentStatusCode"]?.ToString() ?? "",
                Convert.ToBoolean(reader["IsEditable"]));

            // 2) groups
            var groups = new List<OrgAssuranceScopeGroupRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    groups.Add(new OrgAssuranceScopeGroupRow(
                        Convert.ToInt64(reader["ScopeGroupId"]),
                        reader["GroupOperator"]?.ToString() ?? "AND",
                        Convert.ToInt32(reader["GroupOrder"]),
                        ReadStringOrNull(reader, "GroupLabel")));
                }
            }

            // 3) conditions
            var conditions = new List<OrgAssuranceScopeConditionRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    conditions.Add(new OrgAssuranceScopeConditionRow(
                        Convert.ToInt64(reader["ScopeConditionId"]),
                        Convert.ToInt64(reader["ScopeGroupId"]),
                        Convert.ToInt32(reader["DimensionId"]),
                        reader["DimensionCode"]?.ToString() ?? "",
                        reader["DimensionName"]?.ToString() ?? "",
                        Convert.ToBoolean(reader["IsNot"]),
                        reader["ConditionOperator"]?.ToString() ?? "AND",
                        Convert.ToInt32(reader["ConditionOrder"]),
                        Convert.ToBoolean(reader["IncludeAll"])));
                }
            }

            // 4) values
            var values = new List<OrgAssuranceScopeConditionValueRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    values.Add(new OrgAssuranceScopeConditionValueRow(
                        Convert.ToInt64(reader["ScopeConditionValueId"]),
                        Convert.ToInt64(reader["ScopeConditionId"]),
                        ReadLongOrNull(reader,  "DimensionEntityId"),
                        ReadStringOrNull(reader, "DimensionEntityCode"),
                        ReadStringOrNull(reader, "DimensionEntityName")));
                }
            }

            return new OrgAssuranceScopeTree(header, groups, conditions, values);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.GetScopeAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            throw;
        }
    }

    public async Task<OrgAssuranceScopeSaveResult> SaveScopeAsync(
        OrgAssuranceScopeSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceScopeSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceScopeSaveResult(false, Error: "DefinitionId is required.");

        // Serialize the tree to the JSON shape the proc expects.
        var payload = new
        {
            groups = (request.Groups ?? Array.Empty<OrgAssuranceScopeSaveGroup>())
                .Select(g => new
                {
                    groupOperator = string.IsNullOrWhiteSpace(g.GroupOperator) ? "AND" : g.GroupOperator!.Trim().ToUpperInvariant(),
                    groupOrder    = g.GroupOrder ?? 0,
                    groupLabel    = g.GroupLabel,
                    conditions    = (g.Conditions ?? Array.Empty<OrgAssuranceScopeSaveCondition>())
                        .Select(c => new
                        {
                            dimensionCode     = c.DimensionCode?.Trim().ToUpperInvariant() ?? "",
                            isNot             = c.IsNot ?? false,
                            conditionOperator = string.IsNullOrWhiteSpace(c.ConditionOperator) ? "AND" : c.ConditionOperator!.Trim().ToUpperInvariant(),
                            conditionOrder    = c.ConditionOrder ?? 0,
                            includeAll        = c.IncludeAll ?? false,
                            values            = (c.Values ?? Array.Empty<OrgAssuranceScopeSaveValue>())
                                .Select(v => new { entityId = v.EntityId, entityCode = v.EntityCode, entityName = v.EntityName })
                        })
                })
        };
        var scopeJson = System.Text.Json.JsonSerializer.Serialize(payload);

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_scope_save";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@scope_json",      DbType.String, scopeJson, -1);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceScopeSaveResult(true, request.DefinitionId);
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.SaveScopeAsync failed with SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceScopeSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // 562: Scope Builder Step 2 -- Discover related GRAC intelligence
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceScopeDiscovery?> GetScopeDiscoveryAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_scope_discover";
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@definition_id",   DbType.Int64, definitionId);
            AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

            var categories = new List<OrgAssuranceScopeDiscoveryCategory>();
            var rows       = new List<OrgAssuranceScopeDiscoveryRow>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
                categories.Add(new OrgAssuranceScopeDiscoveryCategory(
                    reader["CategoryCode"]?.ToString() ?? "",
                    reader["CategoryName"]?.ToString() ?? "",
                    ReadIntOrNull(reader, "DisplayOrder") ?? 0,
                    ReadLongOrNull(reader, "ItemCount") ?? 0,
                    reader["IsIncluded"] != DBNull.Value && Convert.ToBoolean(reader["IsIncluded"])));
            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    rows.Add(new OrgAssuranceScopeDiscoveryRow(
                        reader["CategoryCode"]?.ToString() ?? "",
                        Convert.ToInt64(reader["RecordId"]),
                        ReadStringOrNull(reader, "RecordCode"),
                        ReadStringOrNull(reader, "RecordName"),
                        ReadStringOrNull(reader, "Status"),
                        ReadStringOrNull(reader, "Reason")));
            return new OrgAssuranceScopeDiscovery(categories, rows);
        }
        catch (SqlException ex) when (ex.Number is 53606 or 53607)
        {
            return null;
        }
    }

    public async Task<OrgAssuranceScopeSaveResult> SaveScopeCategoriesAsync(
        OrgAssuranceScopeCategorySaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceScopeSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceScopeSaveResult(false, Error: "DefinitionId is required.");

        var json = System.Text.Json.JsonSerializer.Serialize(
            (request.Categories ?? Array.Empty<OrgAssuranceScopeCategoryInput>())
                .Where(c => !string.IsNullOrWhiteSpace(c.Code))
                .Select(c => new { code = c.Code.Trim().ToUpperInvariant(), isIncluded = c.IsIncluded }));
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_scope_category_save";
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@categories_json", DbType.String, json, -1);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceScopeSaveResult(true, request.DefinitionId);
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.SaveScopeCategoriesAsync failed with SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceScopeSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // 564: Control and Practice Mapping (Audit Configuration step).
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceMappingOptions> GetMappingOptionsAsync(
        long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_mapping_options";
        AddParam(command, "@organization_id", DbType.Int64, organizationId);

        var practices = new List<OrgAssuranceMappingOptionRow>();
        var instances = new List<OrgAssuranceMappingOptionRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            practices.Add(new OrgAssuranceMappingOptionRow(
                Convert.ToInt64(reader["Id"]),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                null, null,
                ReadIntOrNull(reader, "InstanceCount")));
        if (await reader.NextResultAsync(cancellationToken))
            while (await reader.ReadAsync(cancellationToken))
                instances.Add(new OrgAssuranceMappingOptionRow(
                    Convert.ToInt64(reader["Id"]),
                    ReadStringOrNull(reader, "Code"),
                    ReadStringOrNull(reader, "Name"),
                    ReadLongOrNull(reader,   "PracticeId"),
                    ReadStringOrNull(reader, "PracticeCode"),
                    null));
        return new OrgAssuranceMappingOptions(practices, instances);
    }

    public async Task<OrgAssuranceMappingResult?> GetMappingAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_definition_mapping_get";
            AddParam(command, "@organization_id", DbType.Int64, organizationId);
            AddParam(command, "@definition_id",   DbType.Int64, definitionId);
            AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken)) return null;
            var header = new OrgAssuranceMappingHeader(
                definitionId,
                ReadLongOrNull(reader,   "VersionId"),
                ReadStringOrNull(reader, "StatusCode"),
                reader["IsEditable"] != DBNull.Value && Convert.ToBoolean(reader["IsEditable"]));
            var items = new List<OrgAssuranceMappingRow>();
            if (await reader.NextResultAsync(cancellationToken))
                while (await reader.ReadAsync(cancellationToken))
                    items.Add(new OrgAssuranceMappingRow(
                        Convert.ToInt64(reader["MappingId"]),
                        reader["MappingType"]?.ToString() ?? "",
                        ReadLongOrNull(reader,   "RecordId"),
                        ReadStringOrNull(reader, "RecordCode"),
                        ReadStringOrNull(reader, "RecordName"),
                        ReadStringOrNull(reader, "ManualKind"),
                        ReadStringOrNull(reader, "ManualReference"),
                        ReadStringOrNull(reader, "Note"),
                        ReadIntOrNull(reader,    "DisplayOrder") ?? 0,
                        ReadLongOrNull(reader,   "PracticeId"),
                        reader["IsAvailable"] != DBNull.Value && Convert.ToBoolean(reader["IsAvailable"])));
            return new OrgAssuranceMappingResult(header, items);
        }
        catch (SqlException ex) when (ex.Number is 53606 or 53607)
        {
            return null;
        }
    }

    public async Task<OrgAssuranceMappingSaveResult> SaveMappingAsync(
        OrgAssuranceMappingSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceMappingSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceMappingSaveResult(false, Error: "DefinitionId is required.");

        var json = System.Text.Json.JsonSerializer.Serialize(
            (request.Items ?? Array.Empty<OrgAssuranceMappingInput>())
                .Where(i => !string.IsNullOrWhiteSpace(i.MappingType))
                .Select(i => new
                {
                    mappingType = i.MappingType.Trim().ToUpperInvariant(),
                    recordId    = i.RecordId,
                    manualKind  = i.ManualKind,
                    reference   = i.Reference,
                    name        = i.Name,
                    note        = i.Note
                }));
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_definition_mapping_save";
            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@items_json",      DbType.String, json, -1);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);
            var count = await command.ExecuteScalarAsync(cancellationToken);
            return new OrgAssuranceMappingSaveResult(true,
                count is null || count == DBNull.Value ? null : Convert.ToInt32(count));
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.SaveMappingAsync failed with SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceMappingSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Evidence Types (question Evidence Type lookup). Evidence
    // Configuration removed by 536.
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceEvidenceLookupRow>> ListEvidenceTypesAsync(CancellationToken cancellationToken)
        => await ListLookupAsync("grac_practice.sp_org_assurance_evidence_type_list", cancellationToken);

    private async Task<IReadOnlyList<OrgAssuranceEvidenceLookupRow>> ListLookupAsync(string procName, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procName;

        var rows = new List<OrgAssuranceEvidenceLookupRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceEvidenceLookupRow(
                ReadIntOrNull(reader,   "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name")));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // Workflow Configuration (Stage 2 -- BRD Part 2 Sec 6)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceAdminWorkflowTemplateRow>> ListAdminWorkflowTemplatesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_admin_workflow_template_list";

        var rows = new List<OrgAssuranceAdminWorkflowTemplateRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceAdminWorkflowTemplateRow(
                ReadLongOrNull(reader,   "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    // 538: one Admin template and its stages, shaped as organization stages.
    public async Task<OrgAssuranceAdminWorkflowTemplateDetail?> GetAdminWorkflowTemplateAsync(long templateId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_admin_workflow_template_stage_list";
        AddParam(command, "@template_id", DbType.Int64, templateId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        var id          = ReadLongOrNull(reader,   "Id");
        var code        = ReadStringOrNull(reader, "Code");
        var name        = ReadStringOrNull(reader, "Name");
        var description = ReadStringOrNull(reader, "Description");
        var totalSla    = ReadIntOrNull(reader,    "TotalSlaDays");

        var stages = new List<OrgAssuranceAdminWorkflowTemplateStageRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                stages.Add(new OrgAssuranceAdminWorkflowTemplateStageRow(
                    ReadIntOrNull(reader,    "StageOrder"),
                    ReadStringOrNull(reader, "StageCode"),
                    ReadStringOrNull(reader, "StageName"),
                    ReadStringOrNull(reader, "StageType"),
                    ReadIntOrNull(reader,    "SlaDays"),
                    ReadStringOrNull(reader, "Instructions"),
                    ReadStringOrNull(reader, "AdminStageType"),
                    ReadIntOrNull(reader,    "SlaHours")));
            }
        }
        return new OrgAssuranceAdminWorkflowTemplateDetail(id, code, name, description, totalSla, stages);
    }

    public async Task<IReadOnlyList<OrgAssuranceWorkflowStageTypeRow>> ListWorkflowStageTypesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_workflow_stage_type_list";

        var rows = new List<OrgAssuranceWorkflowStageTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceWorkflowStageTypeRow(
                reader["StageTypeCode"]?.ToString() ?? "",
                reader["StageTypeName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"])));
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceOrganizationRoleRow>> ListOrganizationRolesAsync(long organizationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_organization_role_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<OrgAssuranceOrganizationRoleRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceOrganizationRoleRow(
                Convert.ToInt64(reader["RoleId"]),
                reader["RoleName"]?.ToString() ?? ""));
        }
        return rows;
    }

    public async Task<OrgAssuranceWorkflowResult?> GetWorkflowAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_workflow_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        try
        {
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            if (!await reader.ReadAsync(cancellationToken)) return null;
            var header = new OrgAssuranceWorkflowHeader(
                Convert.ToInt64(reader["DefinitionId"]),
                Convert.ToInt64(reader["VersionId"]),
                ReadLongOrNull(reader, "CurrentVersionId"),
                reader["CurrentStatusCode"]?.ToString() ?? "",
                Convert.ToBoolean(reader["IsEditable"]));

            OrgAssuranceWorkflowConfigRow? config = null;
            if (await reader.NextResultAsync(cancellationToken))
            {
                if (await reader.ReadAsync(cancellationToken))
                {
                    config = new OrgAssuranceWorkflowConfigRow(
                        Convert.ToInt64(reader["WorkflowConfigId"]),
                        ReadLongOrNull(reader,   "WorkflowTemplateId"),
                        ReadStringOrNull(reader, "WorkflowTemplateCode"),
                        ReadStringOrNull(reader, "WorkflowTemplateName"),
                        ReadStringOrNull(reader, "WorkflowName"),
                        ReadStringOrNull(reader, "Description"),
                        ReadIntOrNull(reader,    "TotalSlaDays"));
                }
            }

            var stages = new List<OrgAssuranceWorkflowStageRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    stages.Add(new OrgAssuranceWorkflowStageRow(
                        Convert.ToInt64(reader["StageId"]),
                        Convert.ToInt32(reader["StageOrder"]),
                        reader["StageCode"]?.ToString() ?? "",
                        reader["StageName"]?.ToString() ?? "",
                        reader["StageType"]?.ToString() ?? "CUSTOM",
                        ReadLongOrNull(reader,   "AssignedRoleId"),
                        ReadStringOrNull(reader, "AssignedRoleName"),
                        ReadLongOrNull(reader,   "AssignedEmployeeId"),
                        ReadStringOrNull(reader, "AssignedEmployeeName"),
                        ReadIntOrNull(reader,    "SlaDays"),
                        ReadLongOrNull(reader,   "EscalationRoleId"),
                        ReadStringOrNull(reader, "EscalationRoleName"),
                        ReadIntOrNull(reader,    "EscalationAfterDays"),
                        ReadStringOrNull(reader, "Instructions")));
                }
            }

            return new OrgAssuranceWorkflowResult(header, config, stages);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.GetWorkflowAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            throw;
        }
    }

    public async Task<OrgAssuranceWorkflowSaveResult> SaveWorkflowAsync(
        OrgAssuranceWorkflowSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceWorkflowSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceWorkflowSaveResult(false, Error: "DefinitionId is required.");

        var header = request.Header ?? new OrgAssuranceWorkflowSaveHeader(null, null, null, null, null, null);
        var headerPayload = new
        {
            workflowTemplateId   = header.WorkflowTemplateId,
            workflowTemplateCode = header.WorkflowTemplateCode,
            workflowTemplateName = header.WorkflowTemplateName,
            workflowName         = header.WorkflowName,
            description          = header.Description,
            totalSlaDays         = header.TotalSlaDays
        };
        var stagesPayload = (request.Stages ?? Array.Empty<OrgAssuranceWorkflowSaveStage>())
            .Where(s => !string.IsNullOrWhiteSpace(s.StageName))
            .Select((s, idx) => new
            {
                stageOrder            = s.StageOrder ?? (idx + 1),
                stageCode             = string.IsNullOrWhiteSpace(s.StageCode) ? $"STG{idx + 1:00}" : s.StageCode.Trim(),
                stageName             = s.StageName.Trim(),
                stageType             = string.IsNullOrWhiteSpace(s.StageType) ? "CUSTOM" : s.StageType.Trim().ToUpperInvariant(),
                assignedRoleId        = s.AssignedRoleId,
                assignedRoleName      = s.AssignedRoleName,
                assignedEmployeeId    = s.AssignedEmployeeId,
                assignedEmployeeName  = s.AssignedEmployeeName,
                slaDays               = s.SlaDays,
                escalationRoleId      = s.EscalationRoleId,
                escalationRoleName    = s.EscalationRoleName,
                escalationAfterDays   = s.EscalationAfterDays,
                instructions          = s.Instructions
            });

        var headerJson = System.Text.Json.JsonSerializer.Serialize(headerPayload);
        var stagesJson = System.Text.Json.JsonSerializer.Serialize(stagesPayload);

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_workflow_save";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@header_json",     DbType.String, headerJson, -1);
            AddParam(command, "@stages_json",     DbType.String, stagesJson, -1);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceWorkflowSaveResult(true, request.DefinitionId);
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);   // shares the Draft-only THROW space
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.SaveWorkflowAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceWorkflowSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Scoring Configuration (Stage 2 -- BRD Part 2 Sec 7)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceAdminScoringModelRow>> ListAdminScoringModelsAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_admin_scoring_model_list";

        var rows = new List<OrgAssuranceAdminScoringModelRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceAdminScoringModelRow(
                ReadLongOrNull(reader,   "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceScoringModelTypeRow>> ListScoringModelTypesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scoring_model_type_list";

        var rows = new List<OrgAssuranceScoringModelTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceScoringModelTypeRow(
                reader["ModelTypeCode"]?.ToString() ?? "",
                reader["ModelTypeName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                Convert.ToBoolean(reader["SupportsBands"]),
                Convert.ToBoolean(reader["SupportsThreshold"])));
        }
        return rows;
    }

    public async Task<OrgAssuranceScoringResult?> GetScoringAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scoring_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        try
        {
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);

            if (!await reader.ReadAsync(cancellationToken)) return null;
            var header = new OrgAssuranceScoringHeader(
                Convert.ToInt64(reader["DefinitionId"]),
                Convert.ToInt64(reader["VersionId"]),
                ReadLongOrNull(reader, "CurrentVersionId"),
                reader["CurrentStatusCode"]?.ToString() ?? "",
                Convert.ToBoolean(reader["IsEditable"]));

            OrgAssuranceScoringConfigRow? config = null;
            if (await reader.NextResultAsync(cancellationToken))
            {
                if (await reader.ReadAsync(cancellationToken))
                {
                    config = new OrgAssuranceScoringConfigRow(
                        Convert.ToInt64(reader["ScoringConfigId"]),
                        ReadLongOrNull(reader,    "ScoringModelId"),
                        ReadStringOrNull(reader,  "ScoringModelCode"),
                        ReadStringOrNull(reader,  "ScoringModelName"),
                        reader["ScoringModelType"]?.ToString() ?? "PASS_FAIL",
                        ReadDecimalOrNull(reader, "MaxScore"),
                        ReadDecimalOrNull(reader, "PassThreshold"),
                        ReadDecimalOrNull(reader, "WarningThreshold"),
                        ReadDecimalOrNull(reader, "FailThreshold"),
                        ReadStringOrNull(reader,  "Description"));
                }
            }

            var bands = new List<OrgAssuranceScoringBandRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    bands.Add(new OrgAssuranceScoringBandRow(
                        Convert.ToInt64(reader["BandId"]),
                        Convert.ToInt32(reader["BandOrder"]),
                        reader["BandCode"]?.ToString() ?? "",
                        reader["BandName"]?.ToString() ?? "",
                        Convert.ToDecimal(reader["MinScore"]),
                        Convert.ToDecimal(reader["MaxScore"]),
                        ReadStringOrNull(reader, "OutcomeCode"),
                        ReadStringOrNull(reader, "ColorHex"),
                        ReadStringOrNull(reader, "Description")));
                }
            }

            return new OrgAssuranceScoringResult(header, config, bands);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.GetScoringAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            throw;
        }
    }

    public async Task<OrgAssuranceScoringSaveResult> SaveScoringAsync(
        OrgAssuranceScoringSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceScoringSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceScoringSaveResult(false, Error: "DefinitionId is required.");

        var header = request.Header ?? new OrgAssuranceScoringSaveHeader(null, null, null, null, null, null, null, null, null);
        var headerPayload = new
        {
            scoringModelId    = header.ScoringModelId,
            scoringModelCode  = header.ScoringModelCode,
            scoringModelName  = header.ScoringModelName,
            scoringModelType  = string.IsNullOrWhiteSpace(header.ScoringModelType) ? "PASS_FAIL" : header.ScoringModelType!.Trim().ToUpperInvariant(),
            maxScore          = header.MaxScore,
            passThreshold     = header.PassThreshold,
            warningThreshold  = header.WarningThreshold,
            failThreshold     = header.FailThreshold,
            description       = header.Description
        };

        var bandsPayload = (request.Bands ?? Array.Empty<OrgAssuranceScoringSaveBand>())
            .Where(b => !string.IsNullOrWhiteSpace(b.BandName))
            .Select((b, idx) => new
            {
                bandOrder   = b.BandOrder ?? (idx + 1),
                bandCode    = string.IsNullOrWhiteSpace(b.BandCode) ? $"BAND{idx + 1:00}" : b.BandCode.Trim(),
                bandName    = b.BandName.Trim(),
                minScore    = b.MinScore,
                maxScore    = b.MaxScore,
                outcomeCode = string.IsNullOrWhiteSpace(b.OutcomeCode) ? null : b.OutcomeCode!.Trim().ToUpperInvariant(),
                colorHex    = b.ColorHex,
                description = b.Description
            });

        var headerJson = System.Text.Json.JsonSerializer.Serialize(headerPayload);
        var bandsJson  = System.Text.Json.JsonSerializer.Serialize(bandsPayload);

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_scoring_save";

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",   DbType.Int64,  request.DefinitionId);
            AddParam(command, "@header_json",     DbType.String, headerJson, -1);
            AddParam(command, "@bands_json",      DbType.String, bandsJson,  -1);
            AddParam(command, "@actor",           DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceScoringSaveResult(true, request.DefinitionId);
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);   // shares the Draft-only THROW space
            logger.LogWarning(ex,
                "OrgAssuranceDefinitionService.SaveScoringAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceScoringSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // -----------------------------------------------------------------
    // Trigger Configuration (Stage 3 -- BRD Part 2 Sec 9)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceTriggerTypeRow>> ListTriggerTypesAsync(CancellationToken cancellationToken)
        => await ListSimpleVocabAsync<OrgAssuranceTriggerTypeRow>(
            "grac_practice.sp_org_assurance_trigger_type_list",
            r => new OrgAssuranceTriggerTypeRow(
                r["TriggerTypeCode"]?.ToString() ?? "",
                r["TriggerTypeName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])),
            cancellationToken);

    public async Task<IReadOnlyList<OrgAssuranceScheduleFrequencyRow>> ListScheduleFrequenciesAsync(CancellationToken cancellationToken)
        => await ListSimpleVocabAsync<OrgAssuranceScheduleFrequencyRow>(
            "grac_practice.sp_org_assurance_schedule_frequency_list",
            r => new OrgAssuranceScheduleFrequencyRow(
                r["FrequencyCode"]?.ToString() ?? "",
                r["FrequencyName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])),
            cancellationToken);

    public async Task<IReadOnlyList<OrgAssuranceEventCodeRow>> ListEventCodesAsync(CancellationToken cancellationToken)
        => await ListSimpleVocabAsync<OrgAssuranceEventCodeRow>(
            "grac_practice.sp_org_assurance_event_code_list",
            r => new OrgAssuranceEventCodeRow(
                r["EventCode"]?.ToString() ?? "",
                r["EventName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])),
            cancellationToken);

    public async Task<IReadOnlyList<OrgAssuranceContinuousSourceRow>> ListContinuousSourcesAsync(CancellationToken cancellationToken)
        => await ListSimpleVocabAsync<OrgAssuranceContinuousSourceRow>(
            "grac_practice.sp_org_assurance_continuous_source_list",
            r => new OrgAssuranceContinuousSourceRow(
                r["SourceCode"]?.ToString() ?? "",
                r["SourceName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])),
            cancellationToken);

    private async Task<IReadOnlyList<T>> ListSimpleVocabAsync<T>(
        string procName,
        Func<DbDataReader, T> map,
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procName;

        var rows = new List<T>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(map(reader));
        return rows;
    }

    public async Task<OrgAssuranceTriggerListResult?> ListTriggersAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_trigger_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);

        try
        {
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken)) return null;

            var header = new OrgAssuranceTriggerHeader(
                Convert.ToInt64(reader["DefinitionId"]),
                Convert.ToInt64(reader["VersionId"]),
                ReadLongOrNull(reader, "CurrentVersionId"),
                reader["CurrentStatusCode"]?.ToString() ?? "",
                Convert.ToBoolean(reader["IsEditable"]));

            var triggers = new List<OrgAssuranceTriggerRow>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                    triggers.Add(MapTriggerRow(reader));
            }
            return new OrgAssuranceTriggerListResult(header, triggers);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceDefinitionService.ListTriggersAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            throw;
        }
    }

    private static OrgAssuranceTriggerRow MapTriggerRow(DbDataReader r) => new(
        Convert.ToInt64(r["TriggerId"]),
        r["TriggerCode"]?.ToString() ?? "",
        r["TriggerName"]?.ToString() ?? "",
        r["TriggerType"]?.ToString() ?? "MANUAL",
        Convert.ToBoolean(r["IsEnabled"]),
        ReadStringOrNull(r, "Description"),
        ReadStringOrNull(r, "ScheduleFrequencyCode"),
        ReadIntOrNull(r,    "ScheduleFrequencyId"),
        ReadStringOrNull(r, "ScheduleFrequencyName"),
        ReadDateTimeOrNull(r, "ScheduleStartDate"),
        ReadDateTimeOrNull(r, "ScheduleEndDate"),
        ReadTimeSpanOrNull(r, "ScheduleTime"),
        ReadIntOrNull(r, "DayOfWeek"),
        ReadIntOrNull(r, "DayOfMonth"),
        ReadIntOrNull(r, "MonthOfYear"),
        ReadDateTimeOrNull(r, "NextRunAt"),
        ReadDateTimeOrNull(r, "LastRunAt"),
        ReadStringOrNull(r, "EventCode"),
        ReadStringOrNull(r, "EventName"),
        ReadStringOrNull(r, "EventSource"),
        ReadStringOrNull(r, "EventFilterJson"),
        ReadStringOrNull(r, "ContinuousSourceCode"),
        ReadStringOrNull(r, "ContinuousEndpoint"),
        ReadStringOrNull(r, "ContinuousRuleCode"));

    public async Task<OrgAssuranceTriggerSaveResult> SaveTriggerAsync(
        OrgAssuranceTriggerSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceTriggerSaveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceTriggerSaveResult(false, Error: "DefinitionId is required.");
        if (string.IsNullOrWhiteSpace(request.TriggerCode))
            return new OrgAssuranceTriggerSaveResult(false, Error: "TriggerCode is required.");
        if (string.IsNullOrWhiteSpace(request.TriggerName))
            return new OrgAssuranceTriggerSaveResult(false, Error: "TriggerName is required.");
        if (string.IsNullOrWhiteSpace(request.TriggerType))
            return new OrgAssuranceTriggerSaveResult(false, Error: "TriggerType is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_trigger_save";

            AddParam(command, "@organization_id",         DbType.Int64,   request.OrganizationId);
            AddParam(command, "@definition_id",           DbType.Int64,   request.DefinitionId);
            AddParam(command, "@trigger_id",              DbType.Int64,   (object?)request.TriggerId ?? DBNull.Value);
            AddParam(command, "@trigger_code",            DbType.String,  request.TriggerCode.Trim(), 80);
            AddParam(command, "@trigger_name",            DbType.String,  request.TriggerName.Trim(), 200);
            AddParam(command, "@trigger_type",            DbType.String,  request.TriggerType.Trim().ToUpperInvariant(), 30);
            AddParam(command, "@is_enabled",              DbType.Boolean, request.IsEnabled ?? true);
            AddParam(command, "@description",             DbType.String,  (object?)request.Description ?? DBNull.Value, -1);

            AddParam(command, "@schedule_frequency_code", DbType.String,  (object?)request.ScheduleFrequencyCode ?? DBNull.Value, 30);
            AddParam(command, "@schedule_frequency_id",   DbType.Int32,   (object?)request.ScheduleFrequencyId ?? DBNull.Value);
            AddParam(command, "@schedule_frequency_name", DbType.String,  (object?)request.ScheduleFrequencyName ?? DBNull.Value, 120);
            AddParam(command, "@schedule_start_date",     DbType.Date,    (object?)request.ScheduleStartDate ?? DBNull.Value);
            AddParam(command, "@schedule_end_date",       DbType.Date,    (object?)request.ScheduleEndDate   ?? DBNull.Value);
            AddParam(command, "@schedule_time",           DbType.Time,    (object?)request.ScheduleTime ?? DBNull.Value);
            AddParam(command, "@day_of_week",             DbType.Int32,   (object?)request.DayOfWeek  ?? DBNull.Value);
            AddParam(command, "@day_of_month",            DbType.Int32,   (object?)request.DayOfMonth ?? DBNull.Value);
            AddParam(command, "@month_of_year",           DbType.Int32,   (object?)request.MonthOfYear?? DBNull.Value);

            AddParam(command, "@event_code",              DbType.String,  (object?)request.EventCode   ?? DBNull.Value, 60);
            AddParam(command, "@event_name",              DbType.String,  (object?)request.EventName   ?? DBNull.Value, 200);
            AddParam(command, "@event_source",            DbType.String,  (object?)request.EventSource ?? DBNull.Value, 100);
            AddParam(command, "@event_filter_json",       DbType.String,  (object?)request.EventFilterJson ?? DBNull.Value, -1);

            AddParam(command, "@continuous_source_code",  DbType.String,  (object?)request.ContinuousSourceCode ?? DBNull.Value, 30);
            AddParam(command, "@continuous_endpoint",     DbType.String,  (object?)request.ContinuousEndpoint   ?? DBNull.Value, 500);
            AddParam(command, "@continuous_rule_code",    DbType.String,  (object?)request.ContinuousRuleCode   ?? DBNull.Value, 80);

            AddParam(command, "@actor",                   DbType.String,  (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@trigger_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceTriggerSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapTriggerReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceDefinitionService.SaveTriggerAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceTriggerSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceTriggerCommandResult> DeleteTriggerAsync(
        long organizationId, long triggerId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_trigger_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@trigger_id",      DbType.Int64,  triggerId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceTriggerCommandResult(true, triggerId);
        }
        catch (SqlException ex)
        {
            var reason = MapTriggerReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceDefinitionService.DeleteTriggerAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceTriggerCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // Trigger-specific THROW mapping (093 uses 54001-54007 plus shared codes).
    private static string MapTriggerReason(int errorNumber) => errorNumber switch
    {
        53602 => "IDS_REQUIRED",
        53606 => "DEFINITION_NOT_FOUND",
        53607 => "WRONG_ORGANIZATION",
        53608 => "NOT_DRAFT",
        53611 => "NO_CURRENT_VERSION",
        54001 => "TRIGGER_CODE_REQUIRED",
        54002 => "TRIGGER_NAME_REQUIRED",
        54003 => "INVALID_TRIGGER_TYPE",
        54004 => "INVALID_EVENT_FILTER_JSON",
        54005 => "DUPLICATE_TRIGGER_CODE",
        54006 => "TRIGGER_NOT_FOUND",
        54007 => "TRIGGER_VERSION_MISMATCH",
        _     => "SQL_ERROR"
    };

    // -----------------------------------------------------------------
    // Scope Resolution Engine (Stage 3 -- BRD Part 2 Sec 3)
    // -----------------------------------------------------------------
    public async Task<OrgAssuranceScopeResolveResult> ResolveScopeAsync(
        OrgAssuranceScopeResolveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new OrgAssuranceScopeResolveResult(false, Error: "OrganizationId is required.");
        if (request.DefinitionId <= 0)
            return new OrgAssuranceScopeResolveResult(false, Error: "DefinitionId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_scope_resolve";

            AddParam(command, "@organization_id",    DbType.Int64,  request.OrganizationId);
            AddParam(command, "@definition_id",      DbType.Int64,  request.DefinitionId);
            AddParam(command, "@version_id",         DbType.Int64,  (object?)request.VersionId   ?? DBNull.Value);
            AddParam(command, "@resolution_purpose", DbType.String, string.IsNullOrWhiteSpace(request.ResolutionPurpose) ? "PREVIEW" : request.ResolutionPurpose!.Trim().ToUpperInvariant(), 30);
            AddParam(command, "@execution_id",       DbType.Int64,  (object?)request.ExecutionId ?? DBNull.Value);
            AddParam(command, "@actor",              DbType.String, (object?)request.Actor       ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@resolution_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceScopeResolveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapScopeReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceDefinitionService.ResolveScopeAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceScopeResolveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceScopeResolutionListResult> ListScopeResolutionsAsync(
        long organizationId, long definitionId, long? versionId, int page, int pageSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_resolution_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@definition_id",   DbType.Int64, definitionId);
        AddParam(command, "@version_id",      DbType.Int64, (object?)versionId ?? DBNull.Value);
        AddParam(command, "@page",            DbType.Int32, Math.Max(1, page));
        AddParam(command, "@page_size",       DbType.Int32, Math.Clamp(pageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  pg    = page;
        int  size  = pageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            pg    = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<OrgAssuranceScopeResolutionListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapResolutionRow(reader));
        }
        return new OrgAssuranceScopeResolutionListResult(total, pg, size, rows);
    }

    public async Task<OrgAssuranceScopeResolutionDetail?> GetScopeResolutionAsync(
        long organizationId, long resolutionId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_resolution_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@resolution_id",   DbType.Int64, resolutionId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        var header = MapResolutionRow(reader);

        var summary = new List<OrgAssuranceScopeResolutionSummaryRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                summary.Add(new OrgAssuranceScopeResolutionSummaryRow(
                    reader["DimensionCode"]?.ToString() ?? "",
                    ReadStringOrNull(reader, "DimensionName"),
                    Convert.ToInt64(reader["EntityCount"])));
            }
        }
        return new OrgAssuranceScopeResolutionDetail(header, summary);
    }

    public async Task<OrgAssuranceScopeResolutionEntityListResult> ListScopeResolutionEntitiesAsync(
        long organizationId, long resolutionId, string? dimensionCode, string? search, int page, int pageSize, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_scope_resolution_entity_list";

        AddParam(command, "@organization_id", DbType.Int64,  organizationId);
        AddParam(command, "@resolution_id",   DbType.Int64,  resolutionId);
        AddParam(command, "@dimension_code",  DbType.String, (object?)dimensionCode ?? DBNull.Value, 60);
        AddParam(command, "@search",          DbType.String, (object?)search        ?? DBNull.Value, 200);
        AddParam(command, "@page",            DbType.Int32,  Math.Max(1, page));
        AddParam(command, "@page_size",       DbType.Int32,  Math.Clamp(pageSize, 1, 500));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  pg    = page;
        int  size  = pageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            pg    = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<OrgAssuranceScopeResolutionEntityRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new OrgAssuranceScopeResolutionEntityRow(
                    Convert.ToInt64(reader["EntityRowId"]),
                    reader["DimensionCode"]?.ToString() ?? "",
                    ReadStringOrNull(reader, "DimensionName"),
                    ReadLongOrNull(reader,   "EntityId"),
                    ReadStringOrNull(reader, "EntityCode"),
                    ReadStringOrNull(reader, "EntityName"),
                    ReadIntOrNull(reader,    "SourceGroupOrder"),
                    ReadIntOrNull(reader,    "SourceConditionOrder")));
            }
        }
        return new OrgAssuranceScopeResolutionEntityListResult(total, pg, size, rows);
    }

    private static OrgAssuranceScopeResolutionListRow MapResolutionRow(DbDataReader r) => new(
        Convert.ToInt64(r["ResolutionId"]),
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt64(r["DefinitionVersionId"]),
        r["ResolutionPurpose"]?.ToString() ?? "PREVIEW",
        ReadLongOrNull(r, "ExecutionId"),
        Convert.ToDateTime(r["ResolvedAt"]),
        r["ResolvedBy"]?.ToString() ?? "",
        Convert.ToInt64(r["TotalEntityCount"]),
        ReadStringOrNull(r, "SummaryJson"),
        ReadStringOrNull(r, "Notes"));

    // Reason mapping for scope-specific THROW numbers (074).
    private static string MapScopeReason(int errorNumber) => errorNumber switch
    {
        53602 => "IDS_REQUIRED",
        53606 => "NOT_FOUND",
        53607 => "WRONG_ORGANIZATION",
        53608 => "NOT_DRAFT",
        53611 => "NO_CURRENT_VERSION",
        53701 => "ORGANIZATION_ID_REQUIRED",
        53702 => "DIMENSION_CODE_REQUIRED",
        53703 => "INVALID_JSON",
        53704 => "UNKNOWN_DIMENSION",
        53705 => "INVALID_CATEGORIES",   // 562
        53706 => "UNKNOWN_CATEGORY",     // 562
        53707 => "INVALID_MAPPING",      // 564
        53708 => "MAPPED_RECORD_NOT_FOUND",   // 564
        53709 => "MANUAL_MAPPING_NAME_REQUIRED",  // 564
        _     => "SQL_ERROR"
    };

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
        await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
        return connection;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType        = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static long? ReadLongOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);

    private static int? ReadIntOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);

    private static decimal? ReadDecimalOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : Convert.ToDecimal(r[col]);

    private static DateTime? ReadDateTimeOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : Convert.ToDateTime(r[col]);

    private static TimeSpan? ReadTimeSpanOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : (TimeSpan)r[col];

    private static string? ReadStringOrNull(DbDataReader r, string col) =>
        r[col] == DBNull.Value ? null : r[col].ToString();

    private static OrgAssuranceDefinitionListRow MapListRow(DbDataReader r) => new(
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt64(r["OrganizationId"]),
        r["DefinitionCode"]?.ToString() ?? "",
        r["DefinitionName"]?.ToString() ?? "",
        // 119 hybrid role+employee Owner
        ReadLongOrNull(r, "OwnerRoleId"),
        ReadStringOrNull(r, "OwnerRoleName"),
        ReadLongOrNull(r, "OwnerEmployeeId"),
        ReadStringOrNull(r, "OwnerDisplayName"),
        ReadLongOrNull(r, "CurrentVersionId"),
        ReadLongOrNull(r, "ActiveVersionId"),
        r["CurrentStatusCode"]?.ToString() ?? "",
        r["CurrentStatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["CurrentStatusIsTerminal"]),
        ReadIntOrNull(r,  "CurrentVersionNumber"),
        ReadStringOrNull(r, "CurrentVersionLabel"),
        ReadDateTimeOrNull(r, "CurrentEffectiveDate"),
        ReadStringOrNull(r, "CurrentCategoryCode"),
        ReadStringOrNull(r, "CurrentCategoryName"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceDefinitionDetail MapDetailRow(DbDataReader r) => new(
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt64(r["OrganizationId"]),
        r["DefinitionCode"]?.ToString() ?? "",
        r["DefinitionName"]?.ToString() ?? "",
        // 119 hybrid role+employee Owner
        ReadLongOrNull(r, "OwnerRoleId"),
        ReadStringOrNull(r, "OwnerRoleName"),
        ReadLongOrNull(r, "OwnerEmployeeId"),
        ReadStringOrNull(r, "OwnerDisplayName"),
        ReadLongOrNull(r, "CurrentVersionId"),
        ReadLongOrNull(r, "ActiveVersionId"),
        r["CurrentStatusCode"]?.ToString() ?? "",
        r["CurrentStatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["CurrentStatusIsTerminal"]),
        ReadIntOrNull(r, "CurrentVersionNumber"),
        ReadStringOrNull(r, "CurrentVersionLabel"),
        ReadStringOrNull(r, "Description"),
        ReadStringOrNull(r, "Objective"),
        ReadDateTimeOrNull(r, "EffectiveDate"),
        ReadLongOrNull(r, "AssuranceCategoryId"),
        ReadStringOrNull(r, "AssuranceCategoryCode"),
        ReadStringOrNull(r, "AssuranceCategoryName"),
        // 560 -- tolerant: the columns exist only once 560 is run.
        HasColumn(r, "AssuranceApproachId")   ? ReadLongOrNull(r, "AssuranceApproachId")     : null,
        HasColumn(r, "AssuranceApproachCode") ? ReadStringOrNull(r, "AssuranceApproachCode") : null,
        HasColumn(r, "AssuranceApproachName") ? ReadStringOrNull(r, "AssuranceApproachName") : null,
        ReadStringOrNull(r, "SubmittedBy"), ReadDateTimeOrNull(r, "SubmittedDt"),
        ReadStringOrNull(r, "ApprovedBy"),  ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadStringOrNull(r, "ActivatedBy"), ReadDateTimeOrNull(r, "ActivatedDt"),
        ReadStringOrNull(r, "RetiredBy"),   ReadDateTimeOrNull(r, "RetiredDt"),
        ReadStringOrNull(r, "EnteredBy"),   ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),   ReadDateTimeOrNull(r, "UpdatedDt"));

    // 560: tolerant read of columns a later migration adds.
    private static bool HasColumn(DbDataReader r, string col)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), col, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static OrgAssuranceDefinitionHistoryRow MapHistoryRow(DbDataReader r) => new(
        Convert.ToInt64(r["HistoryId"]),
        Convert.ToInt64(r["DefinitionId"]),
        ReadLongOrNull(r, "DefinitionVersionId"),
        r["ActionCode"]?.ToString() ?? "",
        ReadStringOrNull(r, "FromStatusCode"), ReadStringOrNull(r, "FromStatusName"),
        ReadStringOrNull(r, "ToStatusCode"),   ReadStringOrNull(r, "ToStatusName"),
        ReadStringOrNull(r, "ReasonText"),
        ReadStringOrNull(r, "ActorDisplayName"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"));

    private static OrgAssuranceDefinitionVersionRow MapVersionRow(DbDataReader r) => new(
        Convert.ToInt64(r["VersionId"]),
        Convert.ToInt64(r["DefinitionId"]),
        Convert.ToInt32(r["VersionNumber"]),
        ReadStringOrNull(r, "VersionLabel"),
        ReadStringOrNull(r, "Description"),
        ReadStringOrNull(r, "Objective"),
        ReadDateTimeOrNull(r, "EffectiveDate"),
        ReadLongOrNull(r, "AssuranceCategoryId"),
        ReadStringOrNull(r, "AssuranceCategoryCode"),
        ReadStringOrNull(r, "AssuranceCategoryName"),
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        ReadStringOrNull(r, "SubmittedBy"), ReadDateTimeOrNull(r, "SubmittedDt"),
        ReadStringOrNull(r, "ApprovedBy"),  ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadStringOrNull(r, "ActivatedBy"), ReadDateTimeOrNull(r, "ActivatedDt"),
        ReadStringOrNull(r, "RetiredBy"),   ReadDateTimeOrNull(r, "RetiredDt"),
        ReadStringOrNull(r, "EnteredBy"),   ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),   ReadDateTimeOrNull(r, "UpdatedDt"));

    private OrgAssuranceDefinitionSaveResult HandleSqlErrorAsSave(SqlException ex, string op)
    {
        var reason = MapReason(ex.Number);
        logger.LogWarning(ex,
            "OrgAssuranceDefinitionService.{Op} failed with SQL error {Number}: {Message}",
            op, ex.Number, ex.Message);
        // 2026-11-04: two creates racing past the 53605 check meet the
        // UNIQUE(organization_id, definition_code) constraint instead; show
        // the same message rather than the raw constraint text.
        var error = ex.Number is 2627 or 2601
            ? "A definition with this code already exists in the organization."
            : ex.Message;
        return new OrgAssuranceDefinitionSaveResult(false, Error: error, ReasonCode: reason);
    }

    private OrgAssuranceDefinitionTransitionResult HandleSqlErrorAsTransition(SqlException ex, string op)
    {
        var reason = MapReason(ex.Number);
        logger.LogWarning(ex,
            "OrgAssuranceDefinitionService.{Op} failed with SQL error {Number}: {Message}",
            op, ex.Number, ex.Message);
        return new OrgAssuranceDefinitionTransitionResult(false, Error: ex.Message, ReasonCode: reason);
    }

    // Reason codes match the THROW numbers used in 070.
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        53601 => "ORGANIZATION_ID_REQUIRED",
        53602 => "IDS_REQUIRED",
        53603 => "CODE_REQUIRED",
        53604 => "NAME_REQUIRED",
        53605 => "DUPLICATE_CODE",
        2627 or 2601 => "DUPLICATE_CODE",   // unique key (organization_id, definition_code)
        53606 => "NOT_FOUND",
        53607 => "WRONG_ORGANIZATION",
        53608 => "NOT_EDITABLE_IN_REVIEW",
        53609 => "STATUS_LOOKUP_FAILED",
        53610 => "ILLEGAL_TRANSITION",
        53611 => "NO_CURRENT_VERSION",
        53612 => "CONFIGURATION_INCOMPLETE",   // 537: submit before the configuration is complete
        53613 => "APPROACH_NOT_FOUND",         // 560: Assurance Approach missing or inactive
        53614 => "FRAMEWORKS_INVALID",         // 560: Applicable Frameworks list not valid JSON
        53615 => "MANDATE_INVALID",            // 560: an Audit Mandate missing / inactive, or the list not valid JSON
        _     => "SQL_ERROR"
    };
}
