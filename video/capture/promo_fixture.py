"""Fictional mailboxes for the promo film.

Every sender, address and message here is invented. Addresses use the reserved
example.com/.org/.net domains. The smoke-test mail is the same text as the
public screenshots (tests/terminal_publication.py). Nothing reads a real
mailbox, configuration or credential.
"""
from __future__ import annotations

import base64
import copy
import html
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))

from probes.cache_refresh_fixture import repage  # noqa: E402
from terminal_cache import ProviderFixture  # noqa: E402
from terminal_integration import Client, require  # noqa: E402
from terminal_publication import SMOKE, SMOKE_HTML, SUBJECT  # noqa: E402

PERSONAL, WORK, OPTIONAL = "personal@example.com", "work@example.com", "optional@example.com"
ACCOUNTS = (PERSONAL, WORK, OPTIONAL)
BASE_MS = 1791280800000  # 2026-10-06 10:00 UTC, as in the publication captures
STEP_MS = 1800000
SMOKE_ID = "promo-work-096"
NEWSLETTER_ID = "promo-work-095"
COUNT = 96

NEWSLETTER_SUBJECT = "October build notes"
NEWSLETTER_HTML = (
    "<html><body>"
    "<h1>October build notes</h1>"
    "<p>Hello from <strong>Harbor Workshop</strong>. Here is what changed this month.</p>"
    "<h2>Shipped</h2>"
    "<ul><li><strong>Faster sync</strong> for the shared board</li>"
    "<li>Calmer notifications</li><li>Dark mode for the print view</li></ul>"
    "<h2>By the numbers</h2>"
    "<table><thead><tr><th>Area</th><th>Fixed</th><th>Open</th></tr></thead><tbody>"
    "<tr><td>Board</td><td>12</td><td>3</td></tr>"
    "<tr><td>Exports</td><td>7</td><td>1</td></tr>"
    "<tr><td>Mobile</td><td>4</td><td>0</td></tr>"
    "</tbody></table>"
    "<blockquote>Small releases, often. That is the whole plan.</blockquote>"
    "<p><img src=\"https://example.net/harbor/logo.png\" alt=\"[Harbor Workshop logo]\"></p>"
    "<p>See you next month,<br><em>The Harbor Workshop team</em></p>"
    "<p><a href=\"https://example.net/harbor/october\">Read the full notes</a></p>"
    "</body></html>"
)

# (sender, address, subject, snippet, unread). Index 0 is newest.
WORK_MAIL = (
    ("Omagma Volcano", PERSONAL, SUBJECT, "The smoke is metaphorical. Your inbox is not on fire. 🌋", True),
    ("Harbor Workshop", "notes@harbor.example.net", NEWSLETTER_SUBJECT, "Three fixes, two features and one very calm release.", True),
    ("Cedar Studio", "hello@cedar.example.org", "A smaller inbox, a calmer morning ☕", "Three tiny improvements. One noticeably quieter morning.", True),
    ("Riley", "riley@example.org", "Friday's launch checklist 🚀", "The last few details are ready. Let's make the landing smooth.", False),
    ("Lumen Design", "studio@lumen.example.net", "Design review: keep the good bits", "The clean layout works. The giant buttons can take a holiday.", True),
    ("Project Lantern", "lantern@example.org", "Notes from the demo ✨", "A reader, a terminal, and a suspiciously useful little volcano.", False),
    ("Willow Collective", "team@willow.example.org", "Re: A very reasonable memory budget", "Turns out mail can leave room for the rest of your computer.", True),
    ("Northstar Tools", "updates@northstar.example.com", "Your October workspace summary", "A tidy overview of what changed, without fifteen browser tabs.", False),
    ("Open Trail", "meetup@opentrail.example.org", "Community meetup: bring your questions", "Short talks, good coffee, and a little time to catch up.", False),
    ("Studio Orbit", "hi@orbit.example.net", "The subject line does the heavy lifting", "Sender, subject, and preview. No treasure hunt required.", True),
    ("Maple Desk", "desk@maple.example.com", "Next week's office hours", "A short schedule for a busy week. Pick the time that works.", False),
)
PERSONAL_MAIL = (
    ("Riverside Library", "holds@library.example.org", "Your hold is ready 📚", "Two books are waiting at the front desk until Saturday.", True),
    ("Sam", "sam@example.net", "Lisbon, round two?", "Same tram, more pastries. I found three free weekends.", True),
    ("Spoke & Chain", "shop@spoke.example.com", "Your bike is ready 🚲", "New chain, true wheels, and a bell that finally rings.", False),
    ("Alex", "alex@example.net", "Sunday pancakes at ten 🥞", "Bring the good syrup. I have the coffee covered.", True),
    ("Paper Moon Prints", "orders@papermoon.example.org", "Your photo book proof", "Approve by Friday and it ships next week.", False),
    ("Boulder Hall", "news@boulder.example.com", "New routes this weekend", "Twelve fresh problems, two of them suspiciously friendly.", False),
)
OPTIONAL_MAIL = (
    ("Garage Lab", "crew@garage.example.org", "Side project: ideas for v0.3", "A shorter list, a clearer goal and one bold idea.", True),
    ("The Night Shift", "band@nightshift.example.net", "Practice moved to Thursday 🎸", "Same room, earlier start. Bring the new chorus.", True),
    ("Registrar Example", "renewals@registrar.example.com", "Your domain renews next month", "No action needed. Auto-renew is on.", False),
    ("Open Trail", "meetup@opentrail.example.org", "Hackathon teams are forming", "Pick a problem, find two friends, ship something small.", False),
)

REPLY_BODY = "Confirmed: one very small eruption, zero fires. Notes and a photo attached. 🌋"
CC_QUERY = "ced"
CC_ADDRESS = "hello@cedar.example.org"
ATTACHMENTS = (("eruption-report.md", "er"), ("lava-lamp.png", "la"))


def known_addresses():
    """Every fictional address the fixture can show, for the capture privacy gate."""
    found = {PERSONAL, WORK, OPTIONAL, CC_ADDRESS}
    for entries in (WORK_MAIL, PERSONAL_MAIL, OPTIONAL_MAIL):
        found.update(address for _, address, *_ in entries)
    return sorted(address.lower() for address in found)


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def html_body(sender, snippet):
    return (f"<html><body><p>Hello Morgan,</p><p>{html.escape(snippet)}</p>"
            f"<p>Cheers,<br>{html.escape(sender)}</p></body></html>")


def mailbox(template, account, entries, special=None, count=COUNT):
    """Gmail-shaped messages, newest first; later entries become 'Earlier notes'."""
    key = account.split("@")[0]
    special = special or {}
    messages = []
    for index in range(count):
        sender, address, subject, snippet, unread = entries[index % len(entries)]
        if index >= len(entries):
            subject = f"Earlier notes {index + 1}: {subject}"
        number = count - index
        message_id = f"promo-{key}-{number:03}"
        body = special.get(message_id, html_body(sender, snippet)).encode()
        to = f"Morgan <{account}>"
        message = copy.deepcopy(template)
        message.update(id=message_id, threadId=f"promo-{key}-thread-{number:03}",
                       internalDate=str(BASE_MS - index * STEP_MS),
                       labelIds=["INBOX", "UNREAD"] if unread else ["INBOX"], snippet=snippet)
        message["sizeEstimate"] = len(body)
        message["payload"] = {
            "partId": "", "mimeType": "text/html", "filename": "",
            "headers": [
                {"name": "From", "value": f"{sender} <{address}>"},
                {"name": "To", "value": to},
                {"name": "Subject", "value": subject},
                {"name": "Message-ID", "value": f"<{message_id}@example.org>"},
                {"name": "Content-Type", "value": "text/html; charset=utf-8"},
            ],
            "body": {"size": len(body), "data": b64(body)},
        }
        messages.append(message)
    return messages


def fixture(directory):
    """A ProviderFixture whose three accounts hold the promo mailboxes."""
    source = ProviderFixture(directory)
    plans = {
        WORK: (WORK_MAIL, {SMOKE_ID: SMOKE_HTML, NEWSLETTER_ID: NEWSLETTER_HTML}),
        PERSONAL: (PERSONAL_MAIL, None),
        OPTIONAL: (OPTIONAL_MAIL, None),
    }
    for account, (entries, special) in plans.items():
        baseline = source.data[account]["baseline"]
        template = baseline["messages"][0]
        baseline["labels"] = [{"id": "INBOX", "name": "Inbox", "type": "system"}]
        baseline["messages"] = mailbox(template, account, entries, special)
        repage(baseline)
        source.stage(account, "baseline")
    return source


def seed(binary, directory, source, count=32, accounts=ACCOUNTS):
    """Fill the private fixture cache, as the publication capture does."""
    with Client(binary, directory, extra=source.options()) as client:
        for account in accounts:
            client.request("mail.refresh", account, label="INBOX", limit=count, prefetchLimit=count)
            client.request("labels.list", account)
        if WORK in accounts:
            message = client.request("mail.read", WORK, messageId=SMOKE_ID, cacheOnly=True)
            require(message["subject"] == SUBJECT, "promo smoke-test mail was not cached")
            require("".join(SMOKE.split()) in "".join(message["bodyText"].split()), "promo smoke-test text changed")
            letter = client.request("mail.read", WORK, messageId=NEWSLETTER_ID, cacheOnly=True)
            require(letter["subject"] == NEWSLETTER_SUBJECT, "promo newsletter was not cached")
        require(client.request("cache.stats")["fixtureSends"] == 0, "promo seeding sent mail")
    require(client.process.returncode == 0 and not client.stderr, "promo seed failed cleanup")


def png(width=96, height=96):
    """A small warm gradient PNG, generated locally for the attachment take."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            heat = max(0.0, 1 - ((x - width / 2) ** 2 + (y - height * .62) ** 2) ** .5 / (width * .55))
            row += bytes((int(40 + 215 * heat), int(22 + 136 * heat ** 1.4), int(28 + 70 * heat ** 3)))
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


def attachment_files(directory):
    """The two local files the compose take attaches; returned in attach order."""
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    report = directory / ATTACHMENTS[0][0]
    report.write_text(
        "# Eruption report\n\n"
        "- Size: very small\n- Fires: zero\n- Smoke: metaphorical\n- Inbox: calm\n\n"
        "Observed from a safe distance by a suspiciously productive volcano.\n")
    (directory / ATTACHMENTS[1][0]).write_bytes(png())
    return [directory / name for name, _ in ATTACHMENTS]
