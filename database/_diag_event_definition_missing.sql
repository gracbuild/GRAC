-- =====================================================================
-- _diag_event_definition_missing.sql
--
-- For: "sp_event_instance_raise_scoped: event definition not found for
--       organization." (error 67223) when pressing Raise Event.
--
-- READ-ONLY. Changes nothing. Run it in the grac_practice database and
-- read the six result sets top to bottom.
--
-- ---------------------------------------------------------------------
-- WHAT THE ERROR MEANS
-- ---------------------------------------------------------------------
-- The Raise Event button posts to /scope/raise/people or /scope/raise/asset,
-- which runs sp_event_raise_people_lifecycle / sp_event_raise_asset_lifecycle.
-- Neither takes an event code from the screen, so both default it:
--
--     ONBOARD      -> PEOPLE_ONBOARDING
--     OFFBOARD     -> PEOPLE_OFFBOARDING
--     COMMISSION   -> ASSET_COMMISSIONING
--     DECOMMISSION -> ASSET_DECOMMISSIONING
--
-- and hand it to sp_event_instance_raise_scoped, which resolves it with
--
--     SELECT TOP 1 event_definition_id
--     FROM   grac_practice.event_definition
--     WHERE  organization_id = @organization_id
--       AND  event_code      = @event_code
--       AND  status          = N'Active';
--
-- No row -> THROW 67223. So one of three things is true for the
-- organization you raised it on:
--
--   (a) it has no event_definition row for that code at all -- the usual
--       cause: migration 126 seeded the four codes for every organization
--       that existed WHEN IT RAN, and has no hook for organizations
--       created afterwards;
--   (b) the row exists but its status is not exactly N'Active';
--   (c) the caller passed a custom @event_code that nobody has defined.
--
-- Section 2 below says which.
-- =====================================================================
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------
-- 1. Do the objects even exist at the expected build?
-- ---------------------------------------------------------------------
SELECT '1. objects' AS Section, o.name AS Object_,
       CASE WHEN OBJECT_ID('grac_practice.' + o.name) IS NOT NULL
            THEN 'present' ELSE 'MISSING' END AS State
FROM  (VALUES (N'event_definition'), (N'entity_type_master'),
              (N'sp_event_instance_raise_scoped'),
              (N'sp_event_raise_people_lifecycle'),
              (N'sp_event_raise_asset_lifecycle'),
              (N'sp_event_definition_ensure_baseline')   -- only after 335
       ) AS o(name);
GO

-- ---------------------------------------------------------------------
-- 2. THE ANSWER. One row per active organization x the four lifecycle
--    codes, saying exactly what the resolver would find.
--
--    Anything other than 'OK' in Verdict is a raise that will throw
--    67223 for that organization and that action.
-- ---------------------------------------------------------------------
SELECT '2. per org' AS Section,
       o.organization_id            AS OrganizationId,
       o.organization_name          AS OrganizationName,
       o.status                     AS OrgStatus,
       v.event_code                 AS EventCode,
       v.raised_by                  AS RaisedBy,
       ed.event_definition_id       AS EventDefinitionId,
       ed.status                    AS DefinitionStatus,
       CASE WHEN ed.event_definition_id IS NULL THEN 'MISSING -- no row'
            WHEN ed.status <> N'Active'         THEN 'INACTIVE -- status is ' + ISNULL(ed.status, N'(null)')
            ELSE 'OK' END           AS Verdict
FROM   grac_practice.organization o
CROSS  JOIN (VALUES
          (N'PEOPLE_ONBOARDING',     N'Raise Event -> Onboard'),
          (N'PEOPLE_OFFBOARDING',    N'Raise Event -> Offboard'),
          (N'ASSET_COMMISSIONING',   N'Raise Event -> Commission'),
          (N'ASSET_DECOMMISSIONING', N'Raise Event -> Decommission')
       ) AS v(event_code, raised_by)
LEFT   JOIN grac_practice.event_definition ed
       ON ed.organization_id = o.organization_id
      AND ed.event_code      = v.event_code
WHERE  o.status = N'Active'
ORDER  BY o.organization_id, v.event_code;
GO

-- ---------------------------------------------------------------------
-- 3. Organizations that migration 126 could never have reached.
--
--    126 seeds WHERE o.status = N'Active'. An organization whose status
--    is spelled differently ('active', 'ACTIVE', NULL) was skipped by the
--    seed AND is skipped by section 2 above -- so if the org you raised
--    on is not listed there at all, look for it here.
-- ---------------------------------------------------------------------
SELECT '3. non-Active orgs' AS Section,
       organization_id AS OrganizationId, organization_name AS OrganizationName,
       '[' + ISNULL(status, N'(null)') + ']' AS StatusExactly
FROM   grac_practice.organization
WHERE  status IS NULL OR status <> N'Active';
GO

-- ---------------------------------------------------------------------
-- 4. Every event_definition actually on file, so a custom code the
--    caller passed (cause (c)) is visible rather than guessed at.
-- ---------------------------------------------------------------------
SELECT '4. all definitions' AS Section,
       ed.organization_id AS OrganizationId, ed.event_code AS EventCode,
       ed.event_name AS EventName, ed.entity_category AS EntityCategory,
       ed.status AS Status, ed.entered_by AS EnteredBy, ed.entered_dt AS EnteredOn
FROM   grac_practice.event_definition ed
ORDER  BY ed.organization_id, ed.event_code;
GO

-- ---------------------------------------------------------------------
-- 5. The obligation side of the same raise.
--
--    The wrappers raise the OBLIGATION path only when the same code also
--    exists in GRAC_New.event_type_master. A code present here but absent
--    in section 2 raises obligations and no checklists, and vice versa --
--    which is a different complaint ("it raised, but nothing appeared")
--    and worth seeing next to this one.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.event_type_master','U') IS NULL
    SELECT '5. GRAC_New event types' AS Section,
           'GRAC_New.event_type_master not present' AS Note;
ELSE
    SELECT '5. GRAC_New event types' AS Section,
           etm.event_code AS EventCode, etm.status AS Status
    FROM   GRAC_New.event_type_master etm
    WHERE  etm.event_code IN (N'PEOPLE_ONBOARDING', N'PEOPLE_OFFBOARDING',
                              N'ASSET_COMMISSIONING', N'ASSET_DECOMMISSIONING')
    ORDER  BY etm.event_code;
GO

-- ---------------------------------------------------------------------
-- 6. What to do.
-- ---------------------------------------------------------------------
SELECT '6. next step' AS Section, Fix
FROM  (VALUES
 (N'MISSING rows in section 2  -> run 335_event_definition_ensure_baseline.sql. It creates the four codes for every active organization that lacks them, and makes the raise create them itself for organizations added later.'),
 (N'INACTIVE rows in section 2 -> somebody deactivated that event on purpose. 335 deliberately will NOT reactivate it. Reactivate it on the Events screen, or decide the event should not be raised.'),
 (N'Org missing from section 2 but listed in section 3 -> its organization.status is not exactly N''Active''. Fix the status; the seed and the resolver both key on it.'),
 (N'Code in section 4 that nobody expected -> a caller is passing a custom @event_code. Define it on the Events screen or stop passing it.')
      ) AS t(Fix);
GO
