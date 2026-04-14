#!/bin/bash
# generate-versioned-bundle.sh

AWS_PROFILE="turtles"
AWS_REGION="us-east-1"
WANTED_ADDONS="aws-ebs-csi-driver coredns kube-proxy vpc-cni"
FIXED_CLUSTER_INFRA="cluster-fixed"
FIXED_BOOTSTRAP="bootstrap-fixed"

USER_ARN="arn:aws:iam::058264532137:user/emendonca-remote"
NODE_ROLE_ARN="arn:aws:iam::058264532137:role/nodes.cluster-api-provider-aws.sigs.k8s.io"

echo "------------------------------------------------"
echo "EKS Versioned Bundle Generator"
echo "------------------------------------------------"

# 1. Fetch K8s Versions
versions=( $(aws eks describe-cluster-versions --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion' --output text --profile $AWS_PROFILE) )
PS3="Select EKS version: "
select selected_version in "${versions[@]}"; do [ -n "$selected_version" ] && break; done

# 2. Build Filter Query
FILTER_QUERY=""
for addon in $WANTED_ADDONS; do
    [ -z "$FILTER_QUERY" ] && FILTER_QUERY="addonName == '$addon'" || FILTER_QUERY="$FILTER_QUERY || addonName == '$addon'"
done

# 3. Fetch Addon Defaults
K8S_V="v${selected_version}.0"
raw_json=$(aws eks describe-addon-versions --kubernetes-version "$selected_version" \
    --query "addons[?$FILTER_QUERY] | sort_by(@, &addonName)[].{name: addonName, versions: addonVersions}" \
    --output json --profile $AWS_PROFILE)

addon_json=$(echo "$raw_json" | jq -c '[.[] | {
    name: .name, 
    version: (.versions[] | select(.compatibilities[] | .defaultVersion == true or .defaultVersion == "true") | .addonVersion) // .versions[0].addonVersion
}]')

# 4. Fetch AL2023 AMI ID
# CAPA v2.9.1 has a bug where AMI auto-discovery always looks for AL2, which
# doesn't exist for EKS >= 1.33. We must look up the AL2023 AMI and hardcode it.
echo "Looking up EKS-optimized AL2023 AMI for v${selected_version} in ${AWS_REGION}..."
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${selected_version}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text \
    --profile $AWS_PROFILE)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    echo "ERROR: Could not find AL2023 AMI for EKS ${selected_version} in ${AWS_REGION}"
    exit 1
fi
echo "  Found AMI: $AMI_ID"

# 5. Generate Output
V_SUF="${selected_version//./-}"
OUTPUT_FILE="eks-bundle-v$V_SUF.yaml"

cat <<EOF > $OUTPUT_FILE
# --- VERSIONED CONTROL PLANE ---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: AWSManagedControlPlaneTemplate
metadata:
  name: eks-control-plane-v$V_SUF
  namespace: default
spec:
  template:
    spec:
      version: $K8S_V
      region: $AWS_REGION
      sshKeyName: default-key
      associateOIDCProvider: false
      endpointAccess:
        public: true
        private: true
      # This configuration populates the aws-auth ConfigMap
      iamAuthenticatorConfig:
        mapRoles:
          - rolearn: "$NODE_ROLE_ARN"
            username: "system:node:{{EC2PrivateDNSName}}"
            groups:
              - system:bootstrappers
              - system:nodes
        mapUsers:
          - userarn: "$USER_ARN"
            username: admin
            groups:
              - system:masters
      addons:
$(echo "$addon_json" | jq -r '.[] | "        - name: \(.name)\n          version: \(.version)\n          conflictResolution: overwrite"')
---
EOF

# 6. Generate version-specific machine templates
# CAPA bug: AMI auto-discovery uses AL2 SSM path which doesn't exist for EKS >= 1.33.
# We hardcode the AL2023 AMI per version. These templates are version-specific.
generate_machine_template() {
  local size=$1
  local instance_type=$2
  cat <<EOF >> $OUTPUT_FILE
# --- MACHINE TEMPLATE: ${size^^} (v$V_SUF) ---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSMachineTemplate
metadata:
  name: worker-v$V_SUF-$size
  namespace: default
spec:
  template:
    spec:
      iamInstanceProfile: nodes.cluster-api-provider-aws.sigs.k8s.io
      instanceType: $instance_type
      sshKeyName: default-key
      ami:
        id: $AMI_ID
---
EOF
}

generate_machine_template "medium" "t3.medium"
generate_machine_template "large" "t3.large"
generate_machine_template "xlarge" "t3.xlarge"

# 7. Generate ClusterClasses referencing version-specific machine templates
generate_class() {
  local size=$1
  cat <<EOF >> $OUTPUT_FILE
# --- CLUSTER CLASS: ${size^^} (v$V_SUF) ---
apiVersion: cluster.x-k8s.io/v1beta1
kind: ClusterClass
metadata:
  name: eks-v$V_SUF-$size
  namespace: default
spec:
  infrastructure:
    ref:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
      kind: AWSManagedClusterTemplate
      name: $FIXED_CLUSTER_INFRA
  controlPlane:
    ref:
      apiVersion: controlplane.cluster.x-k8s.io/v1beta2
      kind: AWSManagedControlPlaneTemplate
      name: eks-control-plane-v$V_SUF
  workers:
    machineDeployments:
      - class: default-worker
        template:
          bootstrap:
            ref:
              apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
              kind: EKSConfigTemplate
              name: $FIXED_BOOTSTRAP
          infrastructure:
            ref:
              apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
              kind: AWSMachineTemplate
              name: worker-v$V_SUF-$size
---
EOF
}

generate_class "medium"
generate_class "large"
generate_class "xlarge"

echo "------------------------------------------------"
echo "SUCCESS: $OUTPUT_FILE generated"
echo "  K8s version: $K8S_V"
echo "  AL2023 AMI:  $AMI_ID"
echo "  ClusterClasses: eks-v$V_SUF-{medium,large,xlarge}"
echo "------------------------------------------------"
