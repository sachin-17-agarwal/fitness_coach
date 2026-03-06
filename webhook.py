"""
webhook.py — Flask server that receives incoming WhatsApp messages from Twilio.

When you send a WhatsApp message to your bot number, Twilio calls this server.
This server passes your message to the coach and sends the reply back.

To run locally for testing:
  1. pip install flask
  2. python webhook.py
  3. In another terminal: ngrok http 5000
  4. Copy the ngrok URL and paste it into Twilio's WhatsApp sandbox webhook field

To run in production:
  Deploy to a cheap VPS (DigitalOcean $4/month, Railway, Render free tier)
  and point Twilio to your server URL.
"""

from flask import Flask, request
from twilio.twiml.messaging_response import MessagingResponse
from coach import handle_incoming_message
from memory import load_memory

app = Flask(__name__)

@app.route("/webhook", methods=["POST"])
def webhook():
    """Receives incoming WhatsApp messages from Twilio."""
    incoming_msg = request.values.get("Body", "").strip()
    sender = request.values.get("From", "")
    
    print(f"📨 Message from {sender}: {incoming_msg}")
    
    if not incoming_msg:
        return str(MessagingResponse())
    
    # Load memory and get coach response
    memory = load_memory()
    coach_reply = handle_incoming_message(incoming_msg, memory)
    
    # Send reply back via Twilio
    resp = MessagingResponse()
    resp.message(coach_reply)
    return str(resp)

@app.route("/health", methods=["GET"])
def health():
    return "Coach is running 💪", 200

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    debug = os.environ.get("RAILWAY_ENVIRONMENT") is None
    print(f"🚀 Webhook server starting on port {port}...")
    app.run(host="0.0.0.0", port=port, debug=debug)
