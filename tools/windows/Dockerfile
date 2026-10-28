# the windows cross build (llvm-mingw), the way ci runs it: tools/windows/deps.sh, then build.sh
FROM ubuntu:24.04
ENV LANG=C.UTF-8
COPY base.sh /base.sh
RUN /base.sh && rm -rf /var/lib/apt/lists/*
