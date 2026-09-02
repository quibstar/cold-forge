import { chromium, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

const EMAIL = process.env.SMOKE_EMAIL || "quibstar@gmail.com";
const PASSWORD = process.env.SMOKE_PASSWORD || "devpassword123!";

/**
 * Signs in once and saves the session for every test to reuse.
 *
 * Logging in per test made the suite flaky, and always in the login itself
 * rather than in what was being tested: the form is a LiveView, so a patch
 * arriving between filling it and submitting resets the fields, and the submit
 * then bounces back to the log-in page. A suite that fails for reasons
 * unrelated to its subject is worse than no suite, because you learn to ignore
 * it.
 *
 * Doing it once also means the dev server's first compile-on-demand happens
 * here, not inside a test with a five-second assertion timeout.
 */
export default async function globalSetup(config) {
  const { baseURL, storageState } = config.projects[0].use;
  const browser = await chromium.launch();
  const page = await browser.newPage({ baseURL });

  await page.goto("/users/log-in");
  await page.waitForFunction(() => window.liveSocket?.isConnected?.() === true, null, {
    timeout: 60_000,
  });

  const form = page.locator("form").filter({ has: page.locator("input[type=password]") });
  await form.locator("input[type=email]").fill(EMAIL);
  await form.locator("input[type=password]").fill(PASSWORD);

  // Confirm the values survived any patch before submitting, so a failure here
  // says "the form was cleared" rather than "the login mysteriously bounced".
  await expect(form.locator("input[type=email]")).toHaveValue(EMAIL);
  await expect(form.locator("input[type=password]")).toHaveValue(PASSWORD);

  await Promise.all([
    page.waitForURL(/\/admin/, { timeout: 60_000 }),
    form.getByRole("button", { name: /log in and stay/i }).click(),
  ]);

  fs.mkdirSync(path.dirname(storageState), { recursive: true });
  await page.context().storageState({ path: storageState });
  await browser.close();
}
