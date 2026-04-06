#!/bin/bash
# generate-versioned-bundle.sh

AWS_PROFILE="turtles"
WANTED_ADDONS="aws-ebs-csi-driver coredns kube-proxy vpc-cni"
FIXED_CLUSTER_INFRA="cluster-fixed"
FIXED_BOOTSTRAP="bootstrap-fixed"

USER_ARN="arn:aws:iam::058264532137:user/emendonca-remote"
NODE_ROLE_ARN="arn:aws:iam::058264532137:role/nodes.cluster-api-provider-aws.sigs.k8s.io"

echo "------------------------------------------------"
echo "EKS Bundle Generator (Ready for 1.33)"
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

# 4. Generate Output
V_SUF="${selected_version//./-}"
OUTPUT_FILE="eks-bundle-v$V_SUF.yaml"

cat <<EOF > $OUTPUT_FILE
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: AWSManagedControlPlaneTemplate
metadata:
  name: eks-control-plane-v$V_SUF
  namespace: default
spec:
  template:
    spec:
      version: $K8S_V
      region: us-east-1
      sshKeyName: default-key
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

generate_class() {
  local size=$1
  cat <<EOF >> $OUTPUT_FILE
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
              name: worker-$size
---
EOF
}

generate_class "medium"
generate_class "large"
generate_class "xlarge"

