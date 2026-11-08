import Fastify from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';

const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL || 'info'
  },
  requestIdHeader: 'x-request-id',
  bodyLimit: 1048576
});

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';

const services = {
  auth: process.env.AUTH_SERVICE_URL || 'http://localhost:3001',
  employees: process.env.EMPLOYEE_SERVICE_URL || 'http://localhost:3002',
  products: process.env.PRODUCT_SERVICE_URL || 'http://localhost:3003',
  orders: process.env.ORDER_SERVICE_URL || 'http://localhost:3004'
};

await app.register(helmet);

await app.register(cors, {
  origin: process.env.CORS_ORIGIN
    ? process.env.CORS_ORIGIN.split(',')
    : false
});

await app.register(rateLimit, {
  max: Number(process.env.RATE_LIMIT_MAX || 100),
  timeWindow: '1 minute'
});

app.get('/health', async () => ({
  status: 'healthy',
  service: 'api-gateway'
}));

app.get('/ready', async () => ({
  status: 'ready',
  service: 'api-gateway'
}));

async function proxyRequest(request, reply, serviceUrl) {
  const targetUrl = new URL(
    request.raw.url,
    serviceUrl
  );

  const headers = {};

  for (const name of [
    'authorization',
    'content-type',
    'accept',
    'x-request-id'
  ]) {
    const value = request.headers[name];
    if (value) headers[name] = value;
  }

  headers['x-request-id'] = request.id;

  try {
    const response = await fetch(targetUrl, {
      method: request.method,
      headers,
      body: ['GET', 'HEAD'].includes(request.method)
        ? undefined
        : request.body === undefined
          ? undefined
          : JSON.stringify(request.body),
      signal: AbortSignal.timeout(10000)
    });

    reply.code(response.status);

    const contentType = response.headers.get('content-type');
    if (contentType) {
      reply.header('content-type', contentType);
    }

    const responseBody = await response.arrayBuffer();

    return reply.send(Buffer.from(responseBody));
  } catch (error) {
    request.log.error({
      error: error.message,
      serviceUrl,
      requestId: request.id
    }, 'Backend service request failed');

    return reply.code(502).send({
      error: 'Bad Gateway',
      message: 'Backend service is unavailable',
      requestId: request.id
    });
  }
}

const routes = [
  ['/api/auth', services.auth],
  ['/api/employees', services.employees],
  ['/api/products', services.products],
  ['/api/orders', services.orders]
];

for (const [prefix, serviceUrl] of routes) {
  app.all(prefix, (request, reply) =>
    proxyRequest(request, reply, serviceUrl)
  );

  app.all(`${prefix}/*`, (request, reply) =>
    proxyRequest(request, reply, serviceUrl)
  );
}

app.setErrorHandler((error, request, reply) => {
  request.log.error(error);

  reply.code(error.statusCode || 500).send({
    error: error.statusCode >= 500
      ? 'Internal Server Error'
      : error.message,
    requestId: request.id
  });
});

try {
  await app.listen({ port: PORT, host: HOST });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
