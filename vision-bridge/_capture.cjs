
const { chromium } = require("playwright-core");
const fs = require("fs");

function bail(code, msg) {
  try { process.stderr.write(String(msg)); } catch (e) {}
  process.exit(code);
}

(async () => {
  const out = process.argv[2];
  const url = process.argv[3];
  const w = parseInt(process.argv[4] || "1920", 10);
  const h = parseInt(process.argv[5] || "1080", 10);
  const wait = parseInt(process.argv[6] || "3500", 10);
  const full = process.argv[7] === "full";
  const candidates = JSON.parse(process.argv[8] || "[]");

  let exe = null;
  for (const c of candidates) { if (fs.existsSync(c)) { exe = c; break; } }
  if (!exe) { bail(2, "no Chrome/Edge executable found in " + JSON.stringify(candidates)); }

  const browser = await chromium.launch({
    headless: true,
    executablePath: exe,
    timeout: 60000,
    args: ["--force-device-scale-factor=1", "--disable-dev-shm-usage",
           "--disable-background-networking", "--disable-extensions"],
  });
  const page = await browser.newPage({
    viewport: { width: w, height: h },
    deviceScaleFactor: 1,
  });
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.waitForTimeout(wait);
  await page.screenshot({ path: out, fullPage: full });
  if (!fs.existsSync(out) || fs.statSync(out).size < 512) {
    bail(3, "screenshot produced no usable file at " + out);
  }
  // Report success FIRST, then leave. close() can hang forever here and the
  // capture is already complete.
  process.stdout.write("ok");
  const hardExit = setTimeout(function () { process.exit(0); }, 4000);
  try { await browser.close(); } catch (e) {}
  clearTimeout(hardExit);
  process.exit(0);
})().catch(function (e) { bail(1, (e && e.message) || e); });
