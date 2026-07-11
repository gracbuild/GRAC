(() => {
  "use strict";
  window.setTimeout(() => {
    const logo = document.querySelector(".brand-logo");
    logo?.classList.add("shimmer");
    window.setTimeout(() => logo?.classList.remove("shimmer"), 1200);
  }, 2800);
})();
