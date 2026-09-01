FROM node:22-alpine

WORKDIR /var/www/html

# Common
RUN apk add --no-cache git
RUN apk add --no-cache bash
RUN apk add --no-cache shadow
RUN apk add --no-cache shadow
RUN apk add --no-cache gosu

COPY frontend.entrypoint /frontend.entrypoint
RUN sed -i 's/\r//' /frontend.entrypoint && chmod +x /frontend.entrypoint
ENTRYPOINT ["/frontend.entrypoint"]
CMD ["npm", "run", "dev"]
