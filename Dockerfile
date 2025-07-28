
FROM python:3.11-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      libffi-dev \
      libssl-dev \
      iptables \
 && rm -rf /var/lib/apt/lists/*


WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

RUN cat <<'EOF' > /app/colors.json
{
  "colors": [
    "Quantum Red",
    "Nebula Blue",
    "Photon Yellow",
    "Gravity Green",
    "Quasar Violet",
    "Cosmic Orange",
    "Stellar Indigo",
    "Plasma Pink",
    "Celestial Cyan",
    "Aurora Gold",
    "Radiant Teal",
    "Fusion Magenta",
    "Electron Lime",
    "Aurora Borealis",
    "Solar Turquoise",
    "Galaxy Crimson",
    "Comet Amber",
    "Ionized Chartreuse",
    "Gravity Purple",
    "Supernova Scarlet",
    "Lunar Lavender",
    "Solar Flare",
    "Quantum Azure",
    "Nova Coral",
    "Eclipse Ebony"
  ]
}
EOF

COPY . .

RUN cat <<'EOF' > /app/setup_firewall.sh

set -euo pipefail

iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

for ip in \$(getent ahostsv4 api.openai.com | awk '{print \$1}' | sort -u); do
  iptables -A OUTPUT -d "\$ip" -j ACCEPT
done

iptables -A OUTPUT -j REJECT
EOF
RUN chmod +x /app/setup_firewall.sh

ENTRYPOINT [ "bash", "-lc", "/app/setup_firewall.sh && exec python /app/main.py" ]
