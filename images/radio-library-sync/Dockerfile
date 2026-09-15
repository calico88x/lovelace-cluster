FROM alpine:3.22

RUN apk add --no-cache \
    git \
    git-lfs \
    openssh-client \
    util-linux \
    && git lfs install --system

COPY sync.sh /usr/local/bin/radio-library-sync

RUN chmod 0755 /usr/local/bin/radio-library-sync

ENTRYPOINT ["/usr/local/bin/radio-library-sync"]