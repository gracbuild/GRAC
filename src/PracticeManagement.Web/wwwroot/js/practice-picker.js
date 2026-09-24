/* =====================================================================
   practice-picker.js -- reusable cascading Practice Picker
   ---------------------------------------------------------------------
   Framework -> Source Structure -> Control -> Practice.

   WHY IT EXISTS
     Practice selection appears on many forms and each one used to load
     the organisation's whole practice list up front. On a large tenant
     that is a heavy payload for a control the user touches once. Here
     every level fetches only the rows under the parent just chosen, so
     nothing loads until it is asked for and the practice list is only
     ever one control wide.

   BACKED BY
     /practice/api/practice-picker/*  (Web proxy)
       -> /api/practice/practice-picker/*  (API, migration 282)
     frameworks | structures | controls | practices | resolve

   CONTRACT -- deliberately the same shape as window.__roleHolderPicker
   in _workflow-common.cshtml, so this reads like the picker the project
   already has:

     window.__practicePicker.attach({
       host,                      // element or id -- markup is rendered here
       organizationId,            // required
       required        : false,   // parent form can mark the field required
       labels          : {},      // optional label overrides
       excludePracticeIds: [],    // ids to hide (e.g. already mapped)
       excludedAllText:  fn(n),   // wording when every practice under the
                                  // control is excluded -- the host knows
                                  // WHOSE exclusion it is, this file does not
       excludedHintText: fn(n),   // same, for the hint under the select
       initialPracticeId : null,  // edit mode -- resolves the whole path
       onChange        : fn(state)// fired on every level change
     }) -> instance

     instance.getState()  -> { frameworkId, releaseId, structureNodeId,
                               organizationControlId, practiceId,
                               practiceName, isComplete }
     instance.getPracticeId()          -> number | null
     instance.setExcluded(ids)         -> re-filters the practice level
     instance.reset()                  -> back to "pick a framework"
     instance.validate()               -> true | false (+ shows a message)
     instance.refreshPractices()       -> re-fetch the current control's practices
     instance.destroy()                -> unbind and empty the host

     window.__practicePicker.invalidateCaches()   // after a data import

   NOTES
     * Single-select by design: the current consumers post one
       practiceId. The state object is the extension point if a
       multi-select variant is ever needed.
     * practiceId is grac_practice.practice.practice_id -- the id the
       Risk Centre already posts, so this is a drop-in for it.
     * Caches are per (organizationId + parent id) and hold the PROMISE,
       so two rapid changes cannot fire the same request twice.
   ===================================================================== */
(function () {
    "use strict";

    if (window.__practicePicker) return;   // idempotent, like __wfCommon

    var API = "/practice/api/practice-picker";

    function U(path) {
        var base = String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
        return base + path;
    }

    function esc(v) {
        if (v === null || v === undefined) return "";
        return String(v).replace(/[&<>"']/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
        });
    }

    // ---- caches: key -> Promise<rows[]> ------------------------------
    var cache = Object.create(null);

    function cachedGet(key, path) {
        if (cache[key]) return cache[key];
        cache[key] = fetch(U(path), { credentials: "same-origin" })
            .then(function (r) {
                if (!r.ok) throw new Error("HTTP " + r.status);
                return r.json();
            })
            .then(function (body) { return (body && (body.data || body.Data)) || []; })
            .catch(function (err) {
                // Never cache a failure -- the next attempt should retry.
                delete cache[key];
                throw err;
            });
        return cache[key];
    }

    function invalidateCaches() { cache = Object.create(null); }

    // ---- one attached picker ----------------------------------------
    function attach(opts) {
        opts = opts || {};
        var host = typeof opts.host === "string" ? document.getElementById(opts.host) : opts.host;
        if (!host) { console.error("practice-picker: host not found"); return null; }

        var orgId    = opts.organizationId ? String(opts.organizationId) : "";
        var required = !!opts.required;
        var labels   = Object.assign({
            framework: "Framework",
            structure: "Source Structure",
            control:   "Control / Statement",
            practice:  "Practice"
        }, opts.labels || {});

        var excluded = (opts.excludePracticeIds || []).map(String);

        // 312. THE EXCLUSION IS DECIDED IN SQL, on organization_id AND
        // this risk id. The client list above still applies on top --
        // it costs nothing and covers a caller with no risk -- but it is
        // no longer the only thing standing between the user and a
        // practice that belongs to a different risk.
        var riskId = opts.riskRegisterId ? String(opts.riskRegisterId) : "";

        var state = {
            frameworkId: "", releaseId: "",
            structureNodeId: "", organizationControlId: "",
            practiceId: "", practiceName: ""
        };

        var uid = "pp" + Math.random().toString(36).slice(2, 9);

        host.innerHTML =
            '<div class="pp-root" id="' + uid + '">' +
              level("framework", labels.framework, required) +
              level("structure", labels.structure, required) +
              level("control",   labels.control,   required) +
              level("practice",  labels.practice,  required) +
              '<p class="pp-message" data-pp-message role="status" aria-live="polite"></p>' +
            '</div>';

        function level(key, label, req) {
            return '' +
              '<label class="pp-level" data-pp-level="' + key + '">' +
                '<span class="pp-label">' + esc(label) +
                  (req ? '<span class="pp-required" aria-hidden="true">*</span>' : "") +
                '</span>' +
                '<select data-pp-select="' + key + '"' + (req ? " required" : "") +
                        ' aria-label="' + esc(label) + '"></select>' +
                '<span class="pp-hint" data-pp-hint="' + key + '"></span>' +
              '</label>';
        }

        var root = host.querySelector(".pp-root");
        var sel  = {
            framework: root.querySelector('[data-pp-select="framework"]'),
            structure: root.querySelector('[data-pp-select="structure"]'),
            control:   root.querySelector('[data-pp-select="control"]'),
            practice:  root.querySelector('[data-pp-select="practice"]')
        };
        var msgEl = root.querySelector("[data-pp-message]");

        function hint(key, text) {
            var el = root.querySelector('[data-pp-hint="' + key + '"]');
            if (el) el.textContent = text || "";
        }
        function message(text, kind) {
            msgEl.textContent = text || "";
            msgEl.className = "pp-message" + (kind ? " is-" + kind : "");
        }

        // Placeholder / loading / empty are the SAME select, so a level
        // never silently looks like an ordinary empty dropdown.
        function setPlaceholder(key, text, disabled) {
            var s = sel[key];
            s.innerHTML = '<option value="">' + esc(text) + "</option>";
            s.disabled = !!disabled;
        }

        function fill(key, rows, valueOf, labelOf, placeholder, emptyText, disabledOf) {
            var s = sel[key];
            if (!rows.length) { setPlaceholder(key, emptyText, true); return; }
            var html = '<option value="">' + esc(placeholder) + "</option>";
            for (var i = 0; i < rows.length; i++) {
                // A disabled <option> is visible and unselectable -- which
                // is the point: the reader learns the practice exists and
                // why it is unavailable, instead of the row silently not
                // being there.
                var off = disabledOf ? !!disabledOf(rows[i]) : false;
                html += '<option value="' + esc(valueOf(rows[i])) + '"'
                      + (off ? " disabled" : "") + ">"
                      + esc(labelOf(rows[i])) + "</option>";
            }
            s.innerHTML = html;
            s.disabled = false;
        }

        // Changing a parent clears every level below it -- required
        // behaviour, and it also prevents a stale child id being read
        // by getState() between the change and the fetch completing.
        function clearFrom(key) {
            var order = ["framework", "structure", "control", "practice"];
            var from  = order.indexOf(key);
            for (var i = from; i < order.length; i++) {
                var k = order[i];
                setPlaceholder(k, k === "structure" ? "Select a framework first"
                                : k === "control"   ? "Select a source structure first"
                                : k === "practice"  ? "Select a control or statement first"
                                : "-- select --", true);
                hint(k, "");
            }
            if (from <= 0) { state.frameworkId = ""; state.releaseId = ""; }
            if (from <= 1) state.structureNodeId = "";
            if (from <= 2) state.organizationControlId = "";
            if (from <= 3) { state.practiceId = ""; state.practiceName = ""; }
        }

        async function loadLevel(key, cacheKey, path, opts2) {
            setPlaceholder(key, "Loading...", true);
            hint(key, "");
            try {
                var all  = await cachedGet(cacheKey, path);
                var rows = opts2.filter ? all.filter(opts2.filter) : all;

                // "Nothing here" and "everything here is already taken"
                // are different answers and the user can act on only one
                // of them. Say which it is instead of a flat "not found".
                var emptyText = opts2.emptyText;
                if (!rows.length && all.length && opts2.emptyFilteredText) {
                    emptyText = opts2.emptyFilteredText(all.length);
                }

                fill(key, rows, opts2.valueOf, opts2.labelOf, opts2.placeholder, emptyText, opts2.disabledOf);
                // COUNT WHAT CAN BE PICKED, not what is listed -- some
                // rows are rendered disabled on purpose.
                var pickable = opts2.disabledOf
                    ? rows.filter(function (r) { return !opts2.disabledOf(r); }).length
                    : rows.length;
                var blocked = (rows.length - pickable) + (all.length - rows.length);

                // "N ALREADY USED" IS NOT A UNIVERSAL EXPLANATION, and
                // pretending it was is what cost the most time in this
                // whole area.
                //
                // This hint used to read `all.length + " already used"`
                // for EVERY level. On the Control level that was flatly
                // untrue -- a control is unavailable when it has no
                // practices under it, which has nothing to do with
                // anything being used -- and "1 already used" under an
                // empty Control dropdown was read, reasonably, as a
                // practice being locked by another risk. Two rounds of
                // investigation went into a risk-scoped exclusion bug
                // that did not exist.
                //
                // Each level now supplies its own wording via
                // blockedHintText, and there is no generic fallback that
                // can invent a reason.
                hint(key, pickable
                        ? pickable + " available"
                          + (blocked && typeof opts2.blockedHintText === "function"
                               ? ", " + opts2.blockedHintText(blocked) : "")
                        : (blocked && typeof opts2.blockedHintText === "function"
                             ? opts2.blockedHintText(blocked)
                             : ""));
                return rows;
            } catch (err) {
                setPlaceholder(key, "Could not load", true);
                message("Could not load " + key + ": " + (err.message || err), "error");
                return [];
            }
        }

        function loadFrameworks() {
            return loadLevel("framework",
                "fw/" + orgId,
                API + "/frameworks?organizationId=" + encodeURIComponent(orgId),
                {
                    valueOf: function (r) { return r.releaseId; },
                    labelOf: function (r) {
                        var auth = r.authorityName ? r.authorityName + " - " : "";
                        return auth + (r.frameworkName || r.artifactName || ("Release " + r.releaseId));
                    },
                    placeholder: "-- select a framework --",
                    emptyText:   "No frameworks subscribed"
                });
        }

        function loadStructures(releaseId) {
            return loadLevel("structure",
                "st/" + orgId + "/" + releaseId,
                API + "/structures?organizationId=" + encodeURIComponent(orgId)
                    + "&releaseId=" + encodeURIComponent(releaseId),
                {
                    valueOf: function (r) { return r.structureNodeId; },
                    labelOf: function (r) { return r.structureName || r.nodeTitle; },
                    placeholder: "-- select a source structure --",
                    emptyText:   "No source structures found"
                });
        }

        function loadControls(nodeId) {
            return loadLevel("control",
                "ct/" + orgId + "/" + state.releaseId + "/" + nodeId,
                API + "/controls?organizationId=" + encodeURIComponent(orgId)
                    + "&releaseId=" + encodeURIComponent(state.releaseId)
                    + "&structureNodeId=" + encodeURIComponent(nodeId),
                {
                    // A control with no practices is a dead end -- but
                    // HIDING it was worse than the dead end.
                    //
                    // It was hidden because picking one produced an empty
                    // practice list "that looked like a failure". The
                    // cure was the disease: with the only control hidden,
                    // the Control dropdown came up empty, the practice
                    // level stayed on "Select a control first", and the
                    // user could not select a practice at all -- with no
                    // visible reason, under a hint that wrongly said
                    // something was already used.
                    //
                    // Shown and DISABLED instead. The reader sees the
                    // control exists, sees it carries no practices, and
                    // can go and attach one. Nothing is guessed and
                    // nothing is silently removed.
                    //
                    // PracticeCount comes from the same
                    // organization_control_requirement ->
                    // organization_requirement -> practice chain that
                    // sp_practice_picker_practices walks, so a count of 0
                    // here really does mean that query would return
                    // nothing.
                    disabledOf: function (r) { return (r.practiceCount || 0) === 0; },
                    valueOf: function (r) { return r.organizationControlId; },
                    labelOf: function (r) {
                        var code = r.controlCode ? r.controlCode + " - " : "";
                        var n    = r.practiceCount || 0;
                        return code + (r.controlName || "")
                             + (n ? " (" + n + ")" : "  (no practices attached)");
                    },
                    placeholder: "-- select a control or statement --",
                    emptyText:   "No controls or statements found",
                    blockedHintText: function (n) {
                        return n === 1 ? "1 item here has no practices attached"
                                       : n + " items here have no practices attached";
                    }
                });
        }

        // Practices are NOT cached against the exclude list -- the list
        // changes as the parent form maps things. Cache the control's
        // full set, filter client-side.
        function loadPractices(controlId) {
            return loadLevel("practice",
                // The RISK is part of the key. Without it the second
                // risk opened on a page would read the first risk's
                // cached answer -- which is exactly the "already
                // selected on a risk I never mapped" symptom, and the
                // one cause a client-side filter could not produce on
                // its own.
                "pr/" + orgId + "/" + controlId + "/" + (riskId || "-"),
                API + "/practices?organizationId=" + encodeURIComponent(orgId)
                    + "&organizationControlId=" + encodeURIComponent(controlId)
                    // Sent only when there IS a risk, so the request and
                    // the cache key stay identical for every other
                    // caller of this picker.
                    + (riskId ? "&riskRegisterId=" + encodeURIComponent(riskId)
                              + "&includeAlreadyMapped=true" : ""),
                {
                    // The server kept the already-mapped rows (we asked
                    // for them), so this applies only the caller's own id
                    // list -- and never to a row the server flagged,
                    // because those are meant to be SHOWN, disabled,
                    // with the reason.
                    filter:  function (r) {
                        if (r.alreadyMappedToRisk) return true;
                        return excluded.indexOf(String(r.practiceId)) < 0;
                    },
                    valueOf: function (r) { return r.practiceId; },
                    // Disabled, not hidden. An empty dropdown reading "1
                    // already used" is what made this look like a global
                    // lock; the practice is now visible with the reason
                    // attached, and 'Primary' says the risk was RAISED
                    // from that practice rather than anyone mapping it.
                    disabledOf: function (r) { return !!r.alreadyMappedToRisk; },
                    labelOf: function (r) {
                        var base = (r.practiceCode ? r.practiceCode + " - " : "") + (r.practiceName || "");
                        if (!r.alreadyMappedToRisk) return base;
                        return base + (r.mapSourceCode === "Primary"
                            ? "  (already in this risk's scope - raised from this practice)"
                            : "  (already mapped to this risk)");
                    },
                    placeholder: "-- select a practice --",
                    // Genuinely nothing under this control -- the control
                    // has no practice mapped to it in
                    // organization_control_requirement.
                    emptyText: "No practices found",
                    // The control DOES have practices, but the caller has
                    // excluded them all. WHOSE exclusion that is depends
                    // on the host, so the host supplies the wording:
                    // "already used" left the reader to guess whether it
                    // meant used by this record or used anywhere, and on
                    // the Risk Centre that guess came out wrong.
                    emptyFilteredText: function (n) {
                        if (typeof opts.excludedAllText === "function") return opts.excludedAllText(n);
                        return n === 1 ? "Its only practice is already mapped to this risk"
                                       : "All " + n + " practices here are already mapped to this risk";
                    },
                    // Same hook every level uses now. The host can still
                    // override the wording; what it cannot do is fall
                    // through to a generic "already used".
                    blockedHintText: function (n) {
                        if (typeof opts.excludedHintText === "function") return opts.excludedHintText(n);
                        return n + " already mapped to this risk";
                    }
                });
        }

        function emitChange() {
            if (typeof opts.onChange === "function") {
                try { opts.onChange(getState()); } catch (e) { console.error("practice-picker onChange", e); }
            }
        }

        sel.framework.addEventListener("change", async function () {
            message("");
            clearFrom("structure");
            state.frameworkId = state.releaseId = sel.framework.value;
            emitChange();
            if (state.releaseId) await loadStructures(state.releaseId);
        });

        sel.structure.addEventListener("change", async function () {
            message("");
            clearFrom("control");
            state.structureNodeId = sel.structure.value;
            emitChange();
            if (state.structureNodeId) await loadControls(state.structureNodeId);
        });

        sel.control.addEventListener("change", async function () {
            message("");
            clearFrom("practice");
            state.organizationControlId = sel.control.value;
            emitChange();
            if (state.organizationControlId) await loadPractices(state.organizationControlId);
        });

        sel.practice.addEventListener("change", function () {
            message("");
            state.practiceId = sel.practice.value;
            var opt = sel.practice.options[sel.practice.selectedIndex];
            state.practiceName = state.practiceId && opt ? opt.textContent : "";
            emitChange();
        });

        function getState() {
            return {
                frameworkId:           state.frameworkId || null,
                releaseId:             state.releaseId || null,
                structureNodeId:       state.structureNodeId || null,
                organizationControlId: state.organizationControlId || null,
                practiceId:            state.practiceId ? Number(state.practiceId) : null,
                practiceName:          state.practiceName || null,
                isComplete:            !!state.practiceId
            };
        }

        // Edit mode: one call resolves the whole path, then each level is
        // loaded and preselected top-down so the user sees where the
        // stored practice actually sits.
        async function preload(practiceId) {
            message("Loading the saved practice...");
            try {
                var r = await fetch(U(API + "/resolve?organizationId=" + encodeURIComponent(orgId)
                        + "&practiceId=" + encodeURIComponent(practiceId)), { credentials: "same-origin" });
                var body = r.ok ? await r.json() : null;
                var path = body && (body.data || body.Data);
                if (!path) {
                    // A practice that reaches no control (manually added).
                    // Keep the stored value, say so, and leave the picker
                    // usable rather than pretending the path exists.
                    message("This practice is not linked to a control, so the hierarchy cannot be shown.", "warn");
                    return;
                }
                await loadFrameworks();
                if (path.releaseId) {
                    sel.framework.value = String(path.releaseId);
                    state.frameworkId = state.releaseId = String(path.releaseId);
                    await loadStructures(path.releaseId);
                }
                if (path.structureNodeId) {
                    sel.structure.value = String(path.structureNodeId);
                    state.structureNodeId = String(path.structureNodeId);
                    await loadControls(path.structureNodeId);
                }
                if (path.organizationControlId) {
                    sel.control.value = String(path.organizationControlId);
                    state.organizationControlId = String(path.organizationControlId);
                    await loadPractices(path.organizationControlId);
                }
                // The saved practice is normally excluded from its own
                // picker; add it back so it can be displayed as selected.
                if (!sel.practice.querySelector('option[value="' + String(practiceId) + '"]')) {
                    var opt = document.createElement("option");
                    opt.value = String(practiceId);
                    opt.textContent = (path.practiceCode ? path.practiceCode + " - " : "") + (path.practiceName || "");
                    sel.practice.appendChild(opt);
                }
                sel.practice.value = String(practiceId);
                sel.practice.disabled = false;
                state.practiceId   = String(practiceId);
                state.practiceName = path.practiceName || "";
                message("");
                emitChange();
            } catch (err) {
                message("Could not resolve the saved practice: " + (err.message || err), "error");
            }
        }

        var instance = {
            getState: getState,
            getPracticeId: function () { return state.practiceId ? Number(state.practiceId) : null; },
            // Returns a promise ONLY when it actually reloads, and the
            // caller decides whether to wait. It used to fire
            // loadPractices() without the caller being able to await it,
            // so a reset() straight afterwards cleared the selects while
            // that fetch was still in flight -- and when it landed it
            // repopulated the practice list for a control the user was no
            // longer on. openMapPracticeDialog does exactly that
            // sequence, which is how the race was found.
            setExcluded: function (ids) {
                excluded = (ids || []).map(String);
                if (!state.organizationControlId) return Promise.resolve([]);
                return loadPractices(state.organizationControlId);
            },

            // The organisation is captured at attach time, so a reused
            // instance would keep the first one. The Risk Centre attaches
            // ONE picker for the whole page and re-opens it for every
            // risk; two risks in different organisations would have had
            // the second one browsing the first one's frameworks.
            //
            // Returns true when the org actually changed, so the caller
            // knows the cascade has to be rebuilt.
            // The risk the exclusion is scoped to. Same reasoning as
            // setOrganizationId: this picker is attached once and reused
            // for every risk on the page, so the risk cannot stay at
            // whatever it was on the first open -- that would be the
            // cross-risk bug, in the client this time.
            setRiskRegisterId: function (id) {
                var next = id ? String(id) : "";
                if (next === riskId) return false;
                riskId = next;
                clearFrom("framework");
                sel.framework.value = "";
                return true;
            },

            setOrganizationId: function (id) {
                var next = id ? String(id) : "";
                if (next === orgId) return false;
                orgId = next;
                // The level caches are keyed by organisation, so nothing
                // has to be evicted -- but the SELECTED path belongs to
                // the old org and must not survive.
                //
                // clearFrom("framework"), not a hand-written list of
                // state keys: the first draft of this cleared
                // state.structureId, which is not a key this picker has
                // (it is structureNodeId), so the old structure would
                // have survived the org change. clearFrom already owns
                // the correct set and cannot drift from it.
                clearFrom("framework");
                sel.framework.value = "";
                return true;
            },
            refreshPractices: function () {
                if (!state.organizationControlId) return Promise.resolve([]);
                delete cache["pr/" + orgId + "/" + state.organizationControlId];
                return loadPractices(state.organizationControlId);
            },
            reset: function () {
                clearFrom("framework");
                sel.framework.value = "";
                message("");
                emitChange();
                return loadFrameworks();
            },
            validate: function () {
                if (!required || state.practiceId) { message(""); return true; }
                message(!state.releaseId            ? "Select a framework."
                      : !state.structureNodeId      ? "Select a source structure."
                      : !state.organizationControlId ? "Select a control or statement."
                      : "Select a practice.", "error");
                return false;
            },
            setOrganization: function (newOrgId) {
                orgId = newOrgId ? String(newOrgId) : "";
                return instance.reset();
            },
            destroy: function () { host.innerHTML = ""; }
        };

        // Boot: only the framework list loads up front -- that is the
        // whole point. Everything below waits for a parent selection.
        clearFrom("structure");
        loadFrameworks().then(function () {
            if (opts.initialPracticeId) return preload(opts.initialPracticeId);
        });

        return instance;
    }

    window.__practicePicker = {
        attach: attach,
        invalidateCaches: invalidateCaches
    };
})();
