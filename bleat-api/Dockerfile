FROM rust:1.97-bookworm AS build

WORKDIR /workspace
COPY bleat-api/Cargo.toml bleat-api/Cargo.lock bleat-api/
COPY bleat-api/src bleat-api/src
COPY bleat-api/tests bleat-api/tests
COPY bleat-api/trust bleat-api/trust
RUN cargo build --locked --manifest-path bleat-api/Cargo.toml --release

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

COPY --from=build --chown=nonroot:nonroot /workspace/bleat-api/target/release/bleat-api /usr/local/bin/bleat-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bleat-api"]
