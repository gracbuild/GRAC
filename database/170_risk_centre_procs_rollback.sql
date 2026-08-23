SET NOCOUNT ON;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_attachment_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_attachment_list;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_attachment_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_attachment_get;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_attachment_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_attachment_save;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_withdraw','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_withdraw;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_reject','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_reject;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_accept','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_accept;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_get;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_list;
GO
IF OBJECT_ID('grac_practice.sp_risk_candidate_create','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_risk_candidate_create;
GO
PRINT '170 rollback complete.';
GO
