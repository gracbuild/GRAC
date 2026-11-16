// =====================================================================
// ManagementDashboardController  (migration 414)
//
// Route: /api/practice/management-dashboard/{module}?organizationId=
//   module = governance | issues-actions | audit-assurance
//
// One read per dashboard: KPIs, ageing bands, distributions and lists
// (501 + notConfigured:true when the module's procedure is missing, 503)
// in a single response (ManagementDashboard). The Web tier checks the
// session and the organization; the caller (employee id, admin flag)
// comes from the X-PM-Caller-* headers it stamps from the SESSION, and
// only Governance uses it (Operationalize's ownership rule).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
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
        // 503: the module's dashboard procedure is not in this database (its
        // migration was never applied -- e.g. TPRM's 490). That is "not set
        // up", not a failure: say so, so Home and the dashboard page show a
        // neutral "not set up" state instead of an error or zeros (spec 3.4).
        catch (SqlException ex) when (ex.Number == 2812)
        {
            logger.LogWarning("ManagementDashboard {Module}: procedure missing in this database ({Message})", module, ex.Message);
            return StatusCode(StatusCodes.Status501NotImplemented, new
            {
                error = "This module is not set up in this database yet (its database migration has not been applied).",
                notConfigured = true
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ManagementDashboard {Module} failed for organization {OrganizationId}", module, organizationId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = ex.Message });
        }
    }
}
