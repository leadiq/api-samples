FROM alpine:3.21

# Install the only tools the scripts need:
#   bash — the shell interpreter (Alpine only ships with sh by default)
#   curl — sends HTTP requests to the LeadIQ API
RUN apk add --no-cache bash curl

WORKDIR /app

COPY bash/ .
