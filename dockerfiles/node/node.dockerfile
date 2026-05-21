FROM node:22-alpine

WORKDIR /var/www/html

# Install git (needed by some npm packages)
RUN apk add --no-cache git

COPY node.entrypoint /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173

ENTRYPOINT ["/entrypoint.sh"]
CMD ["npm", "run", "dev"]
