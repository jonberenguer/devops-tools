FROM python:3.12-alpine

RUN apk add --no-cache ncurses

WORKDIR /app
COPY src/ /app/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
