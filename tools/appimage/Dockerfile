# the old base for local appimage builds (ci runs base.sh in ubuntu:22.04 itself)
FROM ubuntu:22.04
COPY base.sh /base.sh
RUN /base.sh && rm -rf /var/lib/apt/lists/*
