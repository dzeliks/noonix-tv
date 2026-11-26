# the oldest browser engines lg and samsung tvs run (chromium 53, 56: snapshot builds mounted at /engines), for tools/smoke-engines.sh
FROM ubuntu:16.04
RUN apt-get update && apt-get install -y --no-install-recommends xvfb libgtk2.0-0 libgconf-2-4 libnss3 libxss1 \
    libasound2 libxtst6 libxrandr2 libatk1.0-0 libcups2 fonts-dejavu-core ca-certificates python3 && rm -rf /var/lib/apt/lists/*
