# Dockerfile for x86_64 Jenkins Jnlp Slave Agent Container with Kubectl and Docker Installed

FROM jenkinsci/jnlp-slave

MAINTAINER Alanny Lopez (alanny.lopez@ibm.com)

USER root

# Download and install Kubectl
RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s \
    https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl \
    && chmod +x ./kubectl \
    && mv ./kubectl /usr/local/bin/kubectl

# install docker for jenkins and grant access to user
RUN curl -sSL https://get.docker.com/ | sh
RUN usermod -a -G docker jenkins

USER jenkins

ENTRYPOINT ["jenkins-slave"]
