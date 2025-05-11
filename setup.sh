#!/bin/bash

# === SETUP AWAL ===
IP_SERVER="8.215.192.205"
DOMAIN="riyan200324.duckdns.org"
USERNAME="riyan"
PASSWORD="saputra"
WS_PORT=8888
WS_PATH="/ssh_ws/"
INSTALL_DIR="/opt/ssh_ws"

echo "[*] Memastikan port 80 tidak digunakan..."
fuser -k 80/tcp || true

echo "[*] Install dependensi..."
apt update -y && apt install -y nginx python3 python3-venv python3-pip

echo "[*] Setup project di $INSTALL_DIR..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR
python3 -m venv venv
source venv/bin/activate
pip install websockets paramiko

echo "[*] Membuat file server WebSocket..."
cat <<EOF > $INSTALL_DIR/ssh_ws_server.py
import asyncio, websockets, paramiko, os

SSH_HOST = os.getenv("SSH_HOST", "$IP_SERVER")
SSH_PORT = int(os.getenv("SSH_PORT", 22))
SSH_USERNAME = os.getenv("SSH_USERNAME", "$USERNAME")
SSH_PASSWORD = os.getenv("SSH_PASSWORD", "$PASSWORD")

async def handle_client(websocket, path):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SSH_HOST, port=SSH_PORT, username=SSH_USERNAME, password=SSH_PASSWORD)
    chan = ssh.get_transport().open_session()
    chan.get_pty()
    chan.invoke_shell()

    async def to_ssh():
        async for msg in websocket:
            chan.send(msg)

    async def from_ssh():
        while True:
            if chan.recv_ready():
                data = chan.recv(1024)
                await websocket.send(data.decode())

    await asyncio.gather(to_ssh(), from_ssh())

async def main():
    async with websockets.serve(handle_client, "0.0.0.0", $WS_PORT):
        await asyncio.Future()

asyncio.run(main())
EOF

echo "[*] Membuat systemd service..."
cat <<EOF > /etc/systemd/system/sshws.service
[Unit]
Description=SSH over WebSocket
After=network.target

[Service]
Environment="SSH_HOST=$IP_SERVER"
Environment="SSH_PORT=22"
Environment="SSH_USERNAME=$USERNAME"
Environment="SSH_PASSWORD=$PASSWORD"
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/ssh_ws_server.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Setting up Nginx untuk reverse proxy..."
cat <<EOF > /etc/nginx/sites-available/ssh_ws
server {
    listen 80;
    server_name $IP_SERVER $DOMAIN;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$WS_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ssh_ws /etc/nginx/sites-enabled/ssh_ws
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

echo "[*] Aktifkan service systemd..."
systemctl daemon-reload
systemctl enable sshws
systemctl start sshws

echo "[✔] SSH WebSocket berhasil di-setup di ws://$IP_SERVER$WS_PATH"
