#!/bin/bash

#Install Filebeat for graylog.una.ca
# This script installs Filebeat on a Debian/Ubuntu system

# Download and install the Elastic GPG key
sudo apt-get update
sudo apt-get install -y wget apt-transport-https
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -

# Add the Elastic repository
echo "deb https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee -a /etc/apt/sources.list.d/elastic-8.x.list

# Install Filebeat
sudo apt-get update
sudo apt-get install -y filebeat

# Enable and start Filebeat service
sudo systemctl enable filebeat
sudo systemctl start filebeat

echo "Filebeat installation complete."

