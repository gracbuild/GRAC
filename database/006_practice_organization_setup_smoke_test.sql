/*
  PracticeManagement Organization Setup smoke test.
  Run inside GRAC_NewPhase after 001/003/004/002/005.
  This validates dbo.pm_manage_practice_repository can save an organization.
*/
USE GRAC_NewPhase;
GO

DECLARE @payload NVARCHAR(MAX)=N'{
  "organization": {
    "id": 0,
    "code": "SMOKE-ORG",
    "name": "Smoke Test Organization",
    "industry": "Banking",
    "entityType": "Bank",
    "country": "India",
    "status": "Active"
  },
  "attributes": {
    "deposit_taking_status": "Yes",
    "asset_size_scale": "Large",
    "stores_cardholder_data": false,
    "geographic_presence": ["India"],
    "business_functions": ["IT"],
    "technology_landscape": ["Core Banking"]
  },
  "releaseIds": []
}';

EXEC dbo.pm_manage_practice_repository
 @p_entity_type=N'organization-setup',
 @p_action=N'SAVE',
 @p_id=0,
 @p_payload=@payload,
 @p_usr_id=N'smoke-test';

SELECT organization_id,organization_code,organization_name,status
FROM grac_practice.organization
WHERE organization_code=N'SMOKE-ORG';
