SET NOCOUNT ON;

IF OBJECT_ID('grac_practice.practice_instance','U') IS NOT NULL
BEGIN
    UPDATE grac_practice.practice_instance
    SET assurance_mode = CASE
            WHEN LTRIM(RTRIM(assurance_mode)) = N'Automated' THEN N'Automated'
            ELSE N'Manual'
        END,
        updated_by = COALESCE(NULLIF(updated_by,N''),N'system'),
        updated_dt = SYSUTCDATETIME()
    WHERE NULLIF(LTRIM(RTRIM(assurance_mode)),N'') IS NULL
       OR LTRIM(RTRIM(assurance_mode)) NOT IN (N'Manual',N'Automated');
END

IF OBJECT_ID('grac_practice.assurance_mode_master','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.assurance_mode_master','assurance_mode_name') IS NOT NULL
   AND COL_LENGTH('grac_practice.assurance_mode_master','assurance_mode_code') IS NOT NULL
   AND COL_LENGTH('grac_practice.assurance_mode_master','status') IS NOT NULL
BEGIN
    UPDATE grac_practice.assurance_mode_master
    SET status = CASE
            WHEN assurance_mode_name IN (N'Manual',N'Automated')
              OR assurance_mode_code IN (N'Manual',N'Automated') THEN N'Active'
            ELSE N'Inactive'
        END,
        updated_by = COALESCE(NULLIF(updated_by,N''),N'system'),
        updated_dt = SYSUTCDATETIME()
    WHERE assurance_mode_name IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid')
       OR assurance_mode_code IN (N'Manual',N'Automated',N'Semi-Automated',N'Semi Automated',N'Hybrid');
END
