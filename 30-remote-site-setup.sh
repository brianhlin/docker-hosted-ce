#!/bin/bash

set -x

# save old -e status
if [[ $- = *e* ]]; then
    olde=-e
else
    olde=+e
fi

set -e

BOSCO_KEY=/etc/osg/bosco.key
ENDPOINT_CONFIG=/etc/endpoints.ini

function errexit {
    echo "$1" >&2
    exit 1
}


function debug_file_contents {
    filename=$1
    echo "Contents of $filename"
    echo "===================="
    cat "$filename"
    echo "===================="
}

function fetch_remote_os_info {
    ruser=$1
    rhost=$2
    ssh -q -i $BOSCO_KEY "$ruser@$rhost" "cat /etc/os-release"
}

setup_ssh_config () {
  echo "Adding user ${ruser}"
  ssh_dir="/home/${ruser}/.ssh"
  # setup user and SSH dir
  adduser --base-dir /home/ "${ruser}"
  mkdir -p $ssh_dir
  chown "${ruser}": $ssh_dir
  chmod 700 $ssh_dir

  # copy Bosco key
  ssh_key=$ssh_dir/bosco_key.rsa
  cp $BOSCO_KEY $ssh_key
  chmod 600 $ssh_key
  chown "${ruser}": $ssh_key

  ssh_config=$ssh_dir/config
  cat <<EOF > "$ssh_config"
Host $remote_fqdn
  Port $remote_port
  IdentityFile ${ssh_key}
  IdentitiesOnly yes
EOF
  debug_file_contents "$ssh_config"

  # setup known hosts
  known_hosts=$ssh_dir/known_hosts
  echo "$REMOTE_HOST_KEY" >> "$known_hosts"
  debug_file_contents $known_hosts

  for ssh_file in $ssh_dir/config $ssh_dir/known_hosts; do
      chown "${ruser}": "$ssh_file"
  done

  # debugging
  ls -l "$ssh_dir"
}


# Install the WN client, CAs, and CRLs on the remote host
# Store logs in /var/log/condor-ce/ to simplify serving logs via Kubernetes
setup_endpoints_ini () {
    echo "Setting up endpoint.ini entry for ${ruser}@$remote_fqdn..."
    remote_os_major_ver=$1
    osg_ver=3.4
    if [[ $remote_os_major_ver -gt 6 ]]; then
        osg_ver=3.5
    fi
    cat <<EOF >> $ENDPOINT_CONFIG
[Endpoint ${RESOURCE_NAME}-${ruser}]
local_user = ${ruser}
remote_host = $remote_fqdn
remote_user = ${ruser}
remote_dir = bosco-osg-wn-client
upstream_url = https://repo.opensciencegrid.org/tarball-install/${osg_ver}/osg-wn-client-latest.el${remote_os_major_ver}.x86_64.tar.gz
EOF
}

# $REMOTE_HOST needs to be specified in the environment
remote_fqdn=${REMOTE_HOST%:*}
if [[ $REMOTE_HOST =~ :[0-9]+$ ]]; then
    remote_port=${REMOTE_HOST#*:}
else
    remote_port=22
fi

REMOTE_HOST_KEY=`ssh-keyscan -p "$remote_port" "$remote_fqdn"`
[[ -n $REMOTE_HOST_KEY ]] || errexit "Failed to determine host key for $remote_fqdn:$remote_port"

# Set the appropriate SSH key for bosco_cluster commands
root_ssh_dir=/root/.ssh/
mkdir -p $root_ssh_dir
chmod 700 $root_ssh_dir

ssh_config=$root_ssh_dir/config
cat <<EOF > "$ssh_config"
Host $remote_fqdn
  Port $remote_port
  IdentityFile ${BOSCO_KEY}
  ControlMaster auto
  ControlPath $root_ssh_dir/cm-%r@%h:%p
  ControlPersist  15m
EOF
chmod 700 $ssh_config
debug_file_contents "$ssh_config"

known_hosts=$root_ssh_dir/known_hosts
echo "$REMOTE_HOST_KEY" >> "$known_hosts"
debug_file_contents "$known_hosts"

# Debug output of file permissions
ls -l $root_ssh_dir

# Populate the bosco override dir from a Git repo
if [[ -n $BOSCO_GIT_ENDPOINT && -n $BOSCO_DIRECTORY ]]; then
    OVERRIDE_DIR=/etc/condor-ce/bosco_override
    /usr/local/bin/bosco-override-setup.sh "$BOSCO_GIT_ENDPOINT" "$BOSCO_DIRECTORY" /etc/osg/git.key
fi
unset GIT_SSH_COMMAND

users=$(cat /etc/grid-security/grid-mapfile /etc/grid-security/voms-mapfile | \
            awk '/^"[^"]+" +[a-zA-Z0-9\-\._]+$/ {print $NF}' | \
            sort -u)
[[ -n $users ]] || errexit "Did not find any user mappings in the VOMS or Grid mapfiles"

# Allow the condor user to run the WN client updater as the local users
CONDOR_SUDO_FILE=/etc/sudoers.d/10-condor-ssh
condor_sudo_users=`tr ' ' ',' <<< $users`
echo "condor ALL = ($condor_sudo_users) NOPASSWD: /usr/bin/update-remote-wn-client" \
      > $CONDOR_SUDO_FILE
chmod 644 $CONDOR_SUDO_FILE

grep '^OSG_GRID="/cvmfs/oasis.opensciencegrid.org/osg-software/osg-wn-client' \
     /var/lib/osg/job-environment*.conf > /dev/null 2>&1 || cvmfs_wn_client=no

# Enable bosco_cluster debug output
bosco_cluster_opts=(-d )
if [[ -n $OVERRIDE_DIR ]]; then
    if [[ -d $OVERRIDE_DIR ]]; then
        bosco_cluster_opts+=(-o "$OVERRIDE_DIR")
    else
        echo "WARNING: $OVERRIDE_DIR is not a directory. Skipping Bosco override."
    fi
fi

[[ $REMOTE_BOSCO_DIR ]] && bosco_cluster_opts+=(-b "$REMOTE_BOSCO_DIR") \
        || REMOTE_BOSCO_DIR=bosco

echo "Using Bosco tarball: $(bosco_findplatform --url)"
for ruser in $users; do
    setup_ssh_config
done

###################
# REMOTE COMMANDS #
###################

# We have to pick a user for SSH, may as well be the first one
remote_os_info=$(fetch_remote_os_info "$(printf "%s\n" $users | head -n1)" "$remote_fqdn")
remote_os_ver=$(echo "$remote_os_info" | awk -F '=' '/^VERSION_ID/ {print $2}' | tr -d '"')

for ruser in $users; do
    echo "Installing remote Bosco installation for ${ruser}@$remote_fqdn"
    [[ $cvmfs_wn_client == 'no' ]] && setup_endpoints_ini "${remote_os_ver%%.*}"
    # $REMOTE_BATCH needs to be specified in the environment
    bosco_cluster "${bosco_cluster_opts[@]}" -a "${ruser}@$remote_fqdn" "$REMOTE_BATCH"

    echo "Installing environment files for $ruser@$remote_fqdn..."
    # Copy over environment files to allow for dynamic WN variables (SOFTWARE-4117)
    rsync -av /var/lib/osg/osg-*job-environment.conf \
          "${ruser}@$remote_fqdn:$REMOTE_BOSCO_DIR/glite/etc"
done

if [[ $cvmfs_wn_client == 'no' ]]; then
    echo "Installing remote WN client tarballs..."
    sudo -u condor update-all-remote-wn-clients --log-dir /var/log/condor-ce/
else
    echo "Skipping remote WN client tarball installation, using CVMFS..."
fi

set $olde
