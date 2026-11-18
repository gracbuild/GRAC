// =====================================================================
// OrgRegistryModels  (migrations 569-572)
//
// Contracts for OrgRegistryController: Organization Management ->
// Organization Registry. The registry is the organization master data of
// workbook "GRAC_Organization_Registry" sheets 01-13; the field rules live
// in the sp_orgreg_<area>_save procedures, so the payload is passed through
// as the JSON the screen built (keys = the field keys of the area).
// Own file per charter section 5.
// =====================================================================
using System.Text.Json;

namespace PracticeManagement.Api.Models;

/// <summary>Save one registry record. Data is the form as a JSON object
/// (keys = field keys, reference fields as ids, multi-selects as arrays).
/// Actor is the sign-in that saved -- set by the Web tier from the session,
/// never by the browser.</summary>
/// AllowedLegalEntityIds (575): null for GRAC administration; otherwise the
/// caller's organization ids, set by the Web tier from the session.
public sealed record OrgRegistrySaveRequest(JsonElement? Data, string? Actor, long[]? AllowedLegalEntityIds);

/// <summary>Outcome of a save. Field is the field key the procedure named
/// when it refused the record ("[fieldKey] message"), for the screen to mark.</summary>
public sealed record OrgRegistrySaveResult(bool Success, string Message, long? Id, string? Field);
