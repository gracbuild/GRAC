// =====================================================================
// AssetConfigController (Web tier)  (migration 420)
//
// Thin proxy: /practice/api/asset-config/*  ->  /api/practice/asset-config/*
//
// Unlike the older module proxies (org-sla, exception-centre) this one
// enforces the menu grant as well as the session and the organization,
// the same way RoleViewDataScopeController does:
//   field-groups / field-definitions   asset-field-dictionary VIEW
//   taxonomy                           VIEW on either screen
//   GET  templates...                  asset-form-templates VIEW
//   POST templates/{id}/transition
//        toStatusCode = APPROVED       asset-form-templates APPROVE
//        toStatusCode = DRAFT          ADD, EDIT or APPROVE (return / reject)
//   POST templates/{id}/evaluate       asset-form-templates VIEW (421, read-only preview)
//   any other POST                     asset-form-templates ADD or EDIT
//   valuation...  (422)                same rules against asset-valuation-config:
//                                      GET and POST valuation/{id}/calculate VIEW,
//                                      transition APPROVED APPROVE, DRAFT ADD/EDIT/APPROVE,
//                                      other POSTs ADD or EDIT
//   option-lists... (423)              asset-option-lists: GET VIEW, POST ADD or EDIT
//   taxonomy/governance (424)          asset-taxonomy VIEW (organization required)
//   POST taxonomy/categories | subcategories | types
//                                      global masters: platform administrator (PM_ADMIN)
//                                      AND asset-taxonomy ADD or EDIT -- no organization
//   POST taxonomy/types/{id}/org-defaults
//                                      asset-taxonomy EDIT for that organization
//   tech-catalog... (425)              asset-tech-catalog: GET VIEW; POST as templates
//                                      (transition APPROVED -> APPROVE, DRAFT -> ADD/EDIT/APPROVE,
//                                      other POSTs ADD or EDIT); "shared": true additionally
//                                      needs the platform administrator (PM_ADMIN);
//                                      .../approve (426 / 427 compatibility) -> APPROVE;
//                                      tech-catalog/os/... (427) follows the same rules
//   register... (428)                  asset-register: GET VIEW (organization required);
//                                      POST register/evaluate VIEW; POST register ADD for a
//                                      new asset, EDIT for an existing one (assetId);
//                                      POST register/{id}/transition EDIT (429);
//                                      POST register/lifecycle-changes/{id}/decide
//                                      APPROVE / REJECT -> APPROVE, CANCEL -> EDIT;
//                                      POST register/{id}/technology/... EDIT (430);
//                                      POST register/technology-exceptions/{id}/decide
//                                      APPROVE / REJECT / REVOKE -> APPROVE, WITHDRAW -> EDIT
//   attestation... (431)               asset-attestation: GET VIEW (organization required);
//                                      POST attestation/profiles ADD or EDIT, attestation/generate
//                                      ADD, attestation/{id}/respond VIEW (the procedure allows
//                                      only the assignee), attestation/{id}/decide CANCEL ->
//                                      APPROVE, APPROVE / RETURN -> VIEW (the procedure allows
//                                      only the manager); register/{id}/custody: register VIEW;
//                                      attestation/exceptions/{id}/action (432) APPROVE / REJECT /
//                                      REASSIGN / CANCEL -> APPROVE, the investigator actions ->
//                                      VIEW (the procedure allows only the investigator);
//                                      attestation/exception-settings | exception-rules -> EDIT
//   register workflows (433)           POST register/{id}/workflows EDIT; .../step COMPLETE -> EDIT,
//                                      APPROVE / REJECT -> APPROVE, CONFIRM / DECLINE -> VIEW (the
//                                      procedure allows only the owner the step waits for);
//                                      .../cancel EDIT (the procedure allows only the starter)
//   contracts... (434)                 asset-contracts: GET VIEW (organization required); POST contracts
//                                      ADD for a new contract, EDIT for an existing one (contractId);
//                                      contracts/versions/{id}/action APPROVE / REJECT -> APPROVE,
//                                      SUBMIT / REVIEW / RETURN / WITHDRAW -> EDIT (the procedure keeps
//                                      the submitter from reviewing / approving); contracts/contacts/
//                                      {id}/action VALIDATE -> APPROVE (not the creator, in SQL), END ->
//                                      EDIT; every other contract POST -> EDIT (435: entitlements,
//                                      coverage, coverage requirements and settings);
//                                      GET register/{id}/coverage -> asset-register VIEW (435)
//                                      contracts/renewals/{id}/action APPROVE / RETURN -> APPROVE (the
//                                      procedure keeps the submitter from approving), other steps EDIT (436)
//   notifications... (437)             asset-notifications: GET VIEW (organization required); POST
//                                      notifications/profiles ADD or EDIT, notifications/matrix EDIT,
//                                      notifications/occurrences/{id}/snooze APPROVE (the configured
//                                      roles of 9.1.1), notifications/log/{id}/delivery EDIT,
//                                      notifications/run EDIT
//   notifications/mine... (437)        the caller's own notices: session only, no organization or menu
//                                      grant -- the API addresses them to the stamped employee
//   activities... (438)                asset-activities: GET VIEW (organization required); POST
//                                      activities/settings, activities/occurrences/{id}/reconcile and
//                                      activities/run EDIT; (439) activities/occurrences/{id}/result and
//                                      /disposition EDIT, /result-decision APPROVE (the procedure keeps the
//                                      submitter from reviewing), activities/dispositions/{id}/decision
//                                      APPROVE / REJECT -> APPROVE, WITHDRAW -> EDIT (requester only, in SQL),
//                                      activities/reviews/{id}/decision APPROVE
//   relationships... (440)             asset-relationships: GET VIEW (organization required); POST
//                                      relationships ADD for a proposal, EDIT for a change (relationshipId);
//                                      relationships/{id}/action APPROVE / REJECT / CONFIRM /
//                                      ACCEPT_RETIREMENT -> APPROVE, DISPUTE / RETIRE / WITHDRAW -> EDIT
//                                      (segregation of duties and the withdrawing requester in SQL)
//   business-services... (441)         business-services: GET VIEW (organization required); POST
//                                      business-services ADD for a new service, EDIT for a change (serviceId);
//                                      /transition and settings EDIT; /retirement-decision APPROVE / REJECT
//                                      -> APPROVE, WITHDRAW -> EDIT (segregation of duties in SQL). The
//                                      supporting-item mappings go through relationships... (440 rules)
//   discovery... (442)                 asset-discovery: GET VIEW (organization required); POST sources,
//                                      sources/{id}/priorities, rules, settings and batches EDIT;
//                                      exceptions/{id}/resolve ACCEPT_OBSERVED -> APPROVE, other actions EDIT
//                                      relationships/ci-lookup also open to asset-discovery VIEW (asset picker)
//                                      443: stale/settings, stale/reviews and stale/reviews/{id}/action EDIT;
//                                      REQUEST_DECOMMISSION also needs asset-register EDIT (lifecycle move)
//                                      444: merges (draft) EDIT; merges/{id}/action APPROVE / REJECT / RECOVER
//                                      -> APPROVE, SUBMIT / CANCEL -> EDIT, EXECUTE -> EDIT + asset-register EDIT;
//                                      RECOVER also needs asset-register EDIT
//                                      445: splits / splits/{id}/action as merges
//   Asset Value (446)                  GET register/{id}/valuation -> asset-register VIEW;
//                                      POST register/{id}/valuation/recalculate -> asset-register EDIT;
//                                      POST register/{id}/valuation/method (override) -> asset-register APPROVE;
//                                      GET valuation/recalculation -> asset-valuation-config VIEW;
//                                      POST valuation/recalculation (run) -> asset-valuation-config APPROVE
//   reports... (452)                   asset-reports: GET VIEW (organization required); POST reports/{code}/export
//                                      VIEW (the export policy and the APPROVE an approver policy needs are checked
//                                      in SQL); POST reports/settings EDIT. Every report call carries
//                                      X-PM-Caller-Report-Areas (the report screens the session may VIEW) and
//                                      X-PM-Caller-Report-Approve; a report is refused unless its screen is listed.
//                                      453: POST reports/schedules and reports/schedules/{id}/run EDIT;
//                                      POST reports/deliveries/recipients/{id}/download VIEW (only the recipient, in SQL)
//   governance... (450)                asset-governance: GET VIEW (organization required); POST settings,
//                                      settings/overall, relationship-rules, snapshot EDIT
//   privacy... (448)                   asset-privacy: GET VIEW (organization required); POST requirements,
//                                      exceptions (request), run EDIT; exceptions/{id}/action APPROVE / REJECT /
//                                      REVOKE -> APPROVE, WITHDRAW -> EDIT; reviews/{id}/complete EXTEND -> APPROVE,
//                                      other outcomes EDIT (segregation of duties in SQL);
//                                      GET register/{id}/privacy -> asset-register VIEW
//   Consistency rules (447)            GET valuation/consistency/... -> asset-valuation-config VIEW;
//                                      POST valuation/consistency/rules ADD or EDIT;
//                                      .../rules/{id}/action ACTIVATE / RETIRE -> APPROVE, NEW_VERSION / DISCARD -> ADD or EDIT;
//                                      GET register/consistency/findings -> asset-register VIEW;
//                                      POST register/consistency/findings/{id}/action ACCEPT / WITHDRAW -> EDIT,
//                                      APPROVE / REJECT / REVOKE -> APPROVE; POST register/consistency/run -> EDIT
// Every template call must name an organization the session may act on.
// The caller (X-PM-Caller-Employee-Id) is stamped by CallerIdentityHandler.
// Web tier never opens SQL.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/asset-config")]
public sealed class AssetConfigController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<AssetConfigController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private const string DictionaryArea = "asset-field-dictionary";
    private const string TemplateArea = "asset-form-templates";
    private const string ValuationArea = "asset-valuation-config";   // 422
    private const string OptionListArea = "asset-option-lists";      // 423
    private const string TaxonomyArea = "asset-taxonomy";            // 424
    private const string TechCatalogArea = "asset-tech-catalog";     // 425
    private const string RegisterArea = "asset-register";            // 428
    private const string AttestationArea = "asset-attestation";      // 431
    private const string ContractArea = "asset-contracts";           // 434
    private const string NotificationArea = "asset-notifications";   // 437
    private const string ActivityArea = "asset-activities";          // 438
    private const string RelationshipArea = "asset-relationships";   // 440
    private const string ServiceArea = "business-services";          // 441
    private const string DiscoveryArea = "asset-discovery";          // 442
    private const string PrivacyArea = "asset-privacy";              // 448
    private const string GovernanceArea = "asset-governance";        // 450
    private const string ReportArea = "asset-reports";               // 452
    private const string CallerReportAreasHeader = "X-PM-Caller-Report-Areas";       // 452
    private const string CallerReportApproveHeader = "X-PM-Caller-Report-Approve";   // 452

    // 452: the screens a report can be based on (asset_report_definition.view_area). A report on another screen is
    // refused until its screen is added here.
    private static readonly string[] ReportScreenAreas =
    {
        RegisterArea, AttestationArea, RelationshipArea, ServiceArea, DiscoveryArea, ContractArea, GovernanceArea,
        PrivacyArea, ActivityArea, "risk-centre-register"
    };
    private const string PlatformAdminRole = "PM_ADMIN";

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

    [HttpGet("{**path}")]
    public async Task<IActionResult> ProxyGet(string path, CancellationToken ct)
    {
        if (SessionMissing() is { } unauthorized) return unauthorized;
        var lower = (path ?? "").ToLowerInvariant();

        bool allowed;
        if (lower == "taxonomy/governance")
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(TaxonomyArea, "VIEW");
        }
        else if (lower == "register" || lower.StartsWith("register/"))
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(RegisterArea, "VIEW");
        }
        else if (lower.StartsWith("tech-catalog"))
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(TechCatalogArea, "VIEW");
        }
        else if (lower.StartsWith("discovery/"))                                // 442
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(DiscoveryArea, "VIEW");
        }
        else if (lower == "business-services" || lower.StartsWith("business-services/"))   // 441
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(ServiceArea, "VIEW");
        }
        else if (lower == "relationships" || lower.StartsWith("relationships/"))   // 440
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(RelationshipArea, "VIEW")
                      || (lower == "relationships/ci-lookup" && Can(DiscoveryArea, "VIEW"));   // 442: asset picker of the queue
        }
        else if (lower.StartsWith("activities/"))                               // 438
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(ActivityArea, "VIEW");
        }
        else if (lower == "notifications/mine" || lower.StartsWith("notifications/mine/"))   // 437: own notices
            allowed = true;
        else if (lower.StartsWith("notifications/"))                            // 437
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(NotificationArea, "VIEW");
        }
        else if (lower == "contracts" || lower.StartsWith("contracts/"))       // 434
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(ContractArea, "VIEW");
        }
        else if (lower == "attestation" || lower.StartsWith("attestation/"))   // 431
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(AttestationArea, "VIEW");
        }
        else if (lower.StartsWith("option-lists"))
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(OptionListArea, "VIEW");
        }
        else if (lower == "reports" || lower.StartsWith("reports/"))           // 452
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(ReportArea, "VIEW");
        }
        else if (lower == "governance" || lower.StartsWith("governance/"))     // 450
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(GovernanceArea, "VIEW");
        }
        else if (lower.StartsWith("privacy/"))                                  // 448
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(PrivacyArea, "VIEW");
        }
        else if (lower.StartsWith("valuation"))
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(ValuationArea, "VIEW");
        }
        else if (lower.StartsWith("templates"))
        {
            if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId)) return OrganizationDenied();
            allowed = Can(TemplateArea, "VIEW");
        }
        else if (lower == "taxonomy")
            allowed = Can(TemplateArea, "VIEW") || Can(DictionaryArea, "VIEW");
        else if (lower is "field-groups" or "field-definitions")
            // The template designer's field library reads the dictionary too.
            allowed = Can(DictionaryArea, "VIEW") || Can(TemplateArea, "VIEW");
        else
            return NotFound(new { error = "Unknown asset configuration resource." });

        if (!allowed) return Denied();
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Get, "api/practice/asset-config/" + path + qs, null, ct,
            reportCaller: lower == "reports" || lower.StartsWith("reports/"));
    }

    [HttpPost("{**path}")]
    public async Task<IActionResult> ProxyPost(string path, CancellationToken ct)
    {
        if (SessionMissing() is { } unauthorized) return unauthorized;
        var lower = (path ?? "").ToLowerInvariant();
        var isValuation = lower.StartsWith("valuation");
        var isOptionList = lower.StartsWith("option-lists");   // 423
        if (lower.StartsWith("taxonomy/"))                      // 424
            return await TaxonomyPostAsync(path!, lower, ct);
        if (lower.StartsWith("notifications/mine/"))            // 437: own notices -- the API uses the stamped employee
        {
            using var mineReader = new StreamReader(Request.Body);
            var mineBody = await mineReader.ReadToEndAsync(ct);
            return await ForwardAsync(HttpMethod.Post, "api/practice/asset-config/" + path,
                string.IsNullOrWhiteSpace(mineBody) ? "{}" : mineBody, ct);
        }
        var isNotification = lower.StartsWith("notifications/");                 // 437
        var isActivity = lower.StartsWith("activities/");                        // 438
        var isRelationship = lower == "relationships" || lower.StartsWith("relationships/");   // 440
        var isService = lower == "business-services" || lower.StartsWith("business-services/");   // 441
        var isDiscovery = lower.StartsWith("discovery/");                        // 442
        var isPrivacy = lower.StartsWith("privacy/");                            // 448
        var isGovernance = lower.StartsWith("governance/");                      // 450
        var isReport = lower.StartsWith("reports/");                             // 452
        var isTechCatalog = lower.StartsWith("tech-catalog");  // 425
        var isRegister = lower == "register" || lower.StartsWith("register/");   // 428
        var isAttestation = lower.StartsWith("attestation/");                    // 431
        var isContract = lower == "contracts" || lower.StartsWith("contracts/");  // 434
        if (!isValuation && !isOptionList && !isTechCatalog && !isRegister && !isAttestation && !isContract && !isNotification
            && !isActivity && !isRelationship && !isService && !isDiscovery && !isPrivacy && !isGovernance && !isReport
            && !lower.StartsWith("templates"))
            return NotFound(new { error = "Unknown asset configuration resource." });
        var area = isReport ? ReportArea : isGovernance ? GovernanceArea : isPrivacy ? PrivacyArea : isDiscovery ? DiscoveryArea : isService ? ServiceArea : isRelationship ? RelationshipArea : isActivity ? ActivityArea : isNotification ? NotificationArea : isContract ? ContractArea : isAttestation ? AttestationArea : isRegister ? RegisterArea : isTechCatalog ? TechCatalogArea : isOptionList ? OptionListArea
                 : isValuation ? ValuationArea : TemplateArea;

        using var reader = new StreamReader(Request.Body);
        var body = await reader.ReadToEndAsync(ct);
        long organizationId = 0;
        string? toStatus = null;
        var shared = false;                                     // 425: shared technology catalogue
        long assetId = 0;                                       // 428: register save -- ADD vs EDIT
        string? decision = null;                                // 429: lifecycle change decision
        string? exceptionAction = null;                         // 432: verification exception action
        string? outcome = null;                                 // 448: privacy review outcome
        long contractId = 0;                                    // 434: contract save -- ADD vs EDIT
        long relationshipId = 0;                                // 440: relationship save -- ADD vs EDIT
        long serviceId = 0;                                     // 441: service save -- ADD vs EDIT
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return BadRequest(new { error = "Invalid request body." });
            if (doc.RootElement.TryGetProperty("organizationId", out var org)) org.TryGetInt64(out organizationId);
            if (doc.RootElement.TryGetProperty("toStatusCode", out var st) && st.ValueKind == JsonValueKind.String)
                toStatus = st.GetString()?.Trim().ToUpperInvariant();
            if (doc.RootElement.TryGetProperty("shared", out var sh) && sh.ValueKind == JsonValueKind.True)
                shared = true;
            if (doc.RootElement.TryGetProperty("assetId", out var aid) && aid.ValueKind == JsonValueKind.Number)
                aid.TryGetInt64(out assetId);
            if (doc.RootElement.TryGetProperty("decision", out var dc) && dc.ValueKind == JsonValueKind.String)
                decision = dc.GetString()?.Trim().ToUpperInvariant();
            if (doc.RootElement.TryGetProperty("action", out var ac) && ac.ValueKind == JsonValueKind.String)
                exceptionAction = ac.GetString()?.Trim().ToUpperInvariant();
            if (doc.RootElement.TryGetProperty("outcome", out var oc) && oc.ValueKind == JsonValueKind.String)
                outcome = oc.GetString()?.Trim().ToUpperInvariant();
            if (doc.RootElement.TryGetProperty("contractId", out var cid) && cid.ValueKind == JsonValueKind.Number)
                cid.TryGetInt64(out contractId);
            if (doc.RootElement.TryGetProperty("relationshipId", out var rid) && rid.ValueKind == JsonValueKind.Number)
                rid.TryGetInt64(out relationshipId);
            if (doc.RootElement.TryGetProperty("serviceId", out var sid) && sid.ValueKind == JsonValueKind.Number)
                sid.TryGetInt64(out serviceId);
        }
        catch (JsonException) { return BadRequest(new { error = "Invalid request body." }); }

        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId)) return OrganizationDenied();

        var isTransition = lower.EndsWith("/transition");
        // 421: the Preview tab's evaluate call writes nothing -- VIEW is enough.
        // evaluate (421) and calculate (422) write nothing -- VIEW is enough.
        var allowed = lower.EndsWith("/evaluate") || lower.EndsWith("/calculate")
            ? Can(area, "VIEW")
            : isNotification && lower == "notifications/profiles"   // 437
            ? Can(area, "ADD", "EDIT")
            : isNotification && lower.StartsWith("notifications/occurrences/") && lower.EndsWith("/snooze")
            ? Can(area, "APPROVE")
            : isNotification && (lower == "notifications/matrix" || lower == "notifications/run"
                                 || (lower.StartsWith("notifications/log/") && lower.EndsWith("/delivery")))
            ? Can(area, "EDIT")
            : isNotification
            ? false
            : isActivity && (lower == "activities/settings" || lower == "activities/run"     // 438
                             || (lower.StartsWith("activities/occurrences/") && lower.EndsWith("/reconcile")))
            ? Can(area, "EDIT")
            : isActivity && lower.StartsWith("activities/occurrences/")                         // 439
                         && (lower.EndsWith("/result") || lower.EndsWith("/disposition"))
            ? Can(area, "EDIT")
            : isActivity && lower.StartsWith("activities/occurrences/") && lower.EndsWith("/result-decision")
            ? Can(area, "APPROVE")
            : isActivity && lower.StartsWith("activities/dispositions/") && lower.EndsWith("/decision")
            ? (decision is "APPROVE" or "REJECT" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isActivity && lower.StartsWith("activities/reviews/") && lower.EndsWith("/decision")
            ? Can(area, "APPROVE")
            : isActivity
            ? false
            : isRelationship && lower == "relationships"              // 440: proposal ADD, change EDIT
            ? Can(area, relationshipId > 0 ? "EDIT" : "ADD")
            : isRelationship && lower.EndsWith("/action")
            ? (exceptionAction is "APPROVE" or "REJECT" or "CONFIRM" or "ACCEPT_RETIREMENT" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isRelationship
            ? false
            : isService && lower == "business-services"                // 441: new service ADD, change EDIT
            ? Can(area, serviceId > 0 ? "EDIT" : "ADD")
            : isService && lower.EndsWith("/retirement-decision")
            ? (decision is "APPROVE" or "REJECT" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isService && (lower.EndsWith("/transition") || lower == "business-services/settings")
            ? Can(area, "EDIT")
            : isService
            ? false
            : isDiscovery && lower.StartsWith("discovery/exceptions/") && lower.EndsWith("/resolve")   // 442
            ? (exceptionAction == "ACCEPT_OBSERVED" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isDiscovery && (lower.StartsWith("discovery/merges/") || lower.StartsWith("discovery/splits/")) && lower.EndsWith("/action")   // 444 / 445
            ? (exceptionAction is "APPROVE" or "REJECT" ? Can(area, "APPROVE")
               : exceptionAction == "RECOVER" ? Can(area, "APPROVE") && Can(RegisterArea, "EDIT")
               : exceptionAction == "EXECUTE" ? Can(area, "EDIT") && Can(RegisterArea, "EDIT")
               : Can(area, "EDIT"))
            : isDiscovery && (lower == "discovery/merges" || lower == "discovery/splits")             // 444 / 445
            ? Can(area, "EDIT")
            : isDiscovery && lower.StartsWith("discovery/stale/reviews/") && lower.EndsWith("/action")   // 443
            ? (exceptionAction == "REQUEST_DECOMMISSION" ? Can(area, "EDIT") && Can(RegisterArea, "EDIT") : Can(area, "EDIT"))
            : isDiscovery && (lower == "discovery/stale/settings" || lower == "discovery/stale/reviews")   // 443
            ? Can(area, "EDIT")
            : isDiscovery && (lower == "discovery/sources" || lower == "discovery/rules" || lower == "discovery/settings"
                              || (lower.StartsWith("discovery/sources/") && (lower.EndsWith("/priorities") || lower.EndsWith("/batches"))))
            ? Can(area, "EDIT")
            : isDiscovery
            ? false
            : isPrivacy && lower.StartsWith("privacy/exceptions/") && lower.EndsWith("/action")   // 448
            ? (exceptionAction is "APPROVE" or "REJECT" or "REVOKE" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isPrivacy && lower.StartsWith("privacy/reviews/") && lower.EndsWith("/complete")    // 448: an extension is approved
            ? (outcome == "EXTEND" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isPrivacy && (lower == "privacy/requirements" || lower == "privacy/exceptions" || lower == "privacy/run")
            ? Can(area, "EDIT")
            : isPrivacy
            ? false
            : isGovernance && (lower == "governance/settings" || lower == "governance/settings/overall"   // 450
                               || lower == "governance/relationship-rules" || lower == "governance/snapshot")
            ? Can(area, "EDIT")
            : isGovernance
            ? false
            : isReport && lower.StartsWith("reports/") && lower.EndsWith("/export")   // 452: policy / approver in SQL
            ? Can(area, "VIEW")
            : isReport && lower == "reports/settings"
            ? Can(area, "EDIT")
            : isReport && lower.StartsWith("reports/deliveries/recipients/") && lower.EndsWith("/download")   // 453: recipient in SQL
            ? Can(area, "VIEW")
            : isReport && (lower == "reports/schedules" || (lower.StartsWith("reports/schedules/") && lower.EndsWith("/run")))   // 453
            ? Can(area, "EDIT")
            : isReport
            ? false
            : isContract && lower == "contracts"                 // 434: new contract ADD, existing contract EDIT
            ? Can(area, contractId > 0 ? "EDIT" : "ADD")
            : isContract && lower.StartsWith("contracts/versions/") && lower.EndsWith("/action")
            ? (exceptionAction is "APPROVE" or "REJECT" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isContract && lower.StartsWith("contracts/contacts/") && lower.EndsWith("/action")
            ? (exceptionAction == "VALIDATE" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isContract && lower.StartsWith("contracts/renewals/") && lower.EndsWith("/action")   // 436
            ? (exceptionAction is "APPROVE" or "RETURN" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isContract
            ? Can(area, "EDIT")
            : isAttestation && lower == "attestation/profiles"   // 431
            ? Can(area, "ADD", "EDIT")
            : isAttestation && lower == "attestation/generate"
            ? Can(area, "ADD")
            : isAttestation && lower.EndsWith("/respond")        // assignee identity enforced in SQL
            ? Can(area, "VIEW")
            : isAttestation && lower.StartsWith("attestation/exceptions/") && lower.EndsWith("/action")   // 432
            ? (exceptionAction is "APPROVE" or "REJECT" or "REASSIGN" or "CANCEL" ? Can(area, "APPROVE") : Can(area, "VIEW"))
            : isAttestation && (lower == "attestation/exception-settings" || lower == "attestation/exception-rules")
            ? Can(area, "EDIT")
            : isAttestation && lower.EndsWith("/decide")         // manager identity enforced in SQL; cancel needs APPROVE
            ? (decision == "CANCEL" ? Can(area, "APPROVE") : Can(area, "VIEW"))
            : isAttestation
            ? false
            : isRegister && lower.EndsWith("/decide")            // 429 / 430: lifecycle change, technology exception
            ? (decision is "APPROVE" or "REJECT" or "REVOKE" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isRegister && lower.Contains("/technology/")       // 430: installation record, exception request
            ? Can(area, "EDIT")
            : isRegister && lower.StartsWith("register/workflows/") && lower.EndsWith("/step")   // 433
            ? (exceptionAction is "APPROVE" or "REJECT" ? Can(area, "APPROVE")
               : exceptionAction is "CONFIRM" or "DECLINE" ? Can(area, "VIEW") : Can(area, "EDIT"))
            : isRegister && (lower.EndsWith("/workflows") || (lower.StartsWith("register/workflows/") && lower.EndsWith("/cancel")))
            ? Can(area, "EDIT")
            : isRegister && isTransition                         // 429: lifecycle transition (approval gates in SQL)
            ? Can(area, "EDIT")
            : isRegister && lower.EndsWith("/valuation/recalculate")   // 446: one asset now
            ? Can(area, "EDIT")
            : isRegister && lower.StartsWith("register/consistency/findings/") && lower.EndsWith("/action")   // 447
            ? (exceptionAction is "APPROVE" or "REJECT" or "REVOKE" ? Can(area, "APPROVE") : Can(area, "EDIT"))
            : isRegister && lower == "register/consistency/run"      // 447: re-evaluate
            ? Can(area, "EDIT")
            : isRegister && lower.EndsWith("/valuation/method")        // 446: method override -- authorized role (5.1.18.5.3)
            ? Can(area, "APPROVE")
            : isRegister                                         // 428: new asset ADD, existing asset EDIT
            ? Can(area, assetId > 0 ? "EDIT" : "ADD")
            : lower.EndsWith("/approve")                         // 426: firmware compatibility approval
            ? Can(area, "APPROVE")
            : isValuation && lower == "valuation/recalculation"    // 446: controlled recalculation run
            ? Can(area, "APPROVE")
            : isValuation && lower.StartsWith("valuation/consistency/rules/") && lower.EndsWith("/action")   // 447
            ? (exceptionAction is "ACTIVATE" or "RETIRE" ? Can(area, "APPROVE") : Can(area, "ADD", "EDIT"))
            : isTransition && toStatus == "APPROVED"
            ? Can(area, "APPROVE")
            : isTransition && toStatus == "DRAFT"
                ? Can(area, "ADD", "EDIT", "APPROVE")
                : Can(area, "ADD", "EDIT");
        if (!allowed) return Denied();
        // 425: the shared catalogue reaches every organization.
        if (isTechCatalog && shared && !Roles().Any(r => r.Equals(PlatformAdminRole, StringComparison.OrdinalIgnoreCase)))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "The shared technology catalogue is maintained by the platform administrator." });

        return await ForwardAsync(HttpMethod.Post, "api/practice/asset-config/" + path, body, ct, reportCaller: isReport);
    }

    // 424: the taxonomy masters are global -- one change reaches every
    // organization -- so only the platform administrator may write them.
    // The organization defaults of a type follow the usual organization +
    // menu-grant rule.
    private async Task<IActionResult> TaxonomyPostAsync(string path, string lower, CancellationToken ct)
    {
        using var reader = new StreamReader(Request.Body);
        var body = await reader.ReadToEndAsync(ct);
        if (lower.EndsWith("/org-defaults"))
        {
            long organizationId = 0;
            try
            {
                using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
                if (doc.RootElement.ValueKind != JsonValueKind.Object) return BadRequest(new { error = "Invalid request body." });
                if (doc.RootElement.TryGetProperty("organizationId", out var org)) org.TryGetInt64(out organizationId);
            }
            catch (JsonException) { return BadRequest(new { error = "Invalid request body." }); }
            if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(organizationId)) return OrganizationDenied();
            if (!Can(TaxonomyArea, "EDIT")) return Denied();
        }
        else if (lower is "taxonomy/categories" or "taxonomy/subcategories" or "taxonomy/types")
        {
            if (!Roles().Any(r => r.Equals(PlatformAdminRole, StringComparison.OrdinalIgnoreCase)) || !Can(TaxonomyArea, "ADD", "EDIT"))
                return StatusCode(StatusCodes.Status403Forbidden,
                    new { error = "The asset taxonomy is shared by every organization; only the platform administrator can change it." });
        }
        else
            return NotFound(new { error = "Unknown asset configuration resource." });

        return await ForwardAsync(HttpMethod.Post, "api/practice/asset-config/" + path, body, ct);
    }

    // 452: set from the session (never from the browser): the report screens the caller may VIEW and whether the
    // caller holds Asset Reports APPROVE (exports whose policy needs an approver).
    private void StampReportCaller(HttpRequestMessage msg)
    {
        msg.Headers.Remove(CallerReportAreasHeader);
        msg.Headers.Remove(CallerReportApproveHeader);
        msg.Headers.TryAddWithoutValidation(CallerReportAreasHeader,
            string.Join(",", ReportScreenAreas.Where(a => Can(a, "VIEW"))));
        msg.Headers.TryAddWithoutValidation(CallerReportApproveHeader, Can(ReportArea, "APPROVE") ? "1" : "0");
    }

    private IActionResult? SessionMissing() =>
        string.IsNullOrWhiteSpace(HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey))
            ? Unauthorized(new { error = "Session expired. Please sign in again." })
            : null;

    private IActionResult OrganizationDenied() =>
        StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller is not authorised for the requested organization." });

    private IActionResult Denied() =>
        StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });

    private async Task<IActionResult> ForwardAsync(HttpMethod method, string relativeUrl, string? body, CancellationToken ct,
        bool reportCaller = false)
    {
        try
        {
            using var msg = new HttpRequestMessage(method, relativeUrl);
            if (body is not null)
            {
                msg.Content = new StringContent(body);
                msg.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
            if (reportCaller) StampReportCaller(msg);                            // 452
            var client = BuildClient();
            if (reportCaller) client.Timeout = TimeSpan.FromMinutes(5);           // 452: whole-organization reports and exports
            if (relativeUrl.Contains("/discovery/sources/", StringComparison.OrdinalIgnoreCase)
                && relativeUrl.EndsWith("/batches", StringComparison.OrdinalIgnoreCase))
                client.Timeout = TimeSpan.FromMinutes(10);                       // 442: batch ingestion
            if (relativeUrl.EndsWith("/valuation/recalculation", StringComparison.OrdinalIgnoreCase) && method == HttpMethod.Post)
                client.Timeout = TimeSpan.FromMinutes(10);                       // 446: recalculation run
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
            logger.LogError(ex, "AssetConfig proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
