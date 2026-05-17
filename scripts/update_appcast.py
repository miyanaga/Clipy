#!/usr/bin/env python3
"""
appcast.xml を Sparkle 2.x 形式で更新するスクリプト。
リリースワークフロー (.github/workflows/release.yml) から呼ばれる。

使い方:
    python3 scripts/update_appcast.py \\
        --appcast docs/appcast.xml \\
        --version 1.2.2 \\
        --tag v1.2.2 \\
        --url https://github.com/.../releases/download/v1.2.2/Clipy-1.2.2.dmg \\
        --size 12345678 \\
        --signature "base64edSignatureHere==" \\
        --min-os 13.0
"""

import argparse
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

JST = timezone(timedelta(hours=9))

ITEM_TEMPLATE = """\
        <item>
            <title>Version {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://github.com/miyanaga/Clipy/releases/tag/{tag}</sparkle:releaseNotesLink>
            <enclosure
                url="{url}"
                length="{size}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}"
            />
        </item>"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Update Sparkle appcast.xml")
    parser.add_argument("--appcast", required=True, help="Path to appcast.xml")
    parser.add_argument("--version", required=True, help="App version (e.g. 1.2.2)")
    parser.add_argument("--tag", required=True, help="Git tag (e.g. v1.2.2)")
    parser.add_argument("--url", required=True, help="DMG download URL")
    parser.add_argument("--size", required=True, help="DMG file size in bytes")
    parser.add_argument("--signature", required=True, help="Sparkle EdDSA signature")
    parser.add_argument("--min-os", default="13.0", help="Minimum macOS version")
    args = parser.parse_args()

    appcast_path = Path(args.appcast)
    if not appcast_path.exists():
        print(f"Error: {appcast_path} not found", file=sys.stderr)
        sys.exit(1)

    pub_date = datetime.now(JST).strftime("%a, %d %b %Y %H:%M:%S %z")

    new_item = ITEM_TEMPLATE.format(
        version=args.version,
        pub_date=pub_date,
        min_os=args.min_os,
        tag=args.tag,
        url=args.url,
        size=args.size,
        signature=args.signature,
    )

    content = appcast_path.read_text(encoding="utf-8")

    # <channel> の最初の子要素として新しい <item> を挿入
    # （既存の <item> より前に置くことで最新が先頭になる）
    if "<item>" in content:
        content = content.replace("<item>", new_item + "\n        <item>", 1)
    else:
        # item がまだない場合はコメントの後に挿入
        insert_marker = "<!-- リリースエントリは scripts/update_appcast.py によって自動生成されます -->"
        if insert_marker in content:
            content = content.replace(
                insert_marker,
                insert_marker + "\n" + new_item,
            )
        else:
            # フォールバック: </channel> の直前
            content = content.replace("    </channel>", new_item + "\n    </channel>")

    appcast_path.write_text(content, encoding="utf-8")
    print(f"appcast.xml updated: version={args.version}, tag={args.tag}")


if __name__ == "__main__":
    main()
