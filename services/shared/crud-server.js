import Fastify from 'fastify';
import jwt from '@fastify/jwt';
import pg from 'pg';

const { Pool } = pg;

export async function startCrudService(config) {
  const app = Fastify({
    logger: true,
    bodyLimit: 1048576,
    requestIdHeader: 'x-request-id'
  });

  const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    max: Number(process.env.DB_POOL_SIZE || 10),
    connectionTimeoutMillis: 3000,
    idleTimeoutMillis: 30000
  });

  const { table, route, fields, required = [], ownerField = null } = config;

  if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
    throw new Error('JWT_SECRET must contain at least 32 characters');
  }

  await app.register(jwt, {
    secret: process.env.JWT_SECRET
  });

  app.decorate('authenticate', async (request, reply) => {
    try {
      await request.jwtVerify();
    } catch {
      return reply.code(401).send({ error: 'Unauthorized' });
    }
  });

  app.get('/health', async () => ({
    status: 'healthy',
    service: config.service
  }));

  app.get('/ready', async (_request, reply) => {
    try {
      await pool.query('SELECT 1');
      return { status: 'ready', service: config.service };
    } catch {
      return reply.code(503).send({ status: 'not-ready' });
    }
  });

  const base = `/api/${route}`;

  // List records with pagination
  app.get(base, { preHandler: app.authenticate }, async (request) => {
    const limit = Math.min(
      Math.max(Number.parseInt(request.query.limit, 10) || 20, 1),
      100
    );
    const offset = Math.max(
      Number.parseInt(request.query.offset, 10) || 0,
      0
    );

    const values = [];
    let where = '';

    if (ownerField) {
      values.push(request.user.sub);
      where = `WHERE ${ownerField} = $1`;
    }

    values.push(limit, offset);

    const result = await pool.query(
      `SELECT * FROM ${table} ${where}
       ORDER BY created_at DESC
       LIMIT $${values.length - 1} OFFSET $${values.length}`,
      values
    );

    return {
      data: result.rows,
      pagination: { limit, offset, count: result.rowCount }
    };
  });

  // Create record
  app.post(base, { preHandler: app.authenticate }, async (request, reply) => {
    const body = request.body || {};
    const data = {};

    for (const field of fields) {
      if (body[field] !== undefined) data[field] = body[field];
    }

    if (ownerField) data[ownerField] = request.user.sub;

    for (const field of required) {
      if (data[field] === undefined || data[field] === null || data[field] === '') {
        return reply.code(400).send({ error: `${field} is required` });
      }
    }

    const keys = Object.keys(data);

    try {
      const values = keys.map((key) => data[key]);
      const columns = keys.join(', ');
      const placeholders = keys.map((_, i) => `$${i + 1}`).join(', ');

      const result = await pool.query(
        `INSERT INTO ${table} (${columns})
         VALUES (${placeholders}) RETURNING *`,
        values
      );

      return reply.code(201).send({ data: result.rows[0] });
    } catch (error) {
      if (error.code === '23505') {
        return reply.code(409).send({ error: 'Record already exists' });
      }
      if (error.code === '23503') {
        return reply.code(400).send({ error: 'Referenced record does not exist' });
      }
      throw error;
    }
  });

  // Get one record
  app.get(`${base}/:id`, { preHandler: app.authenticate }, async (request, reply) => {
    const values = [request.params.id];
    let where = 'id = $1';

    if (ownerField) {
      values.push(request.user.sub);
      where += ` AND ${ownerField} = $2`;
    }

    const result = await pool.query(
      `SELECT * FROM ${table} WHERE ${where}`,
      values
    );

    if (!result.rowCount) {
      return reply.code(404).send({ error: 'Record not found' });
    }

    return { data: result.rows[0] };
  });

  // Update record
  app.put(`${base}/:id`, { preHandler: app.authenticate }, async (request, reply) => {
    const body = request.body || {};
    const data = {};

    for (const field of fields) {
      if (body[field] !== undefined) data[field] = body[field];
    }

    const keys = Object.keys(data);

    if (!keys.length) {
      return reply.code(400).send({ error: 'No valid fields supplied' });
    }

    const values = keys.map((key) => data[key]);
    values.push(request.params.id);

    let where = `id = $${values.length}`;

    if (ownerField) {
      values.push(request.user.sub);
      where += ` AND ${ownerField} = $${values.length}`;
    }

    const assignments = keys.map(
      (key, i) => `${key} = $${i + 1}`
    );

    try {
      const result = await pool.query(
        `UPDATE ${table}
         SET ${assignments.join(', ')}, updated_at = NOW()
         WHERE ${where} RETURNING *`,
        values
      );

      if (!result.rowCount) {
        return reply.code(404).send({ error: 'Record not found' });
      }

      return { data: result.rows[0] };
    } catch (error) {
      if (error.code === '23505') {
        return reply.code(409).send({ error: 'Record already exists' });
      }
      throw error;
    }
  });

  // Delete record
  app.delete(`${base}/:id`, { preHandler: app.authenticate }, async (request, reply) => {
    const values = [request.params.id];
    let where = 'id = $1';

    if (ownerField) {
      values.push(request.user.sub);
      where += ' AND customer_id = $2';
    }

    const result = await pool.query(
      `DELETE FROM ${table} WHERE ${where} RETURNING id`,
      values
    );

    if (!result.rowCount) {
      return reply.code(404).send({ error: 'Record not found' });
    }

    return { message: 'Record deleted', id: result.rows[0].id };
  });

  app.setErrorHandler((error, request, reply) => {
    request.log.error(error);
    reply.code(error.statusCode || 500).send({
      error: error.statusCode ? error.message : 'Internal server error'
    });
  });

  app.addHook('onClose', async () => pool.end());

  const port = Number(process.env.PORT || config.port);
  await app.listen({ port, host: '0.0.0.0' });
}
