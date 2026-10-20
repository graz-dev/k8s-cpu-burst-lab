#!/usr/bin/env python3
"""Screenshot of a public web page, at 2x device scale.

Example:
  web.py --url https://bugs.openjdk.org/browse/JDK-8359211 --out out/jdk-8359211.png
"""
import argparse
import os

from playwright.sync_api import sync_playwright


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--scale", type=float, default=2.0)
    ap.add_argument("--full-page", action="store_true")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_context(
            viewport={"width": args.width, "height": args.height},
            device_scale_factor=args.scale,
        ).new_page()
        page.goto(args.url, wait_until="networkidle")
        page.screenshot(path=args.out, full_page=args.full_page)
        browser.close()
    print(args.out)


if __name__ == "__main__":
    main()
