// =====================================================================
// OrganizationSsoSettingController  (migration 466 -- organization-wise SSO)
//
// Route: /api/practice/org-sso
//   GET  ?organizationId=     the organization's SSO policy (defaults = off)
//   POST { organizationId, ssoEnabled, allowMicrosoft, allowGoogle,
//          microsoftTenantIds, allowedEmailDomains, loginMode }
//        save it (SSO_AND_PASSWORD | SSO_ONLY)
//        467: + autoCreateUsers, defaultRoleId, requireAdminApproval
//   POST /approve-user { organizationId, employeeId }
//        467: approve a user created by SSO that waits for approval
//        (Organization Administration -> Users tab -> Approve)
//
// Read and written by Organization Administration -> Organization tab ->
// "Single Sign-On". The Web proxy checks the session, the organization and
// the organization-administration grant (VIEW to read, ADD|EDIT to save); the
// procedure validates the values. Enforcement is at sign-in
// (PracticeAuthenticationService). docs/single-sign-on.md.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-sso")]
public sealed class OrganizationSsoSettingController(
    IOrganizationSsoSettingService service,
    ILogger<OrganizationSsoSettingController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private string Actor =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0
            ? $"employee:{id}" : "system";

    [HttpGet]
    public async Task<IActionResult> Get([FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var row = await service.GetAsync(organizationId, cancellationToken);
            return row is null ? NotFound(new { error = "Organization not found." }) : Ok(row);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Organization SSO setting get failed for organization {OrganizationId}", organizationId);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = ex.Message });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Save([FromBody] OrganizationSsoSettingSaveRequest request, CancellationToken cancellationToken)
    {
        if (request is null || request.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var result = await service.SaveAsync(request, Actor, cancellationToken);
        return result.Success ? Ok(result) : BadRequest(new { error = result.Error });
    }

    [HttpPost("approve-user")]
    public async Task<IActionResult> ApproveUser([FromBody] OrganizationSsoUserApproveRequest request, CancellationToken cancellationToken)
    {
        if (request is null || request.OrganizationId <= 0 || request.EmployeeId <= 0)
            return BadRequest(new { error = "organizationId and employeeId are required." });
        var error = await service.ApproveUserAsync(request, Actor, cancellationToken);
        return error is null ? Ok(new { success = true }) : BadRequest(new { error });
    }
}
