// Please see documentation at https://learn.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Write your JavaScript code.

// Session timeout -> login page.
//
// The server ends a sign-in after Security:TokenLifetimeMinutes of
// inactivity (Program.cs, idle-timeout middleware). Two things send the
// browser straight to the login page when that happens:
//   1. Any same-origin fetch answered 401 (every "Session expired"
//      response in the Web controllers) -- one place, instead of each
//      screen's script handling 401 on its own.
//   2. An idle timer: if the user makes no request for the timeout period,
//      the page is reloaded; the server then redirects it to
//      /Login?returnUrl=<this page>. Reloading rather than jumping to the
//      login page directly means a tab that is still signed in (because
//      the user was active in another tab) simply stays on its page.
// Background requests (header X-PM-Background) do not reset the timer,
// matching the server, which does not renew the session for them.
// Only active on layout pages: the login pages set no pmLoginUrl.
(function () {
    'use strict';
    if (typeof window.fetch !== 'function') return;

    var redirecting = false;
    var idleTimer = null;

    function goToLogin() {
        if (redirecting || !window.pmLoginUrl) return;
        redirecting = true;
        var returnUrl = window.location.pathname + window.location.search;
        window.location.assign(window.pmLoginUrl + '?returnUrl=' + encodeURIComponent(returnUrl));
    }

    function resetIdleTimer() {
        var minutes = Number(window.pmSessionTimeoutMinutes);
        if (!window.pmLoginUrl || !(minutes > 0)) return;
        if (idleTimer) window.clearTimeout(idleTimer);
        // A few seconds of grace so the server-side expiry has passed.
        idleTimer = window.setTimeout(function () {
            if (!redirecting) window.location.reload();
        }, minutes * 60000 + 5000);
    }

    function isBackground(init) {
        var headers = init && init.headers;
        if (!headers) return false;
        if (typeof headers.has === 'function') return headers.has('X-PM-Background');
        if (Array.isArray(headers)) {
            return headers.some(function (h) { return String(h[0]).toLowerCase() === 'x-pm-background'; });
        }
        return Object.keys(headers).some(function (k) { return k.toLowerCase() === 'x-pm-background'; });
    }

    function isSameOrigin(url) {
        try { return new URL(url, window.location.href).origin === window.location.origin; }
        catch (e) { return false; }
    }

    var nativeFetch = window.fetch;
    window.fetch = function (input, init) {
        var url = typeof input === 'string' ? input : (input && input.url) || String(input);
        var background = isBackground(init) || isBackground(input);
        return nativeFetch.apply(this, arguments).then(function (response) {
            if (isSameOrigin(url)) {
                if (response.status === 401) goToLogin();
                else if (!background) resetIdleTimer();
            }
            return response;
        });
    };

    document.addEventListener('DOMContentLoaded', resetIdleTimer);
})();

// Frozen page heading height -> --pm-page-head-h (2026-10-01).
//
// .pm-page-heading is position:sticky (practice-management.css section 1).
// The grid cap --pm-grid-max-h subtracts the heading's height so a grid
// scrolled up under the heading still fits below it, with its own sticky
// column header visible. The height is not a constant: compact vs normal
// headings, long descriptions that wrap, action buttons that wrap, and
// Risk Centre swapping between its page views all change it. So it is
// measured here and published on <html>.
//
// Only a heading that is shown AND actually sticky counts (the phone /
// short-window / print rules switch the freeze off); otherwise 0px.
// A ResizeObserver catches size changes and show/hide; a MutationObserver
// picks up headings that screens render after load.
(function () {
    'use strict';
    if (typeof window.ResizeObserver !== 'function') return;

    var root = document.documentElement;
    var observed = new WeakSet();
    var queued = false;

    var resizeObserver = new ResizeObserver(schedule);

    function current() {
        var list = document.querySelectorAll('.pm-page-heading');
        for (var i = 0; i < list.length; i++) {
            var el = list[i];
            if (el.offsetParent !== null && window.getComputedStyle(el).position === 'sticky') return el;
        }
        return null;
    }

    function update() {
        queued = false;
        var list = document.querySelectorAll('.pm-page-heading');
        for (var i = 0; i < list.length; i++) {
            if (!observed.has(list[i])) {
                observed.add(list[i]);
                resizeObserver.observe(list[i]);
            }
        }
        var heading = current();
        var value = heading ? Math.ceil(heading.getBoundingClientRect().height) + 'px' : '0px';
        if (root.style.getPropertyValue('--pm-page-head-h') !== value) {
            root.style.setProperty('--pm-page-head-h', value);
        }
    }

    function schedule() {
        if (queued) return;
        queued = true;
        window.requestAnimationFrame(update);
    }

    function start() {
        update();
        new MutationObserver(schedule).observe(document.body, {
            childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'class', 'style']
        });
        window.addEventListener('resize', schedule);
    }

    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
})();
