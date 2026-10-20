#!/usr/bin/env bash
# Capture desktop + mobile screenshots of CAPTURE_URL into CAPTURE_DIR.
#   final-desktop.png (1440x900) and final-mobile.png (390x844).
# Exit 75: temporary navigation/browser infrastructure failure.
# Exit 1: script defect or rendering failure.
# Never touches the app server; output stays in CAPTURE_DIR (outside source).
set -euo pipefail

URL="${CAPTURE_URL:-}"
OUT="${CAPTURE_DIR:-}"

script_fail() { echo "[capture.sh] ERROR: $1" >&2; exit 1; }
temp_fail() { echo "[capture.sh] TEMP: $1" >&2; exit 75; }

[[ -n "$URL" ]] || script_fail "CAPTURE_URL is required"
[[ -n "$OUT" ]] || script_fail "CAPTURE_DIR is required"
case "$URL" in
  http://*|https://*) ;;
  *) script_fail "CAPTURE_URL must be an http(s) URL, got: $URL" ;;
esac

# --- create capture directory (timing on every command) ----------------------
/usr/bin/time -p mkdir -p "$OUT" || script_fail "cannot create CAPTURE_DIR: $OUT"

# --- preflight: classify navigation failures before launching a browser ------
set +e
http_code="$(/usr/bin/time -p curl --silent --show-error --location --max-time 45 --output /dev/null --write-out '%{http_code}' -- "$URL" 2>/dev/null)"
curl_ec=$?
set -e
http_code="$(printf '%s' "$http_code" | tail -c 3)"
[[ -n "$http_code" ]] || http_code=000
if [[ $curl_ec -ne 0 && $http_code == 000 ]]; then
  temp_fail "preflight could not reach $URL (curl exit $curl_ec)"
fi
case "$http_code" in
  2*) ;;
  408|429|5*) temp_fail "preflight HTTP $http_code for $URL" ;;
  4*) script_fail "preflight HTTP $http_code for $URL" ;;
  *) temp_fail "preflight HTTP $http_code (curl exit $curl_ec) for $URL" ;;
esac
echo "[capture.sh] preflight OK (HTTP $http_code) $URL"

# --- browser capture (own browser instance, closed at the end) ---------------
export CAPTURE_URL="$URL" CAPTURE_DIR="$OUT"
set +e
/usr/bin/time -p node --input-type=module - <<'NODE'
import { createRequire } from 'node:module'
import { readFileSync, mkdirSync, existsSync, statSync } from 'node:fs'
import { join } from 'node:path'

const url = process.env.CAPTURE_URL
const out = process.env.CAPTURE_DIR
const transient = msg => { console.error('[capture] TEMP: ' + msg); process.exit(75) }
const defect = msg => { console.error('[capture] ERROR: ' + msg); process.exit(1) }

const runtime = join(process.env.HOME || '', '.local/share/omgithub-playwright')
if (!existsSync(runtime)) transient(`playwright runtime missing at ${runtime}`)
const require = createRequire(join(runtime, 'package.json'))
let chromium
try { ({ chromium } = require('playwright')) } catch (error) { transient('playwright not loadable: ' + error.message) }

if (process.platform === 'linux') {
  try { process.env.DISPLAY ||= ':' + readFileSync(join(runtime, 'display'), 'utf8').trim() } catch {}
}
let config = {}
try { config = JSON.parse(readFileSync(join(runtime, process.platform === 'darwin' ? 'metal.json' : 'linux.json'), 'utf8')) } catch {}

const launchVariants = [
  { ...(config.browser?.launchOptions || {}), timeout: 45000 },
  { headless: true, timeout: 45000, args: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage'] },
]
mkdirSync(out, { recursive: true })
let browser = null
for (const [i, opts] of launchVariants.entries()) {
  try {
    browser = await chromium.launch(opts)
    console.log(`[capture] browser launched (variant ${i}, headless=${opts.headless ?? config.browser?.launchOptions?.headless ?? false})`)
    break
  } catch (error) {
    console.error(`[capture] launch variant ${i} failed: ${error.message}`)
    browser = null
  }
}
if (!browser) transient('unable to launch chromium via playwright runtime')

let exit = 0
try {
  for (const [name, width, height, mobile] of [
    ['desktop', 1440, 900, false],
    ['mobile', 390, 844, true],
  ]) {
    const context = await browser.newContext({
      viewport: { width, height },
      deviceScaleFactor: 1,
      ...(mobile ? {
        userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        isMobile: true,
        hasTouch: true,
      } : {}),
    }).catch(error => transient('newContext: ' + error.message))
    const page = await context.newPage().catch(error => transient('newPage: ' + error.message))
    page.setDefaultTimeout(30000)
    page.on('pageerror', error => console.error('[capture][pageerror]', error.message))
    const response = await page.goto(url, { waitUntil: 'load', timeout: 45000 }).catch(error => transient('goto: ' + error.message))
    if (!response) transient('no response loading ' + url)
    const status = response.status()
    if (status < 200 || status >= 400) {
      if (status === 408 || status === 429 || status >= 500) transient(`HTTP ${status} loading preview`)
      defect(`HTTP ${status} loading preview`)
    }
    await page.locator(process.env.CAPTURE_READY_SELECTOR || 'body').waitFor({ state: 'visible' })
      .catch(error => defect('content did not render: ' + error.message))
    await page.waitForFunction(() => document.fonts.status === 'loaded', null, { timeout: 15000 }).catch(() => {})
    await page.waitForTimeout(1200)
    const file = join(out, `final-${name}.png`)
    await page.screenshot({ path: file, timeout: 30000 }).catch(error => {
      if (error.name === 'TimeoutError' || !browser.isConnected()) transient('screenshot: ' + error.message)
      defect('screenshot: ' + error.message)
    })
    const size = statSync(file).size
    if (size < 2048) defect(`screenshot implausible (${size} bytes): ${file}`)
    console.log(`[capture] captured ${name}: ${file} (${size} bytes, HTTP ${status}, viewport ${width}x${height})`)
    await context.close().catch(() => {})
  }
} catch (error) {
  console.error('[capture] ' + (error?.stack || error))
  exit = error?.exitCode || 1
} finally {
  await browser?.close().catch(() => {})
}
process.exit(exit)
NODE
node_ec=$?
set -e
[[ $node_ec -eq 0 ]] || exit $node_ec

echo "[capture.sh] done: $OUT/final-desktop.png + $OUT/final-mobile.png (app left running)"
