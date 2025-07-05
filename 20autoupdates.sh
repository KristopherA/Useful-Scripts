# Configure APT auto-upgrades
if sed -i 's/#\?\(APT::Periodic::Update-Package-Lists\).*$/\1 "1";/' /etc/apt/apt.conf.d/20auto-upgrades; then
  echo "APT 'Update-Package-Lists' in 20auto-upgrades configured successfully."
else
  echo "Failed to configure APT 'Update-Package-Lists'. Manually check /etc/apt/apt.conf.d/20auto-upgrades."
  exit 1
fi

if sed -i 's|^//\(APT::Periodic::Update-Package-Lists\)$|\1|' etc/apt/apt.conf.d/20auto-upgrades; then
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