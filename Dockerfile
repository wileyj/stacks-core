FROM rust:bookworm

ARG STACKS_NODE_VERSION="No Version Info"
ARG GIT_BRANCH='No Branch Info'
ARG GIT_COMMIT='No Commit Info'

WORKDIR /src

COPY . .

RUN mkdir /out

RUN rustup toolchain install stable
RUN cargo build --features monitoring_prom,slog_json --release

RUN cp -R target/release/. /out
RUN cp -R target/release/. /bin

CMD ["stacks-node", "mainnet"]
