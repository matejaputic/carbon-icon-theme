# Dockerfile for agent-browser
# Exposes headless browser automation for AI agents via CDP and WebSocket streaming
# Designed to run in Kubernetes alongside Claude Code containers

FROM node:22-bookworm-slim

# Install system dependencies for Chromium/Playwright
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Playwright/Chromium dependencies
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    # Additional utilities
    git \
    ca-certificates \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm and set up PNPM_HOME
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@9 --activate

# Set working directory
WORKDIR /app

# Clone agent-browser repository
RUN git clone --depth 1 https://github.com/vercel-labs/agent-browser.git .

# Install Node.js dependencies
RUN pnpm install --frozen-lockfile

# Build TypeScript
RUN pnpm build

# Install Playwright Chromium (with deps already installed above)
RUN pnpm exec playwright install chromium

# Add app bin directory to PATH so agent-browser CLI is accessible
ENV PATH="/app/bin:$PATH"

# Create a non-root user for security
RUN groupadd -r agentbrowser && useradd -r -g agentbrowser -G audio,video agentbrowser \
    && mkdir -p /home/agentbrowser \
    && chown -R agentbrowser:agentbrowser /home/agentbrowser /app

# Set Playwright browser path for the user
ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright

# Environment variables for configuration
# CDP port for Chrome DevTools Protocol connections
ENV CDP_PORT=9222
# WebSocket streaming port for live browser preview
ENV AGENT_BROWSER_STREAM_PORT=9223
# Run in headless mode
ENV HEADLESS=true

# Expose ports:
# 9222 - Chrome DevTools Protocol (CDP) for browser control
# 9223 - WebSocket streaming for live browser preview
EXPOSE 9222 9223

# Create entrypoint script
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

# Start Chromium with remote debugging enabled
# This allows Claude Code (in another container) to connect via CDP
echo "Starting Chromium with remote debugging on port ${CDP_PORT}..."

# Get Chromium executable path from Playwright
CHROMIUM_PATH=$(pnpm exec playwright install chromium --dry-run 2>/dev/null | grep -o '/.*chromium-[0-9]*/chrome-linux/chrome' || echo "")

if [ -z "$CHROMIUM_PATH" ]; then
    # Fallback: find chromium in Playwright cache
    CHROMIUM_PATH=$(find /root/.cache/ms-playwright -name "chrome" -type f -executable 2>/dev/null | head -1)
fi

if [ -z "$CHROMIUM_PATH" ]; then
    echo "Error: Could not find Chromium executable"
    exit 1
fi

echo "Found Chromium at: $CHROMIUM_PATH"

# Start Chromium in background with remote debugging
"$CHROMIUM_PATH" \
    --headless=new \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-software-rasterizer \
    --no-sandbox \
    --remote-debugging-address=0.0.0.0 \
    --remote-debugging-port=${CDP_PORT} \
    --window-size=1280,720 \
    &

CHROMIUM_PID=$!
echo "Chromium started with PID $CHROMIUM_PID"

# Wait for CDP to be available
echo "Waiting for CDP endpoint..."
for i in {1..30}; do
    if curl -s "http://localhost:${CDP_PORT}/json/version" > /dev/null 2>&1; then
        echo "CDP endpoint ready at port ${CDP_PORT}"
        break
    fi
    sleep 1
done

# Keep container running and handle signals
trap "kill $CHROMIUM_PID 2>/dev/null" EXIT SIGTERM SIGINT

echo ""
echo "============================================"
echo "agent-browser is ready!"
echo ""
echo "From Claude Code (same pod), connect using:"
echo "  agent-browser connect ${CDP_PORT}"
echo ""
echo "Or use CDP directly at:"
echo "  ws://localhost:${CDP_PORT}"
echo ""
echo "WebSocket streaming available at:"
echo "  ws://localhost:${AGENT_BROWSER_STREAM_PORT}"
echo "============================================"
echo ""

# Wait for Chromium process
wait $CHROMIUM_PID
EOF

RUN chmod +x /entrypoint.sh

# Install curl for health checks
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${CDP_PORT}/json/version || exit 1

ENTRYPOINT ["/entrypoint.sh"]
