#!/usr/bin/env bash
# lib/gen_microservices.sh
# Génère les microservices API (Express) et Web (nginx) avec leurs Dockerfiles.
#
# Usage : gen_microservices.sh WORK_DIR APP_AUTHOR
#
# Variables d'environnement (avec valeurs par défaut) :
#   APP_NAME (tp-app), APP_PORT (80), API_PORT (3000)

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
APP_AUTHOR="${2:?APP_AUTHOR required}"

APP_NAME="${APP_NAME:-tp-app}"
APP_PORT="${APP_PORT:-80}"
API_PORT="${API_PORT:-3000}"

mkdir -p "$WORK_DIR/microservices/api"
mkdir -p "$WORK_DIR/microservices/web"

# ----- API Express ----------------------------------------------------------
cat > "$WORK_DIR/microservices/api/package.json" <<EOF
{
  "name": "${APP_NAME}-api",
  "version": "1.0.0",
  "description": "API microservice — TP DevSecOps",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "author": "${APP_AUTHOR}",
  "license": "MIT",
  "dependencies": {
    "express": "^4.19.2"
  }
}
EOF

cat > "$WORK_DIR/microservices/api/server.js" <<EOF
const express = require('express');
const app = express();
const PORT = process.env.PORT || ${API_PORT};

const APP_NAME = '${APP_NAME}-api';
const APP_AUTHOR = '${APP_AUTHOR}';
const APP_VERSION = process.env.APP_VERSION || '1.0.0';
const DEPLOYED_AT = new Date().toISOString();

app.use(express.json());

app.get('/', (req, res) => {
  res.json({
    message: 'Hello from ' + APP_NAME,
    version: APP_VERSION
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptime_seconds: Math.floor(process.uptime())
  });
});

app.get('/info', (req, res) => {
  res.json({
    name: APP_NAME,
    author: APP_AUTHOR,
    version: APP_VERSION,
    deployed_at: DEPLOYED_AT
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(\`[\${APP_NAME}] listening on \${PORT} — version \${APP_VERSION}\`);
});
EOF

cat > "$WORK_DIR/microservices/api/Dockerfile" <<EOF
# Image minimale Alpine pour réduire la surface d'attaque
FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

COPY server.js ./

EXPOSE ${API_PORT}

USER node

CMD ["node", "server.js"]
EOF

cat > "$WORK_DIR/microservices/api/.dockerignore" <<'EOF'
node_modules
npm-debug.log
.git
.env
README.md
EOF

# ----- Web (nginx + HTML statique) ------------------------------------------
# Configuration nginx si APP_PORT != 80
if [[ "$APP_PORT" != "80" ]]; then
  cat > "$WORK_DIR/microservices/web/nginx.conf" <<EOF
server {
    listen       ${APP_PORT};
    server_name  _;
    root         /usr/share/nginx/html;
    index        index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
fi

cat > "$WORK_DIR/microservices/web/index.html" <<EOF
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>TP DevSecOps — ${APP_AUTHOR}</title>
  <style>
    :root {
      --navy: #1E2761;
      --coral: #F96167;
      --ice: #CADCFC;
      --bg: #F2F5FB;
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: var(--bg);
      color: #1a1a1a;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
    }
    .card {
      background: white;
      border-radius: 16px;
      padding: 3rem;
      max-width: 720px;
      width: 100%;
      box-shadow: 0 20px 60px rgba(30,39,97,0.12);
      border-left: 6px solid var(--coral);
    }
    h1 {
      font-family: Georgia, serif;
      color: var(--navy);
      font-size: 2.5rem;
      margin-bottom: 0.5rem;
    }
    .tagline {
      color: var(--coral);
      font-style: italic;
      margin-bottom: 2rem;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 1rem;
      margin-top: 2rem;
    }
    .stat {
      background: var(--bg);
      padding: 1rem;
      border-radius: 8px;
      border-top: 3px solid var(--navy);
    }
    .stat strong {
      display: block;
      font-size: 0.75rem;
      color: var(--navy);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 0.3rem;
    }
    .stat span {
      font-family: 'SF Mono', Consolas, monospace;
      color: #555;
      font-size: 0.95rem;
    }
    .api-status {
      margin-top: 2rem;
      padding: 1rem;
      background: var(--bg);
      border-radius: 8px;
      font-family: 'SF Mono', Consolas, monospace;
      font-size: 0.9rem;
    }
    .badge {
      display: inline-block;
      padding: 0.2rem 0.6rem;
      border-radius: 999px;
      font-size: 0.75rem;
      font-weight: 700;
      margin-left: 0.5rem;
    }
    .badge.ok { background: #d4f5e0; color: #2c8b5a; }
    .badge.ko { background: #ffe0e2; color: #c44; }
  </style>
</head>
<body>
  <div class="card">
    <h1>TP DevSecOps</h1>
    <p class="tagline">— déployé via Skills Claude Code —</p>

    <p>Chaîne automatisée pilotée en langage naturel par un agent IA. Cette page est servie par nginx dans un pod Kubernetes, derrière un ingress Traefik.</p>

    <div class="grid">
      <div class="stat"><strong>Auteur</strong><span>${APP_AUTHOR}</span></div>
      <div class="stat"><strong>App</strong><span>${APP_NAME}</span></div>
      <div class="stat"><strong>Frontend</strong><span>nginx:alpine</span></div>
      <div class="stat"><strong>Backend</strong><span>node:20-alpine</span></div>
    </div>

    <div class="api-status">
      <strong>API :</strong> <span id="api-state">vérification…</span>
      <span id="api-badge" class="badge">…</span>
      <br>
      <pre id="api-response" style="margin-top:0.5rem;font-size:0.8rem;color:#888;"></pre>
    </div>
  </div>

  <script>
    fetch('/api/health')
      .then(r => r.json().then(d => ({ ok: r.ok, data: d })))
      .then(({ ok, data }) => {
        document.getElementById('api-state').textContent = ok ? 'opérationnelle' : 'erreur';
        const badge = document.getElementById('api-badge');
        badge.textContent = ok ? '✓ OK' : '✗ KO';
        badge.className = 'badge ' + (ok ? 'ok' : 'ko');
        document.getElementById('api-response').textContent = JSON.stringify(data, null, 2);
      })
      .catch(e => {
        document.getElementById('api-state').textContent = 'inaccessible';
        document.getElementById('api-badge').textContent = '✗ KO';
        document.getElementById('api-badge').className = 'badge ko';
      });
  </script>
</body>
</html>
EOF

if [[ "$APP_PORT" != "80" ]]; then
  cat > "$WORK_DIR/microservices/web/Dockerfile" <<EOF
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE ${APP_PORT}
EOF
else
  cat > "$WORK_DIR/microservices/web/Dockerfile" <<EOF
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE ${APP_PORT}
EOF
fi

# ----- README à la racine ----------------------------------------------------
cat > "$WORK_DIR/README.md" <<EOF
# ${APP_NAME} — chaîne IA-pilotée

> Application microservices déployée sur Kubernetes (k3s), pipeline CI/CD GitHub Actions, pilotée en langage naturel via 4 Skills Claude Code custom.

## Quickstart

\`\`\`bash
git clone https://github.com/${APP_AUTHOR}/${APP_NAME}
cd ${APP_NAME}

claude
> "Ajoute une route /stats dans l'API, déploie, vérifie la santé"
\`\`\`

## Structure

\`\`\`
.
├── microservices/
│   ├── api/         # Express.js — port ${API_PORT} — endpoints /, /health, /info
│   └── web/         # nginx + HTML statique — port ${APP_PORT}
├── k8s/base/        # Manifests Kubernetes (deployments + ingress)
├── .github/workflows/
│   └── deploy.yml   # Pipeline CI/CD : build → push → deploy
└── .agents/skills/  # 4 Skills Claude Code custom
\`\`\`

## Endpoints

| URL | Description |
|---|---|
| \`/\` | Frontend (nginx) |
| \`/api/\` | API racine |
| \`/api/health\` | Health-check |
| \`/api/info\` | Métadonnées du déploiement |

## Auteur

${APP_AUTHOR}
EOF

echo "  - microservices/api/{package.json, server.js, Dockerfile} (port ${API_PORT})"
echo "  - microservices/web/{index.html, Dockerfile} (port ${APP_PORT})"
echo "  - README.md"
