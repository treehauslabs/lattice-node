# Stage 1: Build
FROM swift:6.0-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjavascriptcoregtk-4.1-dev \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib \
    && ldd .build/release/LatticeNode > /build/ldd-output.txt 2>&1 || true

# Stage 2: Runtime
FROM ubuntu:22.04

COPY --from=builder /build/ldd-output.txt /tmp/ldd-output.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libjavascriptcoregtk-4.1-0 \
    libsqlite3-0 \
    dnsutils \
    && rm -rf /var/lib/apt/lists/* \
    && echo "=== Binary dependencies ===" && cat /tmp/ldd-output.txt && echo "=== End ===" \
    && rm /tmp/ldd-output.txt

COPY --from=builder /build/.build/release/LatticeNode /usr/local/bin/lattice-node

RUN useradd -m -s /bin/bash lattice
USER lattice

VOLUME /home/lattice/.lattice
EXPOSE 4001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD grep -q "status: OK" /home/lattice/.lattice/health || exit 1

ENTRYPOINT ["lattice-node"]
CMD ["--mine", "Nexus", "--autosize", "--data-dir", "/home/lattice/.lattice"]
