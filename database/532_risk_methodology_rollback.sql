-- =====================================================================
-- 532 ROLLBACK  Risk methodology.
-- Restores sp_risk_rating_resolve to the 206 body (matrix only), drops
-- the 532 procedures, function and tables (THE METHODOLOGY SETTINGS AND
-- EVERY ASSESSMENT'S METHODOLOGY VALUES ARE LOST), and removes the menu
-- row and its permissions. Ratings already stored on risks stay as they
-- were saved. Also remove the row from 274_menu_master_seed.sql.
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_rating_resolve
    @organization_id  BIGINT,
    @likelihood_value INT,
    @impact_value     INT,
    @rating_code      NVARCHAR(30)  OUTPUT,
    @rating_name      NVARCHAR(120) OUTPUT,
    @rating_score     INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @rating_code  = NULL;
    SET @rating_name  = NULL;
    SET @rating_score = NULL;

    IF @organization_id IS NULL
        THROW 56041, 'sp_risk_rating_resolve: organization_id is required.', 1;

    -- A partially scored analysis is legal while the analyst is still
    -- working (BRD 7 lists the fields, BRD 8 is where completeness is judged),
    -- so an unscored pair resolves to NULL rather than throwing.
    IF @likelihood_value IS NULL OR @impact_value IS NULL
        RETURN;

    SELECT @rating_code  = rating_code,
           @rating_name  = rating_name,
           @rating_score = rating_score
      FROM grac_practice.risk_matrix_cell
     WHERE organization_id  = @organization_id
       AND likelihood_value = @likelihood_value
       AND impact_value     = @impact_value;

    -- A scored pair with no matrix cell is a configuration error, not a
    -- data error: the organisation offered a level its matrix does not
    -- cover. Fail loudly -- silently registering an unrated risk would
    -- breach BRD 9.1.
    IF @rating_code IS NULL
        THROW 56042, 'sp_risk_rating_resolve: no matrix cell for this likelihood/impact pair. Check the organisation''s risk matrix configuration.', 1;

END;
GO

IF OBJECT_ID('grac_practice.sp_risk_methodology_register_summary','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_register_summary;
IF OBJECT_ID('grac_practice.sp_risk_methodology_assessment_get','P')   IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_assessment_get;
IF OBJECT_ID('grac_practice.sp_risk_methodology_assessment_save','P')  IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_assessment_save;
IF OBJECT_ID('grac_practice.sp_risk_methodology_publish','P')          IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_publish;
IF OBJECT_ID('grac_practice.sp_risk_methodology_draft_save','P')       IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_draft_save;
IF OBJECT_ID('grac_practice.sp_risk_methodology_draft_discard','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_draft_discard;
IF OBJECT_ID('grac_practice.sp_risk_methodology_draft_create','P')     IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_draft_create;
IF OBJECT_ID('grac_practice.sp_risk_methodology_get','P')              IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_get;
IF OBJECT_ID('grac_practice.sp_risk_methodology_template_fill','P')    IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_methodology_template_fill;
IF OBJECT_ID('grac_practice.fn_risk_rating_rank') IS NOT NULL DROP FUNCTION grac_practice.fn_risk_rating_rank;
GO

IF OBJECT_ID('grac_practice.risk_assessment_dimension_value','U')  IS NOT NULL DROP TABLE grac_practice.risk_assessment_dimension_value;
IF OBJECT_ID('grac_practice.risk_assessment_methodology','U')      IS NOT NULL DROP TABLE grac_practice.risk_assessment_methodology;
IF OBJECT_ID('grac_practice.risk_methodology_appetite','U')        IS NOT NULL DROP TABLE grac_practice.risk_methodology_appetite;
IF OBJECT_ID('grac_practice.risk_methodology_impact_area','U')     IS NOT NULL DROP TABLE grac_practice.risk_methodology_impact_area;
IF OBJECT_ID('grac_practice.risk_methodology_score_band','U')      IS NOT NULL DROP TABLE grac_practice.risk_methodology_score_band;
IF OBJECT_ID('grac_practice.risk_methodology_dimension_level','U') IS NOT NULL DROP TABLE grac_practice.risk_methodology_dimension_level;
IF OBJECT_ID('grac_practice.risk_methodology_dimension','U')       IS NOT NULL DROP TABLE grac_practice.risk_methodology_dimension;
IF OBJECT_ID('grac_practice.risk_methodology_version','U')         IS NOT NULL DROP TABLE grac_practice.risk_methodology_version;
GO

DELETE p FROM grac_practice.organization_role_menu_permission p
  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
 WHERE m.menu_key = N'risk-methodology';
DELETE FROM grac_practice.menu_master WHERE menu_key = N'risk-methodology';
GO

SELECT '532 rolled back' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_methodology_version','U') IS NULL
             AND ISNULL(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_rating_resolve')), N'') NOT LIKE N'%grac.risk.methodology%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
