    -- 581: open enterprise risks -- whose Impact Details name the subject's
    -- registry records, whose Business Function is the subject's function,
    -- or mapped to the subject's suggested / confirmed practice instances.
    INSERT INTO @sug (mapping_level, record_key, basis)
    SELECT N'RISK', CAST(x.risk_register_id AS NVARCHAR(80)), LEFT(MIN(x.basis), 400)
      FROM (
            SELECT dm.risk_register_id, N'Impacts ' + r.label AS basis
              FROM @rec r
              JOIN grac_practice.dependency_type_master dt
                   ON dt.dependency_type_code = CASE r.kind WHEN N'LOCATION' THEN N'Location' WHEN N'DEPARTMENT' THEN N'Department'
                                                            WHEN N'FUNCTION' THEN N'BusinessFunction' WHEN N'PROCESS' THEN N'Process' END
              JOIN grac_practice.risk_dependency_map dm
                   ON dm.organization_id = @organization_id AND dm.dependency_type_id = dt.dependency_type_id
                  AND dm.dependency_object_id = r.record_id
             WHERE dm.record_status_id IS NULL
                OR dm.record_status_id IN (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active')
            UNION ALL
            SELECT rr.risk_register_id, N'Business function of the risk: ' + r.label
              FROM @rec r
              JOIN grac_practice.risk_register rr
                   ON rr.organization_id = @organization_id AND rr.business_function_id = r.record_id
             WHERE r.kind = N'FUNCTION'
            UNION ALL
            SELECT pm.risk_register_id, N'Mapped to practice instance ' + ISNULL(pi.instance_code, N'')
              FROM grac_practice.risk_practice_map pm
              JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pm.practice_instance_id
             WHERE pm.organization_id = @organization_id
               AND (pm.record_status_id IS NULL
                    OR pm.record_status_id IN (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active'))
               AND (pm.practice_instance_id IN (SELECT practice_instance_id FROM @inst)
                    OR pm.practice_instance_id IN (SELECT TRY_CAST(m.record_key AS BIGINT)
                                                     FROM grac_practice.org_assurance_universe_mapping m
                                                    WHERE m.universe_subject_id = @universe_subject_id
                                                      AND m.mapping_level = N'PRACTICE_INSTANCE'
                                                      AND m.mapping_status = N'CONFIRMED'))
           ) x
      JOIN grac_practice.risk_register rr2
           ON rr2.risk_register_id = x.risk_register_id AND rr2.organization_id = @organization_id
          AND rr2.status_code NOT IN (N'Closed', N'Retired', N'ClosedAsDuplicate', N'Rejected')
     GROUP BY x.risk_register_id;
