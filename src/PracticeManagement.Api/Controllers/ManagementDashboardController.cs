// =====================================================================
// ManagementDashboardController  (migration 414)
//
// Route: /api/practice/management-dashboard/{module}?organizationId=
//   module = governance | issues-actions | audit-assurance
//
// One read per dashboard: KPIs, ageing bands, distributions and lists
// in a single response (ManagementDashboard). The Web tier checks the
// session and the organization; the caller (employee id, admin flag)
// comes from the X-PM-Caller-* headers it stamps from the SESSION, and
// only Governance uses it (Operationalize's ownership rule).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/management-dashboard")]
public sealed class ManagementDashboardController(
    IManagementDashboardService dashboardService,
    ILogger<ManagementDashboardController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    [HttpGet("{module}")]
    public async Task<IActionResult> Get(string module, [FromQuery] long organizationId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var dashboard = await dashboardService.GetAsync(module, organizationId,
                CallerEmployeeId, CallerIsAdmin, cancellationToken);
            return dashboard is null
                ? NotFound(new { error = $"Unknown dashboard '{module}'." })
                : Ok(dashboard);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ManagementDashboard {Module} failed for organization {OrganizationId}", module, organizationId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = ex.Message });
        }
    }
}
