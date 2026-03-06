"""
whatsapp.py — Sends and receives WhatsApp messages via Twilio.

Setup:
1. Create a free Twilio account at twilio.com
2. Enable the WhatsApp sandbox (takes 2 mins)
3. Add TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN to your .env file
4. For production: apply for a WhatsApp Business number (~$5/month)

Receiving messages:
- Twilio calls a webhook URL when you send a message to your bot
- Use webhook.py (included) to handle incoming messages
- For local testing, use ngrok to expose your local server
"""

import os
from twilio.rest import Client

def send_whatsapp_message(message: str, to_number: str):
    """
    Send a WhatsApp message via Twilio.
    to_number format: "whatsapp:+61412345678"
    """
    account_sid = os.environ.get("TWILIO_ACCOUNT_SID")
    auth_token = os.environ.get("TWILIO_AUTH_TOKEN")
    from_number = os.environ.get("TWILIO_WHATSAPP_FROM", "whatsapp:+14155238886")  # Twilio sandbox default
    
    if not account_sid or not auth_token:
        # If no Twilio credentials, just print to terminal (useful for testing)
        print(f"\n{'─'*50}")
        print("📱 [WhatsApp message would be sent]")
        print(f"To: {to_number}")
        print(f"\n{message}")
        print(f"{'─'*50}\n")
        return
    
    try:
        client = Client(account_sid, auth_token)
        msg = client.messages.create(
            from_=from_number,
            body=message,
            to=to_number
        )
        print(f"✅ WhatsApp message sent. SID: {msg.sid}")
    except Exception as e:
        print(f"❌ WhatsApp send failed: {e}")
        print(f"Message content:\n{message}")
