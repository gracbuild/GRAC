"""Generates wwwroot/js/Organization/org-registry-fields.js from spec.py."""
import json
from spec import ENTITIES

LIST = {
    "organizations": ["organizationCode", "registeredName", "organizationType", "industry", "city", "recordStatus"],
    "legal-entities": ["legalEntityCode", "legalName", "registryOrganizationId", "entityType", "parentLegalEntityId", "inScopeForGrac", "recordStatus"],
    "units": ["unitCode", "unitName", "unitType", "parentUnitId", "legalEntityId", "isOperational", "recordStatus"],
    "locations": ["locationCode", "locationName", "locationType", "legalEntityId", "organizationUnitId", "cityTown", "customerFacing", "operationalStatus"],
    "departments": ["departmentCode", "departmentName", "departmentType", "legalEntityId", "primaryOrganizationUnitId", "departmentHeadPersonId", "recordStatus"],
    "functions": ["functionCode", "functionName", "functionCategory", "criticality", "legalEntityId", "accountableDepartmentId", "functionOwnerPersonId", "recordStatus"],
    "teams": ["teamCode", "teamName", "teamType", "teamSourcing", "legalEntityId", "parentDepartmentId", "teamManagerPersonId", "recordStatus"],
    "people": ["personCode", "fullName", "personCategory", "designation", "legalEntityId", "departmentId", "personStatus", "recordStatus"],
    "committees": ["committeeCode", "committeeName", "committeeType", "legalEntityId", "chairpersonPersonId", "reviewFrequency", "recordStatus"],
    "committee-members": ["membershipCode", "committeeId", "personId", "designationInCommittee", "memberSince", "votingMember", "recordStatus"],
    "processes": ["processCode", "processName", "processLevel", "processNature", "legalEntityId", "owningDepartmentId", "processOwnerPersonId", "recordStatus"],
    "products": ["productCode", "productName", "productCategory", "legalEntityId", "owningDepartmentId", "productStatus"],
    "channels": ["channelCode", "channelName", "channelType", "legalEntityId", "customerFacing", "channelStatus"],
}

STATUS_FIELD = {e["key"]: next(f["key"] for f in e["fields"] if f["col"] == e["status_col"]) for e in ENTITIES}

def gen():
    areas = []
    for e in ENTITIES:
        fields = []
        for f in e["fields"]:
            d = {"key": f["key"], "label": f["label"].rstrip("*").strip(), "kind": f["kind"], "required": f["required"]}
            if f["kind"] in ("master", "multimaster", "locationtype", "designation", "timezone"):
                d["group"] = f["group"] or ("LocationType" if f["kind"] == "locationtype" else "CommitteeMemberDesignation")
            if f.get("default"):
                d["default"] = f["default"]
            if f["kind"] == "choice":
                d["choices"] = [{"value": c, "label": n} for c, n in f["choices"]]
            if f["kind"] in ("ref", "multiref"):
                d["ref"] = f["ref"]
                d["scope"] = f["scope"]
            if f["length"]:
                d["maxLength"] = f["length"]
            if f["kind"] in ("textarea",) or f["key"] in ("dataQualityNote",):
                d["full"] = True
            if f["app"]:
                d["app"] = True
            if f["note"]:
                d["note"] = f["note"]
            if f["key"] == "dataQualityNote":
                d["readonly"] = True
            if e.get("status_only_active_inactive") and f["key"] == "recordStatus":
                d["only"] = ["Active", "Inactive"]
            fields.append(d)
        areas.append({"key": e["key"], "title": e["title"], "single": e["single"], "sheet": e["sheet"],
                      "prefix": e["prefix"], "statusField": STATUS_FIELD[e["key"]],
                      "listColumns": LIST[e["key"]], "fields": fields})
    body = json.dumps(areas, indent=2, ensure_ascii=True)
    return f"""// =====================================================================
// org-registry-fields.js  (migrations 569-572) -- GENERATED, do not edit.
//
// window.gracOrgRegistryFields: the Organization Registry's thirteen areas
// and their fields, one entry per workbook column of sheets 01-13 (label =
// the workbook header without its '*'). Generated from the same field
// specification as migrations 569 / 571 / 572, so the screen, the save
// procedures and the sample-data import cannot drift apart. To change a
// field, change the specification and regenerate all four.
//
// kind: code text textarea date decimal number ddmm email url
//       master (group)        a controlled value of 15 Masters & Codes
//       locationtype          LocationType (location_type_master)
//       designation           CommitteeMemberDesignation (committee_designation_master)
//       timezone              TimeZone (GRAC_New.time_zone_master; empty if not deployed)
//       choice (choices)      a code of a fixed list, shown by its label
//       ref (ref, scope)      one record of another area; scope le / org / any
//       multiref / multimaster  several of them
// app: a GRAC link the workbook has no column for (see note).
// =====================================================================
window.gracOrgRegistryFields = {body};
"""

if __name__ == "__main__":
    print(gen())
