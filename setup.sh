#!/bin/bash

# --- Konfigurasi Awal ---
USERNAME="riyan"
PASSWORD="saputra"
BUG_HOST="dev.appsflyer.com"
SERVER_NAME=$(hostname)
SERVER_IP=$(hostname -I | awk '{print $1}')

# --- Update dan Instalasi ---
apt update && apt upgrade -y
apt install -y python3-pip python3-venv nginx certbot python3-certbot-nginx \
  python3-dev build-essential libssl-dev

# --- Setup Direktori dan Venv ---
mkdir -p /opt/ssh_ws
cd /opt/ssh_ws
python3 -m venv venv
source venv/bin/activate
pip install websockets paramiko pycryptodome

# --- Script WebSocket SSH Server ---
cat << EOF > ssh_ws_server.py
from Crypto.Cipher import AES
import base64
import websockets
import paramiko
import asyncio

def decrypt_payload(data, key):
    raw = base64.b64decode(data)
    nonce, tag, ciphertext = raw[:16], raw[16:32], raw[32:]
    cipher = AES.new(key, AES.MODE_EAX, nonce=nonce)
    return cipher.decrypt_and_verify(ciphertext, tag).decode('utf-8')

async def handle_ssh_connection(websocket, path):
    secret_key = b'secretkey1234567'
    try:
        encrypted = await websocket.recv()
        decrypted = decrypt_payload(encrypted, secret_key)

        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect('$SERVER_IP', username='$USERNAME', password='$PASSWORD')

        chan = ssh.get_transport().open_session()
        chan.get_pty()
        chan.invoke_shell()

        async def to_ssh():
            while True:
                data = await websocket.recv()
                if data:
                    chan.send(data)

        async def from_ssh():
            while True:
                if chan.recv_ready():
                    data = chan.recv(1024)
                    await websocket.send(data.decode())

        await asyncio.gather(to_ssh(), from_ssh())

    except Exception as e:
        print(f"Error: {e}")
    finally:
        ssh.close()

start_server = websockets.serve(handle_ssh_connection, 'localhost', 8888)
asyncio.get_event_loop().run_until_complete(start_server)
asyncio.get_event_loop().run_forever()
EOF

# --- Konfigurasi Nginx ---
cat << EOF > /etc/nginx/sites-available/ssh_ws
server {
    listen 443 ssl;
    server_name $SERVER_NAME;

    ssl_certificate /etc/letsencrypt/live/$SERVER_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SERVER_NAME/privkey.pem;

    location /ssh_ws/ {
        proxy_pass http://127.0.0.1:8888/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
    }
}

server {
    listen 443 ssl;
    server_name $BUG_HOST;

    ssl_certificate /etc/letsencrypt/live/$BUG_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$BUG_HOST/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8888/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
    }
}
EOF

ln -s /etc/nginx/sites-available/ssh_ws /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# --- Pasang SSL ---
certbot --nginx -d $SERVER_NAME -d $BUG_HOST --non-interactive --agree-tos -m you@example.com

# --- Systemd Service ---
cat << EOF > /etc/systemd/system/ssh_ws.service
[Unit]
Description=SSH WebSocket Server
After=network.target

[Service]
ExecStart=/opt/ssh_ws/venv/bin/python3 /opt/ssh_ws/ssh_ws_server.py
WorkingDirectory=/opt/ssh_ws
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh_ws
systemctl start ssh_ws

echo -e "\n✅ SSH WebSocket berhasil disiapkan!"
echo "🔗 WSS URL: wss://$BUG_HOST/"
echo "🧑 Username: $USERNAME"
echo "🔒 Password: $PASSWORD"
