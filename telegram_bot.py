"""
telegram_bot.py - Send and receive Telegram messages via Bot API.
"""

import os
import requests

TELEGRAM_API = "https://api.telegram.org/bot{token}/{method}"


def get_token():
    return os.environ.get("TELEGRAM_BOT_TOKEN", "")


def get_chat_id():
    return os.environ.get("TELEGRAM_CHAT_ID", "")


def send_message(text: str, chat_id: str = None):
    """Send a Telegram message, splitting if over 4096 chars."""
    token = get_token()
    chat_id = chat_id or get_chat_id()

    if not token or not chat_id:
        print(f"\n{'-' * 50}")
        print("[Telegram message would be sent]")
        print(text)
        print(f"{'-' * 50}\n")
        return

    chunks = split_message(text, limit=4096)

    for i, chunk in enumerate(chunks, 1):
        try:
            url = TELEGRAM_API.format(token=token, method="sendMessage")
            resp = requests.post(url, json={
                "chat_id": chat_id,
                "text": chunk,
                "parse_mode": "Markdown",
            }, timeout=10)
            if resp.status_code != 200:
                resp = requests.post(url, json={
                    "chat_id": chat_id,
                    "text": chunk,
                }, timeout=10)

            if resp.status_code == 200:
                print(f"Telegram message sent (part {i}/{len(chunks)})")
            else:
                print(f"Telegram send failed: {resp.status_code} {resp.text}")
        except Exception as e:
            print(f"Telegram send error: {e}")


def _split_long_block(text: str, limit: int) -> list[str]:
    chunks = []
    remaining = text
    while len(remaining) > limit:
        split_at = remaining.rfind("\n", 0, limit + 1)
        if split_at <= 0:
            split_at = remaining.rfind(" ", 0, limit + 1)
        if split_at <= 0:
            split_at = limit
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks


def split_message(text: str, limit: int = 4096) -> list[str]:
    """Split message at paragraph boundaries, then newline/word boundaries."""
    if len(text) <= limit:
        return [text]

    chunks = []
    paragraphs = text.split("\n\n")
    current = ""

    for para in paragraphs:
        if len(current) + len(para) + 2 <= limit:
            current = current + "\n\n" + para if current else para
        else:
            if current:
                chunks.append(current.strip())
            if len(para) > limit:
                chunks.extend(_split_long_block(para, limit))
                current = ""
            else:
                current = para

    if current:
        chunks.append(current.strip())

    return chunks


def set_webhook(webhook_url: str):
    """Register webhook URL with Telegram."""
    token = get_token()
    url = TELEGRAM_API.format(token=token, method="setWebhook")
    resp = requests.post(url, json={"url": webhook_url}, timeout=10)
    print(f"Webhook set: {resp.json()}")
    return resp.json()


def delete_webhook():
    """Remove webhook (for polling mode)."""
    token = get_token()
    url = TELEGRAM_API.format(token=token, method="deleteWebhook")
    resp = requests.post(url, timeout=10)
    return resp.json()
