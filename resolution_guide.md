# Resolution Guide: Fix Postgres and MQTT Service Failures in Regional Namespaces

This guide provides step-by-step instructions to resolve the Postgres database startup failure and the MQTT Service CrashLoopBackOff in the regional namespaces (`brazil`, `ecuador`, `colombia`).

---

## 1. Root Cause Analysis

### Issue A: Postgres Database CrashLoopBackOff (RESOLVED)
- **Offending File:** [kubernetes/regional/postgres.yaml](file:///root/EPSI/altitude0_infra/kubernetes/regional/postgres.yaml)
- **Root Cause:** The environment variables for the Postgres container were defined as `DB_USER` and `DB_PASSWORD`. However, the official PostgreSQL Docker image requires `POSTGRES_USER` and `POSTGRES_PASSWORD` to initialize the database.
- **Resolution:** Change `DB_USER` -> `POSTGRES_USER` and `DB_PASSWORD` -> `POSTGRES_PASSWORD` in the `env` section of [kubernetes/regional/postgres.yaml](file:///root/EPSI/altitude0_infra/kubernetes/regional/postgres.yaml).

---

### Issue B: MQTT Service CrashLoopBackOff ("No Available Server")
- **Offending File:** [kubernetes/regional/mqtt-service.yaml](file:///root/EPSI/altitude0_infra/kubernetes/regional/mqtt-service.yaml)
- **Root Cause:**
  1. An inspection of the `futurekawa-mqtt-service` JAR dependencies reveals that it is a **pure console/daemon application**—it does not contain `spring-boot-starter-web` or any embedded web server (like Tomcat, Jetty, or Netty) on the classpath.
  2. Because it lacks a web server, the application **does not listen on any HTTP port** (neither `8080` nor `8081`).
  3. The manifest in [kubernetes/regional/mqtt-service.yaml](file:///root/EPSI/altitude0_infra/kubernetes/regional/mqtt-service.yaml) defines HTTP-based `livenessProbe` and `readinessProbe` checking port `8080`/`8081`. These probes will always fail with `connection refused`, causing Kubernetes to continuously kill and restart the pods.

---

## 2. Steps to Resolve

Since the MQTT Service is a background daemon that subscribes to Mosquitto and processes messages in background threads, it does not need to expose any HTTP endpoints or run liveness/readiness probes.

### Step 1: Remove HTTP Probes from MQTT Service Manifest
Open [kubernetes/regional/mqtt-service.yaml](file:///root/EPSI/altitude0_infra/kubernetes/regional/mqtt-service.yaml) and remove or comment out the `readinessProbe` and `livenessProbe` blocks entirely (lines 58–69):

```diff
-           readinessProbe:
-             httpGet:
-               path: /actuator/health
-               port: 8081
-             initialDelaySeconds: 5
-             periodSeconds: 10
-           livenessProbe:
-             httpGet:
-               path: /health/liveness
-               port: {{ app_port }}
-             initialDelaySeconds: 15
-             periodSeconds: 20
```

*Note: You can leave the port definition (`containerPort: 8081`) and the Service/Ingress resources intact as they do not affect the pod's execution stability.*

---

### Step 2: Run the Ansible Playbook
Apply the updated configuration by running the playbook:

```bash
ansible-playbook -i ansible/inventory.ini ansible/deploy-apps.yml
```

---

## 3. Verification

After the playbook runs, verify that the pods stay running:
```bash
kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get pods -n staging-brazil -l app=mqtt-service
```
The pods should now show status `Running` and `READY: 1/1` without restarting.
