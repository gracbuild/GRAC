// =====================================================================
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
window.gracOrgRegistryFields = [
  {
    "key": "organizations",
    "title": "Organizations",
    "single": "Organization",
    "sheet": "01 Organization Profile",
    "prefix": "ORG",
    "statusField": "recordStatus",
    "listColumns": [
      "organizationCode",
      "registeredName",
      "organizationType",
      "industry",
      "city",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "organizationCode",
        "label": "Organization Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "registeredName",
        "label": "Registered Name",
        "kind": "text",
        "required": true,
        "maxLength": 250
      },
      {
        "key": "brandName",
        "label": "Common / Brand Name",
        "kind": "text",
        "required": false,
        "maxLength": 250
      },
      {
        "key": "organizationType",
        "label": "Organization Type",
        "kind": "master",
        "required": true,
        "group": "OrganizationType"
      },
      {
        "key": "industry",
        "label": "Industry",
        "kind": "text",
        "required": true,
        "maxLength": 160
      },
      {
        "key": "regulatorClassification",
        "label": "RBI / Regulator Classification",
        "kind": "text",
        "required": false,
        "maxLength": 400,
        "note": "Field Dictionary lists Data Type 'Date'; the sample value is text, so it is stored as text."
      },
      {
        "key": "registrationCin",
        "label": "Registration / CIN",
        "kind": "text",
        "required": false,
        "maxLength": 80
      },
      {
        "key": "lei",
        "label": "LEI (if applicable)",
        "kind": "text",
        "required": false,
        "maxLength": 40
      },
      {
        "key": "incorporationDate",
        "label": "Date of Incorporation",
        "kind": "date",
        "required": false
      },
      {
        "key": "registeredOfficeAddress",
        "label": "Registered Office Address",
        "kind": "textarea",
        "required": false,
        "maxLength": 500,
        "full": true
      },
      {
        "key": "city",
        "label": "City",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "state",
        "label": "State",
        "kind": "master",
        "required": false,
        "group": "State"
      },
      {
        "key": "country",
        "label": "Country",
        "kind": "master",
        "required": false,
        "group": "Country"
      },
      {
        "key": "pinCode",
        "label": "PIN Code",
        "kind": "text",
        "required": false,
        "maxLength": 20,
        "note": "Field Dictionary marks this 'Unique code'; a PIN code is shared by many records, so it is free text."
      },
      {
        "key": "corporateWebsite",
        "label": "Corporate Website",
        "kind": "url",
        "required": false,
        "maxLength": 300
      },
      {
        "key": "financialYearStart",
        "label": "Financial Year Start (DD-MM)",
        "kind": "ddmm",
        "required": false
      },
      {
        "key": "financialYearEnd",
        "label": "Financial Year End (DD-MM)",
        "kind": "ddmm",
        "required": false
      },
      {
        "key": "primaryContactRole",
        "label": "Primary Contact Role",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "primaryContactEmail",
        "label": "Primary Contact Official Email",
        "kind": "email",
        "required": false,
        "maxLength": 250
      },
      {
        "key": "dataCutoffDate",
        "label": "Data Cut-off Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "dataQualityNote",
        "label": "(GRAC import note)",
        "kind": "textarea",
        "required": false,
        "maxLength": 1000,
        "full": true,
        "app": true,
        "note": "Not a workbook column. Written by the sample-data import when a workbook value could not be loaded as given.",
        "readonly": true
      }
    ]
  },
  {
    "key": "legal-entities",
    "title": "Legal Entities",
    "single": "Legal Entity",
    "sheet": "02 Legal Entities",
    "prefix": "LE",
    "statusField": "recordStatus",
    "listColumns": [
      "legalEntityCode",
      "legalName",
      "registryOrganizationId",
      "entityType",
      "parentLegalEntityId",
      "inScopeForGrac",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "registryOrganizationId",
        "label": "Organization",
        "kind": "ref",
        "required": true,
        "ref": "organizations",
        "scope": "any",
        "app": true,
        "note": "Not a workbook column (sheet 02 has no Organization Code). The GRAC link from a Legal Entity up to its Organization."
      },
      {
        "key": "legalEntityCode",
        "label": "Legal Entity Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "legalName",
        "label": "Legal Name",
        "kind": "text",
        "required": true,
        "maxLength": 250
      },
      {
        "key": "shortName",
        "label": "Short Name",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "entityType",
        "label": "Entity Type",
        "kind": "master",
        "required": true,
        "group": "LegalEntityType"
      },
      {
        "key": "parentLegalEntityId",
        "label": "Parent Legal Entity Code",
        "kind": "ref",
        "required": false,
        "ref": "legal-entities",
        "scope": "org"
      },
      {
        "key": "registrationNumber",
        "label": "Registration Number",
        "kind": "text",
        "required": false,
        "maxLength": 80
      },
      {
        "key": "incorporationDate",
        "label": "Date of Incorporation",
        "kind": "date",
        "required": false
      },
      {
        "key": "registeredOfficeAddress",
        "label": "Registered Office Address",
        "kind": "textarea",
        "required": false,
        "maxLength": 200,
        "full": true
      },
      {
        "key": "city",
        "label": "City",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "state",
        "label": "State",
        "kind": "master",
        "required": false,
        "group": "State"
      },
      {
        "key": "country",
        "label": "Country",
        "kind": "master",
        "required": false,
        "group": "Country"
      },
      {
        "key": "regulator",
        "label": "Regulator",
        "kind": "text",
        "required": false,
        "maxLength": 250
      },
      {
        "key": "regulatoryClassification",
        "label": "Regulatory Classification",
        "kind": "text",
        "required": false,
        "maxLength": 400
      },
      {
        "key": "businessActivity",
        "label": "Business Activity",
        "kind": "text",
        "required": false,
        "maxLength": 500
      },
      {
        "key": "inScopeForGrac",
        "label": "In Scope for GRAC?",
        "kind": "master",
        "required": true,
        "group": "YesNo"
      },
      {
        "key": "entityOwnerPersonId",
        "label": "Entity Owner Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "units",
    "title": "Organization Units",
    "single": "Organization Unit",
    "sheet": "03 Organization Units",
    "prefix": "UNIT",
    "statusField": "recordStatus",
    "listColumns": [
      "unitCode",
      "unitName",
      "unitType",
      "parentUnitId",
      "legalEntityId",
      "isOperational",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "unitCode",
        "label": "Unit Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "unitName",
        "label": "Unit Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "unitType",
        "label": "Unit Type",
        "kind": "master",
        "required": true,
        "group": "OrgUnitType"
      },
      {
        "key": "parentUnitId",
        "label": "Parent Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC because every unit belongs to one Legal Entity (organization_id NOT NULL)."
      },
      {
        "key": "primaryLocationId",
        "label": "Primary Location Code",
        "kind": "ref",
        "required": false,
        "ref": "locations",
        "scope": "le"
      },
      {
        "key": "unitHeadPersonId",
        "label": "Unit Head Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "unitHeadDesignation",
        "label": "Unit Head Designation",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "businessUnitType",
        "label": "Business Unit Type",
        "kind": "master",
        "required": false,
        "group": "BusinessUnitType"
      },
      {
        "key": "stateRegion",
        "label": "State / Region",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "unitCostCentre",
        "label": "Unit Cost Centre",
        "kind": "text",
        "required": false,
        "maxLength": 80
      },
      {
        "key": "isOperational",
        "label": "Is Operational?",
        "kind": "master",
        "required": true,
        "group": "YesNo"
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "locations",
    "title": "Locations",
    "single": "Location",
    "sheet": "04 Locations",
    "prefix": "LOC",
    "statusField": "operationalStatus",
    "listColumns": [
      "locationCode",
      "locationName",
      "locationType",
      "legalEntityId",
      "organizationUnitId",
      "cityTown",
      "customerFacing",
      "operationalStatus"
    ],
    "fields": [
      {
        "key": "locationCode",
        "label": "Location Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "locationName",
        "label": "Location Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "locationType",
        "label": "Location Type",
        "kind": "locationtype",
        "required": true,
        "group": "LocationType"
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (organization_location.organization_id NOT NULL)."
      },
      {
        "key": "organizationUnitId",
        "label": "Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "parentLocationId",
        "label": "Parent Location Code",
        "kind": "ref",
        "required": false,
        "ref": "locations",
        "scope": "le"
      },
      {
        "key": "addressLine1",
        "label": "Address Line 1",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "addressLine2",
        "label": "Address Line 2",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "cityTown",
        "label": "City / Town",
        "kind": "text",
        "required": false,
        "maxLength": 120,
        "note": "Field Dictionary lists Data Type 'Date'; a city is text."
      },
      {
        "key": "district",
        "label": "District",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "state",
        "label": "State",
        "kind": "master",
        "required": true,
        "group": "State"
      },
      {
        "key": "pinCode",
        "label": "PIN Code",
        "kind": "text",
        "required": false,
        "maxLength": 30
      },
      {
        "key": "country",
        "label": "Country",
        "kind": "master",
        "required": true,
        "group": "Country"
      },
      {
        "key": "latitude",
        "label": "Latitude (optional)",
        "kind": "decimal",
        "required": false
      },
      {
        "key": "longitude",
        "label": "Longitude (optional)",
        "kind": "decimal",
        "required": false
      },
      {
        "key": "regionZoneLabel",
        "label": "Region / Zone Label",
        "kind": "text",
        "required": false,
        "maxLength": 160
      },
      {
        "key": "timeZone",
        "label": "Time Zone",
        "kind": "timezone",
        "required": false,
        "group": "TimeZone",
        "app": true,
        "note": "Kept from Organization Administration's Location tab (retired 2026-11-16): the location's time zone (migration 360). Empty when GRAC_New.time_zone_master is not deployed."
      },
      {
        "key": "locationHeadPersonId",
        "label": "Location Head Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "openingDate",
        "label": "Opening Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "closureDate",
        "label": "Closure Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "customerFacing",
        "label": "Customer-facing?",
        "kind": "master",
        "required": true,
        "group": "YesNo"
      },
      {
        "key": "operationalStatus",
        "label": "Operational Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "departments",
    "title": "Departments",
    "single": "Department",
    "sheet": "05 Departments",
    "prefix": "DEPT",
    "statusField": "recordStatus",
    "listColumns": [
      "departmentCode",
      "departmentName",
      "departmentType",
      "legalEntityId",
      "primaryOrganizationUnitId",
      "departmentHeadPersonId",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "departmentCode",
        "label": "Department Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "departmentName",
        "label": "Department Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "shortName",
        "label": "Short Name",
        "kind": "text",
        "required": false,
        "maxLength": 120
      },
      {
        "key": "departmentType",
        "label": "Department Type",
        "kind": "master",
        "required": true,
        "group": "DepartmentType"
      },
      {
        "key": "parentDepartmentId",
        "label": "Parent Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (organization_department.organization_id NOT NULL)."
      },
      {
        "key": "primaryOrganizationUnitId",
        "label": "Primary Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "departmentHeadPersonId",
        "label": "Department Head Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "departmentHeadDesignation",
        "label": "Department Head Designation",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "primaryBusinessFunctionId",
        "label": "Primary Business Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "costCentre",
        "label": "Cost Centre",
        "kind": "text",
        "required": false,
        "maxLength": 80
      },
      {
        "key": "centralisation",
        "label": "Centralised / Distributed",
        "kind": "master",
        "required": false,
        "group": "Centralisation"
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "functions",
    "title": "Business Functions",
    "single": "Business Function",
    "sheet": "06 Business Functions",
    "prefix": "FUNC",
    "statusField": "recordStatus",
    "listColumns": [
      "functionCode",
      "functionName",
      "functionCategory",
      "criticality",
      "legalEntityId",
      "accountableDepartmentId",
      "functionOwnerPersonId",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "functionCode",
        "label": "Function Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "functionName",
        "label": "Function Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "functionCategory",
        "label": "Function Category",
        "kind": "master",
        "required": true,
        "group": "FunctionCategory"
      },
      {
        "key": "parentFunctionId",
        "label": "Parent Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "businessUnitType",
        "label": "Business Unit Type",
        "kind": "master",
        "required": false,
        "group": "BusinessUnitType"
      },
      {
        "key": "criticality",
        "label": "Criticality",
        "kind": "choice",
        "required": true,
        "default": "Medium",
        "choices": [
          {
            "value": "Critical",
            "label": "Critical"
          },
          {
            "value": "High",
            "label": "High"
          },
          {
            "value": "Medium",
            "label": "Medium"
          },
          {
            "value": "Low",
            "label": "Low"
          }
        ],
        "app": true,
        "note": "Kept from Organization Administration's Business Function tab (retired 2026-11-16): the function's criticality (column NOT NULL, default Medium)."
      },
      {
        "key": "functionOwnerPersonId",
        "label": "Function Owner Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "accountableDepartmentId",
        "label": "Accountable Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "executiveSponsorPersonId",
        "label": "Executive Sponsor Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "descriptionScope",
        "label": "Description / Scope",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "keyResponsibilities",
        "label": "Key Responsibilities",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "legalEntityId",
        "label": "Primary Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (organization_business_function.organization_id NOT NULL)."
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus",
        "note": "Migration 365 limits a business function's status to Active / Inactive (CHECK constraint); only those two are offered.",
        "only": [
          "Active",
          "Inactive"
        ]
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "teams",
    "title": "Teams",
    "single": "Team",
    "sheet": "07 Teams",
    "prefix": "TEAM",
    "statusField": "recordStatus",
    "listColumns": [
      "teamCode",
      "teamName",
      "teamType",
      "teamSourcing",
      "legalEntityId",
      "parentDepartmentId",
      "teamManagerPersonId",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "teamCode",
        "label": "Team Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "teamName",
        "label": "Team Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "teamType",
        "label": "Team Type",
        "kind": "master",
        "required": true,
        "group": "TeamType",
        "note": "Stored in team_classification: organization_team.team_type already means In-house / Vendor (migration 133) and is left as it is."
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "app": true,
        "note": "Not a workbook column. GRAC requires it (organization_team.organization_id NOT NULL); the import takes it from the Parent Department, else the Organization Unit."
      },
      {
        "key": "parentDepartmentId",
        "label": "Parent Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "primaryFunctionId",
        "label": "Primary Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "organizationUnitId",
        "label": "Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "teamManagerPersonId",
        "label": "Team Manager Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "teamSourcing",
        "label": "Team Sourcing",
        "kind": "choice",
        "required": true,
        "default": "InHouse",
        "choices": [
          {
            "value": "InHouse",
            "label": "In-house"
          },
          {
            "value": "Vendor",
            "label": "Vendor-managed"
          }
        ],
        "app": true,
        "note": "Kept from Organization Administration's Teams tab (retired 2026-11-16): In-house or Vendor-managed (organization_team.team_type, migration 133)."
      },
      {
        "key": "vendorId",
        "label": "Vendor",
        "kind": "ref",
        "required": false,
        "ref": "vendors",
        "scope": "le",
        "app": true,
        "note": "Kept from Organization Administration's Teams tab (retired 2026-11-16): required for a vendor-managed team, an Active vendor of the same Legal Entity; cleared for an in-house team (133)."
      },
      {
        "key": "teamMembers",
        "label": "Team Members",
        "kind": "multiref",
        "required": false,
        "ref": "people",
        "scope": "le",
        "app": true,
        "note": "Kept from Organization Administration's Teams tab (retired 2026-11-16): the team's members (organization_team_member, migration 362), people of the same Legal Entity."
      },
      {
        "key": "teamPurpose",
        "label": "Team Purpose",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "people",
    "title": "People",
    "single": "Person",
    "sheet": "08 People",
    "prefix": "PERS",
    "statusField": "recordStatus",
    "listColumns": [
      "personCode",
      "fullName",
      "personCategory",
      "designation",
      "legalEntityId",
      "departmentId",
      "personStatus",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "personCode",
        "label": "Person Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "fullName",
        "label": "Full Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "personCategory",
        "label": "Person Category",
        "kind": "master",
        "required": true,
        "group": "PersonCategory"
      },
      {
        "key": "employmentType",
        "label": "Employment Type",
        "kind": "master",
        "required": false,
        "group": "EmploymentType"
      },
      {
        "key": "referenceNo",
        "label": "Employee / Director Reference No.",
        "kind": "text",
        "required": false,
        "maxLength": 80,
        "note": "Field Dictionary lists Data Type 'Date'; the sample values are reference numbers, so it is stored as text."
      },
      {
        "key": "officialEmail",
        "label": "Official Email",
        "kind": "email",
        "required": false,
        "maxLength": 250,
        "note": "organization_employee.email is unique across GRAC (ux_pm_employee_email)."
      },
      {
        "key": "officialPhone",
        "label": "Official Phone (optional)",
        "kind": "text",
        "required": false,
        "maxLength": 40
      },
      {
        "key": "designation",
        "label": "Designation",
        "kind": "text",
        "required": true,
        "maxLength": 150
      },
      {
        "key": "roleName",
        "label": "Role Name / Functional Role",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "app": true,
        "note": "Not a workbook column. GRAC requires it (organization_employee.organization_id NOT NULL); the import takes it from the Department, else the Organization Unit."
      },
      {
        "key": "departmentId",
        "label": "Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "primaryFunctionId",
        "label": "Primary Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "primaryTeamId",
        "label": "Team Code (primary)",
        "kind": "ref",
        "required": false,
        "ref": "teams",
        "scope": "le"
      },
      {
        "key": "organizationUnitId",
        "label": "Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "primaryLocationId",
        "label": "Primary Location Code",
        "kind": "ref",
        "required": false,
        "ref": "locations",
        "scope": "le"
      },
      {
        "key": "reportsToPersonId",
        "label": "Reports To Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "functionalReportsToPersonId",
        "label": "Functional Reporting To Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "joiningDate",
        "label": "Joining / Appointment Date",
        "kind": "date",
        "required": false,
        "note": "Stored in appointment_dt, not onboarded_dt: onboarded_dt drives the People Onboarding event (migration 131)."
      },
      {
        "key": "exitDate",
        "label": "Exit / End Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "personStatus",
        "label": "Person Status",
        "kind": "master",
        "required": true,
        "group": "PersonStatus"
      },
      {
        "key": "isKmp",
        "label": "Key Managerial Personnel?",
        "kind": "master",
        "required": false,
        "group": "YesNo"
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus",
        "note": "organization_employee.status is also the sign-in status: only Active people can sign in (and only with a password set)."
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "committees",
    "title": "Committees",
    "single": "Committee",
    "sheet": "09 Committees",
    "prefix": "COMM",
    "statusField": "recordStatus",
    "listColumns": [
      "committeeCode",
      "committeeName",
      "committeeType",
      "legalEntityId",
      "chairpersonPersonId",
      "reviewFrequency",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "committeeCode",
        "label": "Committee Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "committeeName",
        "label": "Committee Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "committeeType",
        "label": "Committee Type",
        "kind": "master",
        "required": true,
        "group": "CommitteeType"
      },
      {
        "key": "legalEntityId",
        "label": "Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (organization_committee.organization_id NOT NULL)."
      },
      {
        "key": "committeeMandate",
        "label": "Committee Mandate",
        "kind": "textarea",
        "required": true,
        "full": true,
        "note": "Field Dictionary lists Data Type 'Date'; a mandate is text."
      },
      {
        "key": "scopeResponsibilities",
        "label": "Scope / Responsibilities",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "chairpersonPersonId",
        "label": "Chairperson Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "secretaryPersonId",
        "label": "Committee Secretary Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "reviewFrequency",
        "label": "Review Frequency",
        "kind": "master",
        "required": false,
        "group": "ReviewFrequency",
        "note": "Kept as the workbook value; review_frequency_id (frequency_master) is kept in step when a frequency of the same name exists."
      },
      {
        "key": "torReference",
        "label": "Terms of Reference Reference",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "constitutedDate",
        "label": "Constituted Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "lastReviewedDate",
        "label": "Last Reviewed Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "nextReviewDueDate",
        "label": "Next Review Due Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "committee-members",
    "title": "Committee Members",
    "single": "Committee Membership",
    "sheet": "10 Committee Members",
    "prefix": "MEM",
    "statusField": "recordStatus",
    "listColumns": [
      "membershipCode",
      "committeeId",
      "personId",
      "designationInCommittee",
      "memberSince",
      "votingMember",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "membershipCode",
        "label": "Membership Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "committeeId",
        "label": "Committee Code",
        "kind": "ref",
        "required": true,
        "ref": "committees",
        "scope": "any"
      },
      {
        "key": "personId",
        "label": "Person Code",
        "kind": "ref",
        "required": true,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "designationInCommittee",
        "label": "Designation in Committee",
        "kind": "designation",
        "required": true,
        "group": "CommitteeMemberDesignation"
      },
      {
        "key": "memberSince",
        "label": "Member Since",
        "kind": "date",
        "required": false
      },
      {
        "key": "memberUntil",
        "label": "Member Until",
        "kind": "date",
        "required": false
      },
      {
        "key": "votingMember",
        "label": "Voting Member?",
        "kind": "master",
        "required": false,
        "group": "YesNo"
      },
      {
        "key": "permanentInvitee",
        "label": "Permanent Invitee?",
        "kind": "master",
        "required": false,
        "group": "YesNo"
      },
      {
        "key": "participationRequirement",
        "label": "Attendance / Participation Requirement",
        "kind": "text",
        "required": false,
        "maxLength": 300
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "processes",
    "title": "Business Processes",
    "single": "Business Process",
    "sheet": "11 Business Processes",
    "prefix": "PROC",
    "statusField": "recordStatus",
    "listColumns": [
      "processCode",
      "processName",
      "processLevel",
      "processNature",
      "legalEntityId",
      "owningDepartmentId",
      "processOwnerPersonId",
      "recordStatus"
    ],
    "fields": [
      {
        "key": "processCode",
        "label": "Process Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "processName",
        "label": "Process Name",
        "kind": "text",
        "required": true,
        "maxLength": 220
      },
      {
        "key": "processLevel",
        "label": "Process Level",
        "kind": "master",
        "required": true,
        "group": "ProcessLevel"
      },
      {
        "key": "parentProcessId",
        "label": "Parent Process Code",
        "kind": "ref",
        "required": false,
        "ref": "processes",
        "scope": "le"
      },
      {
        "key": "processNature",
        "label": "Process Nature",
        "kind": "master",
        "required": true,
        "group": "ProcessNature"
      },
      {
        "key": "businessFunctionId",
        "label": "Business Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "owningDepartmentId",
        "label": "Owning Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "processOwnerPersonId",
        "label": "Process Owner Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "accountableExecutivePersonId",
        "label": "Accountable Executive Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "descriptionObjective",
        "label": "Description / Objective",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "keyActivities",
        "label": "Key Activities / Scope",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "primaryProductId",
        "label": "Primary Product / Service Code",
        "kind": "ref",
        "required": false,
        "ref": "products",
        "scope": "le"
      },
      {
        "key": "primaryChannelId",
        "label": "Primary Channel Code",
        "kind": "ref",
        "required": false,
        "ref": "channels",
        "scope": "le"
      },
      {
        "key": "legalEntityId",
        "label": "Applicable Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (organization_dependency_process.organization_id NOT NULL)."
      },
      {
        "key": "primaryOrganizationUnitId",
        "label": "Primary Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "locationScope",
        "label": "Applicable Location Scope",
        "kind": "text",
        "required": false,
        "maxLength": 300
      },
      {
        "key": "processFrequency",
        "label": "Process Frequency",
        "kind": "master",
        "required": false,
        "group": "ProcessFrequency"
      },
      {
        "key": "annualVolume",
        "label": "Approx. Annual Volume (optional)",
        "kind": "number",
        "required": false
      },
      {
        "key": "customerImpact",
        "label": "Customer Impact?",
        "kind": "master",
        "required": false,
        "group": "YesNo"
      },
      {
        "key": "regulatoryImpact",
        "label": "Regulatory Impact",
        "kind": "master",
        "required": false,
        "group": "RegulatoryImpact"
      },
      {
        "key": "regulatoryReferences",
        "label": "Key Regulatory / Policy References",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "keyRiskCategories",
        "label": "Key Risk Categories",
        "kind": "multimaster",
        "required": false,
        "group": "ProcessRisk",
        "note": "Semicolon-separated in the workbook; stored one row per category (organization_process_risk_category)."
      },
      {
        "key": "recordStatus",
        "label": "Record Status",
        "kind": "master",
        "required": true,
        "group": "RecordStatus"
      },
      {
        "key": "effectiveFrom",
        "label": "Effective From",
        "kind": "date",
        "required": false
      },
      {
        "key": "effectiveTo",
        "label": "Effective To",
        "kind": "date",
        "required": false
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "products",
    "title": "Products & Services",
    "single": "Product / Service",
    "sheet": "12 Products & Services",
    "prefix": "PROD",
    "statusField": "productStatus",
    "listColumns": [
      "productCode",
      "productName",
      "productCategory",
      "legalEntityId",
      "owningDepartmentId",
      "productStatus"
    ],
    "fields": [
      {
        "key": "productCode",
        "label": "Product / Service Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "productName",
        "label": "Product / Service Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "productCategory",
        "label": "Product Category",
        "kind": "master",
        "required": true,
        "group": "ProductCategory"
      },
      {
        "key": "schemeVariant",
        "label": "Scheme / Variant Name",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "description",
        "label": "Description",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "owningFunctionId",
        "label": "Owning Business Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "owningDepartmentId",
        "label": "Owning Department Code",
        "kind": "ref",
        "required": false,
        "ref": "departments",
        "scope": "le"
      },
      {
        "key": "productOwnerPersonId",
        "label": "Product Owner Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "legalEntityId",
        "label": "Applicable Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (every product belongs to one Legal Entity)."
      },
      {
        "key": "customerSegment",
        "label": "Customer Segment",
        "kind": "text",
        "required": false,
        "maxLength": 200
      },
      {
        "key": "securedUnsecured",
        "label": "Secured / Unsecured (if applicable)",
        "kind": "master",
        "required": false,
        "group": "SecuredUnsecured",
        "note": "Field Dictionary links this to YesNo, but the column asks Secured / Unsecured and the sample answers Secured / Unsecured / Not applicable; those three are kept as their own list."
      },
      {
        "key": "regulatoryClassification",
        "label": "Regulatory Classification",
        "kind": "text",
        "required": false,
        "maxLength": 400
      },
      {
        "key": "launchDate",
        "label": "Launch Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "withdrawalDate",
        "label": "Withdrawal Date",
        "kind": "date",
        "required": false
      },
      {
        "key": "productStatus",
        "label": "Product Status",
        "kind": "master",
        "required": true,
        "group": "ProductStatus"
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  },
  {
    "key": "channels",
    "title": "Delivery Channels",
    "single": "Delivery Channel",
    "sheet": "13 Delivery Channels",
    "prefix": "CHAN",
    "statusField": "channelStatus",
    "listColumns": [
      "channelCode",
      "channelName",
      "channelType",
      "legalEntityId",
      "customerFacing",
      "channelStatus"
    ],
    "fields": [
      {
        "key": "channelCode",
        "label": "Channel Code",
        "kind": "code",
        "required": true,
        "maxLength": 80
      },
      {
        "key": "channelName",
        "label": "Channel Name",
        "kind": "text",
        "required": true,
        "maxLength": 200
      },
      {
        "key": "channelType",
        "label": "Channel Type",
        "kind": "master",
        "required": true,
        "group": "ChannelType"
      },
      {
        "key": "description",
        "label": "Description",
        "kind": "textarea",
        "required": false,
        "full": true
      },
      {
        "key": "owningFunctionId",
        "label": "Owning Business Function Code",
        "kind": "ref",
        "required": false,
        "ref": "functions",
        "scope": "le"
      },
      {
        "key": "channelOwnerPersonId",
        "label": "Channel Owner Person Code",
        "kind": "ref",
        "required": false,
        "ref": "people",
        "scope": "org"
      },
      {
        "key": "legalEntityId",
        "label": "Applicable Legal Entity Code",
        "kind": "ref",
        "required": true,
        "ref": "legal-entities",
        "scope": "any",
        "note": "Optional in the workbook; required in GRAC (every channel belongs to one Legal Entity)."
      },
      {
        "key": "primaryOrganizationUnitId",
        "label": "Primary Organization Unit Code",
        "kind": "ref",
        "required": false,
        "ref": "units",
        "scope": "le"
      },
      {
        "key": "customerFacing",
        "label": "Customer-facing?",
        "kind": "master",
        "required": true,
        "group": "YesNo"
      },
      {
        "key": "operationalHours",
        "label": "Operational Hours / Availability",
        "kind": "text",
        "required": false,
        "maxLength": 300
      },
      {
        "key": "geographicScope",
        "label": "Geographic Scope",
        "kind": "text",
        "required": false,
        "maxLength": 300
      },
      {
        "key": "productsSupported",
        "label": "Products / Services Supported (codes)",
        "kind": "multiref",
        "required": false,
        "ref": "products",
        "scope": "le",
        "note": "Semicolon-separated codes in the workbook; stored one row per product (organization_channel_product), as the sheet itself recommends."
      },
      {
        "key": "processesSupported",
        "label": "Processes Supported (codes)",
        "kind": "multiref",
        "required": false,
        "ref": "processes",
        "scope": "le",
        "note": "Semicolon-separated codes in the workbook; stored one row per process (organization_channel_process)."
      },
      {
        "key": "channelStatus",
        "label": "Channel Status",
        "kind": "master",
        "required": true,
        "group": "ChannelStatus"
      },
      {
        "key": "remarks",
        "label": "Remarks",
        "kind": "textarea",
        "required": false,
        "full": true
      }
    ]
  }
];
