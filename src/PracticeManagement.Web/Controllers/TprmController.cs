// =====================================================================
// TprmController (Web tier)  (migrations 486-490, Third-Party Management;
// Vendor Registry rules from 521; TP Risk Register from 524)
//
// Thin proxy: /practice/api/tprm/*  ->  /api/practice/tprm/*
// (the AssetConfigController pattern: session, organization and the menu
// grant of the screen are checked here; the procedures decide the rest --
// scope, segregation of duties, lifecycle gates, versioning).
//
//   GET  lookups                         VIEW on any TPRM screen (524: incl. TP Risk Register)
//   config/...  (tprm-configuration)
//     GET                                VIEW
//     POST .../activate, .../retire      APPROVE (a version / template in force)
//     POST config/delegations            APPROVE (delegating approval authority)
//     other POSTs                        ADD or EDIT
//     organizationId absent = the GRAC baseline: platform administrator
//     (PM_ADMIN) only, for reads and changes
//   third-parties..., samples/load  (tprm-third-parties, Vendor Registry)
//     GET                                VIEW
//     POST third-parties                 ADD (new, no thirdPartyId) / EDIT
//     POST third-parties/{id}/status     APPROVE -- SUSPEND, REINSTATE,
//                                        INACTIVATE, REACTIVATE, ARCHIVE,
//                                        RESTORE (521; 522 retired ACTIVATE:
//                                        registration activates. The
//                                        procedure checks that the action is
//                                        a transition allowed from the
//                                        vendor's current state)
//     POST third-parties/{id}/match-reviews
//                                        decision NOT_DUPLICATE -> EDIT,
//                                        DUPLICATE (archives it) -> APPROVE
//     POST samples/load                  ADD
//   (521 removed the legacy vendors... routes: the Vendor Registry has no
//   link to the GRAC vendor dependency register.)
//   engagements..., risk-assessments..., due-diligence..., evidence...,
//   findings..., decisions..., onboarding..., deviations..., admissions... (tprm-engagements)
//     GET                                VIEW
//     POST engagements                   ADD (new, no engagementId) / EDIT
//     POST engagements/{id}/exposure     EDIT (522: Scope & Exposure)
//     POST engagements/{id}/screening    EDIT (523: refresh the screening report)
//     POST engagements/{id}/applicability APPROVE (523: client decision)
//     POST admissions/{id}/act           APPROVE (523: approver role and SoD in SQL)
//     POST admissions/{id}/withdraw      EDIT (523: decision-maker or admin, in SQL)
//     POST decisions/{id}/act            APPROVE (approver role and SoD in SQL)
//     POST engagements/{id}/activate     APPROVE
//     POST findings/{id}/action          WAIVE -> APPROVE, others EDIT
//     POST onboarding/items/{id}/action  WAIVE -> APPROVE, others EDIT
//     POST deviations/{id}/action        ACCEPT -> APPROVE, REASSESS -> EDIT
//     POST engagements/{id}/lifecycle    RENEW / SCOPE_CHANGE -> EDIT,
//                                        SUSPEND / RESUME / START_EXIT /
//                                        COMPLETE_EXIT / CANCEL -> APPROVE
//     other POSTs                        EDIT
//   risk-register...  (tprm-risk-register, TP Risk Register, 524)
//     GET                                VIEW
//     POST risk-register/{id}/ratings    EDIT (vendor-level area rating)
//     POST risk-register/{id}/profile-reviews
//                                        EDIT (525: periodic vendor profile review)
//     POST risk-register/impact-reviews/{id}/decide
//                                        APPROVE (SoD in SQL: not the decision-maker
//                                        who included the engagement)
//     POST risk-register/{id}/close      APPROVE (SoD in SQL: not the person whose
//                                        action started the exit)
//   reviews..., monitoring/run  (tprm-reviews)
//     GET reviews                        VIEW
//     POST engagements/{id}/reviews      tprm-reviews ADD or tprm-engagements EDIT
//     POST reviews/{id}/complete         EDIT
//     POST monitoring/run                APPROVE
//
// Every call names an organization the session may act on (query string
// for GET, body for POST), except the GRAC baseline configuration above.
// The caller is stamped from the SESSION: X-PM-Caller-Employee-Id
// (CallerIdentityHandler), X-PM-Caller-Is-Admin (organization admin,
// shared rule) and X-PM-Caller-Is-Platform-Admin (PM_ADMIN -- baseline
// editing), overwriting anything the browser sent.
// Web tier never opens SQL.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/tprm")]
public sealed class TprmController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<TprmController> logger) : ControllerBase
{
    private const string ApiBaseKey        = "ApiBaseUrl";
    private const string ApiBase           = "api/practice/tprm/";
    private const string ThirdPartyArea    = "tprm-third-parties";
    private const string EngagementArea    = "tprm-engagements";
    private const string ReviewArea        = "tprm-reviews";
    private const string ConfigurationArea = "tprm-configuration";
    private const string RegisterArea      = "tprm-risk-register";
    private const string PlatformAdminRole = "PM_ADMIN";
    private const string CallerPlatformAdminHeader = "X-PM-Caller-Is-Platform-Admin";

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

    private bool Can(string area, params string[] actions) =>
        actions.Any(a => permissionPolicy.IsAllowed(Roles(), PermissionAreaMap.For(area), a));

    private bool IsPlatformAdmin() =>
        Roles().Any(r => r.Equals(PlatformAdminRole, StringComparison.OrdinalIgnoreCase));

    // ------------------------------------------------------------------
    [HttpGet("{**path}")]
    public async Task<IActionResult> ProxyGet(string path, CancellationToken ct)
    {
        if (SessionMissing() is { } unauthorized) return unauthorized;
        var lower = (path ?? "").ToLowerInvariant().Trim('/');
        long.TryParse(Request.Query["organizationId"], out var orgId);

        bool allowed;
        if (lower == "lookups")
            allowed = Can(ThirdPartyArea, "VIEW") || Can(EngagementArea, "VIEW") || Can(ReviewArea, "VIEW") || Can(ConfigurationArea, "VIEW")
                      || Can(RegisterArea, "VIEW");
        else if (lower.StartsWith("config/"))
        {
            if (orgId <= 0)
            {
                if (!IsPlatformAdmin())
                    return StatusCode(StatusCodes.Status403Forbidden,
                        new { error = "The GRAC baseline is maintained by the platform administrator. Select an organization." });
                return Can(ConfigurationArea, "VIEW") ? await ForwardAsync(HttpMethod.Get, ApiBase + path + Request.QueryString, null, ct) : Denied();
            }
            allowed = Can(ConfigurationArea, "VIEW");
        }
        else if (lower.StartsWith("third-parties"))
            allowed = Can(ThirdPartyArea, "VIEW");
        else if (lower == "reviews")
            allowed = Can(ReviewArea, "VIEW");
        else if (lower == "risk-register" || lower.StartsWith("risk-register/"))
            allowed = Can(RegisterArea, "VIEW");
        else if (lower.StartsWith("engagements") || lower.StartsWith("risk-assessments/") || lower.StartsWith("evidence/"))
            // the Reviews screen opens the engagement it reviews
            allowed = Can(EngagementArea, "VIEW") || (lower.StartsWith("engagements/") && Can(ReviewArea, "VIEW"));
        else
            return NotFound(new { error = "Unknown TPRM resource." });

        if (orgId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
        if (!allowed) return Denied();
        return await ForwardAsync(HttpMethod.Get, ApiBase + path + Request.QueryString, null, ct);
    }

    [HttpPost("{**path}")]
    public async Task<IActionResult> ProxyPost(string path, CancellationToken ct)
    {
        if (SessionMissing() is { } unauthorized) return unauthorized;
        var lower = (path ?? "").ToLowerInvariant().Trim('/');
        var segments = lower.Split('/');
        using var reader = new StreamReader(Request.Body);
        var body = await reader.ReadToEndAsync(ct);
        if (string.IsNullOrWhiteSpace(body)) body = "{}";
        long.TryParse(ReadString(body, "organizationId"), out var orgId);
        var action = (ReadString(body, "action") ?? "").Trim().ToUpperInvariant();

        bool allowed;
        if (lower.StartsWith("config/"))
        {
            var approve = lower.EndsWith("/activate") || lower.EndsWith("/retire") || lower == "config/delegations";
            allowed = approve ? Can(ConfigurationArea, "APPROVE") : Can(ConfigurationArea, "ADD", "EDIT");
            if (orgId <= 0)
            {
                // The GRAC baseline reaches every organization.
                if (!IsPlatformAdmin())
                    return StatusCode(StatusCodes.Status403Forbidden,
                        new { error = "The GRAC baseline is maintained by the platform administrator. Select an organization to change its own configuration." });
                return allowed ? await ForwardAsync(HttpMethod.Post, ApiBase + path, body, ct) : Denied();
            }
        }
        else if (lower == "third-parties")
            allowed = HasId(body, "thirdPartyId") ? Can(ThirdPartyArea, "EDIT") : Can(ThirdPartyArea, "ADD");
        else if (segments.Length == 3 && segments[0] == "third-parties" && segments[2] == "status")
            allowed = Can(ThirdPartyArea, "APPROVE");
        else if (segments.Length == 3 && segments[0] == "third-parties" && segments[2] == "match-reviews")
            // Trimmed like the procedure does, so " DUPLICATE" cannot pass as EDIT.
            allowed = (ReadString(body, "decision") ?? "").Trim().Equals("DUPLICATE", StringComparison.OrdinalIgnoreCase)
                ? Can(ThirdPartyArea, "APPROVE") : Can(ThirdPartyArea, "EDIT");
        else if (lower.StartsWith("third-parties/"))
            allowed = Can(ThirdPartyArea, "EDIT");
        else if (lower == "samples/load")
            allowed = Can(ThirdPartyArea, "ADD");
        else if (lower == "monitoring/run")
            allowed = Can(ReviewArea, "APPROVE");
        // 524 (CR 2 8): rating a vendor-level area is EDIT; the impact
        // review outcome and closing a record are APPROVE (segregation of
        // duties in the procedures).
        else if (segments.Length == 3 && segments[0] == "risk-register" && segments[2] is "ratings" or "profile-reviews")
            allowed = Can(RegisterArea, "EDIT");
        else if (segments.Length == 4 && segments[0] == "risk-register" && segments[1] == "impact-reviews" && segments[3] == "decide")
            allowed = Can(RegisterArea, "APPROVE");
        else if (segments.Length == 3 && segments[0] == "risk-register" && segments[2] == "close")
            allowed = Can(RegisterArea, "APPROVE");
        else if (lower.StartsWith("reviews/"))
            allowed = Can(ReviewArea, "EDIT");
        else if (segments.Length == 3 && segments[0] == "engagements" && segments[2] == "reviews")
            allowed = Can(ReviewArea, "ADD") || Can(EngagementArea, "EDIT");
        else if (lower == "engagements")
            allowed = HasId(body, "engagementId") ? Can(EngagementArea, "EDIT") : Can(EngagementArea, "ADD");
        else if (lower.StartsWith("decisions/") && lower.EndsWith("/act"))
            allowed = Can(EngagementArea, "APPROVE");
        // 523 (CR 2 7): the client's applicability decision and the
        // admission approval are APPROVE; withdrawing a pending admission
        // is EDIT (the procedure allows only the decision-maker or an admin).
        else if (segments.Length == 3 && segments[0] == "engagements" && segments[2] == "applicability")
            allowed = Can(EngagementArea, "APPROVE");
        else if (segments.Length == 3 && segments[0] == "admissions" && segments[2] == "act")
            allowed = Can(EngagementArea, "APPROVE");
        else if (segments.Length == 3 && segments[0] == "admissions" && segments[2] == "withdraw")
            allowed = Can(EngagementArea, "EDIT");
        else if (segments.Length == 3 && segments[0] == "engagements" && segments[2] == "activate")
            allowed = Can(EngagementArea, "APPROVE");
        else if (segments.Length == 3 && segments[0] == "engagements" && segments[2] == "lifecycle")
            allowed = action is "RENEW" or "SCOPE_CHANGE" ? Can(EngagementArea, "EDIT") : Can(EngagementArea, "APPROVE");
        else if (lower.StartsWith("findings/") || lower.StartsWith("onboarding/items/"))
            allowed = action == "WAIVE" ? Can(EngagementArea, "APPROVE") : Can(EngagementArea, "EDIT");
        else if (lower.StartsWith("deviations/"))
            allowed = action == "ACCEPT" ? Can(EngagementArea, "APPROVE") : Can(EngagementArea, "EDIT");
        else if (lower.StartsWith("engagements/") || lower.StartsWith("risk-assessments/") || lower.StartsWith("due-diligence/")
                 || lower.StartsWith("evidence/") || lower.StartsWith("decisions/"))
            allowed = Can(EngagementArea, "EDIT");
        else
            return NotFound(new { error = "Unknown TPRM resource." });

        if (orgId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
        if (!allowed) return Denied();
        return await ForwardAsync(HttpMethod.Post, ApiBase + path, body, ct);
    }

    // ------------------------------------------------------------------
    private static bool HasId(string body, string property) =>
        long.TryParse(ReadString(body, property), out var id) && id > 0;

    private static string? ReadString(string body, string property)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            foreach (var p in doc.RootElement.EnumerateObject())
                if (string.Equals(p.Name, property, StringComparison.OrdinalIgnoreCase))
                    return p.Value.ValueKind switch
                    {
                        JsonValueKind.String => p.Value.GetString(),
                        JsonValueKind.Number => p.Value.GetRawText(),
                        _ => null
                    };
        }
        catch (JsonException) { /* not JSON -- treated as missing */ }
        return null;
    }

    private IActionResult? SessionMissing() =>
        string.IsNullOrWhiteSpace(HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey))
            ? Unauthorized(new { error = "Session expired. Please sign in again." })
            : null;

    private IActionResult OrganizationDenied() =>
        StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller is not authorised for the requested organization." });

    private IActionResult Denied() =>
        StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });

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
            // Organization admin flag (shared rule) and the platform-admin
            // flag, from the session; the employee id is stamped by
            // CallerIdentityHandler on every call.
            CallerIdentityHandler.StampAdminFlag(HttpContext, msg);
            msg.Headers.Remove(CallerPlatformAdminHeader);
            msg.Headers.TryAddWithoutValidation(CallerPlatformAdminHeader, IsPlatformAdmin() ? "1" : "0");

            var client = BuildClient();
            if (relativeUrl.EndsWith("monitoring/run", StringComparison.OrdinalIgnoreCase))
                client.Timeout = TimeSpan.FromMinutes(5);   // whole-organization sweep
            var resp = await client.SendAsync(msg, ct);
            var payload = await resp.Content.ReadAsStringAsync(ct);
            return new ContentResult
            {
                Content = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TPRM proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
