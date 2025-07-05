#!/bin/bash
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
