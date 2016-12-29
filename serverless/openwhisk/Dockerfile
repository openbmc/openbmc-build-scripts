FROM openwhisk/dockerskeleton

ENV FLASK_PROXY_PORT 8080

ENV DEBIAN_FRONTEND noninteractive
RUN apk add --no-cache \
        coreutils \
        sdl \
        perl \
        findutils \
        bzip2 \
        patch \
        g++ \
        gcc \
        make \
        chrpath \
        gawk \
        git \
        python \
        socat \
        subversion \
        texinfo \
        wget \
	bzip2-dev \
	libc-dev \
	file \
	tar \
	bash

# Using edge. Should get this off of edge/testing ASAP
RUN apk add diffstat --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/testing/ --allow-untrusted

ADD exec.c /action/exec.c

# Link /bin/sh to bash
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Build the exec binary
RUN cd /action; gcc -o exec exec.c \
 && cd ..
ADD build.sh /workspace/build.sh
ADD openbmc /workspace/openbmc

RUN adduser -D baker

RUN chown baker:baker /action/exec
RUN chown -R baker:baker /workspace

USER baker

CMD ["/bin/bash", "-c", "cd actionProxy && python -u actionproxy.py"]

