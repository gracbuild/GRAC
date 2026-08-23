// =====================================================================
// OrgRoleLookupController
//
// Route: /api/practice/org-roles
//
// Read-only endpoints used by the Role -> Employee two-step picker
// added in 116a/116b. Both endpoints wrap SPs from migration 117 and
// the pre-existing sp_org_assurance_organization_role_list (084).
//
//   GET  /                        list roles for an org
//   GET  /{roleId}/holders        list current active holders of a role
// =====================================================================
using System.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Infrastructure;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-roles")]
public sealed class OrgRoleLookupController(
    IConfiguration configuration,
    ILogger<OrgRoleLookupController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> ListRoles(
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = new List<object>();
            var connString = SqlConnectionStringResolver.Resolve(configuration);
            await using var connection = new SqlConnection(connString);
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_organization_role_list";
            var p = command.CreateParameter();
            p.ParameterName = "@organization_id";
            p.DbType = DbType.Int64;
            p.Value = organizationId.Value;
            command.Parameters.Add(p);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new
                {
                    roleId   = reader["RoleId"]   == DBNull.Value ? (long?)null : Convert.ToInt64(reader["RoleId"]),
                    roleName = reader["RoleName"]?.ToString() ?? ""
                });
            }
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRoleLookupController.ListRoles failed for org {OrgId}", organizationId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("{roleId:long}/holders")]
    public async Task<IActionResult> ListHolders(
        long roleId,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = new List<object>();
            var connString = SqlConnectionStringResolver.Resolve(configuration);
            await using var connection = new SqlConnection(connString);
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_role_holders_list";
            var pOrg = command.CreateParameter();
            pOrg.ParameterName = "@organization_id";
            pOrg.DbType = DbType.Int64;
            pOrg.Value = organizationId.Value;
            command.Parameters.Add(pOrg);
            var pRole = command.CreateParameter();
            pRole.ParameterName = "@role_id";
            pRole.DbType = DbType.Int64;
            pRole.Value = roleId;
            command.Parameters.Add(pRole);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new
                {
                    employeeId   = Convert.ToInt64(reader["EmployeeId"]),
                    employeeCode = reader["EmployeeCode"]?.ToString() ?? "",
                    employeeName = reader["EmployeeName"]?.ToString() ?? "",
                    email        = reader["Email"]        == DBNull.Value ? null : reader["Email"]?.ToString(),
                    designation  = reader["Designation"]  == DBNull.Value ? null : reader["Designation"]?.ToString(),
                    department   = reader["Department"]   == DBNull.Value ? null : reader["Department"]?.ToString(),
                    roleId       = Convert.ToInt64(reader["RoleId"]),
                    roleName     = reader["RoleName"]?.ToString() ?? ""
                });
            }
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRoleLookupController.ListHolders failed for org {OrgId} role {RoleId}", organizationId, roleId);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
