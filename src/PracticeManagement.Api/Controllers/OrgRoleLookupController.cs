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
//   GET  /responsibility-holders  553: active people whose role carries a
//        ?organizationId=&code=   Role Responsibility (Role Master), e.g.
//                                 code=AUDITOR for the Audit Plan
//                                 engagement's Assigned Auditor
//                                 (sp_org_responsibility_holder_list)
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
            await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
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
            await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
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

    // 553: people whose role carries a responsibility (Role Master's
    // Responsibilities), e.g. code=AUDITOR -- the engagement's auditors.
    [HttpGet("responsibility-holders")]
    public async Task<IActionResult> ListResponsibilityHolders(
        [FromQuery] long? organizationId,
        [FromQuery] string? code,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(code))
            return BadRequest(new { error = "code is required." });

        try
        {
            var rows = new List<object>();
            var connString = SqlConnectionStringResolver.Resolve(configuration);
            await using var connection = new SqlConnection(connString);
            await connection.OpenAsync(cancellationToken);
            await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_responsibility_holder_list";
            var pOrg = command.CreateParameter();
            pOrg.ParameterName = "@organization_id";
            pOrg.DbType = DbType.Int64;
            pOrg.Value = organizationId.Value;
            command.Parameters.Add(pOrg);
            var pCode = command.CreateParameter();
            pCode.ParameterName = "@responsibility_code";
            pCode.DbType = DbType.String;
            pCode.Size = 60;
            pCode.Value = code.Trim();
            command.Parameters.Add(pCode);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                rows.Add(new
                {
                    employeeId   = Convert.ToInt64(reader["EmployeeId"]),
                    employeeCode = reader["EmployeeCode"]?.ToString() ?? "",
                    employeeName = reader["EmployeeName"]?.ToString() ?? "",
                    designation  = reader["Designation"] == DBNull.Value ? null : reader["Designation"]?.ToString(),
                    roleId       = Convert.ToInt64(reader["RoleId"]),
                    roleName     = reader["RoleName"]?.ToString() ?? ""
                });
            }
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgRoleLookupController.ListResponsibilityHolders failed for org {OrgId} code {Code}", organizationId, code);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
