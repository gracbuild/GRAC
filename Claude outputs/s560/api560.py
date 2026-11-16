import sys, os
ROOT = sys.argv[1]

def patch(rel, pairs):
    p = os.path.join(ROOT, rel)
    raw = open(p, 'rb').read()
    crlf = b'\r\n' in raw
    s = raw.decode('utf-8-sig' if raw.startswith(b'\xef\xbb\xbf') else 'utf-8').replace('\r\n', '\n')
    bom = raw.startswith(b'\xef\xbb\xbf')
    for old, new in pairs:
        n = s.count(old)
        assert n == 1, (rel, old[:70], n)
        s = s.replace(old, new)
    if crlf: s = s.replace('\n', '\r\n')
    open(p, 'wb').write((b'\xef\xbb\xbf' if bom else b'') + s.encode('utf-8'))
    print('patched', rel)

M = 'src/PracticeManagement.Api/Models/OrgAssuranceDefinitionModels.cs'
patch(M, [
("""public sealed record OrgAssuranceAdminCategoryRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);
""",
"""public sealed record OrgAssuranceAdminCategoryRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>560: Assurance Approach dropdown row (how the audit is conducted),
/// from grac_practice.org_assurance_approach_master via sp_org_assurance_approach_list.</summary>
public sealed record OrgAssuranceApproachRow(
    long?   Id,
    string? Code,
    string? Name,
    string? Description);

/// <summary>560: one Applicable Framework of a definition version. ReleaseId is the
/// subscribed framework (grac_new.release); null for a framework typed by hand.</summary>
public sealed record OrgAssuranceDefinitionFrameworkRow(
    long?  DefinitionFrameworkId,
    long?  ReleaseId,
    string FrameworkName,
    int    DisplayOrder);

/// <summary>560: an Applicable Framework sent on save.</summary>
public sealed record OrgAssuranceDefinitionFrameworkInput(
    long?   ReleaseId,
    string? Name);
"""),
("""    long?     AssuranceCategoryId,
    string?   AssuranceCategoryCode,
    string?   AssuranceCategoryName,
    string?   SubmittedBy,
    DateTime? SubmittedDt,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    string?   ActivatedBy,
    DateTime? ActivatedDt,
    string?   RetiredBy,
    DateTime? RetiredDt,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt);

/// <summary>Save request""",
"""    long?     AssuranceCategoryId,
    string?   AssuranceCategoryCode,
    string?   AssuranceCategoryName,
    // 560: Assurance Approach (id + code / name as saved) and Audit Mandate.
    long?     AssuranceApproachId,
    string?   AssuranceApproachCode,
    string?   AssuranceApproachName,
    string?   AuditMandate,
    string?   SubmittedBy,
    DateTime? SubmittedDt,
    string?   ApprovedBy,
    DateTime? ApprovedDt,
    string?   ActivatedBy,
    DateTime? ActivatedDt,
    string?   RetiredBy,
    DateTime? RetiredDt,
    string?   EnteredBy,
    DateTime? EnteredDt,
    string?   UpdatedBy,
    DateTime? UpdatedDt,
    // 560: the current version's Applicable Frameworks (second result set).
    IReadOnlyList<OrgAssuranceDefinitionFrameworkRow>? ApplicableFrameworks = null);

/// <summary>Save request"""),
("""    long?   AssuranceCategoryId,
    string? AssuranceCategoryCode,
    string? AssuranceCategoryName,
    string? Actor);""",
"""    long?   AssuranceCategoryId,
    string? AssuranceCategoryCode,
    string? AssuranceCategoryName,
    string? Actor,
    // 560: Assurance Approach, Audit Mandate, Applicable Frameworks
    // (ApplicableFrameworks null = leave the saved list as it is; empty = clear it).
    long?   AssuranceApproachId = null,
    string? AuditMandate        = null,
    IReadOnlyList<OrgAssuranceDefinitionFrameworkInput>? ApplicableFrameworks = null);"""),
])

S = 'src/PracticeManagement.Api/Services/OrgAssuranceDefinitionService.cs'
patch(S, [
("""    Task<IReadOnlyList<OrgAssuranceAdminCategoryRow>> ListAdminCategoriesAsync(CancellationToken cancellationToken);
""",
"""    Task<IReadOnlyList<OrgAssuranceAdminCategoryRow>> ListAdminCategoriesAsync(CancellationToken cancellationToken);

    // 560
    Task<IReadOnlyList<OrgAssuranceApproachRow>> ListApproachesAsync(CancellationToken cancellationToken);
"""),
("""    // -----------------------------------------------------------------
    // List definitions (paginated)
    // -----------------------------------------------------------------""",
"""    // -----------------------------------------------------------------
    // 560: Assurance Approaches (grac_practice.org_assurance_approach_master)
    // -----------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceApproachRow>> ListApproachesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_approach_list";

        var rows = new List<OrgAssuranceApproachRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceApproachRow(
                ReadLongOrNull(reader, "Id"),
                ReadStringOrNull(reader, "Code"),
                ReadStringOrNull(reader, "Name"),
                ReadStringOrNull(reader, "Description")));
        }
        return rows;
    }

    // -----------------------------------------------------------------
    // List definitions (paginated)
    // -----------------------------------------------------------------"""),
("""        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapDetailRow(reader) : null;
    }""",
"""        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        var detail = MapDetailRow(reader);

        // 560: second result set -- the current version's Applicable Frameworks
        // (absent before 560 is run: the list stays empty).
        var frameworks = new List<OrgAssuranceDefinitionFrameworkRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                frameworks.Add(new OrgAssuranceDefinitionFrameworkRow(
                    ReadLongOrNull(reader, "DefinitionFrameworkId"),
                    ReadLongOrNull(reader, "ReleaseId"),
                    reader["FrameworkName"]?.ToString() ?? "",
                    ReadIntOrNull(reader, "DisplayOrder") ?? 0));
        }
        return detail with { ApplicableFrameworks = frameworks };
    }"""),
("""            AddParam(command, "@assurance_category_name", DbType.String, (object?)request.AssuranceCategoryName ?? DBNull.Value, 200);
            AddParam(command, "@actor",                   DbType.String, (object?)request.Actor ?? (object)"system", 100);
""",
"""            AddParam(command, "@assurance_category_name", DbType.String, (object?)request.AssuranceCategoryName ?? DBNull.Value, 200);
            // 560: Assurance Approach, Audit Mandate, Applicable Frameworks (JSON; null = unchanged).
            AddParam(command, "@assurance_approach_id",   DbType.Int64,  (object?)request.AssuranceApproachId ?? DBNull.Value);
            AddParam(command, "@audit_mandate",           DbType.String, (object?)request.AuditMandate ?? DBNull.Value, -1);
            AddParam(command, "@applicable_frameworks_json", DbType.String,
                request.ApplicableFrameworks is null
                    ? DBNull.Value
                    : JsonSerializer.Serialize(request.ApplicableFrameworks
                        .Where(f => !string.IsNullOrWhiteSpace(f.Name))
                        .Select(f => new { releaseId = f.ReleaseId, name = f.Name!.Trim() })), -1);
            AddParam(command, "@actor",                   DbType.String, (object?)request.Actor ?? (object)"system", 100);
"""),
("""        ReadStringOrNull(r, "AssuranceCategoryName"),
        ReadStringOrNull(r, "SubmittedBy"), ReadDateTimeOrNull(r, "SubmittedDt"),
        ReadStringOrNull(r, "ApprovedBy"),  ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadStringOrNull(r, "ActivatedBy"), ReadDateTimeOrNull(r, "ActivatedDt"),
        ReadStringOrNull(r, "RetiredBy"),   ReadDateTimeOrNull(r, "RetiredDt"),
        ReadStringOrNull(r, "EnteredBy"),   ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),   ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceDefinitionHistoryRow""",
"""        ReadStringOrNull(r, "AssuranceCategoryName"),
        // 560 -- tolerant: the columns exist only once 560 is run.
        HasColumn(r, "AssuranceApproachId")   ? ReadLongOrNull(r, "AssuranceApproachId")     : null,
        HasColumn(r, "AssuranceApproachCode") ? ReadStringOrNull(r, "AssuranceApproachCode") : null,
        HasColumn(r, "AssuranceApproachName") ? ReadStringOrNull(r, "AssuranceApproachName") : null,
        HasColumn(r, "AuditMandate")          ? ReadStringOrNull(r, "AuditMandate")          : null,
        ReadStringOrNull(r, "SubmittedBy"), ReadDateTimeOrNull(r, "SubmittedDt"),
        ReadStringOrNull(r, "ApprovedBy"),  ReadDateTimeOrNull(r, "ApprovedDt"),
        ReadStringOrNull(r, "ActivatedBy"), ReadDateTimeOrNull(r, "ActivatedDt"),
        ReadStringOrNull(r, "RetiredBy"),   ReadDateTimeOrNull(r, "RetiredDt"),
        ReadStringOrNull(r, "EnteredBy"),   ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),   ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceDefinitionHistoryRow"""),
("""        53612 => "CONFIGURATION_INCOMPLETE",   // 537: submit before the configuration is complete
""",
"""        53612 => "CONFIGURATION_INCOMPLETE",   // 537: submit before the configuration is complete
        53613 => "APPROACH_NOT_FOUND",         // 560: Assurance Approach missing or inactive
        53614 => "FRAMEWORKS_INVALID",         // 560: Applicable Frameworks list not valid JSON
"""),
])

C = 'src/PracticeManagement.Api/Controllers/OrgAssuranceDefinitionController.cs'
patch(C, [
("""    // ================================================================
    // List definitions
    // ================================================================""",
"""    // ================================================================
    // 560: Assurance Approaches (dropdown feed)
    // ================================================================
    [HttpGet("approaches")]
    public async Task<IActionResult> ListApproaches(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListApproachesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListApproaches failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // List definitions
    // ================================================================"""),
])
