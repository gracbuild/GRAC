// =====================================================================
// window.gracEvidenceSource -- "how is this evidence provided?"
// (migrations 481 / 482).
//
// The three options, their radio group and the show-one-panel rule, in
// one place. Used by:
//   * Operationalize one-time evidence (resolve-workspace.cshtml, 481)
//   * Complete Task recurring evidence (Shared/task-actions.js, 482)
//
// USAGE
//   const S = window.gracEvidenceSource;
//   S.radios('grp-12', 'External', { 'data-ev-source': 12 })  // markup
//   S.panel('External', current, '<div>...</div>')            // markup
//   S.showPanels(rowElement, 'DirectUpload')                   // toggle
//
// A panel lists the option code(s) it belongs to, space separated, in
// data-ev-src-panel; showPanels hides every other panel inside the root.
// Radios use the shared .radio-group / .radio-option styles
// (css/cacca-styles.css).
// =====================================================================
(() => {
  "use strict";

  const SOURCES = [
    { code: "DirectUpload",   label: "Direct Upload" },
    { code: "EvidenceCenter", label: "Evidence Center Reference" },
    { code: "External",       label: "External Evidence Reference" }
  ];
  const DEFAULT = "DirectUpload";

  const esc = v => String(v ?? "").replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const isKnown = v => SOURCES.some(s => s.code === v);

  // attrs address the group (data-* attributes the host wires on).
  function radios(groupName, current, attrs) {
    const a = Object.keys(attrs || {}).map(k => " " + k + '="' + esc(attrs[k]) + '"').join("");
    return '<div class="radio-group rw-evidence-source" role="radiogroup" aria-label="How the evidence is provided"' + a + ">"
         + SOURCES.map(s =>
             '<label class="radio-option"><input type="radio" name="' + esc(groupName) + '" value="' + s.code + '"'
             + (s.code === current ? " checked" : "") + "> " + esc(s.label) + "</label>").join("")
         + "</div>";
  }

  // A block shown only for the listed option(s), space separated.
  function panel(codes, current, html, attrs) {
    const a = Object.keys(attrs || {}).map(k => " " + k + '="' + esc(attrs[k]) + '"').join("");
    return '<div data-ev-src-panel="' + codes + '"' + a
         + (codes.split(" ").includes(current) ? "" : " hidden") + ">" + html + "</div>";
  }

  // Switching option toggles the panels in place -- a redraw would throw
  // away what is typed and not saved yet.
  function showPanels(root, current) {
    if (!root) return;
    root.querySelectorAll("[data-ev-src-panel]").forEach(p => {
      p.hidden = !p.getAttribute("data-ev-src-panel").split(" ").includes(current);
    });
  }

  window.gracEvidenceSource = { SOURCES, DEFAULT, isKnown, radios, panel, showPanels };
})();
