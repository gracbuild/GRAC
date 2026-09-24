  //   Exception    -> Exception View
  //   Risk         -> Risk Centre's candidate detail (not yet registered)
  //   RiskRegister -> Risk Centre's registered-risk full page (215)
  // ContinuousAssurance / EventAssurance / Custom have no dedicated full
  // view to link to today, so they render as plain text.
  const SOURCE_LINK = {
    Gap:          id => U("/Practice/Index/gap-view") + "?gapId=" + encodeURIComponent(id),
    Exception:    id => U("/Practice/Index/exception-view") + "?exceptionId=" + encodeURIComponent(id),
    Risk:         id => U("/Practice/Index/risk-centre") + "#candidateId=" + encodeURIComponent(id),
    RiskRegister: id => U("/Practice/Index/risk-centre") + "#riskId=" + encodeURIComponent(id)
  };
  const SOURCE_LABEL = {
    Gap: "Gap", Exception: "Exception", Risk: "Risk", RiskRegister: "Risk",
    ContinuousAssurance: "Continuous Assurance", EventAssurance: "Event Assurance", Custom: "Source"
  };

  const state = { taskId: null, detail: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const root = document.getElementById("tvRoot");
    if (!root) return;

    const params = new URLSearchParams(location.search);
    state.taskId = Number(params.get("taskId")) || 0;

    if (!state.taskId) {
      unavailable("No task was specified.", "Open this page from Task Center's row menu.");
      return;
    }

    document.getElementById("tvRefreshBtn").addEventListener("click", load);
    await load();
  }

  function unavailable(title, body) {
    document.getElementById("tvRoot").hidden = true;
    document.getElementById("tvUnavailable").hidden = false;
    document.getElementById("tvUnavailableTitle").textContent = title;
