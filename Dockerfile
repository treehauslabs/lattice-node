# Stage 1: Build
FROM swift:6.1-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjavascriptcoregtk-4.1-dev \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib

# Stage 2: Runtime
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    dnsutils \
    libatomic1 \
    libcurl4 \
    libjavascriptcoregtk-4.1-0 \
    libsqlite3-0 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

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
