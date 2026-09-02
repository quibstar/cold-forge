import { defineConfig, devices } from "@playwright/test";

// Its own port, so a server you already have open on 4000 is left alone.
const PORT = process.env.SMOKE_PORT || 4002;
const baseURL = `http://localhost:${PORT}`;

export default defineConfig({
  testDir: ".",
  // These drive a real browser; a hung one should fail rather than hang CI.
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,
  reporter: process.env.CI ? "list" : [["list"]],
  globalSetup: "./global-setup.js",
  use: {
    baseURL,
    // Signed in once by the global setup; see the note there on why not
    // per test.
    storageState: ".auth/state.json",
    // On failure the trace is the difference between "a click did nothing" and
    // knowing which element was actually on top of it.
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  // Both pinned to Chromium: the iPhone profile defaults to WebKit, and these
  // check layout and client JS rather than engine differences — not worth a
  // second 100 MB browser download to run them twice.
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
    { name: "mobile", use: { ...devices["Pixel 5"], browserName: "chromium" } },
  ],
  webServer: {
    command: "mix phx.server",
    cwd: "../..",
    url: baseURL,
    env: { PORT: String(PORT), MIX_ENV: "dev" },
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
