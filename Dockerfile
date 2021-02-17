ARGS BASE_YUM_REPO=release

FROM opensciencegrid/software-base:$BASE_YUM_REPO
LABEL maintainer "OSG Software <help@opensciencegrid.org>"

ARGS BASE_YUM_REPO=release

RUN if [[ $BASE_YUM_REPO = release ]]; then \
       yumrepo=osg-upcoming; else \
       yumrepo=osg-upcoming-$BASE_YUM_REPO; fi && \
    yum install -y --enablerepo=$yumrepo \
                   osg-ce-bosco \
                   # FIXME: avoid htcondor-ce-collector conflict
                   htcondor-ce \
                   htcondor-ce-view \
                   git \
                   openssh-clients \
                   sudo \
                   wget \
                   certbot \
                   perl-LWP-Protocol-https \
                   # ^^^ for fetch-crl, in the rare case that the CA forces HTTPS
                   patch && \
    yum clean all && \
    rm -rf /var/cache/yum/

COPY 25-hosted-ce-setup.sh /etc/osg/image-config.d/
COPY 30-remote-site-setup.sh /etc/osg/image-config.d/
COPY 50-nonroot-gratia-setup.sh /etc/osg/image-config.d/

COPY 99-container.conf /usr/share/condor-ce/config.d/

# do the bad thing of overwriting the existing cron job for fetch-crl
ADD fetch-crl /etc/cron.d/fetch-crl
RUN chmod 644 /etc/cron.d/fetch-crl

# HACK: override condor_ce_jobmetrics from SOFTWARE-4183 until it is released in
# HTCondor-CE.
ADD overrides/condor_ce_jobmetrics /usr/share/condor-ce/condor_ce_jobmetrics

# Include script to drain the CE and upload accounting data to prepare for container teardown
COPY drain-ce.sh /usr/local/bin/

COPY configure-nonroot-gratia.py /usr/local/bin/

# Use "ssh -q" in bosco_cluster until the chang has been upstreamed to condor
COPY overrides/ssh_q.patch /tmp
RUN patch -d / -p0 < /tmp/ssh_q.patch

# Enable bosco_cluster xtrace
COPY overrides/bosco_cluster_xtrace.patch /tmp
RUN patch -d / -p0 < /tmp/bosco_cluster_xtrace.patch

# HACK: Don't copy over the SSH pub key to the remote side. We set
# this up with the site out of band.
COPY overrides/skip_key_copy.patch /tmp
RUN patch -d / -p0 < /tmp/skip_key_copy.patch

# Fix Ubuntu20 OS detection (SOFTWARE-4463)
# Can be dropped when HTCONDOR-242 is involved
COPY overrides/HTCONDOR-242.remote-os-detection.patch /tmp
RUN patch -d / -p0 < /tmp/HTCONDOR-242.remote-os-detection.patch

# Set up Bosco override dir from Git repo (SOFTWARE-3903)
# Expects a Git repo with the following directory structure:
#     RESOURCE_NAME_1/
#         bosco_override/
#         ...
#     RESOURCE_NAME_2/
#         bosco_override/
#         ...
#     ...
COPY bosco-override-setup.sh /usr/local/bin

# Manage HTCondor-CE with supervisor
COPY 10-htcondor-ce.conf /etc/supervisord.d/

