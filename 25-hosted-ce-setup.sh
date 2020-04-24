#!/bin/bash

#kubernetes configmaps arent writeable
stat /tmp/99-local.ini
if [[ $? -eq 0 ]]; then
  cp /tmp/99-local.ini /etc/osg/config.d/99-local.ini
fi

echo "Trying to populate hostname in 99-local.ini with a better value.."
pushd /etc/osg/config.d
  if [[ -z "$_CONDOR_NETWORK_HOSTNAME" ]]; then
    echo '$_CONDOR_NETWORK_HOSTNAME is empty, just using `hostname`'
    sed -i "s/localhost/$(hostname)/" 99-local.ini
  else
    echo '$_CONDOR_NETWORK_HOSTNAME is nonempty, substituting it in..'
    sed -i "s/localhost/$_CONDOR_NETWORK_HOSTNAME/" 99-local.ini
  fi
popd 

# Allow the condor user to run the WN client updater as the local users
users=$(cat /etc/grid-security/grid-mapfile /etc/grid-security/voms-mapfile | \
            awk '/^"[^"]+" +[a-zA-Z0-9\-\._]+$/ {print $NF}' | \
            sort -u | \
            tr '\n' ',')
[[ -n $users ]] || { echo >&2 "No users found in /etc/grid-security/grid-mapfile or /etc/grid-security/voms-mapfile"; exit 1; }
# Use param expansion to remove the trailing comma
CONDOR_SUDO_FILE=/etc/sudoers.d/10-condor-ssh
echo "condor ALL = (${users%%,}) NOPASSWD: /usr/bin/update-remote-wn-client" \
      > $CONDOR_SUDO_FILE
chmod 644 $CONDOR_SUDO_FILE

echo "Running OSG configure.."
# Run the OSG Configure script to set up bosco
osg-configure -c --verbose VERBOSE

# Cert stuff
if [ "${DEVELOPER,,}" == 'true' ]; then
    echo "Establishing OSG Test certificate.."
    # don't do this in the image to make it smaller for prod use
    yum install -y --enablerepo=devops-itb osg-ca-generator
    osg-ca-generator --host --vo osgtest
fi

hostcert_path=/etc/grid-security/hostcert.pem
hostkey_path=/etc/grid-security/hostkey.pem

if [ ! -f $hostcert_path ] && [ ! -f $hostkey_path ]; then
    echo "Establishing Let's Encrypt certificate.."
    # this needs to be automated for renewal
    certbot certonly -n --agree-tos --standalone --email $CE_CONTACT -d $CE_HOSTNAME
    ln -s /etc/letsencrypt/live/$CE_HOSTNAME/cert.pem $hostcert_path
    ln -s /etc/letsencrypt/live/$CE_HOSTNAME/privkey.pem $hostkey_path
fi

echo ">>>>> YOUR CERTIFICATE INFORMATION IS:"
openssl x509 -in $hostcert_path -noout -text
echo "><><><><><><><><><><><><><><><><><><><"

echo ">>>>> YOUR HOST CERT AND KEY ARE:"
cat $hostcert_path
cat $hostkey_path
echo "><><><><><><><><><><><><><><><><><><><"
