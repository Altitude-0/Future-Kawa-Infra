locals {
  kubeconfig_path = "/etc/rancher/k3s/k3s.yaml"
}

resource "null_resource" "install_k3s" {
  triggers = {
    k3s_version = var.k3s_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      if command -v k3s >/dev/null 2>&1; then
        echo "k3s is already installed."
        exit 0
      fi

      if [[ -n "${var.k3s_version}" ]]; then
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${var.k3s_version}' sh -
      else
        curl -sfL https://get.k3s.io | sh -
      fi

      chmod 644 ${local.kubeconfig_path}
    EOT
  }
}

resource "null_resource" "deploy_namespaces_and_apps" {
  depends_on = [null_resource.install_k3s]

  triggers = {
    environment       = var.environment
    central_api_image = var.central_api_image
    country_api_image = var.country_api_image
    frontend_image    = var.frontend_image
    kafka_image       = var.kafka_image
    kafka_ui_image    = var.kafka_ui_image
    postgres_image    = var.postgres_image
    container_port    = tostring(var.container_port)
    replicas          = var.environment == "staging" ? tostring(var.staging_replicas) : tostring(var.production_replicas)
    github_username   = var.github_username
    github_token      = var.github_token != "" ? "present" : "absent"
    manifest_version  = "20" # Fixed imagePullSecrets for regional APIs
    vault_ingress_hash = filemd5("${path.module}/vault-ingress.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      export KUBECONFIG=${local.kubeconfig_path}

      # Wait for k3s API and first node readiness before deploying workloads.
      kubectl wait --for=condition=Ready node --all --timeout=180s
      # ==============================================================================
      # 0. VAULT & EXTERNAL SECRETS OPERATOR (ESO) BRIDGE
      # Sets up the connection between Vault and Kubernetes for secret management.
      # ==============================================================================
      echo "Applying Vault ClusterSecretStore..."
      cat <<YAML | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: external-secrets
          key: token
YAML
echo "Applying external Vault Ingress manifest..."
      kubectl apply -f ${path.module}/vault-ingress.yaml

      # Set replicas based on environment
      REPLICAS=${var.environment == "staging" ? var.staging_replicas : var.production_replicas}

      create_ghcr_secret() {
        local ns=$1
        echo "Creating ExternalSecret for ghcr-auth in $ns..."
        cat <<YAML | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ghcr-auth
  namespace: $ns
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: ghcr-auth
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "https://ghcr.io": {
                "username": "{{ .username }}",
                "password": "{{ .token }}",
                "auth": "{{ printf \`%s:%s\` .username .token | b64enc }}"
              }
            }
          }
  data:
  - secretKey: username
    remoteRef:
      key: ghcr-credentials
      property: username
  - secretKey: token
    remoteRef:
      key: ghcr-credentials
      property: token
YAML
      }

      # ==============================================================================
      # 1. CENTRAL APPLICATION SERVICES
      # Deploys the main API, PostgreSQL database, and Frontend in a shared namespace.
      # ==============================================================================
      MAIN_NS="${var.environment}-application"
      kubectl create namespace $MAIN_NS --dry-run=client -o yaml | kubectl apply -f -
      create_ghcr_secret $MAIN_NS

      # --- Central API Deployment ---
      cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: $MAIN_NS
  labels:
    app: api
    role: main
    environment: "${var.environment}"
  annotations:
    keel.sh/policy: "regex"
    keel.sh/match: "^[0-9]{8}-[0-9]+$$"
    keel.sh/trigger: "poll"
    keel.sh/pollSchedule: "@every 1m"
spec:
  replicas: $REPLICAS
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: api
      role: main
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: api
        role: main
        environment: "${var.environment}"
    spec:
      imagePullSecrets:
        - name: ghcr-auth
      containers:
        - name: api
          image: "${var.central_api_image}"
          ports:
            - containerPort: ${var.container_port}
          env:
            - name: DB_TYPE
              value: "postgres"
            - name: DB_HOST
              value: "postgres"
            - name: DB_PORT
              value: "5432"
            - name: DB_USERNAME
              value: "postgres"
            - name: DB_PASSWORD
              value: "password"
            - name: DB_DATABASE
              value: "sales_analysis"
          readinessProbe:
            httpGet:
              path: /health/readiness
              port: ${var.container_port}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health/liveness
              port: ${var.container_port}
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: $MAIN_NS
spec:
  type: NodePort
  selector:
    app: api
    role: main
    environment: "${var.environment}"
  ports:
    - port: 80
      targetPort: ${var.container_port}
      nodePort: 31081
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  namespace: $MAIN_NS
spec:
  rules:
  - host: "api.karim-portfolio.xyz"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 80
---
# --- Central Postgres Database ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $MAIN_NS
  labels:
    app: postgres
    role: main
    environment: "${var.environment}"
spec:
  replicas: 1 # Central DB is fixed at 1 replica as per requirement
  selector:
    matchLabels:
      app: postgres
      role: main
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: postgres
        role: main
        environment: "${var.environment}"
    spec:
      containers:
        - name: postgres
          image: "${var.postgres_image}"
          env:
            - name: POSTGRES_DB
              value: "sales_analysis"
            - name: POSTGRES_PASSWORD
              value: "password"
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $MAIN_NS
spec:
  type: NodePort
  selector:
    app: postgres
    role: main
    environment: "${var.environment}"
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: 31432
---
# --- Central Frontend Application ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: $MAIN_NS
  labels:
    app: frontend
    role: main
    environment: "${var.environment}"
  annotations:
    keel.sh/policy: "regex"
    keel.sh/match: "^[0-9]{8}-[0-9]+$$"
    keel.sh/trigger: "poll"
    keel.sh/pollSchedule: "@every 1m"
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: frontend
      role: main
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: frontend
        role: main
        environment: "${var.environment}"
    spec:
      containers:
        - name: frontend
          image: "${var.frontend_image}"
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: $MAIN_NS
spec:
  type: NodePort
  selector:
    app: frontend
    role: main
    environment: "${var.environment}"
  ports:
    - port: 80
      targetPort: 80
      nodePort: 31080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frontend
  namespace: $MAIN_NS
spec:
  rules:
  - host: "frontend.karim-portfolio.xyz"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
YAML

      # 2. Create Country-specific Namespaces and Resources
      for country in brazil ecuador colombia; do
        NS="${var.environment}-$country"
        kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -
        create_ghcr_secret $NS

        # Set unique NodePort and Hostname for Kafka UI and Kafka Broker per country
        case $country in
          brazil)
            UI_PORT=30001
            KAFKA_PORT=30092
            API_PORT=30081
            DB_PORT=30432
            UI_HOST="kafka-brazil.karim-portfolio.xyz"
            API_HOST="api-brazil.karim-portfolio.xyz"
            ;;
          ecuador)
            UI_PORT=30002
            KAFKA_PORT=30093
            API_PORT=30082
            DB_PORT=30433
            UI_HOST="kafka-ecuador.karim-portfolio.xyz"
            API_HOST="api-ecuador.karim-portfolio.xyz"
            ;;
          colombia)
            UI_PORT=30003
            KAFKA_PORT=30094
            API_PORT=30083
            DB_PORT=30434
            UI_HOST="kafka-columbia.karim-portfolio.xyz"
            API_HOST="api-columbia.karim-portfolio.xyz"
            ;;
        esac

        cat <<YAML | kubectl apply -f -
# --- Regional API Deployment ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: $NS
  labels:
    app: api
    country: "$country"
    environment: "${var.environment}"
  annotations:
    keel.sh/policy: "regex"
    keel.sh/match: "^[0-9]{8}-[0-9]+$$"
    keel.sh/trigger: "poll"
    keel.sh/pollSchedule: "@every 1m"
spec:
  replicas: $REPLICAS
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: api
      country: "$country"
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: api
        country: "$country"
        environment: "${var.environment}"
    spec:
      imagePullSecrets:
        - name: ghcr-auth
      containers:
        - name: api
          image: "${var.country_api_image}"
          ports:
            - containerPort: ${var.container_port}
          readinessProbe:
            httpGet:
              path: /health/readiness
              port: ${var.container_port}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health/liveness
              port: ${var.container_port}
            initialDelaySeconds: 15
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: $NS
spec:
  type: NodePort
  selector:
    app: api
    country: "$country"
    environment: "${var.environment}"
  ports:
    - port: 80
      targetPort: ${var.container_port}
      nodePort: $API_PORT
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  namespace: $NS
  labels:
    app: api
    country: "$country"
    environment: "${var.environment}"
spec:
  rules:
  - host: "$API_HOST"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 80
---
# --- Regional Kafka Broker ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka
  namespace: $NS
  labels:
    app: kafka
    country: "$country"
    environment: "${var.environment}"
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: kafka
      country: "$country"
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: kafka
        country: "$country"
        environment: "${var.environment}"
    spec:
      containers:
        - name: kafka
          image: "${var.kafka_image}"
          env:
            - name: KAFKA_CFG_NODE_ID
              value: "0"
            - name: KAFKA_CFG_PROCESS_ROLES
              value: "controller,broker"
            - name: KAFKA_CFG_LISTENERS
              value: "PLAINTEXT://:9092,CONTROLLER://:9093,EXTERNAL://:9094"
            - name: KAFKA_CFG_ADVERTISED_LISTENERS
              value: "PLAINTEXT://kafka:9092,EXTERNAL://$UI_HOST:$KAFKA_PORT"
            - name: KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP
              value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT"
            - name: KAFKA_CFG_CONTROLLER_QUORUM_VOTERS
              value: "0@localhost:9093"
            - name: KAFKA_CFG_CONTROLLER_LISTENER_NAMES
              value: "CONTROLLER"
            - name: ALLOW_PLAINTEXT_LISTENER
              value: "yes"
---
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: $NS
spec:
  type: NodePort
  selector:
    app: kafka
    country: "$country"
    environment: "${var.environment}"
  ports:
    - name: internal
      port: 9092
      targetPort: 9092
    - name: external
      port: 9094
      targetPort: 9094
      nodePort: $KAFKA_PORT
---
# --- Regional Kafka UI ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-ui
  namespace: $NS
  labels:
    app: kafka-ui
    country: "$country"
    environment: "${var.environment}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka-ui
      country: "$country"
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: kafka-ui
        country: "$country"
        environment: "${var.environment}"
    spec:
      containers:
        - name: kafka-ui
          image: "${var.kafka_ui_image}"
          env:
            - name: KAFKA_CLUSTERS_0_NAME
              value: "$country"
            - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
              value: "kafka:9092"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-ui
  namespace: $NS
spec:
  type: NodePort
  selector:
    app: kafka-ui
    country: "$country"
    environment: "${var.environment}"
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: $UI_PORT
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kafka-ui
  namespace: $NS
  labels:
    app: kafka-ui
    country: "$country"
    environment: "${var.environment}"
spec:
  rules:
  - host: "$UI_HOST"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kafka-ui
            port:
              number: 8080
---
# --- Regional Postgres Database ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: $NS
  labels:
    app: postgres
    country: "$country"
    environment: "${var.environment}"
spec:
  replicas: $REPLICAS
  selector:
    matchLabels:
      app: postgres
      country: "$country"
      environment: "${var.environment}"
  template:
    metadata:
      labels:
        app: postgres
        country: "$country"
        environment: "${var.environment}"
    spec:
      containers:
        - name: postgres
          image: "${var.postgres_image}"
          env:
            - name: POSTGRES_DB
              value: "sales_analysis"
            - name: POSTGRES_PASSWORD
              value: "password"
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NS
spec:
  type: NodePort
  selector:
    app: postgres
    country: "$country"
    environment: "${var.environment}"
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: $DB_PORT
YAML
      done
    EOT
  }
}

output "kubeconfig_path" {
  value       = local.kubeconfig_path
  description = "Path to the k3s kubeconfig used by kubectl."
}

output "verify_commands" {
  value = [
    "export KUBECONFIG=${local.kubeconfig_path}",
    "kubectl get nodes",
    "kubectl get pods -A -l environment=${var.environment}",
    "kubectl get svc -A -l environment=${var.environment}"
  ]
  description = "Useful commands to verify the country clusters."
}
