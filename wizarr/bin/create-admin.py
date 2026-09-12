#!/usr/bin/env python3
"""Create the initial Wizarr admin account (Krate _secure, no CSRF)."""

import os
import re
import sys

from app import create_app
from app.config import ProductionConfig
from app.extensions import db
from app.models import AdminAccount, Settings

DEFAULT_SETTING_KEYS = (
    "server_type",
    "admin_username",
    "admin_password",
    "server_verified",
    "server_url",
    "api_key",
    "server_name",
    "libraries",
    "overseerr_url",
    "ombi_api_key",
    "discord_id",
    "custom_html",
)


def main() -> int:
    username = os.environ.get("WIZARR_KRATE_USERNAME", "")
    password = os.environ.get("WIZARR_KRATE_PASSWORD", "")

    if not re.fullmatch(r"^[\w'.-]+$", username) or not (3 <= len(username) <= 15):
        print(f"wizarr: invalid admin username {username!r}", file=sys.stderr)
        return 1
    if len(password) < 8 or not re.fullmatch(
        r"^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$", password
    ):
        print(
            "wizarr: password must be 8+ chars with upper, lower and digit",
            file=sys.stderr,
        )
        return 1

    app = create_app(ProductionConfig)
    with app.app_context():
        if AdminAccount.query.first():
            return 0

        for key in DEFAULT_SETTING_KEYS:
            if not Settings.query.filter_by(key=key).first():
                row = Settings()
                row.key = key
                row.value = None
                db.session.add(row)
        db.session.commit()

        settings = {row.key: row for row in Settings.query.all()}
        account = AdminAccount()
        account.username = username
        account.set_password(password)
        db.session.add(account)
        settings["admin_username"].value = username
        settings["admin_password"].value = account.password_hash
        db.session.commit()

    return 0


if __name__ == "__main__":
    sys.exit(main())
