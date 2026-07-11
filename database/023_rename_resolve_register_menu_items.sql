SET NOCOUNT ON;

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
    SET menu_name = updates.menu_name,
        module_type = N'Registers',
        updated_by = COALESCE(NULLIF(updated_by,N''),N'system'),
        updated_dt = SYSUTCDATETIME()
    FROM grac_practice.menu_master menu
    JOIN (VALUES
        (N'workbench-applications', N'Applications'),
        (N'workbench-tools', N'Tools'),
        (N'workbench-vendors', N'Vendors'),
        (N'workbench-assets', N'Assets'),
        (N'workbench-teams', N'Teams'),
        (N'workbench-committees', N'Committees'),
        (N'workbench-processes', N'Processes'),
        (N'workbench-locations', N'Locations')
    ) updates(menu_key, menu_name)
        ON updates.menu_key = menu.menu_key;
END
