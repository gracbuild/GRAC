import sys, os
ROOT = sys.argv[1]

def patch(rel, pairs):
    p = os.path.join(ROOT, rel)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    bom = raw.startswith(b'\xef\xbb\xbf')
    s = raw.decode('utf-8-sig').replace('\r\n', '\n')
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, (rel, old[:80], n)
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + s.encode('utf-8'))
    print('patched', rel)

M = 'src/PracticeManagement.Api/Models/OrgAssuranceDefinitionModels.cs'
patch(M, [
("""public sealed record OrgAssuranceScopeSaveResult(""",
"""/// <summary>562: Scope Builder Step 2 -- one discovered category (sp_org_assurance_scope_discover, result 1).</summary>
public sealed record OrgAssuranceScopeDiscoveryCategory(
    string CategoryCode,
    string CategoryName,
    int    DisplayOrder,
    long   ItemCount,
    bool   IsIncluded);

/// <summary>562: one discovered record and why it is related (result 2).</summary>
public sealed record OrgAssuranceScopeDiscoveryRow(
    string  CategoryCode,
    long    RecordId,
    string? RecordCode,
    string? RecordName,
    string? Status,
    string? Reason);

/// <summary>562: GET definitions/{id}/scope-discovery.</summary>
public sealed record OrgAssuranceScopeDiscovery(
    IReadOnlyList<OrgAssuranceScopeDiscoveryCategory> Categories,
    IReadOnlyList<OrgAssuranceScopeDiscoveryRow>      Rows);

/// <summary>562: POST definitions/{id}/scope-categories -- which categories the audit brings in.</summary>
public sealed record OrgAssuranceScopeCategorySaveRequest(
    long    OrganizationId,
    long    DefinitionId,
    IReadOnlyList<OrgAssuranceScopeCategoryInput>? Categories,
    string? Actor);

public sealed record OrgAssuranceScopeCategoryInput(
    string Code,
    bool   IsIncluded);

public sealed record OrgAssuranceScopeSaveResult("""),
])

S = 'src/PracticeManagement.Api/Services/OrgAssuranceDefinitionService.cs'
patch(S, [
("""    Task<OrgAssuranceScopeSaveResult> SaveScopeAsync(""",
"""    // 562: Scope Builder Step 2 -- discovery and the category flags.
    Task<OrgAssuranceScopeDiscovery?> GetScopeDiscoveryAsync(
        long organizationId, long definitionId, long? versionId, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeSaveResult> SaveScopeCategoriesAsync(
        OrgAssuranceScopeCategorySaveRequest request, CancellationToken cancellationToken);

    Task<OrgAssuranceScopeSaveResult> SaveScopeAsync("""),
("""    // -----------------------------------------------------------------
    // Evidence Types (question Evidence Type lookup). Evidence
    // Configuration removed by 536.
    // -----------------------------------------------------------------""",
"""    // -----------------------------------------------------------------
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
    // Evidence Types (question Evidence Type lookup). Evidence
    // Configuration removed by 536.
    // -----------------------------------------------------------------"""),
("""        53704 => "UNKNOWN_DIMENSION",
""",
"""        53704 => "UNKNOWN_DIMENSION",
        53705 => "INVALID_CATEGORIES",   // 562
        53706 => "UNKNOWN_CATEGORY",     // 562
"""),
])

C = 'src/PracticeManagement.Api/Controllers/OrgAssuranceDefinitionController.cs'
patch(C, [
("""    [HttpPost("definitions/{id:long}/scope")]""",
"""    // ================================================================
    // 562: Scope Builder Step 2 -- Discover related GRAC intelligence,
    // and which discovered categories the audit brings in.
    // ================================================================
    [HttpGet("definitions/{id:long}/scope-discovery")]
    public async Task<IActionResult> GetScopeDiscovery(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.GetScopeDiscoveryAsync(organizationId.Value, id, versionId, cancellationToken);
            return result is null ? NotFound(new { error = "Definition not found." }) : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetScopeDiscovery failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/scope-categories")]
    public async Task<IActionResult> SaveScopeCategories(
        long id,
        [FromBody] OrgAssuranceScopeCategorySaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.SaveScopeCategoriesAsync(body with { DefinitionId = id }, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("definitions/{id:long}/scope")]"""),
])
