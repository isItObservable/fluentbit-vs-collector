FROM cr.fluentbit.io/fluent/fluent-bit:2.2.1

RUN echo "deb http://deb.debian.org/debian bullseye-backports main" >> /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    lua-posix