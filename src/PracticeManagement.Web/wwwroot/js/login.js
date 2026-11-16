(() => {
  "use strict";

  // One check for every animation on the page (chip-label motion, wave).
  const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  // Logo shimmer, once, shortly after the page settles.
  window.setTimeout(() => {
    const logo = document.querySelector(".brand-logo");
    logo?.classList.add("shimmer");
    window.setTimeout(() => logo?.classList.remove("shimmer"), 1200);
  }, 2800);

  // Show / hide password. Each button names its field with
  // data-pw-toggle="<input id>"; the icon and the accessible name follow
  // the state so a screen reader hears "Hide password" once it is shown.
  document.querySelectorAll("[data-pw-toggle]").forEach((button) => {
    const field = document.getElementById(button.getAttribute("data-pw-toggle"));
    if (!field) return;
    const icon = button.querySelector("i");
    button.addEventListener("click", () => {
      const reveal = field.type === "password";
      field.type = reveal ? "text" : "password";
      button.setAttribute("aria-pressed", String(reveal));
      button.setAttribute("aria-label", reveal ? "Hide password" : "Show password");
      if (icon) icon.className = reveal ? "far fa-eye-slash" : "far fa-eye";
      field.focus();
    });
  });

  // Rotating chip labels. A hub chip with data-cycle="A|B|C" steps
  // through those labels (list: Views/Login/_BrandPanel.cshtml).
  // With reduced motion (also reported by remote-desktop sessions and by
  // Windows with "Animation effects" off) the label still changes, but in
  // place -- no lift, no fade.
  document.querySelectorAll(".hub-chip[data-cycle]").forEach((chip) => {
    const labels = chip.getAttribute("data-cycle").split("|").filter(Boolean);
    const text = chip.querySelector(".hub-chip-text");
    if (!text || labels.length < 2) return;
    let index = 0;
    const showNext = () => {
      index = (index + 1) % labels.length;
      text.textContent = labels[index];
    };
    window.setInterval(() => {
      if (document.hidden) return;
      if (reduceMotion) {
        showNext();
        return;
      }
      text.classList.add("is-leaving");
      window.setTimeout(() => {
        showNext();
        text.classList.remove("is-leaving");
        text.classList.add("is-entering");
        void text.offsetWidth; // commit the start position before easing in
        text.classList.remove("is-entering");
      }, 350);
    }, 2600);
  });

  // Particle wave along the bottom of the screen (decorative; the canvas
  // is aria-hidden). Blue on the left, warming to the brand gold on the
  // right, as in the reference design. With reduced motion it is drawn
  // once and left still.
  const canvas = document.querySelector(".login-wave");
  const ctx = canvas?.getContext?.("2d");
  if (!ctx) return;

  const blue = [61, 139, 255];
  const gold = [232, 163, 61];
  const rows = 20;
  const step = 5;
  let width = 0;
  let height = 0;
  let phase = 0;
  let frame = 0;

  const resize = () => {
    const ratio = window.devicePixelRatio || 1;
    width = canvas.clientWidth;
    height = canvas.clientHeight;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  };

  const draw = () => {
    ctx.clearRect(0, 0, width, height);
    for (let x = 0; x <= width; x += step) {
      const t = x / width;
      // Colour: blue until ~55% across, then blend to gold.
      const mix = Math.min(1, Math.max(0, (t - .55) / .3));
      const r = Math.round(blue[0] + (gold[0] - blue[0]) * mix);
      const g = Math.round(blue[1] + (gold[1] - blue[1]) * mix);
      const b = Math.round(blue[2] + (gold[2] - blue[2]) * mix);
      // Fade in from the left edge and out at the right edge.
      const edge = Math.min(1, t / .12) * Math.min(1, (1 - t) / .05);
      for (let row = 0; row < rows; row++) {
        const y = height * .58
          + Math.sin(x * .0055 + phase + row * .16) * height * .16
          + Math.sin(x * .0021 - phase * .6) * height * .1
          + row * 5;
        const alpha = edge * (1 - row / rows) * .6;
        if (alpha <= .02) continue;
        ctx.fillStyle = `rgba(${r},${g},${b},${alpha.toFixed(3)})`;
        ctx.fillRect(x, y, 1.3, 1.3);
      }
    }
  };

  const tick = () => {
    phase += .008;
    draw();
    frame = window.requestAnimationFrame(tick);
  };

  resize();
  draw();
  window.addEventListener("resize", () => { resize(); draw(); });
  if (!reduceMotion) {
    frame = window.requestAnimationFrame(tick);
    // Do not spend frames on a background tab.
    document.addEventListener("visibilitychange", () => {
      window.cancelAnimationFrame(frame);
      if (!document.hidden) frame = window.requestAnimationFrame(tick);
    });
  }
})();
