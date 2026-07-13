using System.Security.Cryptography;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice-management")]
public sealed class PracticeRepositoryController(
    IPracticeRepositoryService service,
    SignedAccessTokenService tokenService,
    EnvelopeCrypto crypto,
    PermissionPolicy permissionPolicy,
    IMemoryCache cache,
    IConfiguration configuration,
    IWebHostEnvironment environment,
    ILogger<PracticeRepositoryController> logger) : ControllerBase
{
    private static readonly HashSet<string> Supported = new(StringComparer.OrdinalIgnoreCase)
    {
        "organizations", "organization-setup", "organization-metadata", "organization-admin-provision", "organization-admin-mark-emailed", "locations", "departments", "business-functions", "teams", "committees", "users",
        "roles", "role-menu-permissions", "user-role-assignments",
        "dependency-applications", "dependency-tools", "dependency-vendors", "dependency-assets", "dependency-processes",
        "user-assignments", "owner-mappings", "applicability-discovery", "applicability-results",
        "repository-subscriptions", "subscription-owner", "repository-import", "organization-controls", "release-statements", "statement-applicability", "custom-release", "custom-release-statements", "custom-release-source-structure", "custom-statement", "organization-requirements",
        "control-applicability", "requirement-applicability", "practices", "practice-instances", "practice-operationalization", "practice-dependency-resolutions",
        "resolve",
        "workbench-all", "workbench-applications", "workbench-tools", "workbench-vendors", "workbench-assets", "workbench-teams", "workbench-committees", "workbench-processes", "workbench-locations",
        "dependencies", "dependency-options", "evidence-configurations", "evidence-obligations", "evidence-alignments", "assurance-attributes", "vendor-attributes",
        "risk-attributes", "audit-attributes", "task-attributes", "resilience-attributes",
        "future-triggers", "repository-subscription-tree", "subscribed-frameworks", "dashboard-summary", "applicability-recommendations", "lookups", "audit-trace",
        "assurance-dashboard", "assurance-generation", "assurance-activities", "assurance-execution", "evidence-assurance", "dependency-assurance",
        "assurance-results", "assurance-findings", "assurance-signals", "assurance-trends", "practice-health", "audit-intelligence", "risk-intelligence",
        "assurance-schedule-rules", "assurance-schedule-overrides", "assurance-calendar-config", "assurance-calendar-events",
        "menu-master"
    };

    [HttpGet]
    public IActionResult Index() => Ok(new { status = "ready", module = "PracticeManagement" });

    [HttpGet("diagnostics/database")]
    public async Task<IActionResult> DatabaseDiagnostics([FromQuery] int organizationId = 2, CancellationToken cancellationToken = default)
    {
        if (!environment.IsDevelopment()) return NotFound();
        var result = await service.DiagnosticsAsync(organizationId, cancellationToken);
        return Ok(result);
    }

    [HttpGet("diagnostics/last-secure-query")]
    public IActionResult LastSecureQueryDiagnostics()
    {
        if (!environment.IsDevelopment()) return NotFound();
        return Ok(cache.TryGetValue("pm-diagnostics:last-secure-query", out object? value)
            ? value
            : new { success = false, message = "No secure query has been captured yet." });
    }

    [HttpPost("secure/query")]
    public Task<IActionResult> Query([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, "VIEW", async (request, principal) =>
        {
            var data = NormalizeQueryData(request);
            CaptureNormalizedQueryDiagnostic(request, data);
            return await service.QueryAsync(new PracticeRepositoryQuery
            {
                EntityType = request.EntityType,
                Id = request.Id,
                Search = request.Search ?? "",
                Status = request.Status ?? "",
                EnteredBy = principal.Subject,
                Data = AddServerSecurityContext(data, principal)
            }, cancellationToken);
        });

    [HttpPost("secure/manage")]
    public Task<IActionResult> Manage([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, null, async (request, principal) =>
        {
            var action = request.Action.Equals("RETIRE", StringComparison.OrdinalIgnoreCase)
                ? "DELETE"
                : request.Id.GetValueOrDefault() > 0 ? "EDIT" : "ADD";
            // subscription-owner and related derived entity types are
            // gated by the same permission as organization-controls
            // (Source Statements). Without this mapping, PM_ORG_ADMIN
            // would fall back to the entity type's raw permission key,
            // which isn't in the roles config.
            var permissionKey = ApiPermissionArea(request.EntityType);
            if (!permissionPolicy.IsAllowed(principal.Roles, permissionKey, action))
                return new PracticeRepositoryResult(false, "You do not have Update Owner permission for this release.");

            return await service.ManageAsync(new PracticeRepositoryCommand
            {
                EntityType = request.EntityType,
                Action = request.Action,
                Id = request.Id,
                EnteredBy = principal.Subject,
                Data = AddServerSecurityContext(request.Data.ValueKind == JsonValueKind.Undefined
                    ? JsonSerializer.SerializeToElement(new { })
                    : request.Data, principal)
            }, cancellationToken);
        });

    private async Task<IActionResult> ExecuteAsync(EncryptedRequest envelope, string? requiredAction,
        Func<SecureRepositoryRequest, AccessPrincipal, Task<PracticeRepositoryResult>> execute)
    {
        var correlationId = HttpContext.TraceIdentifier;
        try
        {
            var token = ReadAuthorizationToken();
            if (!tokenService.TryValidate(token, out var principal))
                return Unauthorized(new { message = "Authorization failed.", correlationId });

            var request = JsonSerializer.Deserialize<SecureRepositoryRequest>(crypto.DecryptRequest(envelope, token),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            if (request is null || !Supported.Contains(request.EntityType))
            {
                logger.LogError("PracticeManagement 400: Unsupported entity type [{EntityType}]. Request is null: {IsNull}. Supported count: {SupportedCount} {CorrelationId}",
                    request?.EntityType ?? "(null)", request is null, Supported.Count, correlationId);
                return BadRequest(crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new PracticeRepositoryResult(false, "Unsupported practice area.")), token));
            }
            CaptureSecureQueryDiagnostic(request);
            if (!IsFresh(request) || !RegisterNonce(request.Nonce))
            {
                logger.LogError("PracticeManagement 400: Request not fresh or nonce replay for [{EntityType}]. TimestampUtc={TimestampUtc} ServerUtcNow={ServerUtcNow} Nonce={Nonce} IsFresh={IsFresh} {CorrelationId}",
                    request.EntityType, request.TimestampUtc, DateTimeOffset.UtcNow, request.Nonce?[..Math.Min(request.Nonce?.Length ?? 0, 16)], IsFresh(request), correlationId);
                return BadRequest(crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new PracticeRepositoryResult(false, "The request is invalid or has expired.")), token));
            }
            if (requiredAction is not null && !permissionPolicy.IsAllowed(principal.Roles, request.EntityType, requiredAction))
                return StatusCode(StatusCodes.Status403Forbidden,
                    crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new PracticeRepositoryResult(false, "You do not have permission to access this area.")), token));

            var result = await execute(request, principal);
            return Ok(crypto.EncryptResponse(result.Success ? "SUCCESS" : "FAIL", JsonSerializer.Serialize(result), token));
        }
        catch (CryptographicException ex)
        {
            logger.LogWarning(ex, "Rejected invalid encrypted PracticeManagement request {CorrelationId}", correlationId);
            return BadRequest(new { message = "The encrypted request is invalid.", correlationId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticeManagement request failed {CorrelationId}", correlationId);
            return StatusCode(StatusCodes.Status500InternalServerError,
                new { message = "The request could not be completed.", correlationId });
        }
    }

    private string ReadAuthorizationToken()
    {
        var authorization = Request.Headers.Authorization.ToString();
        return authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..] : authorization;
    }

    private static JsonElement NormalizeQueryData(SecureRepositoryRequest request)
    {
        var values = request.Data.ValueKind == JsonValueKind.Undefined || request.Data.ValueKind == JsonValueKind.Null
            ? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
            : JsonSerializer.Deserialize<Dictionary<string, object?>>(request.Data.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

        if (request.OrganizationId.HasValue) values["organizationId"] = request.OrganizationId.Value;
        if (request.PracticeId.HasValue) values["practiceId"] = request.PracticeId.Value;
        if (request.PracticeInstanceId.HasValue) values["practiceInstanceId"] = request.PracticeInstanceId.Value;
        return JsonSerializer.SerializeToElement(values);
    }

    private static JsonElement AddServerSecurityContext(JsonElement data, AccessPrincipal principal)
    {
        var values = data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
            ? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
            : JsonSerializer.Deserialize<Dictionary<string, object?>>(data.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

        // Rule 5 — release/statement scope enforcement needs the caller's
        // employee_id + dataScope in the _security envelope so both the
        // C# fallbacks and the SP layer can call fn_visible_releases /
        // fn_visible_statements. Values are populated by the Web-tier
        // gateway from the session identity (see
        // PracticeManagementGatewayController.AddOrganizationAccessContext).
        long? callerEmployeeId = null;
        if (values.TryGetValue("callerEmployeeId", out var employeeIdRaw))
            callerEmployeeId = ToInt64(employeeIdRaw);
        string? callerDataScope = null;
        if (values.TryGetValue("callerDataScope", out var scopeRaw))
            callerDataScope = scopeRaw?.ToString();
        string? callerRoleName = null;
        if (values.TryGetValue("callerRoleName", out var roleRaw))
            callerRoleName = roleRaw?.ToString();

        values["_security"] = new
        {
            isSystemAdmin = principal.Roles.Any(role => role.Equals("PM_ADMIN", StringComparison.OrdinalIgnoreCase)),
            subject = principal.Subject,
            employeeId = callerEmployeeId,
            dataScope = string.IsNullOrWhiteSpace(callerDataScope) ? "ORGANIZATION" : callerDataScope,
            roleName = callerRoleName ?? ""
        };
        return JsonSerializer.SerializeToElement(values);
    }

    // Mirror of the gateway's PermissionArea — release / statement /
    // subscription-owner actions all resolve to organization-controls
    // so they share the Source Statements permission line.
    private static string ApiPermissionArea(string entityType) =>
        entityType.Equals("release-statements", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("statement-applicability", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release-statements", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("custom-statement", StringComparison.OrdinalIgnoreCase)
        || entityType.Equals("subscription-owner", StringComparison.OrdinalIgnoreCase)
            ? "organization-controls"
            : entityType;

    private static long? ToInt64(object? value) => value switch
    {
        null => null,
        long l => l,
        int i => i,
        JsonElement je when je.ValueKind == JsonValueKind.Number && je.TryGetInt64(out var v) => v,
        JsonElement je when je.ValueKind == JsonValueKind.String && long.TryParse(je.GetString(), out var v) => v,
        string s when long.TryParse(s, out var v) => v,
        _ => null
    };

    private void CaptureSecureQueryDiagnostic(SecureRepositoryRequest request)
    {
        if (!environment.IsDevelopment() || !request.Action.Equals("QUERY", StringComparison.OrdinalIgnoreCase)) return;
        object? data = null;
        if (request.Data.ValueKind is not JsonValueKind.Undefined and not JsonValueKind.Null)
            data = JsonSerializer.Deserialize<object>(request.Data.GetRawText());
        cache.Set("pm-diagnostics:last-secure-query", new
        {
            success = true,
            capturedAtUtc = DateTimeOffset.UtcNow,
            request.EntityType,
            request.Id,
            request.Search,
            request.Status,
            request.OrganizationId,
            request.PracticeId,
            request.PracticeInstanceId,
            organizationControlId = TryJsonInt(request.Data, "organizationControlId"),
            data
        }, TimeSpan.FromMinutes(10));
    }

    private void CaptureNormalizedQueryDiagnostic(SecureRepositoryRequest request, JsonElement data)
    {
        if (!environment.IsDevelopment() || !request.Action.Equals("QUERY", StringComparison.OrdinalIgnoreCase)) return;
        cache.Set("pm-diagnostics:last-normalized-query", new
        {
            success = true,
            capturedAtUtc = DateTimeOffset.UtcNow,
            request.EntityType,
            request.Id,
            Search = request.Search ?? "",
            Status = request.Status ?? "",
            organizationId = TryJsonInt(data, "organizationId"),
            organizationControlId = TryJsonInt(data, "organizationControlId"),
            organizationRequirementId = TryJsonInt(data, "organizationRequirementId"),
            practiceId = TryJsonInt(data, "practiceId"),
            repositoryControlId = TryJsonInt(data, "repositoryControlId"),
            data = JsonSerializer.Deserialize<object>(data.GetRawText())
        }, TimeSpan.FromMinutes(10));
    }

    [HttpGet("diagnostics/last-normalized-query")]
    public IActionResult LastNormalizedQueryDiagnostics()
    {
        if (!environment.IsDevelopment()) return NotFound();
        return Ok(cache.TryGetValue("pm-diagnostics:last-normalized-query", out object? value)
            ? value
            : new { success = false, message = "No normalized query has been captured yet." });
    }

    [HttpGet("diagnostics/last-sql-result")]
    public IActionResult LastSqlResultDiagnostics()
    {
        if (!environment.IsDevelopment()) return NotFound();
        return Ok(PracticeRepositoryService.GetLastSqlDiagnostic()
            ?? new { success = false, message = "No SQL result has been captured yet." });
    }

    private static int? TryJsonInt(JsonElement data, string propertyName)
    {
        if (data.ValueKind != JsonValueKind.Object) return null;
        if (!data.TryGetProperty(propertyName, out var property)) return null;
        return property.ValueKind switch
        {
            JsonValueKind.Number when property.TryGetInt32(out var value) => value,
            JsonValueKind.String when int.TryParse(property.GetString(), out var value) => value,
            _ => null
        };
    }

    private bool IsFresh(SecureRepositoryRequest request)
    {
        var validity = configuration.GetValue("Security:RequestValidityMinutes", 5);
        return !string.IsNullOrWhiteSpace(request.Nonce)
            && request.Nonce.Length <= 128
            && Math.Abs((DateTimeOffset.UtcNow - request.TimestampUtc).TotalMinutes) <= validity;
    }

    private bool RegisterNonce(string nonce)
    {
        var key = $"pm-replay:{nonce}";
        if (cache.TryGetValue(key, out _)) return false;
        cache.Set(key, true, TimeSpan.FromMinutes(configuration.GetValue("Security:RequestValidityMinutes", 5)));
        return true;
    }
}
