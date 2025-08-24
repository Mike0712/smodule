# WebRTC WB Suite (full)

- `central/` — mediasoup gateway (HTTPS + WebSocket, RTP ingest API, static client)
- `seller-node/` — Dockerized node with Xvfb + Chrome + FFmpeg + control agent

## Start central
1) Put TLS certs into `central/certs/fullchain.pem` and `central/certs/privkey.pem`.
2) Set `PUBLIC_DOMAIN` and `AGENTS_JSON` in `central/docker-compose.yml`.
3) `docker compose up -d` in `central/`.

## Start seller node
1) Copy `seller-node/.env.example` to `.env` and set `SELLER_CODE` and `CENTRAL_URL`.
2) `docker compose up -d --build` in `seller-node/`.
3) Check logs `/tmp/chrome.log` and `/tmp/ffmpeg.log` inside the container.

## View stream
Open `https://<PUBLIC_DOMAIN>/client.html?seller=sellerA`.
