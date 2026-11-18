// =====================================================================
// OrgRegistryController  (migrations 569-572)
//
// Route: /api/practice/org-registry/...
//   GET  /lookups?registryOrganizationId=&legalEntityId=
//                          controlled values (sheet 15) + pickable records
//   GET  /summary?registryOrganizationId=
//                          Legal Entities with per-area record counts
//   GET  /{area}?registryOrganizationId=&legalEntityId=&id=&status=&search=
//                          one registry area's rows
//   POST /{area}           create  { data: {...}, actor }
//   PUT  /{area}/{id}      update  { data: {...}, actor }
//
// {area}: organizations, legal-entities, units, locations, departments,
// functions, teams, people, committees, committee-members, processes,
// products, channels (OrgRegistryService.Areas). There is no DELETE: a
// registry record is retired through its status and kept for traceability.
//
// registryOrganizationId: 0 = every Organization, -1 = Legal Entities not
// yet assigned to an Organization.
//
// allowedLegalEntityIds (575, query on GET, body on POST/PUT): absent for
// GRAC administration; otherwise the caller's organization ids -- reads and
// writes are confined to them and Organizations / Legal Entities are
// read-only. Set by the Web tier from the session, never by the browser.
//
// The Web tier (OrgRegistryController there) decides who may call this:
// the calling screen's grant (VIEW / ADD / EDIT) -- org-registry also needs
// a GLOBAL-scope sign-in; the Practice Management screens send
// allowedLegalEntityIds ("0" = none). It also sets Actor from the session;
// this controller never trusts a browser for it.
// =====================================================================
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-registry")]
public sealed class OrgRegistryController(
    IOrgRegistryService registryService,
    ILogger<OrgRegistryController> logger) : ControllerBase
{
    [HttpGet("lookups")]
    public async Task<IActionResult> Lookups([FromQuery] long registryOrganizationId = 0, [FromQuery] long legalEntityId = 0,
        [FromQuery] string? allowedLegalEntityIds = null, CancellationToken cancellationToken = default)
    {
        try
        {
            return Ok(new { data = await registryService.LookupsAsync(registryOrganizationId, legalEntityId, ParseAllowed(allowedLegalEntityIds), cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRegistryController.Lookups failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("summary")]
    public async Task<IActionResult> Summary([FromQuery] long registryOrganizationId = 0, [FromQuery] string? allowedLegalEntityIds = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            return Ok(new { data = await registryService.SummaryAsync(registryOrganizationId, ParseAllowed(allowedLegalEntityIds), cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRegistryController.Summary failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("{area}")]
    public async Task<IActionResult> List(string area,
        [FromQuery] long registryOrganizationId = 0, [FromQuery] long legalEntityId = 0, [FromQuery] long id = 0,
        [FromQuery] string? status = "", [FromQuery] string? search = "", [FromQuery] string? allowedLegalEntityIds = null,
        CancellationToken cancellationToken = default)
    {
        if (!registryService.IsArea(area)) return NotFound(new { error = $"Unknown registry area '{area}'." });
        try
        {
            return Ok(new { data = await registryService.ListAsync(area, registryOrganizationId, legalEntityId, id, status, search, ParseAllowed(allowedLegalEntityIds), cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRegistryController.List failed for {Area}", area);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{area}")]
    public Task<IActionResult> Create(string area, [FromBody] OrgRegistrySaveRequest body, CancellationToken cancellationToken) =>
        SaveAsync(area, 0, body, cancellationToken);

    [HttpPut("{area}/{id:long}")]
    public Task<IActionResult> Update(string area, long id, [FromBody] OrgRegistrySaveRequest body, CancellationToken cancellationToken) =>
        SaveAsync(area, id, body, cancellationToken);

    // "1,2,3" -> [1,2,3]; absent -> null (every Legal Entity); present but
    // empty ("none") -> [] (nothing). Set by the Web tier, never the browser.
    private static long[]? ParseAllowed(string? raw)
    {
        if (raw is null) return null;
        return raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                  .Select(t => long.TryParse(t, out var v) ? v : 0).Where(v => v > 0).Distinct().ToArray();
    }

    private async Task<IActionResult> SaveAsync(string area, long id, OrgRegistrySaveRequest? body, CancellationToken cancellationToken)
    {
        if (!registryService.IsArea(area)) return NotFound(new { error = $"Unknown registry area '{area}'." });
        if (body?.Data is not { ValueKind: JsonValueKind.Object } data)
            return BadRequest(new { error = "data is required (the record as a JSON object)." });
        if (string.IsNullOrWhiteSpace(body.Actor))
            return BadRequest(new { error = "actor is required." });

        try
        {
            var result = await registryService.SaveAsync(area, id, data.GetRawText(), body.Actor.Trim(), body.AllowedLegalEntityIds, cancellationToken);
            return result.Success
                ? Ok(new { success = true, message = result.Message, id = result.Id })
                : BadRequest(new { success = false, error = result.Message, field = result.Field });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRegistryController.Save failed for {Area} {Id}", area, id);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
