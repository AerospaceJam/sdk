#!/bin/bash

set -e

SDK_USERNAME="asj"
DEFAULT_HOTSPOT_SSID="AerospaceJam-CHANGEME"
HOTSPOT_PASSWORD="aerospacejam"

export DEBIAN_FRONTEND=noninteractive

echo "Purging stuff..."
apt-get update
apt-get remove -y thonny chromium
apt-get purge -y piwiz
apt-get autoremove -y

echo "Enabling ssh..."
systemctl enable ssh

echo "Setting up hotspot stuff..."
apt-get install -y network-manager libnotify-bin zenity
nmcli con add type wifi ifname wlan0 con-name "CompetitionHotspot" autoconnect yes ssid "${DEFAULT_HOTSPOT_SSID}"
nmcli con modify "CompetitionHotspot" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
nmcli con modify "CompetitionHotspot" wifi-sec.key-mgmt wpa-psk
nmcli con modify "CompetitionHotspot" wifi-sec.psk "${HOTSPOT_PASSWORD}"

echo "Setting timezone to America/Chicago..."
timedatectl set-timezone "America/Chicago"
echo "Setting keyboard layout to 'us'..."
raspi-config nonint do_configure_keyboard "us"
echo "Setting locale to 'en_US.UTF-8'..."
raspi-config nonint do_change_locale "en_US.UTF-8"

echo "Setting hostname..."
echo "aerospacejam" > /etc/hostname
sed -i 's/raspberrypi/aerospacejam/' /etc/hosts

echo "Doing big package operations... This will take a bit."
apt-get install -y git build-essential code firefox \
    python3-dev mypy python3-mypy python3-flask \
    python3-picamera2 python3-smbus python3-rpi.gpio
 
# TODO: can we find a way to package this without --break-system-packages?
pip3 install mpu6050-raspberrypi git+https://github.com/AerospaceJam/bmp180.git --break-system-packages

echo "Installing uv..."
su pi -c "curl -LsSf https://astral.sh/uv/install.sh | sh"

echo "--- Creating desktop icons ---"
DESKTOP_DIR="/home/${SDK_USERNAME}/Desktop"
mkdir -p "${DESKTOP_DIR}"

cat << 'EOF' > /usr/local/bin/dev-mode
#!/bin/bash
# Disables the hotspot and allows normal Wi-Fi connections.
nmcli con down "CompetitionHotspot"
nmcli device set wlan0 autoconnect yes
# A small delay to allow the service to fully switch over
sleep 2
notify-send "Development Mode" "Standard Wi-Fi is now enabled. Use the network icon to connect." -i network-wireless
EOF

# Script for Competition Mode
cat << 'EOF' > /usr/local/bin/comp-mode
#!/bin/bash
# Enables the hotspot for competition.
SSID=$(nmcli -t -f 802-11-wireless.ssid con show CompetitionHotspot | sed 's/.*://')
nmcli device set wlan0 autoconnect no
nmcli con up "CompetitionHotspot"
sleep 2
notify-send "Competition Mode" "Hotspot '${SSID}' is now ACTIVE." -i network-wireless-hotspot
EOF

# Script to Change Hotspot Name
cat << 'EOF' > /usr/local/bin/change-hotspot-name
#!/bin/bash
# Uses Zenity to get a new hotspot name from the user.

CURRENT_SSID=$(nmcli -t -f 802-11-wireless.ssid con show CompetitionHotspot | sed 's/.*://')

NEW_SSID=$(zenity --entry \
    --title="Change Hotspot Name" \
    --text="Enter a new, unique name for your robot's hotspot:" \
    --entry-text="${CURRENT_SSID}")

# Exit if the user pressed Cancel or closed the dialog
if [ $? -ne 0 ]; then
    notify-send "Cancelled" "Hotspot name was not changed." -i dialog-cancel
    exit 0
fi

# Exit if the user entered an empty name
if [ -z "${NEW_SSID}" ]; then
    zenity --error --text="The hotspot name cannot be empty."
    exit 1
fi

# Apply the new name to the NetworkManager profile
nmcli con modify "CompetitionHotspot" 802-11-wireless.ssid "${NEW_SSID}"

notify-send "Success!" "Hotspot name changed to '${NEW_SSID}'.\nRe-enabling competition mode to apply changes." -i dialog-ok

# Restart the connection to broadcast the new name immediately
nmcli con down "CompetitionHotspot"
sleep 1
nmcli con up "CompetitionHotspot"
EOF

chmod +x /usr/local/bin/dev-mode
chmod +x /usr/local/bin/comp-mode
chmod +x /usr/local/bin/change-hotspot-name

echo "Creating desktop icons..."
DESKTOP_DIR="/home/${SDK_USERNAME}/Desktop"
mkdir -p "${DESKTOP_DIR}"

cat << EOF > "${DESKTOP_DIR}/Development Mode.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Development Mode
Comment=Enable Standard Wi-Fi for internet access
Exec=/usr/local/bin/dev-mode
Icon=network-wireless
Terminal=false
Categories=Utility;
EOF

cat << EOF > "${DESKTOP_DIR}/Competition Mode.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Competition Mode
Comment=Enable the local hotspot for robot control
Exec=/usr/local/bin/comp-mode
Icon=network-wireless-hotspot
Terminal=false
Categories=Utility;
EOF

cat << EOF > "${DESKTOP_DIR}/Change Hotspot Name.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Change Hotspot Name
Comment=Set a unique name for your hotspot
Exec=/usr/local/bin/change-hotspot-name
Icon=preferences-system-network
Terminal=false
Categories=Utility;
EOF

echo "Cleaning up..."
chown -R "${SDK_USERNAME}:${SDK_USERNAME}" "/home/${SDK_USERNAME}"
apt-get autoremove -y
apt-get clean