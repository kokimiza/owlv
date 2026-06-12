# ─── Build stage ────────────────────────────────────────────────────────────
FROM haskell:9.14.1 AS build

# libpq-dev: postgresql-simple のビルドに必要
# pkg-config: cabal.project.docker の pkgconfig-depends: libpq に必要
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# .cabal と project ファイルを先にコピーして依存解決をキャッシュする
COPY owlv.cabal .
COPY cabal.project.docker cabal.project

RUN cabal update \
 && cabal build --only-dependencies all

# ソースをコピーしてビルド
COPY app/ app/
COPY src/ src/
COPY test/ test/

RUN cabal build exe:owlv \
 && cp "$(cabal list-bin owlv)" /usr/local/bin/owlv

# ─── Runtime stage ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

# libpq5:    PostgreSQL クライアントランタイム
# libgmp10:  GHC ランタイム (Integer / bignum)
# libffi8:   GHC ランタイム (FFI コール)
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libgmp10 libffi8 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/owlv /usr/local/bin/owlv

CMD ["/usr/local/bin/owlv"]
