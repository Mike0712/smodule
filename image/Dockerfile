FROM mirror.gcr.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    wget gnupg ca-certificates fonts-noto fonts-noto-cjk \
    x11vnc xvfb openbox \
    ffmpeg pulseaudio dbus-x11 \
    curl jq \
    xdotool \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*
RUN wget -qO - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /opt/wb
COPY package.json ./package.json
RUN npm install --omit=dev
# После базовых RUN:
ENV XDG_RUNTIME_DIR=/tmp/runtime
RUN mkdir -p /tmp/runtime && chmod 700 /tmp/runtime

COPY run.sh ./run.sh
COPY agent.js ./agent.js
RUN chmod +x ./run.sh
EXPOSE 9001
CMD ["/opt/wb/run.sh"]
