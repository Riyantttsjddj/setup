#!/bin/bash

# Konfigurasi
SSH_HOST="127.0.0.1"
SSH_PORT=22
SSH_USERNAME="riyan"
SSH_PASSWORD="saputra"
WEB_SOCKET_PORT=8888
NGINX_PORT=80
DOMAIN="8.215.192.205" # Ganti dengan domain atau IP Anda

# Fungsi untuk mengecek apakah port 80 sedang digunakan
check_port_80() {
    if lsof -i :$NGINX_PORT > /dev/null; then
        echo "Port 80 sudah digunakan. Menghentikan proses lama..."
        pid=$(lsof -t -i:$NGINX_PORT)
        kill -9 $pid
        echo "Proses yang menggunakan port 80 telah dihentikan."
    else
        echo "Port 80 tidak digunakan."
    fi
}

# Install dependencies
install_dependencies() {
    echo "Menginstal dependensi..."
    apt update -y
    apt install -y python3 python3-pip python3-venv nginx
    pip install websockets paramiko
}

# Install dan buat server WebSocket Python
install_ws_server() {
    echo "Membuat server WebSocket..."
    mkdir -p /opt/ssh_ws
    cd /opt/ssh_ws
    python3 -m venv venv
    source venv/bin/activate
    cat <<EOL > /opt/ssh_ws/ssh_ws_server.py
import asyncio
import websockets
import paramiko

SSH_HOST = "$SSH_HOST"
SSH_PORT = $SSH_PORT
SSH_USERNAME = "$SSH_USERNAME"
SSH_PASSWORD = "$SSH_PASSWORD"

async def handle_client(websocket, path):
    ssh_client = paramiko.SSHClient()
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh_client.connect(SSH_HOST, port=SSH_PORT, username=SSH_USERNAME, password=SSH_PASSWORD)
    channel = ssh_client.get_transport().open_session()
    channel.get_pty()
    channel.invoke_shell()

    async def to_ssh():
        async for message in websocket:
            channel.send(message)

    async def from_ssh():
        while True:
            if channel.recv_ready():
                output = channel.recv(1024)
                await websocket.send(output.decode())

    await asyncio.gather(to_ssh(), from_ssh())

async def main():
    server = await websockets.serve(handle_client, "0.0.0.0", $WEB_SOCKET_PORT)
    await server.wait_closed()

asyncio.run(main())
EOL

    echo "Server WebSocket siap berjalan di port $WEB_SOCKET_PORT"
}

# Membuat file konfigurasi Nginx
configure_nginx() {
    echo "Mengonfigurasi Nginx..."
    cat <<EOL > /etc/nginx/sites-available/ssh_ws
server {
    listen $NGINX_PORT;
    server_name $DOMAIN;

    location /ssh_ws/ {
        proxy_pass http://127.0.0.1:$WEB_SOCKET_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOL

    ln -s /etc/nginx/sites-available/ssh_ws /etc/nginx/sites-enabled/
    nginx -t
    systemctl restart nginx
}

# Membuat service systemd untuk WebSocket Server agar berjalan otomatis
create_service() {
    echo "Membuat service systemd untuk WebSocket Server..."
    cat <<EOL > /etc/systemd/system/ssh_ws.service
[Unit]
Description=SSH over WebSocket
After=network.target

[Service]
ExecStart=/opt/ssh_ws/venv/bin/python /opt/ssh_ws/ssh_ws_server.py
WorkingDirectory=/opt/ssh_ws
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable ssh_ws
    systemctl start ssh_ws
}

# Memastikan server WebSocket dan Nginx berjalan
start_server() {
    echo "Menjalankan server WebSocket dan Nginx..."
    check_port_80
    install_ws_server
    configure_nginx
    create_service
    systemctl restart nginx
}

# Menjalankan proses instalasi dan konfigurasi
install_dependencies
start_server

echo "Konfigurasi selesai. Server WebSocket berjalan pada port $WEB_SOCKET_PORT."
