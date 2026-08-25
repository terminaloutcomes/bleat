ARG BLEAT_API_IMAGE_NAME="bleat-api"
ARG BLEAT_API_IMAGE_VERSION="development"

FROM rust:1.97-bookworm AS build

ARG ADD_BUILD_ARGS=" --quiet"
ARG BLEAT_API_IMAGE_NAME
ARG BLEAT_API_IMAGE_VERSION

ENV RUSTFLAGS="-Clinker=clang"

RUN apt-get update && apt-get install -y --no-install-recommends clang ca-certificates && rm -rf /var/lib/apt/lists/* && apt-get clean

ENV BLEAT_API_IMAGE_NAME=${BLEAT_API_IMAGE_NAME}
ENV BLEAT_API_IMAGE_VERSION=${BLEAT_API_IMAGE_VERSION}

WORKDIR /workspace

COPY bleat-api/Cargo.toml bleat-api/Cargo.lock bleat-api/
COPY bleat-api/src bleat-api/src
COPY bleat-api/tests bleat-api/tests
COPY bleat-api/trust bleat-api/trust

RUN cd bleat-api && cargo build --locked --release $ADD_BUILD_ARGS

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

ARG BLEAT_API_IMAGE_NAME
ARG BLEAT_API_IMAGE_VERSION

LABEL org.opencontainers.image.title=${BLEAT_API_IMAGE_NAME}
LABEL org.opencontainers.image.version=${BLEAT_API_IMAGE_VERSION}

COPY --from=build --chown=nonroot:nonroot /workspace/bleat-api/target/release/bleat-api /usr/local/bin/bleat-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bleat-api"]
