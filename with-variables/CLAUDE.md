# CLAUDE.md — EKS Cluster Automation with CAPI & Rancher Turtles

## Overview

This repository automates EKS cluster provisioning using Cluster API (CAPI) with the AWS provider (CAPA v2.9.x) managed through Rancher Turtles (v0.25.x). The design lets customers upgrade Kubernetes versions by simply changing the `class` and `version` fields in the Cluster object — no manual file editing required.

**Supported EKS versions: 1.29 through 1.32.** EKS 1.33+ is NOT supported with the current toolchain (see [EKS 1.33+ / AL2023 Limitation](#eks-133--al2023-limitation)).

## Architecture

```
0-enable-aws.yaml              → Enables CAPA providers (infra, control-plane, bootstrap)
1-fixed-infra.yaml             → Shared, version-agnostic templates (machine sizes, bootstrap, cluster infra)
eks-bundle-v1-XX.yaml          → Per-version bundle: AWSManagedControlPlaneTemplate + 3 ClusterClasses
2-variable-cluster.yaml        → The Cluster object — customer only changes class and version here
generate-versioned-bundle.sh   → Script to auto-generate bundles for new EKS versions
```

### How version upgrades work

1. Run `generate-versioned-bundle.sh` — it queries AWS for available EKS versions and their default addon versions, then outputs an `eks-bundle-v1-XX.yaml`.
2. Apply the new bundle to the management cluster.
3. Customer updates `2-variable-cluster.yaml`:
   - `class: eks-v1-31-large` → `class: eks-v1-32-large`
   - `version: v1.31.0` → `version: v1.32.0`
4. CAPI handles the rolling upgrade.

### Upgrade demo example

```yaml
# Before (EKS 1.31):
spec:
  topology:
    class: eks-v1-31-large
    version: v1.31.0

# After (EKS 1.32):
spec:
  topology:
    class: eks-v1-32-large
    version: v1.32.0
```

## File Details

### 0-enable-aws.yaml — CAPA Provider Configuration

Deploys three CAPIProvider objects (control-plane, bootstrap, infrastructure) plus a ClusterRoleBinding for the CAPA controller.

**Critical settings:**
- All three providers MUST have `credentials.rancherCloudCredential: aws-creds`.
- All three providers MUST have matching `version` and `fetchConfig.url` pointing to the same CAPA release.
- The `variables` block is set but note that the Turtles operator may override some variables (see Known Limitations).

**Current versions:**
- CAPA: v2.9.3 (control-plane, bootstrap), v2.9.1 (infrastructure — pinned by Turtles)
- Turtles: v0.25.4

### 1-fixed-infra.yaml — Shared Templates (Version-Agnostic)

Contains resources that don't change across Kubernetes versions:

- **AWSManagedClusterTemplate** (`cluster-fixed`) — empty spec, CAPA manages VPC/networking.
- **EKSConfigTemplate** (`bootstrap-fixed`) — empty spec, CAPA auto-generates AL2 bootstrap userdata.
- **AWSMachineTemplate** × 3 sizes:
  - `worker-medium` → `t3.medium`
  - `worker-large` → `t3.large`
  - `worker-xlarge` → `t3.xlarge`

**Critical: Do NOT hardcode AMI IDs in `AWSMachineTemplate`.** CAPA auto-discovers the correct EKS-optimized AL2 AMI for each K8s version (1.32 and below). Hardcoding AMIs causes bootstrap failures when there's a version mismatch.

All machine templates must include:
```yaml
iamInstanceProfile: nodes.cluster-api-provider-aws.sigs.k8s.io
sshKeyName: default-key
```

### eks-bundle-v1-XX.yaml — Versioned Bundles

Each bundle contains one **AWSManagedControlPlaneTemplate** and three **ClusterClass** objects (medium/large/xlarge).

The control plane template includes:
- `version: v1.XX.0`
- `region: us-east-1`
- `associateOIDCProvider: false`
- `endpointAccess: public: true, private: true` — **REQUIRED**
- `iamAuthenticatorConfig` with `mapRoles` and `mapUsers` — populates `aws-auth` ConfigMap
- `addons` with version-pinned EKS add-ons (auto-discovered by the generator script)

**Critical fields that must be present:**

| Field | Why | What happens without it |
|---|---|---|
| `endpointAccess.public + private` | Nodes need to reach the API server | Nodes launch but kubelet can't connect |
| `associateOIDCProvider` | Explicit control over OIDC | May default to unexpected behavior |
| `iamAuthenticatorConfig.mapRoles` | Populates `aws-auth` ConfigMap | Nodes get `Unauthorized` when joining |
| `addons` with correct versions | EKS requires version-pinned add-ons | Cluster creation fails on AWS side |

**Do NOT include:**
- `roleAdditionalPolicies` — see Known Limitations
- `eksClusterName` — breaks ClusterClass reusability

### 2-variable-cluster.yaml — The Cluster Object

This is the only file customers need to edit:

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: workload-cluster-01
  namespace: default
spec:
  topology:
    class: eks-v1-31-large    # Change this for version/size upgrade
    version: v1.31.0           # Must match the ClusterClass version
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 3
```

### generate-versioned-bundle.sh — Bundle Generator

Queries AWS for available EKS versions and default addon versions. Generates a complete versioned bundle.

- Warns if selected version >= 1.33 (unsupported with current toolchain).
- Requires: `aws` CLI configured with profile `turtles`, and `jq`.

## Deployment Order

```bash
# 1. Enable CAPA providers (one-time setup)
kubectl apply -f 0-enable-aws.yaml
# Wait for capa-controller-manager pod to be Running in capi-providers namespace

# 2. Apply shared infrastructure templates
kubectl apply -f 1-fixed-infra.yaml

# 3. Apply versioned bundles (one or more versions)
kubectl apply -f eks-bundle-v1-31.yaml
kubectl apply -f eks-bundle-v1-32.yaml

# 4. Create the cluster
kubectl apply -f 2-variable-cluster.yaml

# 5. Monitor progress (~15 min for full deployment)
kubectl get cluster workload-cluster-01 -w
```

### Performing a version upgrade

```bash
# 1. Ensure the target version bundle is applied
kubectl apply -f eks-bundle-v1-32.yaml

# 2. Update the cluster object
kubectl edit cluster workload-cluster-01
# Change: class: eks-v1-31-large → class: eks-v1-32-large
# Change: version: v1.31.0 → version: v1.32.0

# 3. CAPI performs rolling upgrade automatically
kubectl get cluster workload-cluster-01 -w
```

## EKS 1.33+ / AL2023 Limitation

**EKS 1.33 and above do NOT work with the current toolchain.** This is due to multiple compounding issues in CAPA v2.9.x:

### Root cause chain

1. **AWS stopped publishing AL2 AMIs** for EKS 1.33+. Only AL2023 and Bottlerocket AMIs are available.

2. **CAPA AMI auto-discovery is hardcoded to AL2.** It queries the SSM parameter `/aws/service/eks/optimized-ami/<version>/amazon-linux-2/recommended/image_id`, which doesn't exist for 1.33+. This causes `InstanceProvisionFailed: failed to get ami SSM parameter: ParameterNotFound`.

3. **Hardcoding an AL2023 AMI doesn't help.** Even with a correct AL2023 AMI, CAPA's EKS bootstrap provider (`EKSConfigTemplate`) generates AL2-style userdata that calls `/etc/eks/bootstrap.sh`. AL2023 uses `nodeadm` instead — `bootstrap.sh` is just a stub that does nothing useful.

4. **CAPA has a `NodeadmConfigTemplate`** designed for AL2023 bootstrapping, but it requires a newer CAPA version. The CRD is not present in v2.9.x.

5. **The Turtles operator (v0.25.x) pins the CAPA infrastructure provider** and prevents upgrading to a version that includes `NodeadmConfigTemplate`.

### When this will be resolved

When either:
- Rancher Turtles ships a version that bundles a CAPA release with `NodeadmConfigTemplate` support, OR
- CAPA v2.9.x receives a backport of `NodeadmConfigTemplate`

At that point, the architecture changes needed are:
- Replace `EKSConfigTemplate` with `NodeadmConfigTemplate` in the ClusterClass bootstrap ref
- Add `cloudInit.insecureSkipSecretsManager: true` and `ami.eksLookupType: AmazonLinux2023` to `AWSMachineTemplate`
- The generator script would need to look up AL2023 AMIs via SSM path: `/aws/service/eks/optimized-ami/<version>/amazon-linux-2023/x86_64/standard/recommended/image_id`

## Known Limitations

### 1. `EKSAllowAddRoles` feature gate

The Turtles operator does NOT support `EKS_ALLOW_ADD_ROLES` as a CAPIProvider variable. The feature gate `EKSAllowAddRoles` always stays `false`. This means **`roleAdditionalPolicies` CANNOT be used** in `AWSManagedControlPlaneTemplate`. CAPA with `EKSEnableIAM=true` automatically attaches `AmazonEKSClusterPolicy` and `AmazonEKSServicePolicy` when creating the service role, so `roleAdditionalPolicies` is not needed for standard deployments.

### 2. Turtles operator overrides

The Turtles operator controls CAPA provider versions and may override:
- `spec.version` — the infra provider is pinned to v2.9.1 regardless of what you set
- `status.variables` — your custom variables may not propagate to the controller's feature gates

To verify what the controller actually has:
```bash
kubectl -n capi-providers get pod -l control-plane=capa-controller-manager -o yaml | grep feature-gates
```

### 3. CAPIProvider variables mapping

`CAPA_EKS_IAM` → `EKSEnableIAM=true` ✅ works
`EXP_EKS` → `EKS=true` ✅ works
`EXP_MACHINE_POOL` → `MachinePool=true` ✅ works
`EKS_ALLOW_ADD_ROLES` → `EKSAllowAddRoles` ❌ does NOT work

### 4. Templates are immutable

To fix a template error, you must delete the cluster, fix the template, and redeploy. CAPA won't re-provision existing instances with updated templates.

## Troubleshooting

### Nodes stuck in `NodeProvisioning` / "Waiting for a node with matching ProviderID"

**Check bootstrap logs on the node:**
```bash
kubectl get secret workload-cluster-01-kubeconfig -o jsonpath='{.data.value}' | base64 -d > /tmp/wc.kubeconfig
kubectl --kubeconfig=/tmp/wc.kubeconfig get nodes
```

**Check the bootstrap secret content:**
```bash
kubectl get secret <machine-name> -o jsonpath='{.data.value}' | base64 -d
```

**Check what userdata the instance received:**
```bash
aws ec2 describe-instance-attribute --instance-id <id> --attribute userData --profile turtles --query 'UserData.Value' --output text | base64 -d
```

**Common causes:**
- `cloud-init` error `FileNotFoundError: /etc/secret-userdata.txt` → AMI/userdata format mismatch (AL2 vs AL2023)
- Bootstrap calls `bootstrap.sh` but AMI is AL2023 → wrong bootstrap provider (need NodeadmConfigTemplate)
- Missing `endpointAccess` → nodes can't reach API server
- Wrong/missing `iamAuthenticatorConfig.mapRoles` → nodes get `Unauthorized`

### `IAMControlPlaneRolesReconciliationFailed`

**"additional rules cannot be added as this has been disabled"** → `roleAdditionalPolicies` is set but `EKSAllowAddRoles` is `false`. Solution: remove `roleAdditionalPolicies`.

**"Policy arn:aws:iam::XXXX:policy/YYY was not found"** → the referenced policy doesn't exist. Use only AWS-managed policy ARNs.

### `InstanceProvisionFailed: failed to get ami SSM parameter`

CAPA is looking up an AL2 AMI that doesn't exist for this K8s version (1.33+). See the AL2023 limitation section above.

### `EKSControlPlaneReconciliationFailed: context canceled`

Transient timeout. The CAPA controller's reconciliation loop timed out waiting for EKS. The controller will retry automatically. Give it 10-15 minutes.

### Checking `aws-auth` ConfigMap on workload cluster

```bash
kubectl get secret workload-cluster-01-kubeconfig -o jsonpath='{.data.value}' | base64 -d > /tmp/wc.kubeconfig
kubectl --kubeconfig=/tmp/wc.kubeconfig -n kube-system get configmap aws-auth -o yaml
```

### Cleaning up failed deployments

```bash
kubectl delete cluster workload-cluster-01
# Wait for AWS resources to be cleaned up
# If orphaned IAM roles remain:
aws iam list-attached-role-policies --role-name workload-cluster-01-iam-service-role --profile turtles
# Detach policies first, then:
aws iam delete-role --role-name workload-cluster-01-iam-service-role --profile turtles
```

## Lessons Learned (Gotchas)

1. **EKS >= 1.33 does NOT work** with CAPA v2.9.x / Turtles v0.25.x. Use EKS 1.32 or below.
2. **Never hardcode AMI IDs** in `AWSMachineTemplate` for AL2 versions — let CAPA auto-discover them.
3. **Never use `roleAdditionalPolicies`** — `EKSAllowAddRoles` is always `false` under Turtles. CAPA handles default policies automatically.
4. **Always include `endpointAccess: public: true, private: true`** in the control plane template.
5. **Always include `associateOIDCProvider: false`** explicitly.
6. **Always include `iamAuthenticatorConfig`** with the node role ARN and admin user ARN.
7. **Do not include `eksClusterName`** — CAPA derives it from the Cluster object.
8. **The `EKSConfigTemplate` should have an empty spec** — CAPA generates AL2 bootstrap userdata automatically.
9. **Addon versions are version-specific** — always use `generate-versioned-bundle.sh` to discover correct defaults.
10. **All three CAPIProvider objects** need `credentials.rancherCloudCredential` and matching version/URL.
11. **The Turtles operator pins the infra provider version** — you cannot upgrade CAPA independently.
12. **AL2023 uses `nodeadm`**, not `bootstrap.sh`. CAPA v2.9.x only generates `bootstrap.sh` userdata via `EKSConfigTemplate`. The `NodeadmConfigTemplate` CRD is needed for AL2023 but is not available in v2.9.x.
