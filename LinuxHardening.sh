#!/bin/bash
set -e
set -u
set -o pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Use sudo."
  exit 1
fi

# Set variables
TIMEZONE="America/Edmonton"

# Set the timezone to Americas/Edmonton
echo "Setting timezone to $TIMEZONE..."
if timedatectl set-timezone "$TIMEZONE"; then
  echo "Timezone successfully set to $TIMEZONE."
else
  echo "Failed to set timezone. Please check your permissions or the timezone value."
  exit 1
fi

# Configure Apt repositories
echo adding Apt repositories for commonly used packages...

#Elasticsearch 

# Get the GPG Key
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -

# Add the Elastic Repo
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list

# DOCKER
# Add Docker's official GPG key:

sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

#System76
# Add the System76 repository for additional drivers and tools

apt-add-repository -y ppa:system76-dev/stable

# Update the package list
apt-get update

# Update the system
echo "Updating the system..."
if apt-get update && apt-get upgrade -y; then
  echo "System successfully updated."
else
  echo "Failed to update the system. Please check your network connection or package manager."
  exit 1
fi

# === Hostname Configuration ===
read -p "Enter the desired hostname (e.g. example-hostname): " NEW_HOSTNAME
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "127.0.0.1 localhost" > /etc/hosts
read -p "Enter the internal IP (e.g. 172.17.1.250): " INTERNAL_IP
read -p "Enter the FQDN (e.g. xxxx.una.ca): " FQDN
HOSTNAME_SHORT=$(echo "$FQDN" | cut -d. -f1)
echo "$INTERNAL_IP $FQDN $HOSTNAME_SHORT" >> /etc/hosts

# Make base UNA folders
echo "Creating base UNA folders..."
mkdir /una-scripts
mkdir /una-backups

#Disable SSH root login

echo "Disabling root login via SSH..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || \
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload ssh
echo "Root login via SSH has been disabled."

# === Firewall Setup (UFW) ===
echo "Setting up UFW firewall..."
apt-get install -y ufw
ufw limit from 172.17.0.0/16 to any port ssh
ufw limit from 192.168.40.0/24 to any port ssh
read -p "Enter any additional ports to allow (e.g. 80/tcp 443/tcp): " PORTS
for port in $PORTS; do
    ufw allow "$port"
done
echo "Enabling UFW..."
ufw --force enable
echo "UFW configuration completed but not secure!"
echo "Current UFW status:"
sudo ufw status


# Secure the tmp directory

echo "Securing the /tmp directory..."
dd if=/dev/zero of=/usr/tmpDSK bs=1024 count=1024000
mkdir /tmpbackup && cp -Rpf /tmp /tmpbackup
mount -t tmpfs -o loop,noexec,nosuid,rw /usr/tmpDSK /tmp
chmod 1777 /tmp
cp -Rpf /tmpbackup/* /tmp/ && rm -rf /tmpbackup/*
echo "/usr/tmpDSK /tmp tmpfs loop,nosuid,noexec,rw 0 0" >> /etc/fstat
mount -o remount /tmp
mkdir /var/tmpold 
mv /var/tmp /var/tmpold 
ln -s /tmp /var/tmp 
cp -prf /var/tmpold/* /tmp/
rm -rf /var/tmpold
echo "Secured the /tmp directory."

#Configure 10-Periodic Updates
if sed -i 's/#\?\(APT::Periodic::Update-Package-Lists\).*$/\1 "1";/' /etc/apt/apt.conf.d/10periodic; then
  echo "APT 'Update-Package-Lists' configured successfully."
else
  echo "Failed to configure APT 'Update-Package-Lists'. Manually check /etc/apt/apt.conf.d/10periodic."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::Update-Package-Lists\.*\)$|\1|' /etc/apt/apt.conf.d/10periodic; then
  echo "Uncommented 'Periodic::Update-Package-Lists' successfully"
else 
  echo "Failed to Uncomment 'Periodic::Update-Package-Lists' Manually check /etc/apt/apt.conf.d/10periodic"
  exit 1
fi

if sed -i 's/#\?\(APT::Periodic::Download-Upgradeable-Packages\).*$/\1 "1";/' /etc/apt/apt.conf.d/10periodic; then
  echo "APT 'Download-Upgradeable-Packages' configured successfully."
else
  echo "Failed to configure APT 'Download-Upgradeable-Packages'. Manually check /etc/apt/apt.conf.d/10periodic."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::Download-Upgradeable-Packages\)$|\1|' /etc/apt/apt.conf.d/10periodic; then
  echo "Uncommented 'Periodic::Download-Upgradeable-Packages' successfully"
else 
  echo "Failed to Uncomment 'Periodic::Download-Upgradeable-Packages' Manually check /etc/apt/apt.conf.d/10periodic"
  exit 1
fi


if sed -i 's/#\?\(APT::Periodic::AutocleanInterval\).*$/\1 "7";/' /etc/apt/apt.conf.d/10periodic; then
  echo "APT 'AutocleanInterval' configured successfully."
else
  echo "Failed to configure APT 'AutocleanInterval'. Manually check /etc/apt/apt.conf.d/10periodic."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::AutocleanInterval\)$|\1|' /etc/apt/apt.conf.d/10periodic; then
  echo "Uncommented 'APT::Periodic::AutocleanInterval' successfully"
else 
  echo "Failed to Uncomment 'APT::Periodic::AutocleanInterval' Manually check /etc/apt/apt.conf.d/10periodic"
  exit 1
fi

#Configure 20-AutoUpdates
# Configure APT auto-upgrades
if sed -i 's/#\?\(APT::Periodic::Update-Package-Lists\).*$/\1 "1";/' /etc/apt/apt.conf.d/20auto-upgrades; then
  echo "APT 'Update-Package-Lists' in 20auto-upgrades configured successfully."
else
  echo "Failed to configure APT 'Update-Package-Lists'. Manually check /etc/apt/apt.conf.d/20auto-upgrades."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::Update-Package-Lists\)$|\1|' /etc/apt/apt.conf.d/20auto-upgrades; then
  echo "Uncommented 'APT::Periodic::Update-Package-Lists' successfully"
else 
  echo "Failed to Uncomment 'APT::Periodic::Update-Package-Lists'"
  exit 1
fi

if sed -i 's/#\?\(APT::Periodic::Unattended-Upgrade\).*$/\1 "1";/' /etc/apt/apt.conf.d/20auto-upgrades; then
  echo "APT 'Unattended-Upgrade' enabled."
else
  echo "Failed to configure APT 'Unattended-Upgrade'. Manually check /etc/apt/apt.conf.d/20auto-upgrades."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::Unattended-Upgrade\)$|\1|' /etc/apt/apt.conf.d/20auto-upgrades; then
  echo "Uncommented 'APT::Periodic::Unattended-Upgrade\' successfully"
else 
  echo "Failed to Uncomment 'APT::Periodic::Unattended-Upgrade\'"
  exit 1
fi

#Configure 50-Unattended updates

# Enable automatic security patches:
echo "Enabling automatic security patches..."
if apt-get install -y unattended-upgrades; then
  echo "Unattended upgrades installed successfully."
else
  echo "Failed to install unattended-upgrades. Please check your package manager."
  exit 1
fi

if sed -i 's/#\?\(Unattended-Upgrade::Remove-Unused-Dependencies;\).*$/\1 "true";/' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Unattended 'Remove-Unused-Dependencies' configured successfully."
else
  echo "Failed to configure unattended 'Remove-Unused-Dependencies'. Manually check /etc/apt/apt.conf.d/50unattended-upgrades."
  exit 1
fi


if sed -i 's|^//\(Unattended-Upgrade::Remove-Unused-Dependencies.*\)$|\1|' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Uncommented 'Remove-Unused-Dependencies' successfully"
else 
  echo "Failed to Uncomment 'Remove-Unused-Dependencies'"
  exit 1
fi

if sed -i 's/#\?\(Unattended-Upgrade::Automatic-Reboot-Time\).*$/\1 "03:15";/' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Unattended 'Automatic-Reboot-Time' configured successfully."
else
  echo "Failed to configure unattended 'Automatic-Reboot-Time'. Manually check /etc/apt/apt.conf.d/50unattended-upgrades."
  exit 1
fi

if sed -i 's|^//\(Unattended-Upgrade::Automatic-Reboot-Time.*\)$|\1|' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Uncommented 'Automatic-Reboot-Time' successfully"
else 
  echo "Failed to Uncomment 'Automatic-Reboot-Time'"
  exit 1
fi

if sed -i 's/#\?\(Unattended-Upgrade::Automatic-Reboot\).*$/\1 "true";/' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Unattended 'Automatic-Reboot' configured successfully."
else
  echo "Failed to configure unattended 'Automatic-Reboot'. Manually check /etc/apt/apt.conf.d/50unattended-upgrades."
  exit 1
fi

if sed -i 's|^//\(Unattended-Upgrade::Automatic-Reboot.*\)$|\1|' /etc/apt/apt.conf.d/50unattended-upgrades; then
  echo "Uncommented 'Automatic-Reboot' successfully"
else 
  echo "Failed to Uncomment 'Automatic-Reboot'"
  exit 1
fi



# Install Glances app for monitoring
echo "Installing Glances..."
if apt-get install -y glances; then
  echo "Glances installed successfully."
else
  echo "Failed to install Glances. Please check your package manager."
  exit 1
fi
# Install and configure Fail2Ban
echo "Installing Fail2Ban..."
if apt-get install -y fail2ban; then
  echo "Fail2Ban installed successfully."
else
  echo "Failed to install Fail2Ban. Please check your package manager."
  exit 1
fi

# Install Filebeat
sudo apt-get update
sudo apt-get install -y filebeat

# Enable and start Filebeat service
sudo systemctl enable filebeat
sudo systemctl start filebeat

echo "Filebeat installation complete."

#Remove unused packages
echo "Removing unused packages..."
if apt-get autoremove -y; then
  echo "Unused packages removed successfully."
else
  echo "Failed to remove unused packages. Please check your package manager."
  exit 1
fi



echo "=== Setup complete ==="
echo ">> You should now manually verify and configure:"
echo "  - Netplan config (/etc/netplan/*.yaml)"
echo "  - SSL certificates if applicable"
echo "  - Disk mounting and formatting if needed"
echo "  - Filebeat setup for graylog.una.ca"
echo ">> Reboot the server to apply all changes."
read -p "Do you want to reboot now? (y/n): " REBOOT_CHOICE
if [[ "$REBOOT_CHOICE" == "y" || "$REBOOT_CHOICE" == "Y" ]]; then
  echo "Rebooting the server..."
  reboot
else
  echo "Reboot skipped. Please remember to reboot later to apply all changes."
fi
# End of script

