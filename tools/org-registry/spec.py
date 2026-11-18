"""
Organization Registry -- single source of truth for the generated SQL,
seed and JS field configuration (migrations 569-572).

Every field maps ONE workbook column (header text verbatim in `label`)
to ONE database column. `app` fields are GRAC-side links the workbook
does not carry as a column (noted in `note`).

kinds:
  code      unique business code (NVARCHAR(80))
  text      free text (len)
  textarea  free text, long (len or None = MAX)
  date      DATE
  decimal   DECIMAL(9,6)
  number    BIGINT
  ddmm      NVARCHAR(5), DD-MM
  email     NVARCHAR(len), simple e-mail shape check
  url       NVARCHAR(len)
  master    text value validated against org_registry_master_value(group)
  locationtype  label -> location_type_master.location_type_id (existing FK)
  designation   label -> committee_designation_master.designation_id (existing FK)
  ref       BIGINT id of another registry record (entity `ref`)
  multiref  bridge table of ids (entity `ref`)
  multimaster bridge table of master values (group)
  choice    text value from a fixed code / label list (`choices`), for an
            existing column whose values are codes, not sheet-15 values
  timezone  label -> GRAC_New.time_zone_master.time_zone_id (existing FK,
            another module's table: every use is guarded by OBJECT_ID)

GRAC fields with no workbook column carry app=True; those added when the
Organization Administration tabs were retired (2026-11-16, 576) also carry
noseed=True: the sample-data import (572) neither reads nor writes them.
multi_extra: extra (column, value) pairs a multiref bridge row needs.
default: the value a new record's form starts with (the column default).

ref scope:
  le   the referenced record must belong to the same Legal Entity
  org  the referenced record must belong to the same Organization
       (or the same Legal Entity when it has no Organization yet)
  any  no scope rule
"""

def F(key, label, col, kind, **kw):
    d = dict(key=key, label=label, col=col, kind=kind, required=False, new=True,
             length=None, group=None, ref=None, scope="any", app=False, note=None,
             multi_table=None, multi_col=None, choices=None, noseed=False, multi_extra=None,
             default=None)
    d.update(kw)
    return d

RS = "RecordStatus"

# The Organization Administration fields the registry took over when that
# page's child tabs were retired (2026-11-16). Existing columns, GRAC-only.
RETIRED_TAB = "Kept from Organization Administration's {tab} tab (retired 2026-11-16): {what}"
CRITICALITY = [("Critical", "Critical"), ("High", "High"), ("Medium", "Medium"), ("Low", "Low")]
TEAM_SOURCING = [("InHouse", "In-house"), ("Vendor", "Vendor-managed")]

ENTITIES = [
  dict(key="organizations", sheet="01 Organization Profile", title="Organizations", single="Organization",
       table="registry_organization", id="registry_organization_id", code="organization_code", name="registered_name",
       le=None, new_table=True, status_col="record_status", record_status_id=False, prefix="ORG",
       fields=[
    F("organizationCode","Organization Code*","organization_code","code",required=True,length=80),
    F("registeredName","Registered Name*","registered_name","text",required=True,length=250),
    F("brandName","Common / Brand Name","brand_name","text",length=250),
    F("organizationType","Organization Type*","organization_type","master",required=True,group="OrganizationType"),
    F("industry","Industry*","industry","text",required=True,length=160),
    F("regulatorClassification","RBI / Regulator Classification","regulator_classification","text",length=400,
      note="Field Dictionary lists Data Type 'Date'; the sample value is text, so it is stored as text."),
    F("registrationCin","Registration / CIN","registration_cin","text",length=80),
    F("lei","LEI (if applicable)","lei","text",length=40),
    F("incorporationDate","Date of Incorporation","incorporation_dt","date"),
    F("registeredOfficeAddress","Registered Office Address","registered_office_address","textarea",length=500),
    F("city","City","city","text",length=120),
    F("state","State","state","master",group="State"),
    F("country","Country","country","master",group="Country"),
    F("pinCode","PIN Code","pin_code","text",length=20,
      note="Field Dictionary marks this 'Unique code'; a PIN code is shared by many records, so it is free text."),
    F("corporateWebsite","Corporate Website","corporate_website","url",length=300),
    F("financialYearStart","Financial Year Start (DD-MM)","financial_year_start","ddmm"),
    F("financialYearEnd","Financial Year End (DD-MM)","financial_year_end","ddmm"),
    F("primaryContactRole","Primary Contact Role","primary_contact_role","text",length=200),
    F("primaryContactEmail","Primary Contact Official Email","primary_contact_email","email",length=250),
    F("dataCutoffDate","Data Cut-off Date","data_cutoff_dt","date"),
    F("recordStatus","Record Status*","record_status","master",required=True,group=RS),
    F("remarks","Remarks","remarks","textarea"),
    F("dataQualityNote","(GRAC import note)","data_quality_note","textarea",length=1000,app=True,
      note="Not a workbook column. Written by the sample-data import when a workbook value could not be loaded as given."),
  ]),

  dict(key="legal-entities", sheet="02 Legal Entities", title="Legal Entities", single="Legal Entity",
       table="organization", id="organization_id", code="organization_code", name="organization_name",
       le="self", new_table=False, status_col="status", record_status_id=True, prefix="LE",
       fields=[
    F("registryOrganizationId","Organization","registry_organization_id","ref",ref="organizations",required=True,app=True,
      note="Not a workbook column (sheet 02 has no Organization Code). The GRAC link from a Legal Entity up to its Organization."),
    F("legalEntityCode","Legal Entity Code*","organization_code","code",required=True,length=80,new=False),
    F("legalName","Legal Name*","organization_name","text",required=True,length=250,new=False),
    F("shortName","Short Name","short_name","text",length=120),
    F("entityType","Entity Type*","entity_type","master",required=True,group="LegalEntityType",new=False),
    F("parentLegalEntityId","Parent Legal Entity Code","parent_organization_id","ref",ref="legal-entities",scope="org"),
    F("registrationNumber","Registration Number","registration_number","text",length=80),
    F("incorporationDate","Date of Incorporation","incorporation_dt","date"),
    F("registeredOfficeAddress","Registered Office Address","address_line1","textarea",length=200,new=False),
    F("city","City","city","text",length=120,new=False),
    F("state","State","state_province","master",group="State",new=False),
    F("country","Country","country","master",group="Country",new=False),
    F("regulator","Regulator","regulator","text",length=250),
    F("regulatoryClassification","Regulatory Classification","regulatory_classification","text",length=400),
    F("businessActivity","Business Activity","business_activity","text",length=500),
    F("inScopeForGrac","In Scope for GRAC?*","in_scope_for_grac","master",required=True,group="YesNo"),
    F("entityOwnerPersonId","Entity Owner Person Code","entity_owner_employee_id","ref",ref="people",scope="org"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","legal_entity_remarks","textarea"),
  ]),

  dict(key="units", sheet="03 Organization Units", title="Organization Units", single="Organization Unit",
       table="organization_division", id="division_id", code="division_code", name="division_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="UNIT",
       fields=[
    F("unitCode","Unit Code*","division_code","code",required=True,length=80,new=False),
    F("unitName","Unit Name*","division_name","text",required=True,length=200,new=False),
    F("unitType","Unit Type*","unit_type","master",required=True,group="OrgUnitType"),
    F("parentUnitId","Parent Unit Code","parent_division_id","ref",ref="units",scope="le"),
    F("legalEntityId","Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC because every unit belongs to one Legal Entity (organization_id NOT NULL)."),
    F("primaryLocationId","Primary Location Code","primary_location_id","ref",ref="locations",scope="le"),
    F("unitHeadPersonId","Unit Head Person Code","head_employee_id","ref",ref="people",scope="org",new=False),
    F("unitHeadDesignation","Unit Head Designation","head_designation","text",length=200),
    F("businessUnitType","Business Unit Type","business_unit_type","master",group="BusinessUnitType"),
    F("stateRegion","State / Region","state_region","text",length=120),
    F("unitCostCentre","Unit Cost Centre","cost_centre","text",length=80),
    F("isOperational","Is Operational?*","is_operational","master",required=True,group="YesNo"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="locations", sheet="04 Locations", title="Locations", single="Location",
       table="organization_location", id="location_id", code="location_code", name="location_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="LOC",
       fields=[
    F("locationCode","Location Code*","location_code","code",required=True,length=80),
    F("locationName","Location Name*","location_name","text",required=True,length=200,new=False),
    F("locationType","Location Type*","location_type_id","locationtype",required=True,new=False),
    F("legalEntityId","Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC (organization_location.organization_id NOT NULL)."),
    F("organizationUnitId","Organization Unit Code","division_id","ref",ref="units",scope="le"),
    F("parentLocationId","Parent Location Code","parent_location_id","ref",ref="locations",scope="le"),
    F("addressLine1","Address Line 1","address_line1","text",length=200,new=False),
    F("addressLine2","Address Line 2","address_line2","text",length=200,new=False),
    F("cityTown","City / Town","city","text",length=120,new=False,
      note="Field Dictionary lists Data Type 'Date'; a city is text."),
    F("district","District","district","text",length=120),
    F("state","State*","state_province","master",required=True,group="State",new=False),
    F("pinCode","PIN Code","postal_code","text",length=30,new=False),
    F("country","Country*","country","master",required=True,group="Country",new=False),
    F("latitude","Latitude (optional)","latitude","decimal"),
    F("longitude","Longitude (optional)","longitude","decimal"),
    F("regionZoneLabel","Region / Zone Label","region","text",length=160,new=False),
    F("timeZone","Time Zone","time_zone_id","timezone",new=False,app=True,noseed=True,group="TimeZone",
      note=RETIRED_TAB.format(tab="Location", what="the location's time zone (migration 360). Empty when GRAC_New.time_zone_master is not deployed.")),
    F("locationHeadPersonId","Location Head Person Code","location_head_id","ref",ref="people",scope="org",new=False),
    F("openingDate","Opening Date","opening_dt","date"),
    F("closureDate","Closure Date","closure_dt","date"),
    F("customerFacing","Customer-facing?*","customer_facing","master",required=True,group="YesNo"),
    F("operationalStatus","Operational Status*","status","master",required=True,group=RS,new=False),
    F("remarks","Remarks","remarks","textarea",new=False),
  ]),

  dict(key="departments", sheet="05 Departments", title="Departments", single="Department",
       table="organization_department", id="department_id", code="department_code", name="department_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="DEPT",
       fields=[
    F("departmentCode","Department Code*","department_code","code",required=True,length=80,new=False),
    F("departmentName","Department Name*","department_name","text",required=True,length=200,new=False),
    F("shortName","Short Name","short_name","text",length=120),
    F("departmentType","Department Type*","department_type","master",required=True,group="DepartmentType"),
    F("parentDepartmentId","Parent Department Code","parent_department_id","ref",ref="departments",scope="le"),
    F("legalEntityId","Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC (organization_department.organization_id NOT NULL)."),
    F("primaryOrganizationUnitId","Primary Organization Unit Code","primary_division_id","ref",ref="units",scope="le"),
    F("departmentHeadPersonId","Department Head Person Code","head_employee_id","ref",ref="people",scope="org",new=False),
    F("departmentHeadDesignation","Department Head Designation","head_designation","text",length=200),
    F("primaryBusinessFunctionId","Primary Business Function Code","primary_business_function_id","ref",ref="functions",scope="le"),
    F("costCentre","Cost Centre","cost_centre","text",length=80),
    F("centralisation","Centralised / Distributed","centralisation","master",group="Centralisation"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="functions", sheet="06 Business Functions", title="Business Functions", single="Business Function",
       table="organization_business_function", id="business_function_id", code="function_code", name="function_name",
       # record_status_id: NOT used -- organization_business_function has no
       # such column on every database (008 adds it only where the table
       # already existed); its status is the CHECKed Active/Inactive (365).
       le="organization_id", new_table=False, status_col="status", record_status_id=False, prefix="FUNC",
       status_only_active_inactive=True,
       fields=[
    F("functionCode","Function Code*","function_code","code",required=True,length=80,new=False),
    F("functionName","Function Name*","function_name","text",required=True,length=200,new=False),
    F("functionCategory","Function Category*","function_category","master",required=True,group="FunctionCategory"),
    F("parentFunctionId","Parent Function Code","parent_function_id","ref",ref="functions",scope="le"),
    F("businessUnitType","Business Unit Type","business_unit_type","master",group="BusinessUnitType"),
    F("criticality","Criticality","criticality","choice",required=True,new=False,app=True,noseed=True,choices=CRITICALITY,default="Medium",
      note=RETIRED_TAB.format(tab="Business Function", what="the function's criticality (column NOT NULL, default Medium).")),
    F("functionOwnerPersonId","Function Owner Person Code","owner_employee_id","ref",ref="people",scope="org"),
    F("accountableDepartmentId","Accountable Department Code","accountable_department_id","ref",ref="departments",scope="le"),
    F("executiveSponsorPersonId","Executive Sponsor Person Code","executive_sponsor_employee_id","ref",ref="people",scope="org"),
    F("descriptionScope","Description / Scope","description","textarea"),
    F("keyResponsibilities","Key Responsibilities","key_responsibilities","textarea"),
    F("legalEntityId","Primary Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC (organization_business_function.organization_id NOT NULL)."),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False,
      note="Migration 365 limits a business function's status to Active / Inactive (CHECK constraint); only those two are offered."),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="teams", sheet="07 Teams", title="Teams", single="Team",
       table="organization_team", id="team_id", code="team_code", name="team_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="TEAM",
       fields=[
    F("teamCode","Team Code*","team_code","code",required=True,length=80),
    F("teamName","Team Name*","team_name","text",required=True,length=200,new=False),
    F("teamType","Team Type*","team_classification","master",required=True,group="TeamType",
      note="Stored in team_classification: organization_team.team_type already means In-house / Vendor (migration 133) and is left as it is."),
    F("legalEntityId","Legal Entity","organization_id","ref",ref="legal-entities",required=True,new=False,app=True,
      note="Not a workbook column. GRAC requires it (organization_team.organization_id NOT NULL); the import takes it from the Parent Department, else the Organization Unit."),
    F("parentDepartmentId","Parent Department Code","parent_department_id","ref",ref="departments",scope="le",new=False),
    F("primaryFunctionId","Primary Function Code","primary_function_id","ref",ref="functions",scope="le"),
    F("organizationUnitId","Organization Unit Code","division_id","ref",ref="units",scope="le"),
    F("teamManagerPersonId","Team Manager Person Code","team_manager_id","ref",ref="people",scope="org",new=False),
    F("teamSourcing","Team Sourcing","team_type","choice",required=True,new=False,app=True,noseed=True,choices=TEAM_SOURCING,default="InHouse",
      note=RETIRED_TAB.format(tab="Teams", what="In-house or Vendor-managed (organization_team.team_type, migration 133).")),
    F("vendorId","Vendor","vendor_id","ref",ref="vendors",scope="le",new=False,app=True,noseed=True,
      note=RETIRED_TAB.format(tab="Teams", what="required for a vendor-managed team, an Active vendor of the same Legal Entity; cleared for an in-house team (133).")),
    F("teamMembers","Team Members","employee_id","multiref",ref="people",scope="le",new=False,app=True,noseed=True,
      multi_table="organization_team_member",
      multi_extra=[("organization_id", "@le"), ("status", "N'Active'"),
                   ("record_status_id", "(SELECT TOP (1) record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active')")],
      note=RETIRED_TAB.format(tab="Teams", what="the team's members (organization_team_member, migration 362), people of the same Legal Entity.")),
    F("teamPurpose","Team Purpose","team_purpose","textarea"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea",new=False),
  ]),

  dict(key="people", sheet="08 People", title="People", single="Person",
       table="organization_employee", id="employee_id", code="employee_code", name="employee_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="PERS",
       fields=[
    F("personCode","Person Code*","employee_code","code",required=True,length=80,new=False),
    F("fullName","Full Name*","employee_name","text",required=True,length=200,new=False),
    F("personCategory","Person Category*","person_category","master",required=True,group="PersonCategory"),
    F("employmentType","Employment Type","employment_type","master",group="EmploymentType"),
    F("referenceNo","Employee / Director Reference No.","reference_no","text",length=80,
      note="Field Dictionary lists Data Type 'Date'; the sample values are reference numbers, so it is stored as text."),
    F("officialEmail","Official Email","email","email",length=250,new=False,
      note="organization_employee.email is unique across GRAC (ux_pm_employee_email)."),
    F("officialPhone","Official Phone (optional)","official_phone","text",length=40),
    F("designation","Designation*","designation","text",required=True,length=150,new=False),
    F("roleName","Role Name / Functional Role","functional_role","text",length=200),
    F("legalEntityId","Legal Entity","organization_id","ref",ref="legal-entities",required=True,new=False,app=True,
      note="Not a workbook column. GRAC requires it (organization_employee.organization_id NOT NULL); the import takes it from the Department, else the Organization Unit."),
    F("departmentId","Department Code","department_id","ref",ref="departments",scope="le",new=False),
    F("primaryFunctionId","Primary Function Code","business_function_id","ref",ref="functions",scope="le",new=False),
    F("primaryTeamId","Team Code (primary)","primary_team_id","ref",ref="teams",scope="le"),
    F("organizationUnitId","Organization Unit Code","division_id","ref",ref="units",scope="le",new=False),
    F("primaryLocationId","Primary Location Code","location_id","ref",ref="locations",scope="le",new=False),
    F("reportsToPersonId","Reports To Person Code","reporting_officer_id","ref",ref="people",scope="org",new=False),
    F("functionalReportsToPersonId","Functional Reporting To Person Code","functional_reporting_to_id","ref",ref="people",scope="org"),
    F("joiningDate","Joining / Appointment Date","appointment_dt","date",
      note="Stored in appointment_dt, not onboarded_dt: onboarded_dt drives the People Onboarding event (migration 131)."),
    F("exitDate","Exit / End Date","exit_dt","date"),
    F("personStatus","Person Status*","person_status","master",required=True,group="PersonStatus"),
    F("isKmp","Key Managerial Personnel?","is_kmp","master",group="YesNo"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False,
      note="organization_employee.status is also the sign-in status: only Active people can sign in (and only with a password set)."),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="committees", sheet="09 Committees", title="Committees", single="Committee",
       table="organization_committee", id="committee_id", code="committee_code", name="committee_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="COMM",
       fields=[
    F("committeeCode","Committee Code*","committee_code","code",required=True,length=80),
    F("committeeName","Committee Name*","committee_name","text",required=True,length=200,new=False),
    F("committeeType","Committee Type*","committee_type","master",required=True,group="CommitteeType"),
    F("legalEntityId","Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC (organization_committee.organization_id NOT NULL)."),
    F("committeeMandate","Committee Mandate*","mandate","textarea",required=True,
      note="Field Dictionary lists Data Type 'Date'; a mandate is text."),
    F("scopeResponsibilities","Scope / Responsibilities","scope_responsibilities","textarea"),
    F("chairpersonPersonId","Chairperson Person Code","chairperson_id","ref",ref="people",scope="org",new=False),
    F("secretaryPersonId","Committee Secretary Person Code","secretary_id","ref",ref="people",scope="org",new=False),
    F("reviewFrequency","Review Frequency","review_frequency","master",group="ReviewFrequency",
      note="Kept as the workbook value; review_frequency_id (frequency_master) is kept in step when a frequency of the same name exists."),
    F("torReference","Terms of Reference Reference","tor_reference","text",length=200),
    F("constitutedDate","Constituted Date","constituted_dt","date"),
    F("lastReviewedDate","Last Reviewed Date","last_reviewed_dt","date"),
    F("nextReviewDueDate","Next Review Due Date","next_review_due_dt","date"),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_from","date"),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea",new=False),
  ]),

  dict(key="committee-members", sheet="10 Committee Members", title="Committee Members", single="Committee Membership",
       table="organization_committee_member", id="committee_member_id", code="membership_code", name=None,
       le="organization_id", le_from=("committeeId","organization_committee","committee_id"),
       new_table=False, status_col="status", record_status_id=True, prefix="MEM",
       fields=[
    F("membershipCode","Membership Code*","membership_code","code",required=True,length=80),
    F("committeeId","Committee Code*","committee_id","ref",ref="committees",required=True,scope="any",new=False),
    F("personId","Person Code*","employee_id","ref",ref="people",required=True,scope="org",new=False),
    F("designationInCommittee","Designation in Committee*","designation_id","designation",required=True,new=False,
      group="CommitteeMemberDesignation"),
    F("memberSince","Member Since","member_since","date"),
    F("memberUntil","Member Until","member_until","date"),
    F("votingMember","Voting Member?","is_voting_member","master",group="YesNo"),
    F("permanentInvitee","Permanent Invitee?","is_permanent_invitee","master",group="YesNo"),
    F("participationRequirement","Attendance / Participation Requirement","participation_requirement","text",length=300),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="processes", sheet="11 Business Processes", title="Business Processes", single="Business Process",
       table="organization_dependency_process", id="process_id", code="process_code", name="process_name",
       le="organization_id", new_table=False, status_col="status", record_status_id=True, prefix="PROC",
       fields=[
    F("processCode","Process Code*","process_code","code",required=True,length=80),
    F("processName","Process Name*","process_name","text",required=True,length=220,new=False),
    F("processLevel","Process Level*","process_level","master",required=True,group="ProcessLevel"),
    F("parentProcessId","Parent Process Code","parent_process_id","ref",ref="processes",scope="le"),
    F("processNature","Process Nature*","process_nature","master",required=True,group="ProcessNature"),
    F("businessFunctionId","Business Function Code","business_function_id","ref",ref="functions",scope="le"),
    F("owningDepartmentId","Owning Department Code","owning_department_id","ref",ref="departments",scope="le"),
    F("processOwnerPersonId","Process Owner Person Code","process_owner_id","ref",ref="people",scope="org",new=False),
    F("accountableExecutivePersonId","Accountable Executive Person Code","accountable_executive_id","ref",ref="people",scope="org"),
    F("descriptionObjective","Description / Objective","description","textarea"),
    F("keyActivities","Key Activities / Scope","key_activities","textarea"),
    F("primaryProductId","Primary Product / Service Code","primary_product_id","ref",ref="products",scope="le"),
    F("primaryChannelId","Primary Channel Code","primary_channel_id","ref",ref="channels",scope="le"),
    F("legalEntityId","Applicable Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,new=False,
      note="Optional in the workbook; required in GRAC (organization_dependency_process.organization_id NOT NULL)."),
    F("primaryOrganizationUnitId","Primary Organization Unit Code","primary_division_id","ref",ref="units",scope="le"),
    F("locationScope","Applicable Location Scope","location_scope","text",length=300),
    F("processFrequency","Process Frequency","process_frequency","master",group="ProcessFrequency"),
    F("annualVolume","Approx. Annual Volume (optional)","annual_volume","number"),
    F("customerImpact","Customer Impact?","customer_impact","master",group="YesNo"),
    F("regulatoryImpact","Regulatory Impact","regulatory_impact","master",group="RegulatoryImpact"),
    F("regulatoryReferences","Key Regulatory / Policy References","regulatory_references","textarea"),
    F("keyRiskCategories","Key Risk Categories","risk_category","multimaster",group="ProcessRisk",
      multi_table="organization_process_risk_category",
      note="Semicolon-separated in the workbook; stored one row per category (organization_process_risk_category)."),
    F("recordStatus","Record Status*","status","master",required=True,group=RS,new=False),
    F("effectiveFrom","Effective From","effective_dt","date",new=False),
    F("effectiveTo","Effective To","effective_to","date"),
    F("remarks","Remarks","remarks","textarea",new=False),
  ]),

  dict(key="products", sheet="12 Products & Services", title="Products & Services", single="Product / Service",
       table="organization_product_service", id="product_service_id", code="product_code", name="product_name",
       le="organization_id", new_table=True, status_col="status", record_status_id=False, prefix="PROD",
       fields=[
    F("productCode","Product / Service Code*","product_code","code",required=True,length=80),
    F("productName","Product / Service Name*","product_name","text",required=True,length=200),
    F("productCategory","Product Category*","product_category","master",required=True,group="ProductCategory"),
    F("schemeVariant","Scheme / Variant Name","scheme_variant","text",length=200),
    F("description","Description","description","textarea"),
    F("owningFunctionId","Owning Business Function Code","owning_function_id","ref",ref="functions",scope="le"),
    F("owningDepartmentId","Owning Department Code","owning_department_id","ref",ref="departments",scope="le"),
    F("productOwnerPersonId","Product Owner Person Code","product_owner_id","ref",ref="people",scope="org"),
    F("legalEntityId","Applicable Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,
      note="Optional in the workbook; required in GRAC (every product belongs to one Legal Entity)."),
    F("customerSegment","Customer Segment","customer_segment","text",length=200),
    F("securedUnsecured","Secured / Unsecured (if applicable)","secured_unsecured","master",group="SecuredUnsecured",
      note="Field Dictionary links this to YesNo, but the column asks Secured / Unsecured and the sample answers Secured / Unsecured / Not applicable; those three are kept as their own list."),
    F("regulatoryClassification","Regulatory Classification","regulatory_classification","text",length=400),
    F("launchDate","Launch Date","launch_dt","date"),
    F("withdrawalDate","Withdrawal Date","withdrawal_dt","date"),
    F("productStatus","Product Status*","status","master",required=True,group="ProductStatus"),
    F("remarks","Remarks","remarks","textarea"),
  ]),

  dict(key="channels", sheet="13 Delivery Channels", title="Delivery Channels", single="Delivery Channel",
       table="organization_delivery_channel", id="channel_id", code="channel_code", name="channel_name",
       le="organization_id", new_table=True, status_col="status", record_status_id=False, prefix="CHAN",
       fields=[
    F("channelCode","Channel Code*","channel_code","code",required=True,length=80),
    F("channelName","Channel Name*","channel_name","text",required=True,length=200),
    F("channelType","Channel Type*","channel_type","master",required=True,group="ChannelType"),
    F("description","Description","description","textarea"),
    F("owningFunctionId","Owning Business Function Code","owning_function_id","ref",ref="functions",scope="le"),
    F("channelOwnerPersonId","Channel Owner Person Code","channel_owner_id","ref",ref="people",scope="org"),
    F("legalEntityId","Applicable Legal Entity Code","organization_id","ref",ref="legal-entities",required=True,
      note="Optional in the workbook; required in GRAC (every channel belongs to one Legal Entity)."),
    F("primaryOrganizationUnitId","Primary Organization Unit Code","primary_division_id","ref",ref="units",scope="le"),
    F("customerFacing","Customer-facing?*","customer_facing","master",required=True,group="YesNo"),
    F("operationalHours","Operational Hours / Availability","operational_hours","text",length=300),
    F("geographicScope","Geographic Scope","geographic_scope","text",length=300),
    F("productsSupported","Products / Services Supported (codes)","product_service_id","multiref",ref="products",scope="le",
      multi_table="organization_channel_product",
      note="Semicolon-separated codes in the workbook; stored one row per product (organization_channel_product), as the sheet itself recommends."),
    F("processesSupported","Processes Supported (codes)","process_id","multiref",ref="processes",scope="le",
      multi_table="organization_channel_process",
      note="Semicolon-separated codes in the workbook; stored one row per process (organization_channel_process)."),
    F("channelStatus","Channel Status*","status","master",required=True,group="ChannelStatus"),
    F("remarks","Remarks","remarks","textarea"),
  ]),
]

# Records outside the registry that a field may point at (picked like a
# ref; never a tab of the screen). code None = the table has no code.
EXTERNAL = [
  dict(key="vendors", title="Vendors", single="Vendor", table="organization_dependency_vendor", id="vendor_id",
       code=None, name="vendor_name", status_col="status", external=True),
]

BY_KEY = {e["key"]: e for e in ENTITIES + EXTERNAL}

# Display name of a referenced entity in lists/lookups: SQL expression on alias `x`.
def code_expr(ent, alias):
    """Code of a referenced record; NULL for a table without one (vendors)."""
    return f"{alias}.{ent['code']}" if ent["code"] else "CAST(NULL AS NVARCHAR(80))"

def ref_name_expr(ent, alias):
    if ent["key"] == "committee-members":
        return f"{alias}.membership_code"
    return f"{alias}.{ent['name']}"

def sql_type(f):
    k = f["kind"]
    if k == "code": return f"NVARCHAR({f['length'] or 80})"
    if k in ("text", "email", "url"): return f"NVARCHAR({f['length']})"
    if k == "textarea": return f"NVARCHAR({f['length']})" if f["length"] else "NVARCHAR(MAX)"
    if k == "date": return "DATE"
    if k == "decimal": return "DECIMAL(9,6)"
    if k == "number": return "BIGINT"
    if k == "ddmm": return "NVARCHAR(5)"
    if k == "master": return "NVARCHAR(120)"
    if k in ("ref",): return "BIGINT"
    if k == "locationtype": return "INT"
    if k == "designation": return "INT"
    if k == "choice": return "NVARCHAR(30)"
    if k == "timezone": return "BIGINT"
    raise ValueError(k)
