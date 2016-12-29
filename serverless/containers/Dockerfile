FROM ubuntu:latest

ENV FLASK_PROXY_PORT 8080

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy \
        build-essential \
        chrpath \
        debianutils \
        diffstat \
        gawk \
        git \
        libdata-dumper-simple-perl \
        libsdl1.2-dev \
        libthread-queue-any-perl \
        python \
        socat \
        subversion \
        texinfo \
        cpio \
        wget

# Add a non-root user for running bitbake
RUN useradd -m --shell /bin/bash baker

# Add the build and prep script and set it as the command to run
ADD build-prep.sh /build-prep.sh
RUN chmod a+rx /build-prep.sh
ADD build.sh /build.sh
CMD /build-prep.sh | tee /home/baker/build-log.txt

