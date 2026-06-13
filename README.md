# Investigation: Scaling Azure Container Apps

## Overview
This activity guides you through investigating and configuring automatic horizontal scaling in Azure Container Apps. You will explore how **KEDA** (Kubernetes Event-Driven Autoscaling) powers the platform and learn to configure different scale rules (HTTP, TCP, CPU, Memory) to match specific workload requirements.

> **Goal:** By the end of this activity, you will understand how to define scaling limits, triggers, and behaviors, and be able to observe real-time scaling actions.

---

## 1. Core Concepts & Investigation

Before running commands, investigate the following concepts. Update your notes with your findings.

### A. How Scaling Works
Azure Container Apps uses **declarative scale rules**. You define the *conditions* (rules), and the platform handles the *creation/removal* of replicas.

**Key Components of Scale Definitions:**
1.  **Limits:** The `minReplicas` and `maxReplicas` allowed.
2.  **Rules:** The triggers (e.g., "If concurrent requests > 10").
3.  **Behaviour:** The timing algorithms (polling, stabilization windows).

### B. The Role of KEDA
*   **Question:** What is KEDA?
*   **Investigation:** KEDA stands for **Kubernetes Event-Driven Autoscaling**. It allows scaling based on external events (like queue length) or internal metrics (CPU), not just HTTP traffic.

### C. Default Behavior
*   **Scenario:** If you deploy a container with `--ingress external` and no custom rules:
    *   **Min Replicas:** 0 (Scale-to-zero is enabled).
    *   **Max Replicas:** 10.
*   **Critical Note:** If ingress is *disabled* and no rules are set, the app scales to zero and **cannot restart** because there is no trigger. You must set `minReplicas: 1` for always-on apps.

---

## 2. Step-by-Step Investigation

### Prerequisites
*   Azure CLI installed and updated (`az upgrade`).
*   Azure Container Apps extension installed:
    ```bash
    az extension add --name containerapp --upgrade
    ```
    *(Note: If using preview features, add `--allow-preview true`)*
*   A resource group created: `az group create --name <rg-name> --location <location>`

---

### Phase 1: Deploy a Baseline App
*Objective: Create a container app to test scaling against.*

1.  **Run the deployment command:**
    ```bash
    az containerapp up \
      --name my-container-app \
      --resource-group <your-resource-group> \
      --image mcr.microsoft.com/dotnet/samples:aspnetapp \
      --ingress external \
      --target-port 80 \
      --query properties.configuration.ingress.fqdn
    ```
2.  **Action:** Copy the returned **FQDN** (e.g., `my-container-app.azurecontainerapps.io`). You will need this for load testing.
3.  **Investigation:** Check the default scaling settings.
    ```bash
    az containerapp show --name my-container-app --resource-group <your-resource-group> --query properties.template.scale
    ```
    *Record the default `minReplicas` and `maxReplicas`.*

---

### Phase 2: Configure HTTP Scale Rules
*Best for: Synchronous APIs, Web Apps where request volume = resource need.*

**Concept:** Scales based on **concurrent requests**.
*   **Calculation:** (Requests in last 15s) / 15.
*   **Threshold:** Default is 10 concurrent requests per replica.
*   **Scale-to-Zero:** Supported.

**Steps:**
1.  **Update the app with an HTTP rule:**
    ```bash
    az containerapp update \
      --name my-container-app \
      --resource-group <your-resource-group> \
      --scale-rule-name my-http-rule \
      --scale-rule-type http \
      --scale-rule-http-concurrency 1
    ```
    *Note: Setting concurrency to `1` triggers scaling immediately after the first request to ensure you see the effect.*

2.  **Monitor Logs:**
    Open a new terminal window and stream logs:
    ```bash
    az containerapp logs show --name my-container-app --resource-group <your-resource-group> --follow
    ```

3.  **Generate Load:**
    Open a *third* terminal and send 50 concurrent requests:
    ```bash
    # Replace <FQDN> with your app's URL
    for i in {1..50}; do curl -s "http://<FQDN>/"; done
    ```
4.  **Observe:** Watch the logs in the second terminal for "Replica created" events.

---

### Phase 3: Configure TCP Scale Rules
*Best for: WebSocket servers, gRPC, Database connection pools.*

**Concept:** Scales based on **active TCP connections**.
*   **Calculation:** Same 15-second averaging window as HTTP.
*   **Scale-to-Zero:** Supported.

**Steps:**
1.  **Add a TCP rule:**
    ```bash
    az containerapp update \
      --name my-container-app \
      --resource-group <your-resource-group> \
      --scale-rule-name my-tcp-rule \
      --scale-rule-type tcp \
      --scale-rule-tcp-concurrency 5
    ```
2.  **Investigation:** How does this differ from the HTTP rule you just created? (Hint: HTTP counts *requests*, TCP counts *open connections*).

---

### Phase 4: Configure CPU & Memory Rules
*Best for: Compute-intensive tasks (image processing, ML) or Memory-heavy tasks (caching).*

**⚠️ Critical Limitation:** CPU and Memory rules **do not support scale-to-zero**. The platform needs at least one running replica to measure utilization.

**Steps:**
1.  **Add a CPU Rule (Demo):**
    *Note: Setting utilization to 1% is for demonstration only.*
    ```bash
    az containerapp update \
      --name my-container-app \
      --resource-group <your-resource-group> \
      --scale-rule-name my-cpu-rule \
      --scale-rule-type cpu \
      --scale-rule-cpu-utilization 1 \
      --min-replicas 1
    ```
    *Note: This command replaces the previous scale rule. To keep multiple rules, you must use YAML (see Phase 5).*

2.  **Investigation:**
    *   Why did we set `--min-replicas 1`?
    *   What happens if you remove this and rely only on CPU? (The app will crash/stop when idle).

---

### Phase 5: Multiple Scale Rules (YAML Approach)
*Objective: Configure HTTP AND CPU rules simultaneously.*

Since CLI `update` commands replace existing rules, use YAML to manage multiple rules.

1.  **Export current configuration:**
    ```bash
    az containerapp show --name my-container-app --resource-group <your-resource-group> --query properties.template > app.yaml
    ```
2.  **Edit `app.yaml`:**
    Locate the `scale` -> `rules` section. Add both HTTP and CPU rules:
    ```yaml
    scale:
      minReplicas: 1
      maxReplicas: 10
      rules:
        - name: http-rule
          type: http
          http:
            concurrentRequests: 10
        - name: cpu-rule
          type: cpu
          cpu:
            utilization: 70
    ```
3.  **Apply the configuration:**
    ```bash
    az containerapp update --name my-container-app --resource-group <your-resource-group> --yaml app.yaml
    ```

---

## 3. Understanding Scale Behavior

Investigate the timing parameters that control how the app reacts.

| Parameter | Value | Description |
| :--- | :--- | :--- |
| **Polling Interval** | 30s | How often KEDA checks CPU/Memory/Events. |
| **HTTP Window** | 15s | How far back HTTP/TCP looks to calculate average. |
| **Scale-Up** | 0s | Immediate. Uses progressive doubling (1 → 2 → 4 → 8...). |
| **Cool-Down** | 300s (5m) | Wait time after load drops before scaling down. Prevents "flapping". |
| **Scale-Down Action** | Immediate | Once cool-down expires, excess replicas are removed at once. |

**Reflection Question:**
*If your app experiences short bursts of traffic (e.g., 2 minutes on, 2 minutes off), how does the 300s cool-down period impact your costs?*

---

## 4. Best Practices Checklist

Use this checklist to evaluate your configuration:

- [ ] **Set Minimum Replicas:** Set `minReplicas: 1` for production to avoid cold starts.
- [ ] **Primary Trigger:** Use HTTP/TCP for API workloads (supports scale-to-zero).
- [ ] **Hybrid Approach:** Combine HTTP (for traffic spikes) with CPU (for heavy processing) using YAML.
- [ ] **Cool-Down Awareness:** Be aware that 5 minutes of "wasted" compute may occur after a burst before scaling down.
- [ ] **Avoid CPU-Only for Zero:** Never rely solely on CPU/Memory rules if you need scale-to-zero capabilities.

---

## 5. Cleanup

If you are finished investigating, delete the resource group to avoid charges:

```bash
az group delete --name <your-resource-group>
