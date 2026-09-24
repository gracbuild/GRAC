-- =====================================================================
-- 230 Trigger mode and event type vocabulary
--
-- WHY
-- ---
-- Migration 228 inferred the Assurance trigger rule from Control
-- Management's rows, and 229 patched the hole that left. Both were
-- working around not being able to see Control Management's code.
--
-- We can see it now. CM's own form
-- (ControlManagement.Web/wwwroot/js/obligation-master-form.js) says
-- exactly what the Assurance panel is:
--
--     Verification Method
--     Trigger Mode  ->  Scheduled    : Assurance Frequency
--                       EventDriven  : Event Domain -> Event, Due Within (days)
--
-- and its CHECK constraint (CM 033) enforces it:
--
--     (trigger_mode IS NULL         AND event_type_id IS NULL)
--  OR (trigger_mode = 'Scheduled'   AND event_type_id IS NULL)
--  OR (trigger_mode = 'EventDriven' AND event_type_id IS NOT NULL)
--
-- The Practice Management add form now mirrors that panel field for
-- field, which needs two vocabularies it did not have: the trigger modes
-- and the event type tree. Both already exist in GRAC_New; this exposes
-- them to the Resolve workspace.
--
-- INFERENCE IS NOT REMOVED, IT IS DEMOTED
-- ---------------------------------------
-- 228/229 stay. They still answer for every type whose panel is not
-- mirrored, and for a Control Management release that adds a driver
-- column nobody has told this module about. What changes is precedence:
-- where a mirrored definition exists it wins, because it is the actual
-- contract rather than a reading of the data.
--
-- WHY NOT JUST CALL CM'S sp_cm_event_type_list
-- --------------------------------------------
-- It is called, inside this procedure -- but wrapped rather than exposed
-- directly. Practice Management's Web tier reaches the database only
-- through its own Api and its own procedures; pointing the workspace at
-- a Control Management procedure by name would put a second module's
-- contract into a PM call site, and the wrapper is where the guard for
-- "CM 033 not applied here" belongs anyway.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: CREATE OR ALTER; reads only.
--
-- DEPENDS ON: Control Management 033 (event_type_master, the
--             assurance-trigger-modes reference options). Degrades to
--             empty result sets without it.
-- Rollback:   database/230_obligation_trigger_vocabulary_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (230): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_obligation_vocabulary
--
--   Result set 1: trigger modes  (reference_option 'assurance-trigger-modes')
--   Result set 2: event types    (event_type_master, flat, with parent)
--
--   Both are empty rather than absent when Control Management 033 has
--   not been applied here -- the form then falls back to the inferred
--   rules from 228/229, which is exactly what it did before.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_vocabulary
AS
BEGIN
    SET NOCOUNT ON;

    -- ---- 1. Trigger modes ----
    -- option_value is what the column stores and what the CHECK
    -- constraint tests; option_label is what the dropdown shows. CM 033
    -- is explicit that these two codes are not extensible reference data
    -- -- application code branches on exactly them -- so the labels are
    -- table-driven while the values are fixed by constraint.
    IF OBJECT_ID('GRAC_New.reference_option','U') IS NOT NULL
        SELECT ro.option_value AS TriggerMode,
               ro.option_label AS TriggerModeLabel,
               ro.display_order AS DisplayOrder
        FROM   GRAC_New.reference_option ro
        WHERE  ro.option_group = N'assurance-trigger-modes'
          AND  ro.status = N'Active'
        ORDER  BY ISNULL(ro.display_order, 999), ro.option_label;
    ELSE
        SELECT CAST(NULL AS NVARCHAR(60))  AS TriggerMode,
               CAST(NULL AS NVARCHAR(200)) AS TriggerModeLabel,
               CAST(NULL AS INT)           AS DisplayOrder
        WHERE  1 = 0;

    -- ---- 2. Event types ----
    -- Flat, with the parent id, exactly as CM's own sp_cm_event_type_list
    -- returns it: the form builds the domain -> event cascade from
    -- ParentEventTypeId rather than the server pre-nesting it, so one
    -- call serves both levels.
    --
    -- Only Active rows, and only what can actually be raised -- the same
    -- rule CM's obligation form applies when it calls its procedure with
    -- @p_include_inactive = 0.
    IF OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL
        SELECT e.event_type_id        AS EventTypeId,
               e.parent_event_type_id AS ParentEventTypeId,
               e.event_code           AS EventCode,
               e.event_name           AS EventName,
               e.description          AS Description,
               CAST(CASE WHEN e.parent_event_type_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsDomain,
               e.display_order        AS DisplayOrder
        FROM   GRAC_New.event_type_master e
        WHERE  e.status = N'Active'
          -- A leaf whose domain has been retired must not be offered; it
          -- would save an event nothing can raise.
          AND  (e.parent_event_type_id IS NULL
                OR EXISTS (SELECT 1 FROM GRAC_New.event_type_master p
                            WHERE p.event_type_id = e.parent_event_type_id
                              AND p.status = N'Active'))
        ORDER  BY ISNULL(e.display_order, 999), e.event_name;
    ELSE
        SELECT CAST(NULL AS BIGINT)        AS EventTypeId,
               CAST(NULL AS BIGINT)        AS ParentEventTypeId,
               CAST(NULL AS NVARCHAR(60))  AS EventCode,
               CAST(NULL AS NVARCHAR(120)) AS EventName,
               CAST(NULL AS NVARCHAR(500)) AS Description,
               CAST(NULL AS BIT)           AS IsDomain,
               CAST(NULL AS INT)           AS DisplayOrder
        WHERE  1 = 0;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 230 verification ===';

SELECT 'vocabulary procedure present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_vocabulary','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'event_type_master reachable',
       CASE WHEN OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL
            THEN 'PASS' ELSE 'REVIEW -- Control Management 033 not applied; the event cascade will be empty' END
UNION ALL
SELECT 'trigger modes seeded',
       CASE WHEN OBJECT_ID('GRAC_New.reference_option','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM GRAC_New.reference_option
                          WHERE option_group = N'assurance-trigger-modes' AND status = N'Active')
            THEN 'PASS' ELSE 'REVIEW -- the form falls back to a text box' END;

PRINT '=== Trigger modes the form will offer ===';
IF OBJECT_ID('GRAC_New.reference_option','U') IS NOT NULL
    SELECT option_value AS TriggerMode, option_label AS Label, display_order AS DisplayOrder
    FROM   GRAC_New.reference_option
    WHERE  option_group = N'assurance-trigger-modes' AND status = N'Active'
    ORDER  BY ISNULL(display_order, 999);

PRINT '=== Event domains and how many events each carries ===';
IF OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL
    SELECT d.event_type_id AS DomainId,
           d.event_name    AS Domain,
           COUNT(e.event_type_id) AS Events
    FROM   GRAC_New.event_type_master d
    LEFT   JOIN GRAC_New.event_type_master e
           ON e.parent_event_type_id = d.event_type_id AND e.status = N'Active'
    WHERE  d.parent_event_type_id IS NULL AND d.status = N'Active'
    GROUP  BY d.event_type_id, d.event_name
    ORDER  BY d.event_name;

PRINT '';
PRINT '230 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
