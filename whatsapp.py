"""
whatsapp.py — Sends WhatsApp messages via Twilio.
Automatically splits messages that exceed Twilio's 1600 character limit.
"""

import os
try:
    from twilio.rest import Client
    TWILIO_AVAILABLE = True
except ImportError:
    TWILIO_AVAILABLE = False

MAX_LENGTH = 1550  # slightly under 1600 to be safe

def split_message(message: str) -> list:
    """Split a long message into chunks under MAX_LENGTH, breaking at paragraph boundaries."""
    if len(message) <= MAX_LENGTH:
        return [message]

    chunks = []
    paragraphs = message.split("\n\n")
    current = ""

    for para in paragraphs:
        if len(current) + len(para) + 2 <= MAX_LENGTH:
            current = current + "\n\n" + para if current else para
        else:
            if current:
                chunks.append(current.strip())
            # If a single paragraph is too long, split at newlines
            if len(para) > MAX_LENGTH:
                lines = para.split("\n")
                current = ""
                for line in lines:
                    if len(current) + len(line) + 1 <= MAX_LENGTH:
                        current = current + "\n" + line if current else line
                    else:
                        if current:
                            chunks.append(current.strip())
                        current = line
            else:
                current = para

    if current:
        chunks.append(current.strip())

    return chunks

def send_whatsapp_message(message: str, to_number: str):
    """
    Send a WhatsApp message via Twilio.
    Automatically splits messages exceeding 1600 characters.
    to_number format: 'whatsapp:+61412345678'
    """
    account_sid = os.environ.get("TWILIO_ACCOUNT_SID")
    auth_token = os.environ.get("TWILIO_AUTH_TOKEN")
    from_number = os.environ.get("TWILIO_WHATSAPP_FROM", "whatsapp:+14155238886")

    chunks = split_message(message)

    if not TWILIO_AVAILABLE or not account_sid or not auth_token:
        print(f"\n{'─'*50}")
        print("📱 [WhatsApp message would be sent]")
        print(f"To: {to_number} ({len(chunks)} part(s))")
        for i, chunk in enumerate(chunks, 1):
            print(f"\n--- Part {i} ---\n{chunk}")
        print(f"{'─'*50}\n")
        return

    try:
        client = Client(account_sid, auth_token)
        for i, chunk in enumerate(chunks, 1):
            msg = client.messages.create(
                from_=from_number,
                body=chunk,
                to=to_number
            )
            print(f"✅ Sent part {i}/{len(chunks)}. SID: {msg.sid}")
    except Exception as e:
        print(f"❌ WhatsApp send failed: {e}")
        print(f"Message content:\n{message}")