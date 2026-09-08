#!/usr/bin/env bash
# lib/gen_manifests.sh
# Génère les manifests Kubernetes (deployments + services + ingress).
#
# Usage : gen_manifests.sh WORK_DIR DOCKERHUB_USER
#
# Variables d'environnement (avec valeurs par défaut) :
#   APP_NAME (tp-app), APP_PORT (80), API_PORT (3000),
#   REPLICAS_API (2), REPLICAS_WEB (2),
#   CPU_LIMIT_API (200m), MEM_LIMIT_API (128Mi),
#   INGRESS_HOST (vide = match par IP),
#   ACME_EMAIL  (vide = pas de TLS ; sinon, génère ClusterIssuer + tls block).

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
DOCKERHUB_USER="${2:?DOCKERHUB_USER required}"

APP_NAME="${APP_NAME:-tp-app}"
APP_PORT="${APP_PORT:-80}"
API_PORT="${API_PORT:-3000}"
REPLICAS_API="${REPLICAS_API:-2}"
REPLICAS_WEB="${REPLICAS_WEB:-2}"
CPU_LIMIT_API="${CPU_LIMIT_API:-200m}"
MEM_LIMIT_API="${MEM_LIMIT_API:-128Mi}"
INGRESS_HOST="${INGRESS_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

# TLS actif uniquement si on a un hostname public ET un email ACME.
TLS_ENABLED=0
[[ -n "$INGRESS_HOST" && -n "$ACME_EMAIL" ]] && TLS_ENABLED=1

API_DEPLOY="${APP_NAME}-api"
WEB_DEPLOY="${APP_NAME}-web"

mkdir -p "$WORK_DIR/k8s/base"

# ----- API deployment + service ---------------------------------------------
cat > "$WORK_DIR/k8s/base/api-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${API_DEPLOY}
  labels:
    app: ${API_DEPLOY}
    tier: backend
spec:
  replicas: ${REPLICAS_API}
  selector:
    matchLabels:
      app: ${API_DEPLOY}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${API_DEPLOY}
        tier: backend
    spec:
      containers:
        - name: api
          image: ${DOCKERHUB_USER}/${APP_NAME}-api:latest
          imagePullPolicy: Always
          ports:
            - containerPort: ${API_PORT}
              name: http
          env:
            - name: PORT
              value: "${API_PORT}"
            - name: APP_VERSION
              value: "1.0.0"
          livenessProbe:
            httpGet:
              path: /health
              port: ${API_PORT}
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health
              port: ${API_PORT}
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "${CPU_LIMIT_API}"
              memory: "${MEM_LIMIT_API}"
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
---
apiVersion: v1
kind: Service
metadata:
  name: ${API_DEPLOY}
  labels:
    app: ${API_DEPLOY}
spec:
  type: ClusterIP
  selector:
    app: ${API_DEPLOY}
  ports:
    - port: 80
      targetPort: ${API_PORT}
      protocol: TCP
      name: http
EOF

# ----- Web deployment + service ---------------------------------------------
cat > "$WORK_DIR/k8s/base/web-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${WEB_DEPLOY}
  labels:
    app: ${WEB_DEPLOY}
    tier: frontend
spec:
  replicas: ${REPLICAS_WEB}
  selector:
    matchLabels:
      app: ${WEB_DEPLOY}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${WEB_DEPLOY}
        tier: frontend
    spec:
      containers:
        - name: web
          image: ${DOCKERHUB_USER}/${APP_NAME}-web:latest
          imagePullPolicy: Always
          ports:
            - containerPort: ${APP_PORT}
              name: http
          livenessProbe:
            httpGet:
              path: /
              port: ${APP_PORT}
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: ${APP_PORT}
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: "20m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: ${WEB_DEPLOY}
  labels:
    app: ${WEB_DEPLOY}
spec:
  type: ClusterIP
  selector:
    app: ${WEB_DEPLOY}
  ports:
    - port: 80
      targetPort: ${APP_PORT}
      protocol: TCP
      name: http
EOF

# ----- Ingress avec middleware stripPrefix sur /api -------------------------
# Annotations supplémentaires en mode TLS :
#   - entrypoints websecure (HTTPS) et redirection HTTP → HTTPS
#   - cert-manager génère un Secret <APP_NAME>-tls signé par Let's Encrypt
INGRESS_ENTRYPOINTS="web"
INGRESS_TLS_BLOCK=""
INGRESS_CERT_ANNOT=""
if (( TLS_ENABLED == 1 )); then
  INGRESS_ENTRYPOINTS="web,websecure"
  INGRESS_CERT_ANNOT=$'\n    cert-manager.io/cluster-issuer: letsencrypt-prod'
  INGRESS_TLS_BLOCK=$(cat <<EOF

  tls:
    - hosts:
        - ${INGRESS_HOST}
      secretName: ${APP_NAME}-tls
EOF
  )
fi

{
  cat <<EOF
---
# Middleware Traefik pour retirer /api avant de forwarder vers l'API
# (sinon Express recevrait /api/health au lieu de /health → 404)
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-prefix
spec:
  stripPrefix:
    prefixes:
      - /api
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${INGRESS_ENTRYPOINTS}
    traefik.ingress.kubernetes.io/router.middlewares: default-strip-api-prefix@kubernetescrd${INGRESS_CERT_ANNOT}
spec:${INGRESS_TLS_BLOCK}
  rules:
EOF

  if [[ -n "$INGRESS_HOST" ]]; then
    cat <<EOF
    - host: ${INGRESS_HOST}
      http:
EOF
  else
    cat <<EOF
    - http:
EOF
  fi

  cat <<EOF
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${API_DEPLOY}
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${WEB_DEPLOY}
                port:
                  number: 80
EOF
} > "$WORK_DIR/k8s/base/ingress.yaml"

# ----- ClusterIssuer Let's Encrypt (seulement si TLS activé) ---------------
if (( TLS_ENABLED == 1 )); then
  cat > "$WORK_DIR/k8s/base/cluster-issuer.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - http01:
          ingress:
            class: traefik
EOF
fi

(( TLS_ENABLED == 1 )) && echo "  - k8s/base/cluster-issuer.yaml (Let's Encrypt — ${ACME_EMAIL})"

echo "  - k8s/base/api-deployment.yaml (${API_DEPLOY}, ${REPLICAS_API} réplicas, ${CPU_LIMIT_API}/${MEM_LIMIT_API})"
echo "  - k8s/base/web-deployment.yaml (${WEB_DEPLOY}, ${REPLICAS_WEB} réplicas)"
echo "  - k8s/base/ingress.yaml (host: ${INGRESS_HOST:-<any>})"
