/*
  033 - Custom Release Source Structure
  Adds source_structure support for organization custom releases.
  Custom releases (subscription_type='Custom' in repository_subscription) can now
  have their own hierarchical source structure, mirroring the repository-level
  source_structure_node pattern in grac_new.

  Also adds structure_node_id to custom_release_statement so every statement
  can be mapped under a source structure node.
*/

-- 1. Create custom_release_source_structure table
IF OBJECT_ID('grac_practice.custom_release_source_structure','U') IS NULL
CREATE TABLE grac_practice.custom_release_source_structure(
  structure_node_id BIGINT IDENTITY PRIMARY KEY,
  subscription_id BIGINT NOT NULL REFERENCES grac_practice.repository_subscription(subscription_id),
  organization_id BIGINT NOT NULL REFERENCES grac_practice.organization(organization_id),
  parent_node_id BIGINT NULL,
  node_level INT NOT NULL DEFAULT 1,
  display_order INT NOT NULL DEFAULT 0,
  node_reference NVARCHAR(160) NULL,
  node_title NVARCHAR(500) NOT NULL,
  description NVARCHAR(MAX) NULL,
  status NVARCHAR(30) NOT NULL DEFAULT 'Active',
  entered_by NVARCHAR(100) NOT NULL,
  entered_dt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_by NVARCHAR(100) NULL,
  updated_dt DATETIME2 NULL,
  CONSTRAINT fk_pm_custom_source_structure_parent
    FOREIGN KEY(parent_node_id) REFERENCES grac_practice.custom_release_source_structure(structure_node_id)
);
GO

-- 2. Add structure_node_id to custom_release_statement
IF COL_LENGTH('grac_practice.custom_release_statement','structure_node_id') IS NULL
  ALTER TABLE grac_practice.custom_release_statement ADD structure_node_id BIGINT NULL
    REFERENCES grac_practice.custom_release_source_structure(structure_node_id);
GO

-- 3. Indexes for performance
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_custom_source_structure_sub_org_status' AND object_id=OBJECT_ID('grac_practice.custom_release_source_structure'))
  CREATE INDEX ix_pm_custom_source_structure_sub_org_status
    ON grac_practice.custom_release_source_structure(subscription_id,organization_id,status,display_order)
    INCLUDE(parent_node_id,node_level,node_reference,node_title);
GO

IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='ix_pm_custom_statement_structure_node' AND object_id=OBJECT_ID('grac_practice.custom_release_statement'))
  CREATE INDEX ix_pm_custom_statement_structure_node
    ON grac_practice.custom_release_statement(structure_node_id,subscription_id,organization_id,status)
    WHERE structure_node_id IS NOT NULL;
GO

PRINT '033_custom_release_source_structure applied successfully.';
GO
