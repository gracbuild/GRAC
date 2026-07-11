using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice-management-gateway")]
[Route("OrganizationManagement/practice-management-gateway")]
public sealed class PracticeManagementGatewayController(
    SecurePracticeClient client,
    PermissionPolicy permissionPolicy,
    NavigationContextProtector navigationContextProtector,
    IConfiguration configuration,
    PasswordHasher passwordHasher,
    ILogger<PracticeManagementGatewayController> logger) : ControllerBase
{
    [HttpGet("diagnostics/config")]
    public IActionResult ConfigDiagnostics()
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment()) return NotFound();
        return Ok(new
        {
            success = true,
            apiBaseUrl = configuration["ApiBaseUrl"] ?? "http://localhost:5045",
            resolvedApiEndpointBaseUrl = client.ApiEndpointBaseUrl()
        });
    }

    [HttpGet("{entityType}")]
    public async Task<IActionResult> Query(string entityType, [FromQuery] int? id, [FromQuery] string search = "",
        [FromQuery] string status = "", [FromQuery] int? organizationId = null, [FromQuery] int? practiceId = null,
        [FromQuery] int? practiceInstanceId = null, [FromQuery] int? organizationControlId = null, [FromQuery] int? organizationRequirementId = null, [FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 25,
        [FromQuery] string owner = "", [FromQuery] string criticality = "", [FromQuery] string originType = "",
        [FromQuery] string dateFrom = "", [FromQuery] string dateTo = "", [FromQuery] string code = "",
        CancellationToken cancellationToken = default)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW")) return Forbid();
        if (string.IsNullOrWhiteSpace(code) && (id.HasValue || organizationId.HasValue || practiceId.HasValue || practiceInstanceId.HasValue || organizationControlId.HasValue || organizationRequirementId.HasValue))
            return BadRequest(new { success = false, message = "Use encrypted navigation context for internal identifiers." });
        try { ApplyNavigationContext(Token(), entityType, code, ref organizationId, ref practiceId, ref practiceInstanceId, ref organizationControlId, ref organizationRequirementId); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        var data = AddOrganizationAccessContext(JsonSerializer.SerializeToElement(new
        {
            organizationId,
            practiceId,
            practiceInstanceId,
            organizationControlId,
            organizationRequirementId,
            pageNumber,
            pageSize,
            owner,
            criticality,
            originType,
            dateFrom,
            dateTo
        }));
        if (!ValidateRequestedOrganization(entityType, data, out var accessMessage))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = accessMessage });

        return await InvokeAsync(() => client.QueryAsync(Token(), new SecureRepositoryRequest
        {
            EntityType = entityType,
            Id = id,
            Search = search,
            Status = status,
            OrganizationId = organizationId,
            PracticeId = practiceId,
            PracticeInstanceId = practiceInstanceId,
            Data = data
        }, cancellationToken));
    }

    [HttpPost("{entityType}/query")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> QueryWithPayload(string entityType, [FromBody] BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW")) return Forbid();
        JsonElement data;
        try { data = NormalizeQueryPayload(Token(), entityType, command); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        data = AddOrganizationAccessContext(data);
        if (!ValidateRequestedOrganization(entityType, data, out var accessMessage))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = accessMessage });
        return await InvokeAsync(() => client.QueryAsync(Token(), new SecureRepositoryRequest
        {
            EntityType = entityType,
            Id = command.Id,
            Search = command.Search,
            Status = command.Status,
            OrganizationId = TryJsonInt(data, "organizationId"),
            PracticeId = TryJsonInt(data, "practiceId"),
            PracticeInstanceId = TryJsonInt(data, "practiceInstanceId"),
            Data = data
        }, cancellationToken));
    }

    [HttpPost("{entityType}/diagnostics/query-payload")]
    [ValidateAntiForgeryToken]
    public IActionResult QueryPayloadDiagnostics(string entityType, [FromBody] BrowserCommand command)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!HttpContext.RequestServices.GetRequiredService<IWebHostEnvironment>().IsDevelopment()) return NotFound();
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW")) return Forbid();
        JsonElement data;
        try { data = NormalizeQueryPayload(Token(), entityType, command); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        return Ok(new
        {
            success = true,
            entityType,
            organizationId = TryJsonInt(data, "organizationId"),
            practiceId = TryJsonInt(data, "practiceId"),
            practiceInstanceId = TryJsonInt(data, "practiceInstanceId"),
            normalizedPayload = JsonSerializer.Deserialize<object>(data.GetRawText())
        });
    }

    [HttpPost("navigation-code")]
    [ValidateAntiForgeryToken]
    public IActionResult NavigationCode([FromBody] NavigationCodeRequest request)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!IsAllowedNavigation(request, Roles())) return Forbid();
        var code = navigationContextProtector.Protect(Token(), new NavigationContext
        {
            SourceArea = request.SourceArea,
            TargetArea = request.TargetArea,
            FilterType = request.FilterType,
            FilterId = request.FilterId,
            OrganizationId = request.OrganizationId,
            ReleaseId = request.ReleaseId,
            OrganizationControlId = request.OrganizationControlId,
            OrganizationRequirementId = request.OrganizationRequirementId,
            DisplayStatus = request.DisplayStatus,
            DisplayCode = request.DisplayCode,
            DisplayName = request.DisplayName
        });
        return Ok(new { success = true, code });
    }

    [HttpGet("navigation-context")]
    public IActionResult NavigationContext([FromQuery] string code, [FromQuery] string targetArea)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        NavigationContext? context;
        try { context = ResolveNavigationContext(Token(), code, targetArea); }
        catch (CryptographicException) { return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." }); }
        if (context is null) return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." });
        if (!permissionPolicy.IsAllowed(Roles(), context.TargetArea, "VIEW")) return Forbid();
        return Ok(new { success = true, filterType = context.FilterType, filterId = context.FilterId, organizationId = context.OrganizationId, releaseId = context.ReleaseId, organizationControlId = context.OrganizationControlId, organizationRequirementId = context.OrganizationRequirementId, displayCode = context.DisplayCode, displayName = context.DisplayName, displayStatus = context.DisplayStatus });
    }

    [HttpPost("{entityType}")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string entityType, [FromBody] BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        var action = command.Id.GetValueOrDefault() > 0 ? "EDIT" : "ADD";
        if (!CanSaveEntity(entityType, action)) return Forbid();
        JsonElement data;
        try
        {
            data = command.Data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
                ? JsonSerializer.SerializeToElement(new { })
                : command.Data;
            data = ApplyNavigationContext(Token(), entityType, command.ContextCode, data);
            data = HashSensitivePayloadFields(entityType, data);
            data = AddOrganizationAccessContext(data);
            if (!ValidateRequestedOrganization(entityType, data, out var accessMessage))
                return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = accessMessage });
        }
        catch (CryptographicException)
        {
            return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." });
        }
        return await InvokeAsync(() => client.ManageAsync(Token(), new SecureRepositoryRequest
        {
            EntityType = entityType,
            Id = command.Id,
            Action = "SAVE",
            OrganizationId = TryJsonInt(data, "organizationId"),
            PracticeId = TryJsonInt(data, "practiceId"),
            PracticeInstanceId = TryJsonInt(data, "practiceInstanceId"),
            Data = data
        }, cancellationToken));
    }

    [HttpPost("{entityType}/retire")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> RetireWithPayload(string entityType, [FromBody] BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "DELETE")) return Forbid();
        return await InvokeAsync(() => client.ManageAsync(Token(), new SecureRepositoryRequest
        {
            EntityType = entityType,
            Id = command.Id,
            Action = "RETIRE",
            Data = JsonSerializer.SerializeToElement(new { })
        }, cancellationToken));
    }

    [HttpPost("{entityType}/{id:int}/retire")]
    [ValidateAntiForgeryToken]
    public IActionResult Retire(string entityType, int id)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        return BadRequest(new { success = false, message = "Use POST body commands for internal identifiers. Plain ID URL actions are not allowed." });
    }

    private async Task<IActionResult> InvokeAsync(Func<Task<string>> action)
    {
        try { return Content(await action(), "application/json"); }
        catch (PracticeApiException ex)
        {
            logger.LogError(ex, "PracticeManagement gateway API call failed {CorrelationId}", HttpContext.TraceIdentifier);
            return StatusCode(StatusCodes.Status502BadGateway, new { success = false, message = ex.Message });
        }
        catch (Exception ex)
        {
            var correlationId = HttpContext.TraceIdentifier;
            logger.LogError(ex, "PracticeManagement gateway request failed {CorrelationId}", correlationId);
            return StatusCode(StatusCodes.Status502BadGateway,
                new { success = false, message = $"The practice service is currently unavailable. Gateway reference: {correlationId}" });
        }
    }

    private string Token()
    {
        var token = HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey);
        if (!string.IsNullOrWhiteSpace(token)) return token;

        throw new UnauthorizedAccessException("Practice Management session has expired.");
    }

    private bool IsSignedIn() => HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is not null
        && HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey) is not null;

    private string[] Roles() => (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries);

    private bool IsSystemAdmin() => Roles().Any(role => role.Equals("PM_ADMIN", StringComparison.OrdinalIgnoreCase));

    private int[] AllowedOrganizationIds()
    {
        var stored = HttpContext.Session.GetString(PracticeSessionIdentity.AllowedOrganizationIdsKey)
            ?? HttpContext.Session.GetString(PracticeSessionIdentity.OrganizationIdKey)
            ?? "";
        return stored.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(value => int.TryParse(value, out var id) ? id : 0)
            .Where(id => id > 0)
            .Distinct()
            .ToArray();
    }

    private JsonElement AddOrganizationAccessContext(JsonElement data)
    {
        var values = data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
            ? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
            : JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

        values["allowedOrganizationIds"] = AllowedOrganizationIds();
        return JsonSerializer.SerializeToElement(values);
    }

    private bool ValidateRequestedOrganization(string entityType, JsonElement data, out string message)
    {
        message = "";
        if (IsSystemAdmin()) return true;
        var requestedOrganizationId = TryJsonInt(data, "organizationId");
        if (!requestedOrganizationId.HasValue || !OrganizationScopedEntityTypes.Contains(entityType)) return true;
        if (AllowedOrganizationIds().Contains(requestedOrganizationId.Value)) return true;
        message = "You do not have access to the selected organization.";
        logger.LogWarning("PracticeManagement blocked organization access. Entity={EntityType} User={User} RequestedOrganizationId={OrganizationId}",
            entityType, HttpContext.Session.GetString(PracticeSessionIdentity.UserKey), requestedOrganizationId);
        return false;
    }

    private static readonly HashSet<string> OrganizationScopedEntityTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "organization-metadata", "repository-subscriptions", "locations", "departments", "business-functions", "teams", "committees",
        "roles", "role-menu-permissions", "users", "dependency-applications", "dependency-tools", "dependency-vendors", "dependency-assets",
        "dependency-processes", "user-assignments", "user-role-assignments", "owner-mappings", "organization-controls", "control-applicability",
        "organization-requirements", "practices", "practice-instances", "practice-operationalization", "resolve", "dependencies", "evidence-configurations",
        "subscribed-frameworks", "release-statements", "statement-applicability", "custom-release", "custom-release-statements", "custom-release-source-structure", "custom-statement", "dashboard-summary",
        "assurance-schedule-rules", "assurance-schedule-overrides", "assurance-calendar-config", "assurance-calendar-events"
    };

    private static string PermissionArea(string entityType) =>
        entityType.Equals("release-statements", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("statement-applicability", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release-statements", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-statement", StringComparison.OrdinalIgnoreCase)
            ? "organization-controls"
            : entityType;

    private bool CanSaveEntity(string entityType, string action)
    {
        var area = PermissionArea(entityType);
        if (entityType.Equals("statement-applicability", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-release", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-statement", StringComparison.OrdinalIgnoreCase))
            return permissionPolicy.IsAllowed(Roles(), area, "ADD") || permissionPolicy.IsAllowed(Roles(), area, "EDIT");
        return permissionPolicy.IsAllowed(Roles(), area, action);
    }

    private JsonElement HashSensitivePayloadFields(string entityType, JsonElement data)
    {
        if (!entityType.Equals("users", StringComparison.OrdinalIgnoreCase)) return data;
        if (!data.TryGetProperty("password", out var passwordElement) || passwordElement.ValueKind != JsonValueKind.String) return data;
        var password = passwordElement.GetString();
        if (string.IsNullOrWhiteSpace(password)) return data;

        var node = JsonNode.Parse(data.GetRawText()) as JsonObject ?? [];
        node["passwordHash"] = passwordHasher.Hash(password);
        node.Remove("password");
        return JsonSerializer.SerializeToElement(node);
    }

    private NavigationContext? ResolveNavigationContext(string token, string code, string targetArea)
    {
        if (string.IsNullOrWhiteSpace(code)) return null;
        var context = navigationContextProtector.Unprotect(token, code);
        if (!context.TargetArea.Equals(targetArea, StringComparison.OrdinalIgnoreCase))
            throw new CryptographicException("Navigation context target does not match the requested area.");
        return context;
    }

    private void ApplyNavigationContext(string token, string entityType, string code, ref int? organizationId, ref int? practiceId, ref int? practiceInstanceId, ref int? organizationControlId, ref int? organizationRequirementId)
    {
        var context = ResolveNavigationContext(token, code, entityType);
        if (context is null) return;
        if (context.OrganizationId.HasValue) organizationId = context.OrganizationId;
        if (context.OrganizationControlId.HasValue && !context.FilterType.Equals("FrameworkStatement", StringComparison.OrdinalIgnoreCase))
            organizationControlId = context.OrganizationControlId;
        if (context.OrganizationRequirementId.HasValue) organizationRequirementId = context.OrganizationRequirementId;
        if (context.FilterType.Equals("Organization", StringComparison.OrdinalIgnoreCase)) organizationId = context.FilterId;
        else if (context.FilterType.Equals("OrganizationControl", StringComparison.OrdinalIgnoreCase)) organizationControlId = context.FilterId;
        else if (context.FilterType.Equals("OrganizationRequirement", StringComparison.OrdinalIgnoreCase)) organizationRequirementId = context.FilterId;
        else if (context.FilterType.Equals("Practice", StringComparison.OrdinalIgnoreCase)) practiceId = context.FilterId;
        else if (context.FilterType.Equals("PracticeInstance", StringComparison.OrdinalIgnoreCase)) practiceInstanceId = context.FilterId;
        else if (context.FilterType.Equals("FrameworkRelease", StringComparison.OrdinalIgnoreCase)) { }
        else if (context.FilterType.Equals("FrameworkStatement", StringComparison.OrdinalIgnoreCase)) { }
        else throw new CryptographicException("Invalid navigation context.");
    }

    private JsonElement ApplyNavigationContext(string token, string entityType, string code, JsonElement data)
    {
        var organizationId = TryJsonInt(data, "organizationId");
        var practiceId = TryJsonInt(data, "practiceId");
        var practiceInstanceId = TryJsonInt(data, "practiceInstanceId");
        var organizationControlId = TryJsonInt(data, "organizationControlId");
        var organizationRequirementId = TryJsonInt(data, "organizationRequirementId");
        ApplyNavigationContext(token, entityType, code, ref organizationId, ref practiceId, ref practiceInstanceId, ref organizationControlId, ref organizationRequirementId);

        if (string.IsNullOrWhiteSpace(code)) return data;
        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText()) ?? [];
        var context = ResolveNavigationContext(token, code, entityType);
        if (organizationId.HasValue) values["organizationId"] = organizationId.Value;
        if (context?.ReleaseId.HasValue == true) values["releaseId"] = context.ReleaseId.Value;
        if (practiceId.HasValue) values["practiceId"] = practiceId.Value;
        if (practiceInstanceId.HasValue) values["practiceInstanceId"] = practiceInstanceId.Value;
        if (organizationControlId.HasValue) values["organizationControlId"] = organizationControlId.Value;
        if (organizationRequirementId.HasValue) values["organizationRequirementId"] = organizationRequirementId.Value;
        if (context?.FilterType.Equals("FrameworkRelease", StringComparison.OrdinalIgnoreCase) == true)
            values["releaseId"] = context.FilterId;
        if (context?.FilterType.Equals("FrameworkStatement", StringComparison.OrdinalIgnoreCase) == true)
        {
            values["frameworkStatementId"] = context.FilterId;
            if (context.ReleaseId.HasValue) values["releaseId"] = context.ReleaseId.Value;
            else if (context.OrganizationControlId.HasValue) values["releaseId"] = context.OrganizationControlId.Value;
            // Statement-driven navigation: the Control concept does not apply. Remove
            // any organizationControlId that reached the payload so practices are
            // filtered only by organization + statement (via the mapping table).
            values.Remove("organizationControlId");
        }
        return JsonSerializer.SerializeToElement(values);
    }

    private JsonElement NormalizeQueryPayload(string token, string entityType, BrowserCommand command)
    {
        var data = command.Data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
            ? JsonSerializer.SerializeToElement(new { })
            : command.Data;
        data = ApplyNavigationContext(token, entityType, command.ContextCode, data);

        var values = JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText()) ?? [];
        PutIfMissing(values, "search", command.Search);
        PutIfMissing(values, "status", command.Status);
        PutIfMissing(values, "owner", command.Owner);
        PutIfMissing(values, "criticality", command.Criticality);
        PutIfMissing(values, "originType", command.OriginType);
        PutIfMissing(values, "dateFrom", command.DateFrom);
        PutIfMissing(values, "dateTo", command.DateTo);
        PutIfMissing(values, "pageNumber", command.PageNumber);
        PutIfMissing(values, "pageSize", command.PageSize);
        return JsonSerializer.SerializeToElement(values);
    }

    private static void PutIfMissing(Dictionary<string, object?> values, string key, object? value)
    {
        if (value is null || values.ContainsKey(key)) return;
        if (value is string text && string.IsNullOrWhiteSpace(text)) return;
        if (value is int number && number <= 0) return;
        values[key] = value;
    }

    private static int? TryJsonInt(JsonElement data, string propertyName)
    {
        if (!data.TryGetProperty(propertyName, out var property)) return null;
        return property.ValueKind switch
        {
            JsonValueKind.Number when property.TryGetInt32(out var value) => value,
            JsonValueKind.String when int.TryParse(property.GetString(), out var value) => value,
            _ => null
        };
    }

    private bool IsAllowedNavigation(NavigationCodeRequest request, string[] roles) =>
        request.FilterId > 0
        && permissionPolicy.IsAllowed(roles, request.SourceArea, "VIEW")
        && permissionPolicy.IsAllowed(roles, request.TargetArea, "VIEW")
        && request switch
        {
            { FilterType: "Organization", TargetArea: "organization-controls" or "control-applicability" or "organization-requirements" or "practices" or "practice-instances" or "repository-subscriptions" } => true,
            { FilterType: "OrganizationControl", TargetArea: "organization-requirements" } => true,
            { FilterType: "FrameworkRelease", TargetArea: "organization-requirements" } => true,
            { FilterType: "FrameworkStatement", TargetArea: "organization-requirements" } => true,
            { FilterType: "OrganizationRequirement", TargetArea: "practices" or "practice-instances" } => true,
            { FilterType: "Practice", TargetArea: "practice-instances" } => true,
            { FilterType: "PracticeInstance", TargetArea: "dependencies" or "evidence-configurations" or "assurance-attributes" or "vendor-attributes" or "risk-attributes" or "audit-attributes" or "task-attributes" or "resilience-attributes" } => true,
            _ => false
        };

    public sealed class BrowserCommand
    {
        public int? Id { get; set; }
        public string Search { get; set; } = "";
        public string Status { get; set; } = "";
        public string Owner { get; set; } = "";
        public string Criticality { get; set; } = "";
        public string OriginType { get; set; } = "";
        public string DateFrom { get; set; } = "";
        public string DateTo { get; set; } = "";
        public int? PageNumber { get; set; }
        public int? PageSize { get; set; }
        public string ContextCode { get; set; } = "";
        public JsonElement Data { get; set; }
    }

    public sealed class NavigationCodeRequest
    {
        public string SourceArea { get; set; } = "";
        public string TargetArea { get; set; } = "";
        public string FilterType { get; set; } = "";
        public int FilterId { get; set; }
        public int? OrganizationId { get; set; }
        public int? ReleaseId { get; set; }
        public int? OrganizationControlId { get; set; }
        public int? OrganizationRequirementId { get; set; }
        public string DisplayStatus { get; set; } = "";
        public string DisplayCode { get; set; } = "";
        public string DisplayName { get; set; } = "";
    }
}
