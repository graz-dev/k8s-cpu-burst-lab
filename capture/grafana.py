#!/usr/bin/env python3
"""Save one Grafana panel of the CPU Burst Lab dashboard as a PNG.

Opens /d-solo/ in headless Chromium at 2x device scale. The default viewport is
960x540 CSS pixels, so the PNG is 1920 px wide with fonts that stay readable on
a slide.

Examples:
  grafana.py --panel cpu --namespace cpu-burst-compare --pod 'petclinic-peak.*' \
      --from 2026-10-20T10:00:00Z --to 2026-10-20T10:03:00Z --out out/gap-chart.png
  grafana.py --panel throttle --namespace cpu-burst-stabilization --pod 'petclinic.*' \
      --results results/stabilization-20261020-101500.json --window runs.a_0s.window \
      --out out/stabilization-0.png
"""
import argparse
import base64
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlencode

from playwright.sync_api import sync_playwright

PANELS = {"cpu": 1, "throttle": 2, "restarts": 3}
DASHBOARD = "dashboard"  # the whole dashboard in kiosk mode


def to_ms(iso):
    return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp() * 1000)


def window_from_results(path, dotted):
    node = json.load(open(path))
    for key in dotted.split("."):
        node = node[key]
    return node["from"], node["to"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--panel", choices=sorted(PANELS) + [DASHBOARD], required=True)
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--pod", default="petclinic.*", help="Pod name regex")
    ap.add_argument("--from", dest="t_from")
    ap.add_argument("--to", dest="t_to")
    ap.add_argument("--results", help="results/*.json to read the window from")
    ap.add_argument("--window", help="dotted path to an object with from and to inside --results")
    ap.add_argument("--out", required=True)
    ap.add_argument("--grafana", default=os.environ.get("GRAFANA_URL", "http://localhost:%s" % os.environ.get("GRAFANA_HOST_PORT", "3000")))
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--background", choices=["white", "transparent"], default="white")
    ap.add_argument("--width", type=int, default=960, help="viewport width in CSS pixels")
    ap.add_argument("--height", type=int, default=540, help="viewport height in CSS pixels")
    ap.add_argument("--scale", type=float, default=2.0)
    args = ap.parse_args()

    if args.results:
        args.t_from, args.t_to = window_from_results(args.results, args.window)
    if not (args.t_from and args.t_to):
        sys.exit("give --from and --to, or --results with --window")

    params = {
        "orgId": 1,
        "var-namespace": args.namespace,
        "var-pod": args.pod,
        "from": to_ms(args.t_from),
        "to": to_ms(args.t_to),
        "theme": "light",
        "refresh": "",
    }
    if args.panel == DASHBOARD:
        params["kiosk"] = "1"
        params["_dash.hideTimePicker"] = "true"
        params["_dash.hideVariables"] = "true"
        params["_dash.hideLinks"] = "true"
        url = "%s/d/cpu-burst-lab/cpu-burst-lab?%s" % (args.grafana.rstrip("/"), urlencode(params))
    else:
        params["panelId"] = PANELS[args.panel]
        url = "%s/d-solo/cpu-burst-lab/cpu-burst-lab?%s" % (args.grafana.rstrip("/"), urlencode(params))
    token = base64.b64encode(("%s:%s" % (args.user, args.password)).encode()).decode()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(
            viewport={"width": args.width, "height": args.height},
            device_scale_factor=args.scale,
            extra_http_headers={"Authorization": "Basic " + token},
        )
        page = ctx.new_page()
        page.goto(url, wait_until="networkidle")
        # A time series panel is done when its canvas is drawn; a stat panel has no canvas.
        page.wait_for_selector("canvas, [data-testid='data-testid Panel header'] ~ *", timeout=30000)
        page.wait_for_load_state("networkidle")
        if args.background == "transparent":
            page.add_style_tag(content="html, body, .react-grid-item, [class*='panel-container'], [class*='panel-content'] { background: transparent !important; }")
        page.screenshot(path=args.out, omit_background=args.background == "transparent")
        browser.close()
    print(args.out)


if __name__ == "__main__":
    main()
