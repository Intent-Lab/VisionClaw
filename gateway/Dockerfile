FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
# tsx is a devDependency and `npm start` runs through it, so dev deps ship too.
RUN npm ci --include=dev

COPY tsconfig.json ./
COPY src ./src
COPY public ./public

ENV NODE_ENV=production
ENV PORT=8788
EXPOSE 8788

CMD ["npm", "start"]
