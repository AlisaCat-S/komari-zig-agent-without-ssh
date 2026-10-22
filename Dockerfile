FROM alpine:3.21

RUN addgroup -S komari && adduser -S -D -H -G komari komari \
    && mkdir -p /var/lib/komari-agent \
    && chown komari:komari /var/lib/komari-agent \
    && chmod 0750 /var/lib/komari-agent

WORKDIR /app

ARG TARGETOS
ARG TARGETARCH

COPY --chown=root:root komari-agent-${TARGETOS}-${TARGETARCH} /app/komari-agent
RUN chmod 0555 /app/komari-agent && touch /.komari-agent-container

USER komari:komari
WORKDIR /var/lib/komari-agent

ENTRYPOINT ["/app/komari-agent"]
CMD ["--help"]
