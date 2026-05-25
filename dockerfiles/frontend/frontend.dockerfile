FROM node:22-alpine

WORKDIR /var/www/html

# Common
RUN apk add --no-cache git
RUN apk add --no-cache bash

COPY frontend.entrypoint /frontend.entrypoint
RUN sed -i 's/\r//' /frontend.entrypoint && chmod +x /frontend.entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["npm", "run", "dev"]
