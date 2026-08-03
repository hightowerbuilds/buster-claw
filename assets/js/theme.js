// Theme bootstrap.
//
// This runs in `<head>`, render-blocking and BEFORE the body paints, which is
// the whole reason it is a separate bundle rather than part of `app.js`:
// `app.js` is `defer`, so a theme applied there lands after first paint and the
// user sees a flash of the wrong one.
//
// It used to be an inline `<script nonce={...}>` in `root.html.heex`, and it was
// the ONLY consumer of that nonce app-wide. Moving it to a file served from
// 'self' let the CSP drop `'nonce-…'` from `script-src` entirely
// (CODE_QUALITY_REFACTOR Phase 4, 08-03) — which is strictly tighter, not just
// tidier: with no nonce in the policy, NO inline script can execute, including
// one injected into a LiveView. That backstop is what the model-authored SVG
// channel is trusted on, so it is worth having in its strongest form.
(() => {
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };

  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system");
  }

  // Cross-tab sync: a theme change in one window follows into the others.
  window.addEventListener(
    "storage",
    (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"),
  );

  window.addEventListener("phx:set-theme", (e) =>
    setTheme(e.target.dataset.phxTheme),
  );
})();
