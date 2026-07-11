/*
  Normalize PracticeManagement menu URLs for virtual-directory hosting.
  Run in the target database after master data scripts.
*/
SET NOCOUNT ON;

IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.menu_master
       SET menu_url = STUFF(menu_url, 1, 1, '')
     WHERE menu_url LIKE '/Practice/Index%';
END

SELECT menu_key, menu_name, menu_url, status
FROM grac_practice.menu_master
WHERE status = 'Active'
ORDER BY display_order, menu_id;
