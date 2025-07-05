#!/bin/bash

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

