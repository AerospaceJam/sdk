#!/bin/bash

set -e

# --- Configuration ---
DEFAULT_USER="pi"
SDK_USERNAME="asj"
SDK_PASSWORD="aerospacejam"
DEFAULT_HOTSPOT_SSID="AerospaceJam-CHANGEME"
HOTSPOT_PASSWORD="aerospacejam"
ENCRYPTED_PASSWORD="$1"

export DEBIAN_FRONTEND=noninteractive

echo "--- Configuring user: Renaming '${DEFAULT_USER}' to '${SDK_USERNAME}' ---"

echo "${DEFAULT_USER}:${ENCRYPTED_PASSWORD}" | chpasswd -e

usermod -l "${SDK_USERNAME}" "${DEFAULT_USER}"
usermod -m -d "/home/${SDK_USERNAME}" "${SDK_USERNAME}"
groupmod -n "${SDK_USERNAME}" "${DEFAULT_USER}"

echo "--- Granting passwordless sudo to ${SDK_USERNAME} ---"
sed -i "s/^${DEFAULT_USER} ALL=(ALL) NOPASSWD: ALL/${SDK_USERNAME} ALL=(ALL) NOPASSWD: ALL/" /etc/sudoers.d/010_pi-nopasswd

echo "--- Configuring automatic login for user ${SDK_USERNAME} ---"

if grep -q "^autologin-user=" /etc/lightdm/lightdm.conf ; then
    sed /etc/lightdm/lightdm.conf -i -e "s/^autologin-user=.*/autologin-user=${SDK_USERNAME}/"
fi

LIGHTDM_CONFIG_DIR="/etc/lightdm/lightdm.conf.d"
mkdir -p "${LIGHTDM_CONFIG_DIR}"
cat << EOF > "${LIGHTDM_CONFIG_DIR}/99-autologin.conf"
[Seat:*]
autologin-user=${SDK_USERNAME}
autologin-user-timeout=0
EOF

GETTY_CONFIG_DIR="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "${GETTY_CONFIG_DIR}"
cat << EOF > "${GETTY_CONFIG_DIR}/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${SDK_USERNAME} --noclear %I \$TERM
EOF

echo "Purging stuff and removing wizard..."
apt-get update
apt-get purge -y piwiz chromium
apt-get autoremove -y
rm -f /etc/xdg/autostart/piwiz.desktop

echo "Enabling ssh..."
systemctl enable ssh

echo "Setting up hotspot stuff..."
apt-get install -y network-manager libnotify-bin zenity
CONNECTION_FILE="/etc/NetworkManager/system-connections/CompetitionHotspot.nmconnection"
CONNECTION_ID="CompetitionHotspot"
UUID=$(cat /proc/sys/kernel/random/uuid)
cat << EOF > "${CONNECTION_FILE}"
[connection]
id=${CONNECTION_ID}
uuid=${UUID}
type=wifi
interface-name=wlan0
autoconnect=true
[wifi]
mode=ap
ssid=${DEFAULT_HOTSPOT_SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${HOTSPOT_PASSWORD}
[ipv4]
method=shared
[ipv6]
method=ignore
EOF
chmod 600 "${CONNECTION_FILE}"
mkdir -p /var/lib/NetworkManager/
cat << EOF > /var/lib/NetworkManager/NetworkManager.state
[main]
NetworkingEnabled=true
WirelessEnabled=true
WWANEnabled=true
EOF
chmod 644 /var/lib/NetworkManager/NetworkManager.state
echo 'net.ipv4.ip_unprivileged_port_start=0' > /etc/sysctl.d/50-unprivileged-ports.conf

echo "Setting timezone to America/Chicago..."
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime

echo "Setting locale to 'en_US.UTF-8'..."
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
echo "Setting hostname..."
echo "aerospacejam" > /etc/hostname
sed -i 's/raspberrypi/aerospacejam/' /etc/hosts

echo "Doing big package operations... This will take a bit."
apt-get install -y gh dunst attr git build-essential firefox \
    python3-dev mypy python3-mypy python3-flask python3-flask-socketio \
    python3-picamera2 python3-smbus python3-rpi.gpio minicom
 
pip3 install mpu6050-raspberrypi git+https://github.com/AerospaceJam/bmp180.git git+https://github.com/AerospaceJam/tfluna.git --break-system-packages

echo "Installing uv for user ${SDK_USERNAME}..."
sudo -H -u "${SDK_USERNAME}" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

echo "--- Creating desktop icons and helper scripts ---"
DESKTOP_DIR="/home/${SDK_USERNAME}/Desktop"
mkdir -p "${DESKTOP_DIR}"

cat << 'EOF' > /usr/local/bin/dev-mode
#!/bin/bash
systemctl stop teamcode.service
# Specifically disable autoconnect for the hotspot connection profile
nmcli con modify "CompetitionHotspot" connection.autoconnect no
nmcli con down "CompetitionHotspot"
# Allow the wlan0 hardware to connect to any other known Wi-Fi network
nmcli device set wlan0 autoconnect yes
sleep 1
notify-send "Development Mode" "Standard Wi-Fi enabled. Will now connect to known networks." -i network-wireless
EOF

cat << 'EOF' > /usr/local/bin/comp-mode
#!/bin/bash
SSID=$(nmcli -t -f 802-11-wireless.ssid con show CompetitionHotspot | sed 's/.*://')
# Prevent the wlan0 hardware from connecting to anything on its own
nmcli device set wlan0 autoconnect no
# Specifically enable autoconnect for the hotspot, ensuring it starts on boot
nmcli con modify "CompetitionHotspot" connection.autoconnect yes
# Bring up the hotspot now
nmcli con up "CompetitionHotspot"
notify-send "Competition Mode" "Starting team code..." -i network-wireless-hotspot
sleep 2
systemctl start teamcode.service
notify-send "Competition Mode" "Hotspot '${SSID}' is now ACTIVE." -i network-wireless-hotspot
EOF

cat << 'EOF' > /usr/local/bin/comp-mode-nonotify
#!/bin/bash
# Prevent the wlan0 hardware from connecting to anything on its own
nmcli device set wlan0 autoconnect no
# Specifically enable autoconnect for the hotspot, ensuring it starts on boot
nmcli con modify "CompetitionHotspot" connection.autoconnect yes
# Bring up the hotspot now
nmcli con up "CompetitionHotspot"
systemctl start teamcode.service
EOF

cat << 'EOF' > /usr/local/bin/change-hotspot-name
#!/bin/bash
notify-send "Change Hotspot Name" "Loading..." -i network-wireless
CURRENT_SSID=$(nmcli -t -f 802-11-wireless.ssid con show CompetitionHotspot | sed 's/.*://')
NEW_SSID=$(zenity --entry --title="Change Hotspot Name" --text="Enter a new, unique name for your drone's hotspot:" --entry-text="${CURRENT_SSID}")
if [ $? -ne 0 ]; then notify-send "Cancelled" "Hotspot name was not changed." -i dialog-cancel; exit 0; fi
if [ -z "${NEW_SSID}" ]; then zenity --error --text="The hotspot name cannot be empty."; exit 1; fi
nmcli con modify "CompetitionHotspot" 802-11-wireless.ssid "${NEW_SSID}"
notify-send "Success!" "Hotspot name changed to '${NEW_SSID}'.\nRe-enabling competition mode to apply changes." -i dialog-ok
nmcli con down "CompetitionHotspot"; sleep 1; nmcli con up "CompetitionHotspot"
EOF

chmod +x /usr/local/bin/dev-mode /usr/local/bin/comp-mode /usr/local/bin/comp-mode-nonotify /usr/local/bin/change-hotspot-name

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

cat << EOF > "${DESKTOP_DIR}/firefox.desktop"
[Desktop Entry]
Type=Link
Name=Firefox
Icon=firefox
URL=/usr/share/applications/firefox.desktop
EOF

cat << EOF > "${DESKTOP_DIR}/thonny.desktop"
[Desktop Entry]
Type=Link
Name=Thonny
Icon=thonny
URL=/usr/share/applications/org.thonny.Thonny.desktop
EOF

cat << EOF > "${DESKTOP_DIR}/Aerospace Jam Docs.desktop"
[Desktop Entry]
Version=1.0
Type=Link
Name=Aerospace Jam Docs
Comment=Open the official documentation website
URL=https://docs.aerospacejam.org/
Icon=help-contents
EOF

cat << EOF > /etc/systemd/system/comp-mode.service
[Unit]
Description=Enable Competition Mode
After=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/comp-mode-nonotify

[Install]
WantedBy=graphical.target
EOF

cat << EOF > /etc/systemd/system/teamcode.service
[Unit]
Description=Aerospace Jam Team Code Service

[Service]
Type=simple
User=${SDK_USERNAME}
WorkingDirectory=/home/${SDK_USERNAME}/teamCode
ExecStart=/usr/bin/python3 /home/${SDK_USERNAME}/teamCode/main.py
Restart=on-failure
EOF

chmod 644 /etc/systemd/system/comp-mode.service /etc/systemd/system/teamcode.service
systemctl enable comp-mode.service

echo "--- Making desktop icons executable and trusted ---"
chmod +x "${DESKTOP_DIR}"/*.desktop
for f in "${DESKTOP_DIR}"/*.desktop; do
    setfattr -n trusted.glib -v y "$f"
done

echo "Setting wallpaper..."
CONFIG_FILE="/etc/xdg/pcmanfm/LXDE-pi/desktop-items-0.conf"
NEW_WALLPAPER="/usr/share/rpd-wallpaper/asj.jpeg"
sed -i "s#^wallpaper=.*#wallpaper=${NEW_WALLPAPER}#" "${CONFIG_FILE}"

echo "Setting final permissions and cleaning up..."
chown -R "${SDK_USERNAME}:${SDK_USERNAME}" "/home/${SDK_USERNAME}"
apt-get autoremove -y
apt-get clean

/usr/lib/raspberrypi-sys-mods/imager_custom set_hostname aerospacejam || true
/usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh || true
