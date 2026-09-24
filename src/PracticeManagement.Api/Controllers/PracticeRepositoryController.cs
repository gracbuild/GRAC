using System.Security.Cryptography;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;
using PracticeManagement.Web.Security; // PermissionAreaMap — linked source file, shared with the Web tier

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice-management")]
public sealed class PracticeRepositoryController(
    IPracticeRepositoryService service,
    IPracticeAuthenticationService authenticationService,
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
        "repository-subscriptions", "subscription-owner", "repository-import", "organization-controls", "release-statements", "statement-applicability", "custom-release", "custom-release-statements", "custom-release-source-structure", "custom-statement", "custom-statement-classification", "organization-requirements",
        // Source Statement mapping picker on the Add/Edit Practice form
        // (Organization Requirements screen, change request 2026-09): read
        // side for the practice's currently-mapped OrgStatementIds. The
        // save side reuses "organization-requirements" itself -- the
        // picker's selection is submitted as part of that same save
        // payload (mappedOrgStatementIds), not as its own manage entity.
        "practice-statement-mappings",
        // Bulk applicability. Both resolve, through PermissionAreaMap, to the
        // same area as the single-record save they loop, so a caller who cannot
        // mark one record cannot mark many.
        "statement-applicability-bulk", "requirement-applicability-bulk",
        "control-applicability", "requirement-applicability", "practices", "practice-instances", "practice-operationalization", "practice-dependency-resolutions",
        "resolve",
        "workbench-all", "workbench-applications", "workbench-tools", "workbench-vendors", "workbench-assets", "workbench-teams", "workbench-committees", "workbench-processes", "workbench-locations",
        "dependencies", "dependency-options", "evidence-configurations", "evidence-obligations", "evidence-obligations-typed", "evidence-alignments", "assurance-attributes", "vendor-attributes",
        "risk-attributes", "audit-attributes", "task-attributes", "resilience-attributes",
        "future-triggers", "repository-subscription-tree", "subscribed-frameworks", "dashboard-summary", "applicability-recommendations", "lookups", "asset-taxonomy", "connection-types", "implementation-status-id", "owners", "user-ownership", "audit-trace",
        // Location's Time Zone dropdown (change request 2026-09-20, migration
        // 361). Read-only lookup: standardized IANA time zones referenced
        // from GRAC_New.time_zone_master (managed in ControlManagement, not
        // here). Same shim pattern as asset-taxonomy / connection-types.
        "time-zones",
        // Team Members tree on the Add/Edit Team form (change request
        // 2026-09-20, migration 362). "team-department-employees" is the
        // read-only Department->Employee tree feed; "team-members" is the
        // currently-selected-members feed used to pre-check the tree on
        // Edit and render the read-only list on View. Both are query-only
        // (routed through secure/query's "VIEW" gate) -- saving selections
        // rides inside the existing "teams" manage payload (memberIds).
        // This whitelist gate runs before ResolveProcedureAsync/permission
        // checks, so omitting an entity type here fails every request for
        // it with 400 "Unsupported practice area." regardless of shim or
        // permission wiring being correct.
        "team-department-employees", "team-members",
        // Committee Members + Committee Designation Master (migration
        // 370). "committee-members" is the currently-selected-members
        // feed used to pre-populate the member list on Edit and render
        // the read-only grid on View, same shape as team-members above.
        // "committee-designations" is both a read-only lookup (system +
        // this organization's own custom designations, for the Add
        // Member row's Designation picker) and a write path (the inline
        // "Add Designation" quick-create) -- saving Committee Member
        // selections themselves rides inside the existing "committees"
        // manage payload (members), same as teams' memberIds.
        "committee-members", "committee-designations",
        "assurance-dashboard", "assurance-generation", "assurance-activities", "assurance-execution", "evidence-assurance", "dependency-assurance",
        "assurance-results", "assurance-findings", "assurance-signals", "assurance-trends", "practice-health", "audit-intelligence", "risk-intelligence",
        "assurance-schedule-rules", "assurance-schedule-overrides", "assurance-calendar-config", "assurance-calendar-events",
        "menu-master",
        // Pre-session auth. Reached with a short-lived PM_LOGIN bootstrap token
        // that carries NO entity permissions, so it is inert on every data path
        // above (Manage/Query enforce IsAllowed, which is false for PM_LOGIN).
        "authenticate", "set-password", "resolve-identity"
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

    // =================================================================
    // Pre-session authentication. Sign-in used to run inside the Web tier
    // against a direct SQL connection; the database is now reached only
    // through the API, so the Web tier calls these two endpoints instead.
    //
    // Both reuse ExecuteAsync, so they inherit its token validation, envelope
    // decryption, freshness and nonce-replay checks unchanged. requiredAction
    // is null — authenticating is the step BEFORE any entity permission
    // exists — but the caller still needs a validly-signed token, which the
    // Web tier mints with the locked-down PM_LOGIN role. The credentials ride
    // in the encrypted request Data, never in the URL or a log.
    // =================================================================
    [HttpPost("secure/authenticate")]
    public Task<IActionResult> Authenticate([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, null, async (request, _) =>
        {
            var loginId = JsonString(request.Data, "loginId");
            var password = JsonString(request.Data, "password");
            if (string.IsNullOrWhiteSpace(loginId) || string.IsNullOrWhiteSpace(password))
                return new PracticeRepositoryResult(false, "User ID/email and password are required.");

            var user = await authenticationService.AuthenticateAsync(loginId, password, cancellationToken);
            // Uniform message on failure — the specific reason is logged inside
            // the service, not returned, to avoid a user-enumeration oracle.
            return user is null
                ? new PracticeRepositoryResult(false, "Invalid user ID/email or password.")
                : new PracticeRepositoryResult(true, "Authenticated.", user);
        });

    // Password-free identity lookup for the bootstrap (ReviewLogin) sign-in,
    // which is verified against configuration and so arrives with no
    // employee_id -- leaving approve, reject and every other actor stamp to
    // fail. Returns identity only: no permissions, no data scope, no token.
    // It is NOT an authentication path; the caller has already authenticated
    // by other means and passes a CONFIGURED login id, never visitor input.
    [HttpPost("secure/resolve-identity")]
    public Task<IActionResult> ResolveIdentity([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, null, async (request, _) =>
        {
            var loginId = JsonString(request.Data, "loginId");
            if (string.IsNullOrWhiteSpace(loginId))
                return new PracticeRepositoryResult(false, "A login id is required.");

            var identity = await authenticationService.ResolveIdentityAsync(loginId, cancellationToken);
            return identity is null
                ? new PracticeRepositoryResult(false, "No active employee matched.")
                : new PracticeRepositoryResult(true, "Resolved.", identity);
        });

    [HttpPost("secure/set-password")]
    public Task<IActionResult> SetPassword([FromBody] EncryptedRequest envelope, CancellationToken cancellationToken) =>
        ExecuteAsync(envelope, null, async (request, _) =>
        {
            var employeeId = JsonLong(request.Data, "employeeId");
            var newPassword = JsonString(request.Data, "newPassword");
            if (employeeId is null or <= 0 || string.IsNullOrWhiteSpace(newPassword))
                return new PracticeRepositoryResult(false, "An employee and a new password are required.");

            var changed = await authenticationService.SetPasswordAsync(employeeId.Value, newPassword, cancellationToken);
            return changed
                ? new PracticeRepositoryResult(true, "Password changed.")
                : new PracticeRepositoryResult(false, "The password could not be changed.");
        });

    private static string? JsonString(JsonElement data, string property) =>
        data.ValueKind == JsonValueKind.Object && data.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long? JsonLong(JsonElement data, string property)
    {
        if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty(property, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetInt64(out var number) => number,
            JsonValueKind.String when long.TryParse(value.GetString(), out var number) => number,
            _ => null
        };
    }

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
            // The area, not the raw entity type. A helper entity type such
            // as release-statements or custom-release has no menu_master row
            // and therefore no permission any role can hold; it is governed
            // by the screen it renders inside. PermissionAreaMap is the same
            // source file the Web gateway uses (linked in the csproj), so the
            // two tiers cannot drift — testing the raw entity type here is
            // what produced "HTTP 403 ... for entity [release-statements]"
            // against callers who held organization-controls:VIEW.
            var permissionArea = PermissionAreaMap.For(request.EntityType);
            if (requiredAction is not null && !permissionPolicy.IsAllowed(principal.Roles, permissionArea, requiredAction))
            {
                logger.LogWarning(
                    "PracticeManagement 403: entity [{EntityType}] resolved to area [{Area}], action {Action}, not held by roles [{Roles}] {CorrelationId}",
                    request.EntityType, permissionArea, requiredAction, string.Join(',', principal.Roles), correlationId);
                return StatusCode(StatusCodes.Status403Forbidden,
                    crypto.EncryptResponse("FAIL", JsonSerializer.Serialize(new PracticeRepositoryResult(false,
                        $"You do not have permission to {requiredAction.ToLowerInvariant()} {permissionArea}.")), token));
            }

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

    // Was a hand-copied mirror of the gateway's PermissionArea, and it
    // had already fallen behind — assurance-calendar-events was never
    // added to it, and secure/query did not call it at all. Both tiers
    // now resolve through the one linked source file so a new mapping is
    // added in a single place.
    private static string ApiPermissionArea(string entityType) => PermissionAreaMap.For(entityType);

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
