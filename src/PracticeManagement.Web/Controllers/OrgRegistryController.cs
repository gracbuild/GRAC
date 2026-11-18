// =====================================================================
// OrgRegistryController (Web tier)  (migrations 569-572)
//
// Thin proxy to Api /api/practice/org-registry for Organization Management
// -> Organization Registry (Partials/org-registry.cshtml). The
// SubscriptionRequestController pattern:
//   * session guard;
//   * every call names its screen (?screen=); the grant is that screen's
//     (PracticeController.ScreenPermissionArea):
//       GET  lookups | summary | {area}   VIEW
//       POST {area}                       ADD
//       PUT  {area}/{id}                  EDIT
//     There is no delete: a registry record is retired through its status;
//   * 575 -- two kinds of screen:
//       org-registry (Organization Management): Organizations and Legal
//         Entities, GRAC administration -- GLOBAL scope required, every
//         Legal Entity;
//       org-registry-structure / -people / -operations (Practice
//         Management -> Organization): an organization's own users --
//         confined to the session's organizations (allowedLegalEntityIds,
//         rebuilt here), Organizations / Legal Entities read-only;
//     and each screen reaches only its own areas (ScreenAreas);
//   * the actor is the SESSION sign-in: the forwarded body is rebuilt with
//     actor set here, so the browser can never name someone else.
// Web tier never opens SQL.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
// Both routes, for the reason SubscriptionRequestController gives: on a
// plain host /OrganizationManagement is a conventional route, not a
// PathBase, and the partial prefixes window.appBasePath.
[Route("practice/api/org-registry")]
[Route("OrganizationManagement/practice/api/org-registry")]
public sealed class OrgRegistryController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<OrgRegistryController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private const string ApiBase    = "api/practice/org-registry";

    // 575: the registry's screens and the areas each one may list / save.
    // Organization Management's org-registry is GRAC administration
    // (GLOBAL scope, every Legal Entity). The other three are Practice
    // Management -> Organization, used by an organization's own users:
    // confined to their Legal Entities, with Organizations and Legal
    // Entities read-only. Must match GROUPS in org-registry.js.
    private static readonly Dictionary<string, string[]> ScreenAreas = new(StringComparer.OrdinalIgnoreCase)
    {
        ["org-registry"]            = ["organizations", "legal-entities"],
        ["org-registry-structure"]  = ["organizations", "legal-entities", "units", "locations", "departments"],
        ["org-registry-people"]     = ["people", "teams", "committees", "committee-members"],
        ["org-registry-operations"] = ["functions", "processes", "products", "channels"]
    };
    private static readonly HashSet<string> ReadOnlyAreasOutsideAdministration =
        new(["organizations", "legal-entities"], StringComparer.OrdinalIgnoreCase);
    private const string AdministrationScreen = "org-registry";

    private HttpClient BuildClient()
    {
        var client = httpClientFactory.CreateClient("PracticeManagementApi");
        if (client.BaseAddress is null)
        {
            var url = (configuration[ApiBaseKey] ?? "http://localhost:5045").Trim().TrimEnd('/') + "/";
            client.BaseAddress = new Uri(url);
        }
        return client;
    }

    private string[] Roles() =>
        (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);

    // The screen the call comes from (?screen=), which decides the grant,
    // the scope and the areas.
    private string Screen() => (Request.Query["screen"].ToString() ?? "").Trim();

    private bool Can(string screen, string action) =>
        permissionPolicy.IsAllowed(Roles(), PracticeController.ScreenPermissionArea(screen), action);

    [HttpGet("lookups")]
    public Task<IActionResult> Lookups(CancellationToken ct) => GetAsync("lookups", null, ct);

    [HttpGet("summary")]
    public Task<IActionResult> Summary(CancellationToken ct) => GetAsync("summary", null, ct);

    [HttpGet("{area}")]
    public Task<IActionResult> List(string area, CancellationToken ct) => GetAsync(Uri.EscapeDataString(area), area, ct);

    [HttpPost("{area}")]
    public Task<IActionResult> Create(string area, CancellationToken ct) =>
        SaveAsync(HttpMethod.Post, area, $"{ApiBase}/{Uri.EscapeDataString(area)}", "ADD", ct);

    [HttpPut("{area}/{id:long}")]
    public Task<IActionResult> Update(string area, long id, CancellationToken ct) =>
        SaveAsync(HttpMethod.Put, area, $"{ApiBase}/{Uri.EscapeDataString(area)}/{id}", "EDIT", ct);

    // ------------------------------------------------------------------
    private async Task<IActionResult> GetAsync(string path, string? area, CancellationToken ct)
    {
        var screen = Screen();
        if (Guard(screen, area, "VIEW", write: false) is { } denied) return denied;
        // Rebuilt, not passed through: the scope comes from the session only.
        var query = Request.Query
            .Where(q => !q.Key.Equals("allowedLegalEntityIds", StringComparison.OrdinalIgnoreCase)
                     && !q.Key.Equals("screen", StringComparison.OrdinalIgnoreCase))
            .Select(q => $"{Uri.EscapeDataString(q.Key)}={Uri.EscapeDataString(q.Value.ToString())}")
            .ToList();
        var allowed = AllowedFor(screen);
        // An empty list is sent as "0" (no organization): an empty query
        // value binds as null in the Api, which would mean "every one".
        if (allowed is not null)
            query.Add("allowedLegalEntityIds=" + Uri.EscapeDataString(allowed.Length == 0 ? "0" : string.Join(",", allowed)));
        var qs = query.Count > 0 ? "?" + string.Join("&", query) : "";
        return await ForwardAsync(HttpMethod.Get, $"{ApiBase}/{path}{qs}", null, ct);
    }

    private async Task<IActionResult> SaveAsync(HttpMethod method, string area, string url, string action, CancellationToken ct)
    {
        var screen = Screen();
        if (Guard(screen, area, action, write: true) is { } denied) return denied;

        JsonElement data;
        using (var sr = new StreamReader(Request.Body))
        {
            var raw = await sr.ReadToEndAsync(ct);
            try
            {
                using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
                // Accept { data: {...} } (what the screen sends) or the bare object.
                var root = doc.RootElement;
                data = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("data", out var d) ? d.Clone() : root.Clone();
            }
            catch (JsonException)
            {
                return BadRequest(new { error = "The request body must be JSON." });
            }
        }
        if (data.ValueKind != JsonValueKind.Object)
            return BadRequest(new { error = "data must be a JSON object." });

        // Rebuilt, not passed through: actor and scope come from the session only.
        var actor = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) ?? "";
        var body = JsonSerializer.Serialize(new { data, actor, allowedLegalEntityIds = AllowedFor(screen) });
        return await ForwardAsync(method, url, body, ct);
    }

    // null = every Legal Entity: Organization Management, or a GLOBAL-scope
    // sign-in on the Practice Management screens. Otherwise the session's
    // organizations (an empty list reaches nothing).
    private long[]? AllowedFor(string screen) =>
        screen.Equals(AdministrationScreen, StringComparison.OrdinalIgnoreCase) || HttpContext.IsGlobalScope()
            ? null
            : HttpContext.AllowedOrganizationIds().ToArray();

    private IActionResult? Guard(string screen, string? area, string action, bool write)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!ScreenAreas.TryGetValue(screen, out var areas))
            return BadRequest(new { error = "Unknown registry screen." });
        if (area is not null && !areas.Contains(area, StringComparer.OrdinalIgnoreCase))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "This area is not part of this screen." });
        if (!Can(screen, action))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        var administration = screen.Equals(AdministrationScreen, StringComparison.OrdinalIgnoreCase);
        if (administration && !HttpContext.IsGlobalScope())
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Organizations and Legal Entities are maintained by a platform (GLOBAL scope) administrator." });
        if (write && !administration && area is not null && ReadOnlyAreasOutsideAdministration.Contains(area))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Organizations and Legal Entities are maintained in Organization Management." });
        return null;
    }

    private async Task<IActionResult> ForwardAsync(HttpMethod method, string relativeUrl, string? body, CancellationToken ct)
    {
        try
        {
            using var msg = new HttpRequestMessage(method, relativeUrl);
            if (body is not null)
            {
                msg.Content = new StringContent(body);
                msg.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
            var resp    = await BuildClient().SendAsync(msg, ct);
            var payload = await resp.Content.ReadAsStringAsync(ct);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRegistry {Method} proxy failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
