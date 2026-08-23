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
    IPracticeEmailService emailService,
    ILogger<PracticeManagementGatewayController> logger) : ControllerBase
{
    // Rule 6 — provisioning + credential email for the auto-created
    // Organisation GRAC Admin. Called by the JS layer immediately after
    // a successful organization-setup save. The plaintext OTP is
    // generated and hashed here on the Web tier (which owns
    // PasswordHasher); only the hash reaches the API + DB.
    [HttpPost("organization-admin/provision-and-notify")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> ProvisionAndNotifyOrganizationAdmin([FromBody] OrganizationAdminProvisionRequest request, CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        if (request is null || request.OrganizationId <= 0 || string.IsNullOrWhiteSpace(request.AdminEmail))
            return BadRequest(new { success = false, message = "organizationId and adminEmail are required." });
        // Only Admins (system or org-scoped) may auto-provision another
        // org's admin; the org-scope guard still applies for non-system admins.
        if (!permissionPolicy.IsAllowed(Roles(), "organization-setup", "ADD")
            && !permissionPolicy.IsAllowed(Roles(), "users", "ADD"))
            return PermissionDenied("organization-setup or users", "ADD");
        if (!IsSystemAdmin() && !AllowedOrganizationIds().Contains(request.OrganizationId))
            return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = "You do not have access to the selected organization." });

        var oneTimePassword = GenerateOneTimePassword();
        var passwordHash = passwordHasher.Hash(oneTimePassword);
        var provisionPayload = JsonSerializer.SerializeToElement(new
        {
            organizationId = request.OrganizationId,
            adminEmail = request.AdminEmail.Trim(),
            adminName = string.IsNullOrWhiteSpace(request.AdminName) ? request.AdminEmail.Trim() : request.AdminName.Trim(),
            passwordHash
        });
        var securedPayload = AddOrganizationAccessContext(provisionPayload);

        string provisionRaw;
        try
        {
            provisionRaw = await client.ManageAsync(Token(), new SecureRepositoryRequest
            {
                EntityType = "organization-admin-provision",
                Action = "SAVE",
                OrganizationId = request.OrganizationId,
                Data = securedPayload
            }, cancellationToken);
        }
        catch (Exception ex)
        {
            var correlationId = HttpContext.TraceIdentifier;
            logger.LogError(ex, "PracticeManagement admin provisioning failed {CorrelationId}", correlationId);
            return StatusCode(StatusCodes.Status502BadGateway,
                new { success = false, message = $"Unable to provision the organisation admin. Reference: {correlationId}" });
        }

        var provisionResult = ExtractProvisionResult(provisionRaw);
        if (provisionResult is null)
        {
            logger.LogWarning("Organization admin provisioning returned no rows. Payload={Payload}", Truncate(provisionRaw, 500));
            return StatusCode(StatusCodes.Status502BadGateway,
                new { success = false, message = "The organisation admin could not be provisioned." });
        }

        // Best-effort SMTP send. Failures never abort provisioning.
        var loginUrl = configuration["Email:LoginUrl"] ?? BuildDefaultLoginUrl();
        var emailResult = await emailService.SendAdminCredentialsAsync(
            provisionResult.Email,
            request.AdminName ?? provisionResult.Email,
            request.OrganizationName ?? "",
            loginUrl,
            oneTimePassword,
            cancellationToken);

        if (emailResult.Delivered)
        {
            try
            {
                var markPayload = AddOrganizationAccessContext(JsonSerializer.SerializeToElement(new
                {
                    organizationId = request.OrganizationId,
                    employeeId = provisionResult.EmployeeId
                }));
                await client.ManageAsync(Token(), new SecureRepositoryRequest
                {
                    EntityType = "organization-admin-mark-emailed",
                    Action = "SAVE",
                    OrganizationId = request.OrganizationId,
                    Data = markPayload
                }, cancellationToken);
            }
            catch (Exception ex)
            {
                // Failing to flip the flag is non-fatal — the admin still
                // has valid credentials; the Users tab will just keep the
                // "Resend credentials" action available.
                logger.LogWarning(ex,
                    "PracticeEmailService delivered credentials but flagging email_credentials_sent failed. EmployeeId={EmployeeId} CorrelationId={CorrelationId}",
                    provisionResult.EmployeeId, emailResult.CorrelationId);
            }
        }

        return Ok(new
        {
            success = true,
            employeeId = provisionResult.EmployeeId,
            alreadyExisted = provisionResult.AlreadyExisted,
            menusGranted = provisionResult.MenusGranted,
            flagsEnabled = provisionResult.FlagsEnabled,
            credentialsEmailed = emailResult.Delivered,
            emailCorrelationId = emailResult.CorrelationId,
            emailFailureReason = emailResult.FailureReason
        });
    }

    private static string GenerateOneTimePassword()
    {
        // 14 chars of URL-safe base64 (~84 bits of entropy) is plenty for
        // a one-time password that must be changed on first sign-in.
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(10);
        return Convert.ToBase64String(bytes).Replace('+', 'A').Replace('/', 'B').TrimEnd('=');
    }

    private string BuildDefaultLoginUrl()
    {
        var scheme = Request.Scheme;
        var host = Request.Host.Value;
        var pathBase = Request.PathBase.HasValue ? Request.PathBase.Value : "";
        return $"{scheme}://{host}{pathBase}/Login";
    }

    private static string Truncate(string value, int max) =>
        string.IsNullOrEmpty(value) || value.Length <= max ? value ?? "" : value[..max];

    private static OrganizationAdminProvisionResult? ExtractProvisionResult(string apiResponse)
    {
        if (string.IsNullOrWhiteSpace(apiResponse)) return null;
        try
        {
            using var document = JsonDocument.Parse(apiResponse);
            if (!TryGetPropertyCaseInsensitive(document.RootElement, "data", out var data)) return null;
            JsonElement? firstRow = data.ValueKind switch
            {
                JsonValueKind.Array when data.GetArrayLength() > 0 => FirstRow(data[0]),
                JsonValueKind.Object => FirstRow(data),
                _ => null
            };
            if (firstRow is null) return null;
            var row = firstRow.Value;
            return new OrganizationAdminProvisionResult(
                EmployeeId: TryReadLong(row, "EmployeeId") ?? TryReadLong(row, "employeeId") ?? 0,
                RoleId: TryReadLong(row, "RoleId") ?? TryReadLong(row, "roleId") ?? 0,
                Email: TryReadString(row, "Email") ?? TryReadString(row, "email") ?? "",
                AlreadyExisted: TryReadBool(row, "AlreadyExisted") ?? TryReadBool(row, "alreadyExisted") ?? false,
                MenusGranted: TryReadLong(row, "MenusGranted") ?? TryReadLong(row, "menusGranted") ?? 0,
                FlagsEnabled: TryReadLong(row, "FlagsEnabled") ?? TryReadLong(row, "flagsEnabled") ?? 0);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static JsonElement? FirstRow(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array)
            return element.GetArrayLength() > 0 ? element[0] : null;
        return element.ValueKind == JsonValueKind.Object ? element : null;
    }

    private static bool TryGetPropertyCaseInsensitive(JsonElement element, string name, out JsonElement value)
    {
        if (element.ValueKind != JsonValueKind.Object) { value = default; return false; }
        foreach (var property in element.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        value = default;
        return false;
    }

    private static long? TryReadLong(JsonElement row, string name)
    {
        if (!TryGetPropertyCaseInsensitive(row, name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetInt64(out var num) => num,
            JsonValueKind.String when long.TryParse(value.GetString(), out var num) => num,
            _ => null
        };
    }

    private static string? TryReadString(JsonElement row, string name) =>
        TryGetPropertyCaseInsensitive(row, name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static bool? TryReadBool(JsonElement row, string name)
    {
        if (!TryGetPropertyCaseInsensitive(row, name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number when value.TryGetInt32(out var num) => num == 1,
            JsonValueKind.String => string.Equals(value.GetString(), "true", StringComparison.OrdinalIgnoreCase)
                                    || value.GetString() == "1",
            _ => null
        };
    }

    public sealed class OrganizationAdminProvisionRequest
    {
        public int OrganizationId { get; set; }
        public string AdminEmail { get; set; } = "";
        public string? AdminName { get; set; }
        public string? OrganizationName { get; set; }
    }

    // MenusGranted / FlagsEnabled come from migration 217's addition to
    // pm_create_organization_admin. They are read defensively (absent
    // columns fall back to 0) so the Web tier keeps working against a
    // database where 217 has not been applied or has been rolled back.
    private sealed record OrganizationAdminProvisionResult(
        long EmployeeId, long RoleId, string Email, bool AlreadyExisted, long MenusGranted, long FlagsEnabled);

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
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW"))
            return PermissionDenied(PermissionArea(entityType), "VIEW");
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
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW"))
            return PermissionDenied(PermissionArea(entityType), "VIEW");
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
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "VIEW"))
            return PermissionDenied(PermissionArea(entityType), "VIEW");
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
        if (!IsAllowedNavigation(request, Roles())) return PermissionDenied("the requested screen", "VIEW");
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
        if (!permissionPolicy.IsAllowed(Roles(), context.TargetArea, "VIEW"))
            return PermissionDenied(context.TargetArea, "VIEW");
        return Ok(new { success = true, filterType = context.FilterType, filterId = context.FilterId, organizationId = context.OrganizationId, releaseId = context.ReleaseId, organizationControlId = context.OrganizationControlId, organizationRequirementId = context.OrganizationRequirementId, displayCode = context.DisplayCode, displayName = context.DisplayName, displayStatus = context.DisplayStatus });
    }

    [HttpPost("{entityType}")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> Save(string entityType, [FromBody] BrowserCommand command, CancellationToken cancellationToken)
    {
        if (!IsSignedIn()) return Unauthorized(new { success = false, message = "Session expired. Please sign in again." });
        var action = command.Id.GetValueOrDefault() > 0 ? "EDIT" : "ADD";
        if (!CanSaveEntity(entityType, action)) return PermissionDenied(PermissionArea(entityType), action);
        JsonElement data;
        try
        {
            data = command.Data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
                ? JsonSerializer.SerializeToElement(new { })
                : command.Data;
            data = ApplyNavigationContext(Token(), entityType, command.ContextCode, data);
            data = HashSensitivePayloadFields(entityType, data, isCreate: action == "ADD");
            data = AddOrganizationAccessContext(data);
            if (!ValidateRequestedOrganization(entityType, data, out var accessMessage))
                return StatusCode(StatusCodes.Status403Forbidden, new { success = false, message = accessMessage });
        }
        catch (CryptographicException)
        {
            return BadRequest(new { success = false, message = "The navigation context is invalid or has expired." });
        }
        catch (InvalidOperationException ex)
        {
            // Server-side configuration guard -- today only DefaultUserPassword()
            // raises this, when UserProvisioning:DefaultPassword is missing from
            // the deployed appsettings. Without this catch the exception escapes
            // to UseExceptionHandler("/Home/Error"), which answers a JSON fetch
            // with an HTML error page: the browser logs a bare 500 and the
            // screen says "The practice service returned an invalid response",
            // neither of which names the missing setting. The message is written
            // for the operator, so it is passed through rather than masked.
            var correlationId = HttpContext.TraceIdentifier;
            logger.LogError(ex, "PracticeManagement gateway save blocked by server configuration. Entity={EntityType} CorrelationId={CorrelationId}",
                entityType, correlationId);
            return StatusCode(StatusCodes.Status500InternalServerError,
                new { success = false, message = $"{ex.Message} Reference: {correlationId}" });
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
        if (!permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), "DELETE"))
            return PermissionDenied(PermissionArea(entityType), "DELETE");
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

    // =================================================================
    // Why this exists instead of ControllerBase.Forbid()
    //
    // Forbid() delegates to HttpContext.ForbidAsync(), which needs an
    // authentication scheme to hand the challenge to. This application
    // has none: Program.cs registers AddSession + UseAuthorization and
    // deliberately no AddAuthentication / UseAuthentication, because
    // identity lives in the session, not in a ClaimsPrincipal. So every
    // Forbid() on this controller threw
    //     InvalidOperationException: No authenticationScheme was
    //     specified, and there was no DefaultForbidScheme found.
    // which left the route answering an HTML page -- the developer
    // exception page in Development, /Home/Error elsewhere -- to a fetch
    // that expects JSON. practice.js could not parse it and reported
    // "The practice service returned an invalid response." for what was
    // really a missing permission.
    //
    // The same route already answers the organization-scope denial with
    // StatusCode(403, json) (see ValidateRequestedOrganization callers);
    // this makes the permission denial answer in the same shape, and
    // names the grant that is missing so it can be fixed rather than
    // guessed at.
    // =================================================================
    private IActionResult PermissionDenied(string area, string action)
    {
        logger.LogWarning(
            "PracticeManagement blocked by menu permission. Area={Area} Action={Action} User={User} Roles={Roles}",
            area, action, HttpContext.Session.GetString(PracticeSessionIdentity.UserKey), string.Join(',', Roles()));
        return StatusCode(StatusCodes.Status403Forbidden, new
        {
            success = false,
            message = $"You do not have permission to {action.ToLowerInvariant()} {area}. "
                    + "Ask an administrator to grant that menu permission to your role."
        });
    }

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
        // Rule 5 — thread the caller's employee_id, dataScope, and roleName
        // through to the SPs / C# helpers so release / statement scope
        // enforcement can happen inside pm_get_practice_repository and
        // pm_manage_practice_repository.
        var employeeIdString = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
        if (long.TryParse(employeeIdString, out var employeeId) && employeeId > 0)
            values["callerEmployeeId"] = employeeId;
        var dataScope = HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey);
        if (!string.IsNullOrWhiteSpace(dataScope)) values["callerDataScope"] = dataScope;
        var roleName = HttpContext.Session.GetString(PracticeSessionIdentity.RoleNameKey);
        if (!string.IsNullOrWhiteSpace(roleName)) values["callerRoleName"] = roleName;
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
        "organization-metadata", "organization-admin-provision", "organization-admin-mark-emailed", "repository-subscriptions", "subscription-owner", "locations", "departments", "business-functions", "teams", "committees",
        "roles", "role-menu-permissions", "users", "dependency-applications", "dependency-tools", "dependency-vendors", "dependency-assets",
        "dependency-processes", "user-assignments", "user-role-assignments", "owner-mappings", "organization-controls", "control-applicability",
        "organization-requirements", "practices", "practice-instances", "practice-operationalization", "resolve", "dependencies", "evidence-configurations",
        "subscribed-frameworks", "release-statements", "statement-applicability", "custom-release", "custom-release-statements", "custom-release-source-structure", "custom-statement", "dashboard-summary",
        "assurance-schedule-rules", "assurance-schedule-overrides", "assurance-calendar-config", "assurance-calendar-events"
    };

    // The mapping itself now lives in Security/PermissionAreaMap.cs,
    // which is linked into PracticeManagement.Api so both tiers resolve
    // the same area for the same entity type. It used to live here only,
    // and the API checked the raw entity type — see the file header for
    // the 403 that came out of that disagreement.
    private static string PermissionArea(string entityType) => PermissionAreaMap.For(entityType);

    private bool CanSaveEntity(string entityType, string action)
    {
        var area = PermissionArea(entityType);
        if (entityType.Equals("statement-applicability", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-release", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-release-source-structure", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("custom-statement", StringComparison.OrdinalIgnoreCase)
            || entityType.Equals("subscription-owner", StringComparison.OrdinalIgnoreCase))
            return permissionPolicy.IsAllowed(Roles(), area, "ADD") || permissionPolicy.IsAllowed(Roles(), area, "EDIT");
        return permissionPolicy.IsAllowed(Roles(), area, action);
    }

    // The Users form no longer collects a password (see migration 208). On a
    // create we substitute the hash of the configured default so the account
    // is provisioned with known-good credentials, and flag it so LoginController
    // forces a change before the first session is issued. The plaintext default
    // never leaves this tier — only the PBKDF2 hash reaches the API and DB.
    //
    // A `password` key is still honoured if one arrives: the endpoint is also
    // reachable from tooling, and silently ignoring a supplied password would
    // be worse than hashing it.
    private JsonElement HashSensitivePayloadFields(string entityType, JsonElement data, bool isCreate)
    {
        if (!entityType.Equals("users", StringComparison.OrdinalIgnoreCase)) return data;

        var password = data.TryGetProperty("password", out var passwordElement)
                       && passwordElement.ValueKind == JsonValueKind.String
            ? passwordElement.GetString()
            : null;
        var suppliedPassword = !string.IsNullOrWhiteSpace(password);

        // An edit with no password supplied leaves the stored hash alone —
        // sp_org_user_save COALESCEs a missing hash to the existing one.
        if (!suppliedPassword && !isCreate) return data;

        var node = JsonNode.Parse(data.GetRawText()) as JsonObject ?? [];
        if (suppliedPassword)
        {
            node["passwordHash"] = passwordHasher.Hash(password!);
        }
        else
        {
            node["passwordHash"] = passwordHasher.Hash(DefaultUserPassword());
            // Provisioned on the shared default — the owner must replace it
            // at first sign-in. Only set on create; an edit must not re-arm
            // the flag for someone who has already chosen their own password.
            node["forcePasswordChange"] = 1;
        }
        node.Remove("password");
        return JsonSerializer.SerializeToElement(node);
    }

    private string DefaultUserPassword()
    {
        var configured = configuration["UserProvisioning:DefaultPassword"];
        if (!string.IsNullOrWhiteSpace(configured)) return configured;
        throw new InvalidOperationException(
            "UserProvisioning:DefaultPassword is not configured. New users cannot be provisioned without it.");
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
            { FilterType: "Practice", TargetArea: "practice-instances" or "practice-view" } => true,
            // The Organization Practices grid does not always carry a practice
            // id, so practice-view is also reachable on the requirement id.
            { FilterType: "OrganizationRequirement", TargetArea: "practice-view" } => true,
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
