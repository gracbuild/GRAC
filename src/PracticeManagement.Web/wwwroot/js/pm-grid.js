/* =====================================================================
   pm-grid -- the standard pager for every list in Practice Management

   THE CONVENTION
   --------------
   A new grid does not write its own paging. It mounts this, sends the
   pageNumber / pageSize it hands out, and gives back the TotalRows its
   procedure already returns. Nothing else.

       const pager = window.__pmGrid.attach({
         hostId:   "regPager",
         onChange: () => refreshRegister()      // refetch, do not slice
       });

       // in the load function
       const qs = new URLSearchParams({
         organizationId: orgId,
         pageNumber: pager.page(),
         pageSize:   pager.size()
       });
       ...
       pager.setTotal(res.totalRows);           // after every load

       // when a FILTER changes, not a page
       pager.reset();                           // -> page 1, fires onChange

   WHY IT EXISTS
   -------------
   Every paged procedure in this codebase already returns TotalRows --
   `COUNT(*) OVER ()`, last in the projection -- and every paged API model
   already carries `TotalRows, Page, PageSize`. The UI threw all of it
   away. The generic grid in practice.js had to guess whether a next page
   existed:

       nextPage.disabled = state.records.length < state.pageSize;

   which is wrong on the exact boundary where the last page is full: 50
   rows at 25 per page shows an enabled Next on page 2, and clicking it
   lands on an empty grid. Reading the total the server already computed
   removes the guess, and lets the label say "26-50 of 50" instead of
   "Page 2".

   SERVER-SIDE, ALWAYS
   -------------------
   onChange refetches. It must never slice an array the page already
   holds: the whole point of the procedures' OFFSET/FETCH is that a long
   register is never all in the browser. A grid that pages client-side
   has already lost the argument.

   Markup and styling match .pm-pager, the shape the generic grid has
   used since the beginning, so the two are visually identical and the
   generic grid can adopt this later without a redesign.
   ===================================================================== */
(function () {
    "use strict";

    const SIZES = [10, 25, 50, 100];
    const DEFAULT_SIZE = 25;

    function attach(opts) {
        const host = document.getElementById(opts.hostId);
        if (!host) return null;

        const st = {
            page: 1,
            size: Number(opts.pageSize) > 0 ? Number(opts.pageSize) : DEFAULT_SIZE,
            total: null,          // null = not reported yet
            rows: 0,              // rows in the page just rendered
            busy: false
        };

        host.className = "pm-pager pm-grid-pager";
        host.innerHTML = `
            <div>
              <button type="button" class="pm-button" data-pg-prev>Previous</button>
              <span data-pg-info>&nbsp;</span>
              <button type="button" class="pm-button" data-pg-next>Next</button>
            </div>
            <label>
              <span class="pm-grid-pager-label">Rows</span>
              <select data-pg-size>
                ${SIZES.map(n => `<option value="${n}"${n === st.size ? " selected" : ""}>${n} / page</option>`).join("")}
              </select>
            </label>`;

        const elPrev = host.querySelector("[data-pg-prev]");
        const elNext = host.querySelector("[data-pg-next]");
        const elInfo = host.querySelector("[data-pg-info]");
        const elSize = host.querySelector("[data-pg-size]");

        function lastPage() {
            if (st.total == null || st.total <= 0) return 1;
            return Math.max(1, Math.ceil(st.total / st.size));
        }

        function render() {
            const from = (st.page - 1) * st.size + 1;

            if (st.total == null) {
                // Before the first load reports a total. Falls back to the
                // old guess rather than showing a wrong count -- a grid
                // whose endpoint does not return TotalRows still works,
                // it just cannot say how many there are.
                elInfo.textContent = st.rows ? `Page ${st.page}` : "";
                elPrev.disabled = st.busy || st.page <= 1;
                elNext.disabled = st.busy || st.rows < st.size;
                return;
            }

            if (st.total === 0) {
                elInfo.textContent = "No rows";
                elPrev.disabled = true;
                elNext.disabled = true;
                return;
            }

            const to = Math.min(st.total, from + st.rows - 1);
            elInfo.textContent = `${from}–${to} of ${st.total}`;
            elPrev.disabled = st.busy || st.page <= 1;
            elNext.disabled = st.busy || st.page >= lastPage();
        }

        function fire() {
            if (typeof opts.onChange === "function") opts.onChange({ page: st.page, size: st.size });
        }

        elPrev.addEventListener("click", () => {
            if (st.page <= 1) return;
            st.page -= 1; render(); fire();
        });

        elNext.addEventListener("click", () => {
            if (st.total != null && st.page >= lastPage()) return;
            st.page += 1; render(); fire();
        });

        elSize.addEventListener("change", () => {
            st.size = Number(elSize.value) || DEFAULT_SIZE;
            // Back to page 1: staying on page 4 while the page size grows
            // can land past the end of the data.
            st.page = 1;
            render(); fire();
        });

        const api = {
            page() { return st.page; },
            size() { return st.size; },

            // Call after EVERY load. rowCount is what actually came back,
            // so the label can say 26-50 rather than assuming a full page.
            setTotal(total, rowCount) {
                const n = Number(total);
                st.total = Number.isFinite(n) && n >= 0 ? n : null;
                st.rows  = Number(rowCount) >= 0 ? Number(rowCount) : st.rows;
                st.busy  = false;
                render();
                return api;
            },

            // Filters changed, not the page. Returns to page 1 and
            // refetches -- staying on page 3 of a filter that now matches
            // four rows shows an empty grid and looks like a fault.
            reset(silent) {
                const moved = st.page !== 1;
                st.page = 1;
                st.total = null;
                render();
                if (!silent && moved) fire();
                return api;
            },

            // Optional: greys the controls while a fetch is in flight so
            // a double click cannot queue two page changes.
            busy(on) { st.busy = !!on; render(); return api; },

            // For a grid that has not loaded yet, and for a load that
            // failed. Drops `busy` as well: a cleared grid is by
            // definition not fetching, and a caller that had set busy(true)
            // before a request that then failed would otherwise leave
            // Prev/Next disabled for good, stranding the user on the page
            // the error happened on.
            clear() { st.total = null; st.rows = 0; st.busy = false; render(); return api; }
        };

        render();
        return api;
    }

    window.__pmGrid = { attach };
})();
