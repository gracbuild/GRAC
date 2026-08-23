-- =====================================================================
-- 090 Organization Assurance Plan procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @procs TABLE(proc_name SYSNAME);
INSERT INTO @procs VALUES
    ('sp_org_assurance_plan_item_delete'),
    ('sp_org_assurance_plan_item_save'),
    ('sp_org_assurance_plan_item_list'),
    ('sp_org_assurance_plan_close'),
    ('sp_org_assurance_plan_activate'),
    ('sp_org_assurance_plan_approve'),
    ('sp_org_assurance_plan_submit'),
    ('sp_org_assurance_plan_transition'),
    ('sp_org_assurance_plan_delete'),
    ('sp_org_assurance_plan_save'),
    ('sp_org_assurance_plan_get'),
    ('sp_org_assurance_plan_list'),
    ('sp_org_assurance_plan_type_list'),
    ('sp_org_assurance_plan_status_list');

DECLARE @p SYSNAME;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT proc_name FROM @procs;
OPEN cur; FETCH NEXT FROM cur INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('grac_practice.' + @p, 'P') IS NOT NULL
        EXEC('DROP PROCEDURE grac_practice.' + @p);
    FETCH NEXT FROM cur INTO @p;
END
CLOSE cur; DEALLOCATE cur;

PRINT '090 rollback complete.';
GO
