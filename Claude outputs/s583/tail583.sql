-- =====================================================================
-- 5. Engine settings (CR2 7.2 "configurable"): per organization, made
--    with the defaults the first time they are read.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_rec_setting_get
    @organization_id BIGINT,
    @employee_id     BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL THROW 54160, 'organization_id is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_rec_setting WHERE organization_id = @organization_id)
        INSERT INTO grac_practice.org_assurance_plan_rec_setting (organization_id) VALUES (@organization_id);
    DECLARE @hia BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    SELECT s.include_band_codes AS IncludeBandCodes, s.due_window_months AS DueWindowMonths,
           s.always_open_high_findings AS AlwaysOpenHighFindings, s.always_high_reg AS AlwaysHighRegSignificance,
           s.always_never_audited AS AlwaysNeverAudited, s.ranking_order AS RankingOrder,
           ISNULL(s.updated_by, s.entered_by) AS ChangedBy, ISNULL(s.updated_dt, s.entered_dt) AS ChangedDt,
           @hia AS CanEdit
      FROM grac_practice.org_assurance_plan_rec_setting s
     WHERE s.organization_id = @organization_id;
    -- The risk bands to choose from: the published RBIA methodology's.
    SELECT b.band_code AS BandCode, b.band_name AS BandName, b.min_score AS MinScore, b.max_score AS MaxScore,
           b.audit_priority AS AuditPriority, b.frequency_months AS FrequencyMonths
      FROM grac_practice.org_assurance_rbia_band b
      JOIN grac_practice.org_assurance_rbia_methodology m
           ON m.rbia_methodology_id = b.rbia_methodology_id AND m.organization_id = @organization_id AND m.status = N'Published'
     ORDER BY b.min_score DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_rec_setting_save
    @organization_id           BIGINT,
    @include_band_codes        NVARCHAR(400),
    @due_window_months         INT,
    @always_open_high_findings BIT,
    @always_high_reg           BIT,
    @always_never_audited      BIT,
    @ranking_order             NVARCHAR(400),
    @employee_id               BIGINT,
    @actor                     NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                    WHERE h.employee_id = @employee_id)
        THROW 54161, 'Only the Head of Internal Audit (or a delegate holding that responsibility) changes the recommendation settings.', 1;
    IF @due_window_months IS NULL OR @due_window_months < 0 OR @due_window_months > 36
        THROW 54168, 'The due window is 0 to 36 months.', 1;

    -- Bands: codes, upper case, no blanks / duplicates.
    DECLARE @bands NVARCHAR(400) = (SELECT STRING_AGG(c, N',') FROM (SELECT DISTINCT UPPER(LTRIM(RTRIM(value))) AS c
                                                                         FROM STRING_SPLIT(ISNULL(@include_band_codes, N''), N',')
                                                                        WHERE LTRIM(RTRIM(value)) <> N'') x);
    -- Ranking: known keys only, each once, in the given order; keys not
    -- given are appended in the default order.
    DECLARE @keys TABLE(k NVARCHAR(40) PRIMARY KEY, def_ord INT);
    INSERT INTO @keys (k, def_ord) VALUES (N'RESIDUAL_SCORE', 1), (N'PRIORITY', 2), (N'REG_SIGNIFICANCE', 3), (N'CRITICALITY', 4),
                                          (N'LAST_AUDIT', 5), (N'OPEN_FINDINGS', 6), (N'OPEN_GAPS', 7), (N'ABOVE_APPETITE', 8);
    DECLARE @given TABLE(ord INT, k NVARCHAR(40));
    INSERT INTO @given (ord, k)
    SELECT CAST(j.[key] AS INT), UPPER(LTRIM(RTRIM(j.value)))
      FROM OPENJSON(N'["' + REPLACE(REPLACE(ISNULL(@ranking_order, N''), N'"', N''), N',', N'","') + N'"]') j
     WHERE LTRIM(RTRIM(j.value)) <> N'';
    IF EXISTS (SELECT 1 FROM @given g WHERE NOT EXISTS (SELECT 1 FROM @keys k WHERE k.k = g.k))
        THROW 54168, 'Unknown ranking key.', 1;
    IF EXISTS (SELECT k FROM @given GROUP BY k HAVING COUNT(*) > 1)
        THROW 54168, 'A ranking key is given twice.', 1;
    DECLARE @rank NVARCHAR(400) = (SELECT STRING_AGG(k, N',') WITHIN GROUP (ORDER BY grp, ord)
                                     FROM (SELECT g.k, 0 AS grp, g.ord FROM @given g
                                           UNION ALL
                                           SELECT k.k, 1, k.def_ord FROM @keys k WHERE NOT EXISTS (SELECT 1 FROM @given g WHERE g.k = k.k)) x);

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_rec_setting WHERE organization_id = @organization_id)
        INSERT INTO grac_practice.org_assurance_plan_rec_setting (organization_id, entered_by) VALUES (@organization_id, @actor);
    UPDATE grac_practice.org_assurance_plan_rec_setting
       SET include_band_codes = ISNULL(@bands, N''), due_window_months = @due_window_months,
           always_open_high_findings = ISNULL(@always_open_high_findings, 0), always_high_reg = ISNULL(@always_high_reg, 0),
           always_never_audited = ISNULL(@always_never_audited, 0), ranking_order = @rank,
           updated_by = @me, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;
END
GO

-- =====================================================================
-- 6. Generate (or refresh) the recommendations of a plan
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_generate
    @organization_id BIGINT,
    @plan_id         BIGINT,
    @employee_id     BIGINT,
    @actor           NVARCHAR(100) = 'system',
    @generated_count INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @generated_count = 0;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                    WHERE h.employee_id = @employee_id)
        THROW 54161, 'Only the Head of Internal Audit (or a delegate holding that responsibility) generates recommendations.', 1;

    DECLARE @pfrom DATE, @pto DATE, @pstatus NVARCHAR(60);
    SELECT @pfrom = p.period_from, @pto = p.period_to, @pstatus = s.status_code
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master s ON s.org_assurance_plan_status_id = p.status_id
     WHERE p.org_assurance_plan_id = @plan_id AND p.organization_id = @organization_id AND p.is_active = 1;
    IF @pstatus IS NULL THROW 54160, 'The plan was not found in this organization.', 1;
    IF @pstatus NOT IN (N'Draft', N'Submitted')
        THROW 54162, 'Recommendations are made for a plan that is Draft or Submitted (revise an approved plan first).', 1;
    IF @pfrom IS NULL OR @pto IS NULL THROW 54162, 'Give the plan its period (from / to) first.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_rec_setting WHERE organization_id = @organization_id)
        INSERT INTO grac_practice.org_assurance_plan_rec_setting (organization_id) VALUES (@organization_id);   -- the defaults
    DECLARE @bands NVARCHAR(400), @window INT, @a_find BIT, @a_reg BIT, @a_never BIT, @rank NVARCHAR(400);
    SELECT @bands = include_band_codes, @window = due_window_months, @a_find = always_open_high_findings,
           @a_reg = always_high_reg, @a_never = always_never_audited, @rank = ranking_order
      FROM grac_practice.org_assurance_plan_rec_setting WHERE organization_id = @organization_id;
    DECLARE @k1 NVARCHAR(40), @k2 NVARCHAR(40), @k3 NVARCHAR(40), @k4 NVARCHAR(40),
            @k5 NVARCHAR(40), @k6 NVARCHAR(40), @k7 NVARCHAR(40), @k8 NVARCHAR(40);
    SELECT @k1 = MAX(CASE WHEN [key] = 0 THEN value END), @k2 = MAX(CASE WHEN [key] = 1 THEN value END),
           @k3 = MAX(CASE WHEN [key] = 2 THEN value END), @k4 = MAX(CASE WHEN [key] = 3 THEN value END),
           @k5 = MAX(CASE WHEN [key] = 4 THEN value END), @k6 = MAX(CASE WHEN [key] = 5 THEN value END),
           @k7 = MAX(CASE WHEN [key] = 6 THEN value END), @k8 = MAX(CASE WHEN [key] = 7 THEN value END)
      FROM OPENJSON(N'["' + REPLACE(@rank, N',', N'","') + N'"]');
    DECLARE @reg_top INT = (SELECT MAX(rank_value) FROM grac_practice.org_assurance_universe_master
                             WHERE organization_id = @organization_id AND master_group = N'REG_SIGNIFICANCE' AND is_active = 1);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @horizon DATE = DATEADD(MONTH, @window, @pto);

    DECLARE @c TABLE(
        sid BIGINT PRIMARY KEY, subject_name NVARCHAR(300),
        rbia_id BIGINT, rbia_ref NVARCHAR(40), residual DECIMAL(6,2), band_code NVARCHAR(30), band_name NVARCHAR(100),
        band_min DECIMAL(6,2), priority NVARCHAR(60), freq INT,
        reg_name NVARCHAR(200), reg_rank INT, crit_name NVARCHAR(200), crit_rank INT,
        last_dt DATETIME2, last_eng BIGINT, last_code NVARCHAR(80), last_result NVARCHAR(200),
        def_id BIGINT, def_name NVARCHAR(400),
        risks INT, above INT, treat INT, gaps INT, f_total INT, f_open INT, f_high INT,
        due_by DATE, never BIT, kind NVARCHAR(20), reasons NVARCHAR(1000),
        s_from DATE, s_to DATE, rank_no INT);

    INSERT INTO @c (sid, subject_name, rbia_id, rbia_ref, residual, band_code, band_name, band_min, priority, freq,
                    reg_name, reg_rank, crit_name, crit_rank, last_dt, last_eng, last_code, last_result, def_id, def_name,
                    risks, above, treat, gaps, f_total, f_open, f_high, never)
    SELECT s.universe_subject_id, s.subject_name,
           cr.rbia_assessment_id, cr.assessment_ref, cr.residual_score, fb.band_code, cr.final_band_name, fb.min_score,
           cr.final_priority, cr.frequency_months,
           rg.name, ISNULL(rg.rank_value, 0), ct.name, ISNULL(ct.rank_value, 0),
           la.last_audit_dt, la.last_engagement_id, la.last_engagement_code, NULLIF(la.last_result, N''),
           la.definition_id, la.definition_name,
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_risks(@organization_id) r
             WHERE r.universe_subject_id = s.universe_subject_id AND r.mapping_status = N'CONFIRMED'),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_risks(@organization_id) r
              JOIN grac_practice.fn_risk_register_methodology_status(@organization_id) ms ON ms.RiskRegisterId = r.risk_register_id
             WHERE r.universe_subject_id = s.universe_subject_id AND ms.AppetiteStatus = N'Above'),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_risks(@organization_id) r
             CROSS APPLY grac_practice.fn_risk_treatment_roots(r.risk_register_id) t
              JOIN grac_practice.vw_pm_practice_task v ON v.task_id = t.task_id
             WHERE r.universe_subject_id = s.universe_subject_id AND v.closed_at IS NULL AND v.current_status_is_terminal = 0),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_gaps(@organization_id) x
              JOIN grac_practice.custom_gap g ON g.custom_gap_id = x.custom_gap_id
             WHERE x.universe_subject_id = s.universe_subject_id AND g.closed_dt IS NULL),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_findings(@organization_id) f
             WHERE f.universe_subject_id = s.universe_subject_id),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_findings(@organization_id) f
              JOIN grac_practice.org_assurance_observation o ON o.org_assurance_observation_id = f.org_assurance_observation_id
              JOIN grac_practice.org_assurance_observation_status_master os ON os.org_assurance_observation_status_id = o.observation_status_id
             WHERE f.universe_subject_id = s.universe_subject_id AND os.is_terminal = 0),
           (SELECT COUNT(*) FROM grac_practice.fn_org_assurance_universe_subject_findings(@organization_id) f
              JOIN grac_practice.org_assurance_observation o ON o.org_assurance_observation_id = f.org_assurance_observation_id
              JOIN grac_practice.org_assurance_observation_status_master os ON os.org_assurance_observation_status_id = o.observation_status_id
             WHERE f.universe_subject_id = s.universe_subject_id AND os.is_terminal = 0 AND o.severity_code IN (N'Critical', N'High')),
           CASE WHEN la.last_audit_dt IS NULL THEN 1 ELSE 0 END
      FROM grac_practice.org_assurance_universe_subject s
      LEFT JOIN grac_practice.fn_org_assurance_rbia_subject_current(@organization_id) cr ON cr.universe_subject_id = s.universe_subject_id
      LEFT JOIN grac_practice.org_assurance_rbia_band fb ON fb.rbia_band_id = cr.final_band_id
      LEFT JOIN grac_practice.org_assurance_universe_master rg ON rg.universe_master_id = s.reg_significance_id
      LEFT JOIN grac_practice.org_assurance_universe_master ct ON ct.universe_master_id = s.criticality_id
      LEFT JOIN grac_practice.fn_org_assurance_universe_subject_audit(@organization_id) la ON la.universe_subject_id = s.universe_subject_id
     WHERE s.organization_id = @organization_id AND s.status_code = N'ACTIVE';

    -- Due by, kind, reasons, suggested period.
    UPDATE @c SET due_by = CASE WHEN never = 0 AND freq IS NOT NULL THEN CAST(DATEADD(MONTH, freq, last_dt) AS DATE) END;
    UPDATE c SET
        kind = CASE WHEN c.rbia_id IS NULL THEN N'NOT_ASSESSED'
                    WHEN (    (N',' + @bands + N',') LIKE N'%,' + ISNULL(c.band_code, N'-') + N',%'
                          AND (c.never = 1 OR c.due_by <= @horizon))
                      OR (@a_find = 1 AND c.f_high > 0)
                      OR (@a_reg = 1 AND c.reg_rank > 0 AND c.reg_rank = @reg_top)
                      OR (@a_never = 1 AND c.never = 1) THEN N'RECOMMENDED'
                    ELSE N'OPTIONAL' END,
        reasons = CONCAT_WS(N'; ',
                    CASE WHEN c.rbia_id IS NULL THEN N'No approved RBIA assessment' END,
                    CASE WHEN c.rbia_id IS NOT NULL AND (N',' + @bands + N',') LIKE N'%,' + ISNULL(c.band_code, N'-') + N',%'
                         THEN N'Band ' + ISNULL(c.band_name, N'') + N' is recommended' END,
                    CASE WHEN c.rbia_id IS NOT NULL AND (N',' + @bands + N',') NOT LIKE N'%,' + ISNULL(c.band_code, N'-') + N',%'
                         THEN N'Band ' + ISNULL(c.band_name, N'') + N' is not in the bands to recommend' END,
                    CASE WHEN c.never = 1 THEN N'Never audited' END,
                    CASE WHEN c.never = 0 AND c.due_by IS NOT NULL AND c.due_by <= @horizon
                         THEN N'Due by ' + CONVERT(NVARCHAR(10), c.due_by, 23) END,
                    CASE WHEN c.never = 0 AND c.due_by IS NOT NULL AND c.due_by > @horizon
                         THEN N'Not due until ' + CONVERT(NVARCHAR(10), c.due_by, 23) END,
                    CASE WHEN c.f_high > 0 THEN CAST(c.f_high AS NVARCHAR(10)) + N' open High / Critical finding(s)' END,
                    CASE WHEN c.reg_rank > 0 AND c.reg_rank = @reg_top THEN ISNULL(c.reg_name, N'') + N' regulatory significance' END,
                    CASE WHEN c.above > 0 THEN CAST(c.above AS NVARCHAR(10)) + N' linked risk(s) above appetite' END)
      FROM @c c;
    UPDATE @c SET s_from = CASE WHEN never = 1 OR due_by IS NULL OR due_by <= @pfrom THEN @pfrom
                                WHEN due_by > @pto THEN DATEFROMPARTS(YEAR(@pto), MONTH(@pto), 1)
                                ELSE DATEFROMPARTS(YEAR(due_by), MONTH(due_by), 1) END;
    UPDATE @c SET s_from = CASE WHEN s_from < @pfrom THEN @pfrom ELSE s_from END;
    UPDATE @c SET s_to = CASE WHEN EOMONTH(s_from) > @pto THEN @pto ELSE EOMONTH(s_from) END;

    -- Rank: Recommended, Optional, Not assessed; then the ranking order.
    WITH r AS (
        SELECT c.sid, ROW_NUMBER() OVER (ORDER BY
                   CASE c.kind WHEN N'RECOMMENDED' THEN 0 WHEN N'OPTIONAL' THEN 1 ELSE 2 END,
                   CASE @k1 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k2 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k3 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k4 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k5 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k6 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k7 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   CASE @k8 WHEN N'RESIDUAL_SCORE' THEN v.v_res WHEN N'PRIORITY' THEN v.v_pri WHEN N'REG_SIGNIFICANCE' THEN v.v_reg WHEN N'CRITICALITY' THEN v.v_crit WHEN N'LAST_AUDIT' THEN v.v_last WHEN N'OPEN_FINDINGS' THEN v.v_find WHEN N'OPEN_GAPS' THEN v.v_gaps WHEN N'ABOVE_APPETITE' THEN v.v_above END DESC,
                   c.subject_name, c.sid) AS rn
          FROM @c c
          CROSS APPLY (SELECT ISNULL(c.residual, -1)                                  AS v_res,
                              ISNULL(c.band_min, -1)                                  AS v_pri,
                              CAST(c.reg_rank AS DECIMAL(18,2))                       AS v_reg,
                              CAST(c.crit_rank AS DECIMAL(18,2))                      AS v_crit,
                              CAST(CASE WHEN c.never = 1 THEN 100000
                                        ELSE DATEDIFF(DAY, c.last_dt, @today) END AS DECIMAL(18,2)) AS v_last,
                              CAST(c.f_high * 1000 + c.f_open AS DECIMAL(18,2))       AS v_find,
                              CAST(c.gaps AS DECIMAL(18,2))                           AS v_gaps,
                              CAST(c.above AS DECIMAL(18,2))                          AS v_above) v)
    UPDATE c SET rank_no = r.rn FROM @c c JOIN r ON r.sid = c.sid;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @before INT = (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_recommendation WHERE org_assurance_plan_id = @plan_id);
    BEGIN TRAN;
    -- Proposed / Deferred: the facts refreshed (a period the Head of
    -- Internal Audit set is kept); Accepted / Rejected: the rank only.
    UPDATE t SET
        rec_kind = c.kind, reasons = c.reasons, rank_no = c.rank_no,
        rbia_assessment_id = c.rbia_id, rbia_ref = c.rbia_ref, residual_score = c.residual, band_code = c.band_code,
        band_name = c.band_name, audit_priority = c.priority, frequency_months = c.freq,
        reg_significance_name = c.reg_name, criticality_name = c.crit_name,
        last_audit_dt = c.last_dt, last_engagement_id = c.last_eng, last_engagement_code = c.last_code, last_result = c.last_result,
        due_by = c.due_by, never_audited = c.never, linked_risks = c.risks, above_appetite = c.above, open_treatment = c.treat,
        open_gaps = c.gaps, findings_total = c.f_total, open_findings = c.f_open, open_high_findings = c.f_high,
        relevant_definition_id = c.def_id, relevant_definition_name = c.def_name,
        suggested_from = CASE WHEN t.timing_set_by_user = 1 THEN t.suggested_from ELSE c.s_from END,
        suggested_to   = CASE WHEN t.timing_set_by_user = 1 THEN t.suggested_to ELSE c.s_to END,
        org_assurance_definition_id = ISNULL(t.org_assurance_definition_id, c.def_id),
        generated_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_plan_recommendation t
      JOIN @c c ON c.sid = t.universe_subject_id
     WHERE t.org_assurance_plan_id = @plan_id AND t.status IN (N'PROPOSED', N'DEFERRED');
    UPDATE t SET rank_no = c.rank_no
      FROM grac_practice.org_assurance_plan_recommendation t
      JOIN @c c ON c.sid = t.universe_subject_id
     WHERE t.org_assurance_plan_id = @plan_id AND t.status IN (N'ACCEPTED', N'REJECTED');
    INSERT INTO grac_practice.org_assurance_plan_recommendation
        (organization_id, org_assurance_plan_id, universe_subject_id, rec_kind, reasons, rank_no,
         rbia_assessment_id, rbia_ref, residual_score, band_code, band_name, audit_priority, frequency_months,
         reg_significance_name, criticality_name, last_audit_dt, last_engagement_id, last_engagement_code, last_result,
         due_by, never_audited, linked_risks, above_appetite, open_treatment, open_gaps, findings_total, open_findings,
         open_high_findings, relevant_definition_id, relevant_definition_name, suggested_from, suggested_to,
         org_assurance_definition_id, entered_by)
    SELECT @organization_id, @plan_id, c.sid, c.kind, c.reasons, c.rank_no,
           c.rbia_id, c.rbia_ref, c.residual, c.band_code, c.band_name, c.priority, c.freq,
           c.reg_name, c.crit_name, c.last_dt, c.last_eng, c.last_code, c.last_result,
           c.due_by, c.never, c.risks, c.above, c.treat, c.gaps, c.f_total, c.f_open,
           c.f_high, c.def_id, c.def_name, c.s_from, c.s_to,
           c.def_id, @actor
      FROM @c c
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_recommendation t
                        WHERE t.org_assurance_plan_id = @plan_id AND t.universe_subject_id = c.sid);
    SET @generated_count = (SELECT COUNT(*) FROM @c);
    DECLARE @added INT = (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_recommendation WHERE org_assurance_plan_id = @plan_id) - @before;
    DECLARE @gchanges NVARCHAR(MAX) = (SELECT @generated_count AS Subjects, @added AS Added,
                                              (SELECT COUNT(*) FROM @c WHERE kind = N'RECOMMENDED') AS Recommended,
                                              (SELECT COUNT(*) FROM @c WHERE kind = N'OPTIONAL') AS Optional,
                                              (SELECT COUNT(*) FROM @c WHERE kind = N'NOT_ASSESSED') AS NotAssessed,
                                              @bands AS IncludeBandCodes, @window AS DueWindowMonths, @rank AS RankingOrder
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    INSERT INTO grac_practice.org_assurance_plan_recommendation_history
        (organization_id, org_assurance_plan_id, plan_recommendation_id, action_code, comment, changes_json, employee_id, actor_name)
    VALUES (@organization_id, @plan_id, NULL, N'GENERATE',
            N'Generated for ' + CAST(@generated_count AS NVARCHAR(10)) + N' Active subject(s); ' + CAST(@added AS NVARCHAR(10)) + N' new.',
            @gchanges, @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 7. The recommendations of a plan
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_list
    @organization_id BIGINT,
    @plan_id         BIGINT,
    @rec_kind        NVARCHAR(20)  = NULL,
    @status          NVARCHAR(20)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @employee_id     BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hia BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                                          WHERE h.employee_id = @employee_id) THEN 1 ELSE 0 END;
    DECLARE @pstatus NVARCHAR(60) = (SELECT s.status_code FROM grac_practice.org_assurance_plan p
                                       JOIN grac_practice.org_assurance_plan_status_master s ON s.org_assurance_plan_status_id = p.status_id
                                      WHERE p.org_assurance_plan_id = @plan_id AND p.organization_id = @organization_id);
    DECLARE @open BIT = CASE WHEN @pstatus IN (N'Draft', N'Submitted') THEN 1 ELSE 0 END;

    SELECT r.plan_recommendation_id AS PlanRecommendationId, r.rank_no AS RankNo, r.rec_kind AS RecKind, r.reasons AS Reasons,
           r.universe_subject_id AS UniverseSubjectId, s.universe_ref AS UniverseRef, s.subject_name AS SubjectName,
           s.status_code AS SubjectStatus,
           r.rbia_assessment_id AS RbiaAssessmentId, r.rbia_ref AS RbiaRef, r.residual_score AS ResidualScore,
           r.band_code AS BandCode, r.band_name AS BandName, r.audit_priority AS AuditPriority, r.frequency_months AS FrequencyMonths,
           r.reg_significance_name AS RegSignificanceName, r.criticality_name AS CriticalityName,
           r.last_audit_dt AS LastAuditDt, r.last_engagement_code AS LastEngagementCode, r.last_result AS LastResult,
           r.due_by AS DueBy, r.never_audited AS NeverAudited, r.linked_risks AS LinkedRisks, r.above_appetite AS AboveAppetite,
           r.open_treatment AS OpenTreatmentActions, r.open_gaps AS OpenGaps, r.findings_total AS Findings,
           r.open_findings AS OpenFindings, r.open_high_findings AS OpenHighFindings,
           r.relevant_definition_id AS RelevantDefinitionId, r.relevant_definition_name AS RelevantDefinitionName,
           r.generated_dt AS GeneratedDt,
           r.status AS Status, r.suggested_from AS SuggestedFrom, r.suggested_to AS SuggestedTo,
           r.org_assurance_programme_id AS ProgrammeId, g.programme_code AS ProgrammeCode, g.programme_name AS ProgrammeName,
           r.org_assurance_definition_id AS DefinitionId, d.definition_code AS DefinitionCode, d.definition_name AS DefinitionName,
           r.org_assurance_plan_item_id AS EngagementId, er.EngagementCode, er.EngagementStatus,
           CAST(CASE WHEN r.org_assurance_plan_item_id IS NOT NULL AND (i.is_active = 0 OR er.EngagementStatus = N'Cancelled')
                     THEN 1 ELSE 0 END AS BIT) AS EngagementRemoved,
           r.decision_reason AS DecisionReason, r.decided_by_name AS DecidedBy, r.decided_dt AS DecidedDt,
           CAST(@hia & @open AS BIT) AS CanDecide
      FROM grac_practice.org_assurance_plan_recommendation r
      JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = r.universe_subject_id
      LEFT JOIN grac_practice.org_assurance_plan_programme g ON g.org_assurance_programme_id = r.org_assurance_programme_id
      LEFT JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = r.org_assurance_definition_id
      LEFT JOIN grac_practice.org_assurance_plan_item i ON i.org_assurance_plan_item_id = r.org_assurance_plan_item_id
      LEFT JOIN grac_practice.fn_org_assurance_engagement_rows(@organization_id) er ON er.EngagementId = r.org_assurance_plan_item_id
     WHERE r.organization_id = @organization_id AND r.org_assurance_plan_id = @plan_id
       AND (s.status_code = N'ACTIVE' OR r.status <> N'PROPOSED')
       AND (NULLIF(@rec_kind, N'') IS NULL OR r.rec_kind = @rec_kind)
       AND (NULLIF(@status, N'') IS NULL OR r.status = @status)
       AND (NULLIF(@search, N'') IS NULL OR s.universe_ref LIKE N'%' + @search + N'%' OR s.subject_name LIKE N'%' + @search + N'%')
     ORDER BY r.rank_no, s.subject_name;

    -- Summary.
    SELECT @pstatus AS PlanStatus, @open AS PlanOpen, @hia AS IsHeadOfInternalAudit,
           (SELECT MAX(action_dt) FROM grac_practice.org_assurance_plan_recommendation_history
             WHERE org_assurance_plan_id = @plan_id AND action_code = N'GENERATE') AS LastGeneratedDt,
           SUM(CASE WHEN r.rec_kind = N'RECOMMENDED' THEN 1 ELSE 0 END) AS Recommended,
           SUM(CASE WHEN r.rec_kind = N'OPTIONAL' THEN 1 ELSE 0 END) AS Optional,
           SUM(CASE WHEN r.rec_kind = N'NOT_ASSESSED' THEN 1 ELSE 0 END) AS NotAssessed,
           SUM(CASE WHEN r.status = N'PROPOSED' THEN 1 ELSE 0 END) AS Proposed,
           SUM(CASE WHEN r.status = N'ACCEPTED' THEN 1 ELSE 0 END) AS Accepted,
           SUM(CASE WHEN r.status = N'DEFERRED' THEN 1 ELSE 0 END) AS Deferred,
           SUM(CASE WHEN r.status = N'REJECTED' THEN 1 ELSE 0 END) AS Rejected
      FROM grac_practice.org_assurance_plan_recommendation r
      JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = r.universe_subject_id
     WHERE r.organization_id = @organization_id AND r.org_assurance_plan_id = @plan_id
       AND (s.status_code = N'ACTIVE' OR r.status <> N'PROPOSED');
END
GO

-- =====================================================================
-- 8. Change timing / programme / audit definition (Proposed, Deferred)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_update
    @organization_id        BIGINT,
    @plan_recommendation_id BIGINT,
    @suggested_from         DATE   = NULL,
    @suggested_to           DATE   = NULL,
    @programme_id           BIGINT = NULL,
    @definition_id          BIGINT = NULL,
    @employee_id            BIGINT,
    @actor                  NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @plan BIGINT, @status NVARCHAR(20), @old_from DATE, @old_to DATE, @old_prog BIGINT, @old_def BIGINT;
    SELECT @plan = org_assurance_plan_id, @status = status, @old_from = suggested_from, @old_to = suggested_to,
           @old_prog = org_assurance_programme_id, @old_def = org_assurance_definition_id
      FROM grac_practice.org_assurance_plan_recommendation
     WHERE plan_recommendation_id = @plan_recommendation_id AND organization_id = @organization_id;
    IF @plan IS NULL THROW 54160, 'The recommendation was not found in this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                    WHERE h.employee_id = @employee_id)
        THROW 54161, 'Only the Head of Internal Audit (or a delegate holding that responsibility) decides recommendations.', 1;
    IF @status NOT IN (N'PROPOSED', N'DEFERRED') THROW 54163, 'Only a Proposed or Deferred recommendation can be changed.', 1;
    DECLARE @pfrom DATE, @pto DATE, @pstatus NVARCHAR(60);
    SELECT @pfrom = p.period_from, @pto = p.period_to, @pstatus = s.status_code
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master s ON s.org_assurance_plan_status_id = p.status_id
     WHERE p.org_assurance_plan_id = @plan;
    IF @pstatus NOT IN (N'Draft', N'Submitted') THROW 54162, 'The plan is no longer Draft or Submitted.', 1;
    IF (CASE WHEN @suggested_from IS NULL THEN 0 ELSE 1 END) <> (CASE WHEN @suggested_to IS NULL THEN 0 ELSE 1 END)
       OR @suggested_from > @suggested_to
       OR @suggested_from < @pfrom OR @suggested_to > @pto
        THROW 54165, 'The audit period needs a start and an end, start before end, inside the plan period.', 1;
    IF @programme_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_programme
                                                  WHERE org_assurance_programme_id = @programme_id AND org_assurance_plan_id = @plan AND is_active = 1)
        THROW 54166, 'The programme is not one of this plan.', 1;
    IF @definition_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition
                                                   WHERE org_assurance_definition_id = @definition_id AND organization_id = @organization_id AND is_active = 1)
        THROW 54166, 'The audit definition was not found.', 1;

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @uchanges NVARCHAR(MAX) = (SELECT @old_from AS OldFrom, @suggested_from AS SuggestedFrom, @old_to AS OldTo, @suggested_to AS SuggestedTo,
                                              @old_prog AS OldProgrammeId, @programme_id AS ProgrammeId,
                                              @old_def AS OldDefinitionId, @definition_id AS DefinitionId
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);
    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_plan_recommendation
       SET suggested_from = @suggested_from, suggested_to = @suggested_to,
           timing_set_by_user = CASE WHEN @suggested_from IS NULL THEN 0 ELSE 1 END,
           org_assurance_programme_id = @programme_id, org_assurance_definition_id = @definition_id,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE plan_recommendation_id = @plan_recommendation_id;
    INSERT INTO grac_practice.org_assurance_plan_recommendation_history
        (organization_id, org_assurance_plan_id, plan_recommendation_id, action_code, from_status, to_status, comment, changes_json, employee_id, actor_name)
    VALUES (@organization_id, @plan, @plan_recommendation_id, N'UPDATE', @status, @status,
            N'Timing / programme / audit definition changed', @uchanges, @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 9. Defer / Reject / Reopen
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_action
    @organization_id        BIGINT,
    @plan_recommendation_id BIGINT,
    @action                 NVARCHAR(20),
    @reason                 NVARCHAR(2000) = NULL,
    @employee_id            BIGINT,
    @actor                  NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @action = UPPER(LTRIM(RTRIM(@action)));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @plan BIGINT, @status NVARCHAR(20), @item BIGINT;
    SELECT @plan = org_assurance_plan_id, @status = status, @item = org_assurance_plan_item_id
      FROM grac_practice.org_assurance_plan_recommendation
     WHERE plan_recommendation_id = @plan_recommendation_id AND organization_id = @organization_id;
    IF @plan IS NULL THROW 54160, 'The recommendation was not found in this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                    WHERE h.employee_id = @employee_id)
        THROW 54161, 'Only the Head of Internal Audit (or a delegate holding that responsibility) decides recommendations.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan p
                     JOIN grac_practice.org_assurance_plan_status_master s ON s.org_assurance_plan_status_id = p.status_id
                    WHERE p.org_assurance_plan_id = @plan AND s.status_code IN (N'Draft', N'Submitted'))
        THROW 54162, 'The plan is no longer Draft or Submitted.', 1;
    -- An accepted one reopens only when its engagement was removed or cancelled.
    DECLARE @removed BIT = CASE WHEN @item IS NOT NULL AND (
                                     NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_item
                                                  WHERE org_assurance_plan_item_id = @item AND is_active = 1)
                                  OR EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_item
                                              WHERE org_assurance_plan_item_id = @item AND cancelled_dt IS NOT NULL))
                                THEN 1 ELSE 0 END;
    IF @action NOT IN (N'DEFER', N'REJECT', N'REOPEN') THROW 54163, 'Unknown action.', 1;
    IF (@action = N'DEFER' AND @status <> N'PROPOSED')
       OR (@action = N'REJECT' AND @status NOT IN (N'PROPOSED', N'DEFERRED'))
       OR (@action = N'REOPEN' AND NOT (@status IN (N'DEFERRED', N'REJECTED') OR (@status = N'ACCEPTED' AND @removed = 1)))
        THROW 54163, 'The recommendation is not in a state that allows this.', 1;
    IF @action = N'REJECT' AND @reason IS NULL THROW 54164, 'Give the reason for rejecting it.', 1;

    DECLARE @to NVARCHAR(20) = CASE @action WHEN N'DEFER' THEN N'DEFERRED' WHEN N'REJECT' THEN N'REJECTED' ELSE N'PROPOSED' END;
    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_plan_recommendation
       SET status = @to,
           decision_reason = CASE WHEN @to = N'PROPOSED' THEN NULL ELSE @reason END,
           decided_by_employee_id = CASE WHEN @to = N'PROPOSED' THEN NULL ELSE @employee_id END,
           decided_by_name = CASE WHEN @to = N'PROPOSED' THEN NULL ELSE @me END,
           decided_dt = CASE WHEN @to = N'PROPOSED' THEN NULL ELSE SYSUTCDATETIME() END,
           org_assurance_plan_item_id = CASE WHEN @to = N'PROPOSED' THEN NULL ELSE org_assurance_plan_item_id END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE plan_recommendation_id = @plan_recommendation_id;
    INSERT INTO grac_practice.org_assurance_plan_recommendation_history
        (organization_id, org_assurance_plan_id, plan_recommendation_id, action_code, from_status, to_status, comment, employee_id, actor_name)
    VALUES (@organization_id, @plan, @plan_recommendation_id, @action, @status, @to, @reason, @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 10. Accept: link the engagement created from the recommendation (the
--     engagement form saved it through sp_org_assurance_plan_item_save)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_link
    @organization_id        BIGINT,
    @plan_recommendation_id BIGINT,
    @plan_item_id           BIGINT,
    @comment                NVARCHAR(2000) = NULL,
    @employee_id            BIGINT,
    @actor                  NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @plan BIGINT, @status NVARCHAR(20), @sid BIGINT;
    SELECT @plan = org_assurance_plan_id, @status = status, @sid = universe_subject_id
      FROM grac_practice.org_assurance_plan_recommendation
     WHERE plan_recommendation_id = @plan_recommendation_id AND organization_id = @organization_id;
    IF @plan IS NULL THROW 54160, 'The recommendation was not found in this organization.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_org_responsibility_holder(@organization_id, N'HEAD_INTERNAL_AUDIT') h
                    WHERE h.employee_id = @employee_id)
        THROW 54161, 'Only the Head of Internal Audit (or a delegate holding that responsibility) accepts recommendations.', 1;
    IF @status NOT IN (N'PROPOSED', N'DEFERRED') THROW 54163, 'Only a Proposed or Deferred recommendation can be accepted.', 1;
    DECLARE @prog BIGINT, @from DATE, @to DATE, @linked BIGINT;
    SELECT @prog = org_assurance_programme_id, @from = scheduled_from, @to = scheduled_to, @linked = universe_subject_id
      FROM grac_practice.org_assurance_plan_item
     WHERE org_assurance_plan_item_id = @plan_item_id AND organization_id = @organization_id
       AND org_assurance_plan_id = @plan AND is_active = 1;
    IF @@ROWCOUNT = 0 THROW 54167, 'The engagement is not one of this plan.', 1;
    IF @linked IS NOT NULL AND @linked <> @sid THROW 54167, 'The engagement is already linked to another Universe subject.', 1;
    DECLARE @def BIGINT = (SELECT TOP (1) org_assurance_definition_id FROM grac_practice.org_assurance_engagement_definition
                            WHERE org_assurance_plan_item_id = @plan_item_id AND is_active = 1 ORDER BY display_order);

    DECLARE @me NVARCHAR(240) = ISNULL((SELECT employee_name FROM grac_practice.organization_employee
                                         WHERE employee_id = @employee_id AND organization_id = @organization_id), @actor);
    DECLARE @code NVARCHAR(80) = (SELECT engagement_code FROM grac_practice.org_assurance_plan_item WHERE org_assurance_plan_item_id = @plan_item_id);
    BEGIN TRAN;
    UPDATE grac_practice.org_assurance_plan_item
       SET universe_subject_id = @sid, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE org_assurance_plan_item_id = @plan_item_id;
    UPDATE grac_practice.org_assurance_plan_recommendation
       SET status = N'ACCEPTED', org_assurance_plan_item_id = @plan_item_id,
           org_assurance_programme_id = @prog, org_assurance_definition_id = ISNULL(@def, org_assurance_definition_id),
           suggested_from = ISNULL(@from, suggested_from), suggested_to = ISNULL(@to, suggested_to),
           decision_reason = NULLIF(LTRIM(RTRIM(@comment)), N''), decided_by_employee_id = @employee_id, decided_by_name = @me,
           decided_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE plan_recommendation_id = @plan_recommendation_id;
    INSERT INTO grac_practice.org_assurance_plan_recommendation_history
        (organization_id, org_assurance_plan_id, plan_recommendation_id, action_code, from_status, to_status, comment, employee_id, actor_name)
    VALUES (@organization_id, @plan, @plan_recommendation_id, N'ACCEPT', @status, N'ACCEPTED',
            N'Engagement ' + ISNULL(@code, CAST(@plan_item_id AS NVARCHAR(20))) + N' created'
            + ISNULL(N'. ' + NULLIF(LTRIM(RTRIM(@comment)), N''), N''), @employee_id, @me);
    COMMIT;
END
GO

-- =====================================================================
-- 11. Decision history of a plan (or of one recommendation)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_recommendation_history
    @organization_id        BIGINT,
    @plan_id                BIGINT,
    @plan_recommendation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.plan_rec_history_id AS HistoryId, h.plan_recommendation_id AS PlanRecommendationId,
           s.universe_ref AS UniverseRef, s.subject_name AS SubjectName,
           h.action_code AS ActionCode, h.from_status AS FromStatus, h.to_status AS ToStatus, h.comment AS Comment,
           h.changes_json AS ChangesJson, h.actor_name AS ActorName, h.action_dt AS ActionDt
      FROM grac_practice.org_assurance_plan_recommendation_history h
      LEFT JOIN grac_practice.org_assurance_plan_recommendation r ON r.plan_recommendation_id = h.plan_recommendation_id
      LEFT JOIN grac_practice.org_assurance_universe_subject s ON s.universe_subject_id = r.universe_subject_id
     WHERE h.organization_id = @organization_id AND h.org_assurance_plan_id = @plan_id
       AND (@plan_recommendation_id IS NULL OR h.plan_recommendation_id = @plan_recommendation_id)
     ORDER BY h.action_dt DESC, h.plan_rec_history_id DESC;
END
GO

-- =====================================================================
-- 12. Menu: Audit Intelligence -> Audit Plan Recommendations (70); the
--     Audit Plans permissions copied; also in 274.
-- =====================================================================
DECLARE @intel_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-audit-intelligence');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'org-audit-plan-recommendations', N'Audit Plan Recommendations', N'Practice/org-audit-plan-recommendations', 70, N'list-check')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @intel_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Audit Assurance',
    status = N'Active', updated_by = 'seed-583', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @intel_id, src.display_order,
     src.icon_class, N'Audit Assurance', N'Active', 'seed-583');
PRINT '583.12: Audit Plan Recommendations menu rows upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT p.role_id, m.menu_id, p.can_view, p.can_add, p.can_edit, p.can_delete, p.can_approve,
       p.status, p.record_status_id, N'seed-583', SYSUTCDATETIME()
FROM   grac_practice.organization_role_menu_permission p
JOIN   grac_practice.menu_master pm ON pm.menu_id = p.menu_id AND pm.menu_key = N'org-assurance-plans'
JOIN   grac_practice.menu_master m  ON m.menu_key = N'org-audit-plan-recommendations'
WHERE  NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission x
        WHERE x.role_id = p.role_id AND x.menu_id = m.menu_id);
PRINT '583.12: Audit Plan Recommendations permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 13. Verification
-- =====================================================================
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + n.name + N' '
  FROM (VALUES (N'fn_org_assurance_universe_subject_instances'), (N'fn_org_assurance_universe_subject_gaps'),
               (N'fn_org_assurance_universe_subject_risks'), (N'fn_org_assurance_universe_subject_findings'),
               (N'fn_org_assurance_universe_subject_audit'), (N'sp_org_assurance_universe_risk_intelligence'),
               (N'sp_org_assurance_plan_rec_setting_get'), (N'sp_org_assurance_plan_rec_setting_save'),
               (N'sp_org_assurance_plan_recommendation_generate'), (N'sp_org_assurance_plan_recommendation_list'),
               (N'sp_org_assurance_plan_recommendation_update'), (N'sp_org_assurance_plan_recommendation_action'),
               (N'sp_org_assurance_plan_recommendation_link'), (N'sp_org_assurance_plan_recommendation_history')) n(name)
 WHERE OBJECT_ID(N'grac_practice.' + n.name) IS NULL;
IF @missing <> N'' RAISERROR('583 verification: missing objects: %s', 16, 1, @missing);
SELECT (SELECT COUNT(*) FROM grac_practice.menu_master
         WHERE menu_key = N'org-audit-plan-recommendations' AND status = N'Active') AS menu_rows;
PRINT '583 done: Audit Intelligence -- Audit Plan Recommendations (engine, settings, decisions, engagement link).';
GO
