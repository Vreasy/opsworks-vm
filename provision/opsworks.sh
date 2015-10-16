#!/bin/bash -eux

# set the agent version to be installed
AGENT_VERSION="33600020150210181912"

echo "==> Generating chef json for first OpsWorks run"
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p $TMPDIR/cookbooks

# Create a base json file to execute some default recipes
cat <<EOT > $TMPDIR/dna.json
{
  "opsworks_initial_setup": {
    "swapfile_instancetypes": null
  },
  "opsworks_custom_cookbooks": {
    "enabled": false,
    "manage_berkshelf": false
  },
  "recipes": [
    "opsworks_initial_setup",
    "ssh_host_keys",
    "ssh_users",
    "dependencies",
    "deploy::default",
    "agent_version",
    "opsworks_stack_state_sync",
    "opsworks_cleanup"
  ]
}
EOT

echo "==> Installing and running OpsWorks agent"
chmod +x /tmp/opsworks/opsworks
env OPSWORKS_AGENT_VERSION="$AGENT_VERSION" /tmp/opsworks/opsworks $TMPDIR/dna.json
