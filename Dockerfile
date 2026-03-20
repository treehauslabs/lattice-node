# Stage 1: Build
FROM swift:6.0-jammy AS builder

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
RUN swift build -c release --static-swift-stdlib

# Stage 2: Runtime
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/.build/release/LatticeNode /usr/local/bin/lattice-node

RUN useradd -m -s /bin/bash lattice
USER lattice

VOLUME /home/lattice/.lattice
EXPOSE 4001

ENTRYPOINT ["lattice-node"]
CMD ["--mine", "Nexus", "--data-dir", "/home/lattice/.lattice"]
