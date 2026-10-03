// =====================================================================
// RoleViewDataScopeController  (migration 415 -- View Data Scope)
//
// Route: /api/practice/roles/{roleId}/view-data-scope
//   GET  ?organizationId=                 the role's View Data Scope
//   POST { organizationId, viewDataScope } set it (ALL | LOCATION | TEAM | OWNER)
//
// Read and written by the Role Menu Permission section's "Advanced
// Settings". The Web proxy checks the session, the organization and the
// same grant the permission matrix needs (role-menu-permissions
// VIEW / ADD|EDIT); the procedure checks the role belongs to the
// organization.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/roles/{roleId:long}/view-data-scope")]
public sealed class RoleViewDataScopeController(
    IRoleViewDataScopeService service,
    ILogger<RoleViewDataScopeController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private string Actor =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0
            ? $"employee:{id}" : "system";

    [HttpGet]
    public async Task<IActionResult> Get(long roleId, [FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var row = await service.GetAsync(organizationId, roleId, cancellationToken);
            return row is null ? NotFound(new { error = "Role not found." }) : Ok(row);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RoleViewDataScope get failed for role {RoleId}", roleId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Save(long roleId, [FromBody] RoleViewDataScopeSaveRequest request, CancellationToken cancellationToken)
    {
        if (request is null || request.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var result = await service.SaveAsync(roleId, request, Actor, cancellationToken);
        return result.Success ? Ok(result) : BadRequest(new { error = result.Error });
    }
}
