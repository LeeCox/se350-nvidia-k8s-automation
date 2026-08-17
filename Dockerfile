FROM alpine:3.22 AS mcp

ARG KUBERNETES_MCP_VERSION=v0.0.66
ARG KUBERNETES_MCP_SHA256=692a7b283a96140311fd46f13b8373657b2e9bfe660a36bb6434e8c42d899dbc
RUN apk add --no-cache ca-certificates curl \
    && curl -fsSL "https://github.com/containers/kubernetes-mcp-server/releases/download/${KUBERNETES_MCP_VERSION}/kubernetes-mcp-server-linux-amd64" \
      -o /kubernetes-mcp-server \
    && echo "${KUBERNETES_MCP_SHA256}  /kubernetes-mcp-server" | sha256sum -c - \
    && chmod 0555 /kubernetes-mcp-server

FROM node:22.18.0-alpine3.22

ENV NODE_ENV=production \
    HOME=/tmp
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts \
    && npm cache clean --force

COPY --from=mcp /kubernetes-mcp-server /usr/local/bin/kubernetes-mcp-server
COPY web-chat-server.mjs ./
COPY public ./public

USER 1000:1000
EXPOSE 3000
CMD ["node", "web-chat-server.mjs"]
