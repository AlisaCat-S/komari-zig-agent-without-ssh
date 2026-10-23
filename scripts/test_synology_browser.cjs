// Run against scripts/test_synology_ui.py --serve, never a real NAS.
// PLAYWRIGHT_MODULE may point to an isolated installation of playwright-core.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright-core");
const assert = require("node:assert/strict");
const path = require("node:path");

async function main() {
  const url = process.argv[2] || "http://127.0.0.1:8876/";
  assert.equal(new URL(url).hostname, "127.0.0.1", "Only the local disposable fixture is supported");
  const browser = await chromium.launch({ executablePath: process.env.CHROME_BIN || "/usr/bin/google-chrome", headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1160, height: 900 }, locale: "zh-CN" });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(url);
    await page.waitForFunction(() => !document.getElementById("fields").disabled);
    assert.equal(await page.locator("#token").inputValue(), "");
    assert.ok(!(await page.content()).includes("private-original-token"));
    assert.equal(await page.locator("#http-confirmed").textContent(), "尚无 HTTP 确认");

    await page.locator("#interval").fill("4");
    await page.locator("#refresh").click();
    await page.waitForFunction(() => document.getElementById("notice").textContent === "状态已刷新。");
    assert.equal(await page.locator("#interval").inputValue(), "4", "polling must not overwrite edits");
    await page.locator("#save").click();
    await page.waitForFunction(() => document.getElementById("edit-state").textContent === "已保存");
    assert.equal(await page.locator("#interval").inputValue(), "4");
    assert.ok((await page.locator("#notice").textContent()).includes("重新启动"));
    assert.equal(await page.locator("#token").inputValue(), "");

    await page.locator("#interval").fill("9");
    await page.locator("#discard").click();
    await page.waitForFunction(() => document.getElementById("interval").value === "4");
    assert.ok(await page.locator("#save").isDisabled());

    // A second editor must get a conflict rather than silently replace newer data.
    const second = await browser.newPage();
    await second.goto(url);
    await second.waitForFunction(() => !document.getElementById("fields").disabled);
    await second.locator("#interval").fill("8");
    await page.locator("#interval").fill("5");
    await page.locator("#save").click();
    await page.waitForFunction(() => document.getElementById("edit-state").textContent === "已保存");
    await second.locator("#save").click();
    await second.waitForFunction(() => document.getElementById("notice").textContent.includes("其他页面"));
    assert.equal(await second.locator("#interval").inputValue(), "8");
    await second.locator("#discard").click();
    await second.waitForFunction(() => document.getElementById("interval").value === "5");
    await second.close();

    // Simulate a rejected DSM session and recovery without discarding unsaved edits.
    await page.evaluate(() => { window.SYNO.SDS.Session.SynoToken = "invalid-session"; });
    await page.locator("#refresh").click();
    await page.waitForFunction(() => document.getElementById("fields").disabled);
    assert.ok((await page.locator("#notice").textContent()).includes("登录 DSM"));
    await page.evaluate(() => { window.SYNO.SDS.Session.SynoToken = "test-syno-token"; });
    await page.locator("#refresh").click();
    await page.waitForFunction(() => !document.getElementById("fields").disabled);

    // A fresh basic-info event must not hide stalled monitoring reports.
    const status = await page.evaluate(() => request());
    const now = Math.floor(Date.now() / 1000);
    status.telemetry.updated_at = now;
    status.telemetry.last_report_sent_at = now - 600;
    await page.evaluate(data => render(data), status);
    assert.equal(await page.locator("#status-title").textContent(), "状态暂未更新");
    status.running = false;
    await page.evaluate(data => render(data), status);
    assert.equal(await page.locator("#status-title").textContent(), "Agent 已停止");
    status.running = true;
    status.telemetry.last_report_sent_at = now;
    await page.evaluate(data => render(data), status);
    assert.equal(await page.locator("#status-title").textContent(), "上报连接已建立");

    const directory = process.env.SCREENSHOT_DIR || "build/synology";
    await page.screenshot({ path: path.join(directory, "ui-desktop.png"), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator(".advanced summary").click();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "mobile layout must not overflow");
    await page.screenshot({ path: path.join(directory, "ui-mobile.png"), fullPage: true });
    assert.deepEqual(errors, []);
    console.log("Browser checks passed: save, polling, discard, concurrent editing, session expiry, stale/stopped/live status, responsive layout.");
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
