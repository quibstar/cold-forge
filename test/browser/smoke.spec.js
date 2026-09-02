import { test, expect } from "@playwright/test";

/**
 * The behaviour that only exists in a browser.
 *
 * Everything else is covered by `mix test`, which renders HTML on the server
 * and never runs a stylesheet or a line of client JS. That blind spot is not
 * theoretical: the mobile sidebar was completely broken — it did not open at
 * all — while every server-side test passed, because the markup was correct
 * and the failure was in CSS.
 *
 * So these cover only what needs a real browser: viewport-dependent layout,
 * class-driven visibility, focus, and keyboard handling. Anything assertable
 * from rendered HTML belongs in the Elixir suite, which is far faster.
 */

// Every test starts signed in: the session is established once in
// global-setup.js and reused, so nothing here spends time — or flakes — on a
// log-in form that is not what it is testing.
// The drawer slides, and Playwright refuses to click a moving target. Waiting
// on the element's own animations beats guessing a delay: it is exact, and it
// does not silently pass if the transition is later made longer.
async function settled(locator) {
  await locator.evaluate((el) => Promise.all(el.getAnimations().map((a) => a.finished)));
}

async function open(page, path) {
  await page.goto(path);
  // Typing or clicking before LiveView has connected is lost: the page arrives
  // as static HTML and the websocket's first patch replaces it.
  await page.waitForFunction(() => window.liveSocket?.isConnected?.() === true);
}

test.describe("mobile drawer", () => {
  test.skip(({ isMobile }) => !isMobile, "only meaningful at phone width");

  test("opens, and closes itself on navigation", async ({ page }) => {
    await open(page, "/admin");

    const drawer = page.locator(".drawer-side aside");
    // Off-canvas rather than absent, so `toBeVisible` would pass either way —
    // the question is whether it is on screen.
    await expect(drawer).not.toBeInViewport();

    await page.getByLabel("Open navigation").click();
    await expect(drawer).toBeInViewport();
    await settled(drawer);

    // The bug this suite exists for: following a link left the drawer sitting
    // on top of the page it had just taken you to.
    await page.locator(".drawer-side").getByRole("link", { name: "Projects" }).click();
    await expect(page).toHaveURL(/\/admin\/projects/);
    await expect(drawer).not.toBeInViewport();
  });

  test("closes from the overlay", async ({ page }) => {
    await open(page, "/admin");

    const drawer = page.locator(".drawer-side aside");
    await page.getByLabel("Open navigation").click();
    await expect(drawer).toBeInViewport();
    await settled(drawer);

    // The overlay spans the viewport, so its centre — and its top-left — sit
    // under the drawer itself. Click the strip beside the drawer, which is the
    // part a person can actually reach.
    const { width } = page.viewportSize();
    await page.locator(".drawer-overlay").click({ position: { x: width - 20, y: 200 } });
    await expect(drawer).not.toBeInViewport();
  });
});

test.describe("desktop sidebar", () => {
  test.skip(({ isMobile }) => isMobile, "pinned open only from lg up");

  test("is pinned open with nothing to click", async ({ page }) => {
    await open(page, "/admin");

    await expect(page.locator(".drawer-side aside")).toBeInViewport();
    await expect(page.getByLabel("Open navigation")).toBeHidden();
  });
});

test.describe("search palette", () => {
  test.skip(({ isMobile }) => isMobile, "the ⌘K path is a desktop affordance");

  test("opens focused, searches, and closes on Escape", async ({ page }) => {
    await open(page, "/admin");

    const modal = page.locator("#search-palette .modal");
    const input = page.locator("#palette-input");

    await expect(modal).not.toHaveClass(/modal-open/);

    await page.getByRole("button", { name: /search/i }).first().click();
    await expect(modal).toHaveClass(/modal-open/);
    // Focus is the whole point of a palette; typing must land without a click.
    await expect(input).toBeFocused();

    await page.keyboard.type("Exterior");
    await expect(page.locator("#search-palette")).toContainText("ExteriorPro");

    await page.keyboard.press("Escape");
    await expect(modal).not.toHaveClass(/modal-open/);
  });

  test("opens on the keyboard shortcut", async ({ page }) => {
    await open(page, "/admin");

    // Spelled out per platform rather than relying on "ControlOrMeta", which
    // did not reach the page handler here.
    await page.keyboard.press(process.platform === "darwin" ? "Meta+k" : "Control+k");
    await expect(page.locator("#search-palette .modal")).toHaveClass(/modal-open/);
    await expect(page.locator("#palette-input")).toBeFocused();
  });
});

test.describe("theme", () => {
  test.skip(({ isMobile }) => isMobile, "the toggle lives in the pinned sidebar");

  test("switching to dark actually repaints", async ({ page }) => {
    await open(page, "/admin");

    const root = page.locator("html");
    await page.locator("[data-phx-theme='dark']").click();
    await expect(root).toHaveAttribute("data-theme", "dark");

    await page.locator("[data-phx-theme='light']").click();
    await expect(root).toHaveAttribute("data-theme", "light");
  });
});
