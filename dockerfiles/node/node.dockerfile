FROM node:22-alpine

WORKDIR /var/www/html

# Common
RUN apk add --no-cache git
RUN apk add --no-cache bash

COPY node.entrypoint /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173

ENTRYPOINT ["/entrypoint.sh"]
CMD ["npm", "run", "dev"]
