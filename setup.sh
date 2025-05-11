#!/bin/bash

# --- Konfigurasi ---
USERNAME="riyan"
PASSWORD="saputra"
DOMAIN="riyan200324.duckdns.org"
BUG_HOST="dev.appsflyer.com"
WS_PORT=8888

# --- Update dan Install ---
apt update && apt install -y nginx python3 python3-pip python3-venv certbot python3-certbot-nginx

# --- Tambahkan user SSH ---
id "$USERNAME" &>/dev/null || useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# --- Setup WebSocket server ---
mkdir -p /opt/ssh_ws && cd /opt/ssh_ws
python3 -m venv venv
source venv/bin/activate
pip install websockets paramiko pycryptodome

cat > ssh_ws_server.py <<EOF
import asyncio, websockets, paramiko
async def handle_client(websocket):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect("127.0.0.1", port=22, username="$USERNAME", password="$PASSWORD")
    chan = ssh.get_transport().open_session()
    chan.get_pty()
    chan.invoke_shell()
    async def to_ssh():
        async for data in websocket:
            chan.send(data)
    async def from_ssh():
        while True:
            if chan.recv_ready():
                data = chan.recv(1024)
                await websocket.send(data.decode())
    await asyncio.gather(to_ssh(), from_ssh())
async def main():
    async with websockets.serve(handle_client, "127.0.0.1", $WS_PORT):
        await asyncio.Future()
asyncio.run(main())
EOF

# --- Systemd service ---
cat > /etc/systemd/system/ssh_ws.service <<EOF
[Unit]
Description=SSH over WebSocket
After=network.target

[Service]
ExecStart=/opt/ssh_ws/venv/bin/python3 /opt/ssh_ws/ssh_ws_server.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable ssh_ws
systemctl restart ssh_ws

# --- Nginx config (tanpa SSL dulu agar certbot bisa jalan) ---
cat > /etc/nginx/sites-available/ssh_ws <<EOF
server {
    listen 80;
    server_name $DOMAIN $BUG_HOST;

    location /ssh_ws/ {
        proxy_pass http://127.0.0.1:$WS_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -s /etc/nginx/sites-available/ssh_ws /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# --- Request SSL ---
certbot --nginx --non-interactive --agree-tos --email admin@$DOMAIN -d $DOMAIN -d $BUG_HOST

# --- Ubah Nginx ke HTTPS setelah SSL valid ---
cat > /etc/nginx/sites-available/ssh_ws <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN $BUG_HOST;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location /ssh_ws/ {
        proxy_pass http://127.0.0.1:$WS_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

nginx -t && systemctl reload nginx

echo -e "\n✅ Installasi selesai!"
echo "🔗 Connect via WSS (WebSocket over SSL):"
echo "   Host/IP  : $BUG_HOST"
echo "   Port     : 443"
echo "   Path     : /ssh_ws/"
echo "   Username : $USERNAME"
echo "   Password : $PASSWORD"
