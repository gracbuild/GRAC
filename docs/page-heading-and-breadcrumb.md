# Page heading and breadcrumb — one path, not two (2026-11-02)

## The report
Every screen showed its location twice, and the two disagreed:

```
header breadcrumb :  Home / Practice Management / Standards & Frameworks
card eyebrow      :  GOVERNANCE / STANDARDS & FRAMEWORKS
```

The lower one is right — `organization-controls` is in the **Governance** group. The ask: make
the breadcrumb correct and drop the duplicate underneath, without editing every page.

## Why the breadcrumb was wrong
`_Layout.cshtml` built the middle segment from a hand-maintained chain:

```csharp
var currentGroup = isOrganizationManagementModule ? "Organization Management"
                 : onboardingOpen   ? PracticeScreen.OrganizationOnboardingGroup
                 : organizationOpen ? PracticeScreen.OrganizationAdministrationGroup
                 : dependencyOpen   ? PracticeScreen.OrganizationDependenciesGroup
                 : practiceOpen     ? PracticeScreen.PracticeManagementGroup
                 : "Practice Management";
```

It knew four groups. `PracticeScreen` defines **more than twenty**. Everything outside those
four — Governance, Issues & Actions, Asset & Contract, Assurance Management, Operations,
Administration, Third-Party Risk, Audit Assurance, Policies & Documents, Registers,
Organization — fell through to the literal `"Practice Management"`.

The card eyebrow never had that problem: it printed `@Model.Group / @Model.Title`, the screen's
own group. So the two were bound to drift, and the chain would have to be extended by hand for
every group added since.

Counted across `PracticeScreen.All`: **101 of 116 screens** were showing the wrong group in the
breadcrumb.

## The fix — two changes, both central

### 1. `Views/Shared/_Layout.cshtml` — the breadcrumb reads the screen's own group
```csharp
var currentScreenGroup = PracticeScreen.All.FirstOrDefault(x => x.Key == currentArea)?.Group;
var currentGroup = isOrganizationManagementModule ? "Organization Management"
                 : !string.IsNullOrWhiteSpace(currentScreenGroup) ? currentScreenGroup
                 : <the old chain, unchanged, as the fallback>;
```

- Read from **`PracticeScreen.All`**, not `ViewBag.Screens`: the latter is filtered to what the
  menu shows for the signed-in role, so it would miss every sub-page (`gap-detail`,
  `task-edit`, `gap-view`, `task-view`, …) and those would silently keep the old fallback.
- The old chain stays as the fallback for a key that is in no definition at all, so nothing
  regresses if a route appears that `All` does not know.
- `string.IsNullOrWhiteSpace` is annotated `[NotNullWhen(false)]`, so the non-null branch is
  clean under the project's `<Nullable>enable</Nullable>`.

Now the breadcrumb and the eyebrow are the same value by construction — they cannot drift
again, and a new group needs no layout change.

### 2. `wwwroot/css/practice-management.css` — the duplicate disappears everywhere
```css
.pm-page-heading:not(.pm-dashboard-heading) .pm-eyebrow { display: none; }
```

**Why CSS and not deleting the markup.** The eyebrow is written out by hand in **84 places
across 76 views** — `Manage.cshtml` (which covers every generic grid screen) plus each
full-page partial. There is no single shared heading component to edit. One rule removes it
from every page that exists today *and* from any page added later by copy-paste, and it is one
line to revert. The `<p>` stays in the DOM, so nothing that reads the heading block changes.

**Two deliberate exclusions:**
- `.pm-dashboard-heading` (Practice/Dashboard.cshtml) — its eyebrow is `Home`, not a repeat of
  the breadcrumb, so it is left alone.
- `.pm-hero` (Home/Index.cshtml) — its eyebrow is `GRAC Part 2`, and it is not inside
  `.pm-page-heading`, so the rule never matches it.

Specificity is 0,3,0, above the two existing `.pm-eyebrow` rules (0,1,0 in
`practice-management.css`, 0,2,0 in `master-layout.css`), and neither of those sets `display`.

## Answering "does every page need doing?"
No. Two files. The breadcrumb fix is one lookup in the layout; the duplicate is one CSS rule.
Nothing under `Views/Practice/Partials/` was touched.

## Verification
- `PracticeScreen.All` parsed and the old chain simulated against it: 101 of 116 screens had the
  wrong breadcrumb group before, 0 after. Spot-checked `organization-controls`:
  `Home / Practice Management / Standards & Frameworks` becomes
  `Home / Governance / Standards & Frameworks`, matching the card.
- Grepped every `display` declaration on `.pm-eyebrow`: only the new rule.
- Both eyebrow uses outside `.pm-page-heading` confirmed unaffected.

## If the markup should go for real
The CSS rule is the visible fix; the 84 `<p class="pm-eyebrow">@Model.Group / @Model.Title</p>`
lines are now dead. Removing them is a mechanical sweep of 76 views and can be done as its own
change — the CSS rule would then be deleted in the same pass.
