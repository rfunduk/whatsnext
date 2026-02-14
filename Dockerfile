FROM docker.io/alpine:3.21 AS build

RUN apk add --no-cache \
    bash curl unzip \
    cmake make gcc clang19 lld musl-dev \
    zlib-dev zlib-static \
    libpng-dev libpng-static \
    libjpeg-turbo-dev libjpeg-turbo-static \
    sqlite-dev sqlite-static

# Odin compiler (glibc binary — needs gcompat to run on musl)
ARG ODIN_VERSION=dev-2026-02
RUN apk add --no-cache gcompat && \
    curl -sL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
    | tar -xzf - -C /opt --strip-components=1 && \
    ln -s /opt/odin /usr/local/bin/odin

WORKDIR /whatsnext

# Tailwind standalone CLI: musl variant (bin/setup downloads glibc one)
RUN mkdir -p build && \
    curl -sL "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-x64-musl" \
    -o build/tailwindcss && \
    chmod +x build/tailwindcss

# Vendor deps layer — only rebuilds when setup script or lib bindings change
COPY bin/setup bin/setup
COPY lib/ lib/
RUN bin/setup

# Source + build — rebuilds on any code/template/style change
COPY . .
ENV PREFIX=/usr/local/bin
RUN bin/build release --static

# ---------------------------------------------------------------------------
FROM scratch

COPY --from=build /whatsnext/build/release/whatsnext /app/whatsnext
COPY --from=build /whatsnext/templates/              /app/templates/
COPY --from=build /whatsnext/migrations/             /app/migrations/
COPY --from=build /whatsnext/static/                 /app/static/
COPY --from=build /whatsnext/vendor/fonts/           /app/vendor/fonts/

WORKDIR /app
EXPOSE 8020
CMD ["./whatsnext", "data/whatsnext.db"]
