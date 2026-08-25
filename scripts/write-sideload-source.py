#!/usr/bin/env python3
"""Write an AltStore / Feather source JSON for an unsigned ScarfGo IPA."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

BUNDLE_ID = "com.scarfgo.app"
SOURCE_ID = "com.scarfgo.sideload"
TINT = "#C25A2A"
MIN_OS = "18.6"
MAX_HISTORY = 15
SCREENSHOTS = (
    "assets/screenshots/scarfgo-servers.png",
    "assets/screenshots/scarfgo-chat.png",
    "assets/screenshots/scarfgo-project-dashboard.png",
    "assets/screenshots/scarfgo-skills.png",
    "assets/screenshots/scarfgo-system.png",
)
DESCRIPTION = (
    "ScarfGo is the native iPhone app for your self-hosted Hermes agent. "
    "Add a server over SSH or a Hermes URL, then chat, browse sessions, "
    "manage skills, and edit settings from your phone.\n\n"
    "This build is unsigned. AltStore and Feather re-sign it with your "
    "own certificate on install."
)


def raw_url(repo: str, ref: str, rel: str) -> str:
    return f"https://raw.githubusercontent.com/{repo}/{ref}/{rel}"


def release_asset_url(repo: str, tag: str, filename: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{quote(filename)}"


def load_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--meta", required=True, type=Path)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--tag", default="scarfgo-sideload")
    parser.add_argument("--ref", default="main", help="git ref for icons and screenshots")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--notes", default="Unsigned ScarfGo build for AltStore and Feather.")
    args = parser.parse_args()

    meta = json.loads(args.meta.read_text(encoding="utf-8"))
    version = str(meta["version"])
    build = str(meta["build"])
    size = int(meta["size"])
    ipa_name = meta["ipaName"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    download_url = release_asset_url(args.repo, args.tag, ipa_name)
    source_url = release_asset_url(args.repo, args.tag, "source.json")
    icon_url = raw_url(args.repo, args.ref, "icon-v2.5.png")
    shots = [raw_url(args.repo, args.ref, path) for path in SCREENSHOTS]

    entry = {
        "version": version,
        "buildVersion": build,
        "date": now,
        "localizedDescription": args.notes,
        "downloadURL": download_url,
        "size": size,
        "minOSVersion": MIN_OS,
    }

    existing = load_json(args.output)
    previous = []
    if existing.get("apps"):
        previous = list(existing["apps"][0].get("versions") or [])
    history = [
        item
        for item in previous
        if not (
            str(item.get("version")) == version
            and str(item.get("buildVersion")) == build
        )
    ]
    versions = [entry, *history][:MAX_HISTORY]

    source = {
        "name": "ScarfGo",
        "subtitle": "Unsigned ScarfGo builds for AltStore and Feather",
        "description": (
            "Rolling unsigned iPhone builds of ScarfGo. Add this source, then "
            "install ScarfGo. AltStore and Feather will re-sign the IPA and "
            "offer updates when a newer build is published."
        ),
        "identifier": SOURCE_ID,
        "sourceURL": source_url,
        "website": f"https://github.com/{args.repo}",
        "iconURL": icon_url,
        "tintColor": TINT,
        "featuredApps": [BUNDLE_ID],
        "apps": [
            {
                "name": "ScarfGo",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": "Scarf",
                "subtitle": "Native iPhone app for your Hermes agent",
                "localizedDescription": DESCRIPTION,
                "iconURL": icon_url,
                "tintColor": TINT,
                "category": "utilities",
                "screenshotURLs": shots,
                "screenshots": shots,
                "appPermissions": {
                    "privacy": {
                        "NSLocalNetworkUsageDescription": {
                            "usageDescription": (
                                "ScarfGo connects to your self-hosted Hermes "
                                "server over SSH, including servers on your "
                                "local network."
                            )
                        }
                    }
                },
                "versions": versions,
                "version": version,
                "versionDate": now,
                "size": size,
                "downloadURL": download_url,
            }
        ],
        "news": existing.get("news") or [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {args.output}")
    print(f"Source URL: {source_url}")
    print(f"IPA URL: {download_url}")


if __name__ == "__main__":
    main()
