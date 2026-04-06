#!/bin/bash
# fill-versions.sh

AWS_PROFILE="turtles"
TEMPLATE_FILE="cluster.template.yaml"
OUTPUT_FILE="3-cluster.yaml"

echo "------------------------------------------------"
echo "EKS Addon Discovery for Rancher Turtles"
echo "------------------------------------------------"

# 1. Fetch available K8s versions
echo "Fetching available EKS versions..."
versions=( $(aws eks describe-cluster-versions \
    --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion' \
    --output text --profile $AWS_PROFILE) )

# 2. Interactive Menu
PS3="Select the target Kubernetes version: "
select selected_version in "${versions[@]}"; do
    if [ -n "$selected_version" ]; then break; else echo "Invalid selection."; fi
done

# 3. Fetch ALL Addon Data in one JSON blob
echo "Downloading default addon versions for v$selected_version..."
addon_json=$(aws eks describe-addon-versions \
    --kubernetes-version "$selected_version" \
    --query "addons[].{name: addonName, version: addonVersions[?compatibilities[?defaultVersion==true]].addonVersion | [0]}" \
    --output json --profile $AWS_PROFILE)

# 4. Map JSON to Environment Variables
# This converts 'vpc-cni' to 'VPC_CNI_VERSION'
while read -r name version; do
    if [ "$version" != "null" ]; then
        var_name=$(echo "$name" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"_VERSION"
        export "$var_name"="$version"
        echo "  Found: $name -> $version"
    fi
done < <(echo "$addon_json" | jq -r '.[] | "\(.name) \(.version)"')

export K8S_VERSION="v${selected_version}.0"

# 5. Generate the final Cluster YAML
if [ -f "$TEMPLATE_FILE" ]; then
    envsubst < "$TEMPLATE_FILE" > "$OUTPUT_FILE"
    echo "------------------------------------------------"
    echo "SUCCESS: $OUTPUT_FILE generated with valid versions."
    echo "------------------------------------------------"
else
    echo "Error: $TEMPLATE_FILE not found."
fi

