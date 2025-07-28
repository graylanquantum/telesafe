FROM python:3.11-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      libffi-dev \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# embed your colors.json as before
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

# Remove setup_firewall.sh entirely since it only contained iptables logic
ENTRYPOINT ["python", "/app/main.py"]
