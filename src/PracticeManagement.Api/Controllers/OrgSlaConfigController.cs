// =====================================================================
// OrgSlaConfigController
//
// Organization SLA Configuration API surface (migrations 178/179/180).
//
// Route: /api/practice/org-sla
// Sub-routes:
//   GET  /masters                                       Control Mgmt SLA master list (defensive discovery of grac_new.sla_master)
//   (GET /process-types retired in 186)
//   GET  /configs?organizationId=&search=&page=&pageSize=  Grid list
//   GET  /configs/{id}?organizationId=                  Detail (header + notify roles + process bindings)
//   POST /configs                                       Adopt new or update existing config
//   POST /configs/{id}/notify-roles                     Full replacement of notify roles
//   (POST /configs/{id}/process-bindings retired in 186)
//   (GET  /for-process                     retired in 186)
//
// Follows the OrgAssuranceDefinitionController / TaskController style:
// thin, delegates to IOrgSlaConfigService, plain JSON envelope
// { data: ... } for reads and { success, ... } for writes.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-sla")]
public sealed class OrgSlaConfigController(
    IOrgSlaConfigService service,
    ILogger<OrgSlaConfigController> logger) : ControllerBase
{
    // ================================================================
    // Lookups
    // ================================================================

    [HttpGet("masters")]
    public async Task<IActionResult> ListSlaMasters(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListSlaMastersAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.ListSlaMasters failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // GET /process-types + related endpoints removed in migration 186.

    // ================================================================
    // Master-first grid (post-181). Preferred entry point for the
    // SLA Configuration screen: returns every active SLA master for
    // the org plus its Not Configured / Active / Inactive status.
    // ================================================================
    [HttpGet("masters-with-config")]
    public async Task<IActionResult> ListMastersWithConfig(
        [FromQuery] long? organizationId,
        [FromQuery] string? search,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListMastersWithConfigAsync(
                new OrgSlaMasterGridQuery(organizationId.Value, search),
                cancellationToken);
            return Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.ListMastersWithConfig failed for org {OrgId}", organizationId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Legacy config grid (pre-181). Retained for callers that want
    // only the adopted rows; not used by the redesigned UI.
    // ================================================================

    [HttpGet("configs")]
    public async Task<IActionResult> ListConfigs(
        [FromQuery] long? organizationId,
        [FromQuery] string? search,
        [FromQuery] int? page,
        [FromQuery] int? pageSize,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListAsync(
                new OrgSlaConfigListQuery(
                    OrganizationId: organizationId.Value,
                    Search:         search,
                    Page:           page ?? 1,
                    PageSize:       pageSize ?? 25),
                cancellationToken);
            return Ok(new { data = result });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.ListConfigs failed for org {OrgId}", organizationId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Detail
    // ================================================================

    [HttpGet("configs/{id:long}")]
    public async Task<IActionResult> GetConfig(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var detail = await service.GetAsync(organizationId.Value, id, cancellationToken);
            if (detail is null) return NotFound(new { error = "SLA config not found." });
            return Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.GetConfig failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Mutations
    // ================================================================

    [HttpPost("configs")]
    public async Task<IActionResult> UpsertConfig(
        [FromBody] OrgSlaConfigUpsertRequest request,
        CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { error = "Request body is required." });
        if (request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.SlaMasterId    <= 0) return BadRequest(new { error = "slaMasterId is required." });
        if (request.WarningPct    < 0 || request.WarningPct    > 100)
            return BadRequest(new { error = "warningPct must be between 0 and 100." });
        if (request.EscalationPct < 0 || request.EscalationPct > 100)
            return BadRequest(new { error = "escalationPct must be between 0 and 100." });
        if (request.WarningPct > request.EscalationPct)
            return BadRequest(new { error = "warningPct must be <= escalationPct (WARNING fires before ESCALATION)." });

        try
        {
            var result = await service.UpsertAsync(request, cancellationToken);
            if (!result.Success) return BadRequest(new { error = result.Error });
            return Ok(new { success = true, orgSlaConfigId = result.OrgSlaConfigId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.UpsertConfig failed for org {OrgId}", request.OrganizationId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("configs/{id:long}/notify-roles")]
    public async Task<IActionResult> SetNotifyRoles(
        long id,
        [FromBody] OrgSlaNotifyRoleSetRequest request,
        CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { error = "Request body is required." });
        if (request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.OrgSlaConfigId != id) return BadRequest(new { error = "orgSlaConfigId mismatch." });

        try
        {
            var result = await service.SetNotifyRolesAsync(request, cancellationToken);
            if (!result.Success) return BadRequest(new { error = result.Error });
            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.SetNotifyRoles failed for config {ConfigId}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // POST /configs/{id}/process-bindings removed in migration 186.

    // ================================================================
    // Set Active / Inactive (181). Toggle keyed by master id so the
    // handler works uniformly from either state on the grid.
    // ================================================================
    [HttpPost("configs/set-active")]
    public async Task<IActionResult> SetActive(
        [FromBody] OrgSlaConfigSetActiveRequest request,
        CancellationToken cancellationToken)
    {
        if (request is null) return BadRequest(new { error = "Request body is required." });
        if (request.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (request.SlaMasterId    <= 0) return BadRequest(new { error = "slaMasterId is required." });

        try
        {
            var result = await service.SetActiveAsync(request, cancellationToken);
            if (!result.Success) return BadRequest(new { error = result.Error });
            return Ok(new { success = true });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgSlaConfigController.SetActive failed for master {MasterId}", request.SlaMasterId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // GET /for-process removed in migration 186 -- resolver retired.
}
