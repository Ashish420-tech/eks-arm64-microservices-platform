#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=========================================="
echo " Creating Employee, Product and Order APIs"
echo "=========================================="

# Load existing local credentials
if [[ ! -f .env ]]; then
  echo "ERROR: Root .env file not found."
  exit 1
fi

set -a
source .env
set +a

: "${DATABASE_URL:?DATABASE_URL missing from .env}"
: "${JWT_SECRET:?JWT_SECRET missing from .env}"

# 1. Shared CRUD implementation
mkdir -p services/shared

cat > services/shared/crud-server.js <<'EOF'
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

EOF

# 2. Employee Service
mkdir -p services/employee-service/src services/employee-service/migrations

cat > services/employee-service/package.json <<'EOF'
{
  "name": "employee-service",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "node --watch src/server.js",
    "start": "node src/server.js",
    "test": "node --test",
    "lint": "node --check src/server.js"
  },
  "dependencies": {
    "@fastify/jwt": "^10.0.0",
    "fastify": "^5.6.2",
    "pg": "^8.16.3"
  }
}
EOF

cat > services/employee-service/src/server.js <<'EOF'
import { startCrudService } from '../../shared/crud-server.js';

await startCrudService({
  service: 'employee-service',
  table: 'employees',
  route: 'employees',
  port: 3103,
  fields: ['full_name', 'email', 'department', 'job_title'],
  required: ['full_name', 'email']
});
EOF

cat > services/employee-service/migrations/001_create_employees.sql <<'EOF'
CREATE TABLE IF NOT EXISTS employees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name VARCHAR(150) NOT NULL,
  email VARCHAR(255) NOT NULL UNIQUE,
  department VARCHAR(100),
  job_title VARCHAR(100),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
EOF

# 3. Product Service
mkdir -p services/product-service/src services/product-service/migrations

cat > services/product-service/package.json <<'EOF'
{
  "name": "product-service",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "node --watch src/server.js",
    "start": "node src/server.js",
    "test": "node --test",
    "lint": "node --check src/server.js"
  },
  "dependencies": {
    "@fastify/jwt": "^10.0.0",
    "fastify": "^5.6.2",
    "pg": "^8.16.3"
  }
}
EOF

cat > services/product-service/src/server.js <<'EOF'
import { startCrudService } from '../../shared/crud-server.js';

await startCrudService({
  service: 'product-service',
  table: 'products',
  route: 'products',
  port: 3104,
  fields: ['name', 'sku', 'description', 'price', 'stock'],
  required: ['name', 'sku', 'price']
});
EOF

cat > services/product-service/migrations/001_create_products.sql <<'EOF'
CREATE TABLE IF NOT EXISTS products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(150) NOT NULL,
  sku VARCHAR(80) NOT NULL UNIQUE,
  description TEXT,
  price NUMERIC(12,2) NOT NULL CHECK (price >= 0),
  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
EOF

# 4. Order Service
mkdir -p services/order-service/src services/order-service/migrations

cat > services/order-service/package.json <<'EOF'
{
  "name": "order-service",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "node --watch src/server.js",
    "start": "node src/server.js",
    "test": "node --test",
    "lint": "node --check src/server.js"
  },
  "dependencies": {
    "@fastify/jwt": "^10.0.0",
    "fastify": "^5.6.2",
    "pg": "^8.16.3"
  }
}
EOF

cat > services/order-service/src/server.js <<'EOF'
import { startCrudService } from '../../shared/crud-server.js';

await startCrudService({
  service: 'order-service',
  table: 'orders',
  route: 'orders',
  port: 3105,
  fields: ['order_number', 'status', 'total_amount'],
  required: ['order_number', 'total_amount'],
  ownerField: 'customer_id'
});
EOF

cat > services/order-service/migrations/001_create_orders.sql <<'EOF'
CREATE TABLE IF NOT EXISTS orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number VARCHAR(80) NOT NULL UNIQUE,
  customer_id UUID NOT NULL REFERENCES users(id),
  status VARCHAR(30) NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
  total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON orders(customer_id);
EOF

# 5. Install all workspace dependencies
echo
echo "Installing workspace dependencies..."
npm install

# 6. Apply migrations to the existing project database
echo
echo "Applying database migrations..."

for migration in \
  services/employee-service/migrations/001_create_employees.sql \
  services/product-service/migrations/001_create_products.sql \
  services/order-service/migrations/001_create_orders.sql
do
  echo "Applying $migration"
  docker compose exec -T postgres \
    psql -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$migration"
done

# 7. Lint all three services
echo
echo "Running syntax checks..."
npm run lint --workspace=employee-service
npm run lint --workspace=product-service
npm run lint --workspace=order-service

echo
echo "=========================================="
echo " All three services created successfully"
echo "=========================================="
echo "Employee Service: http://localhost:3103"
echo "Product Service:  http://localhost:3104"
echo "Order Service:    http://localhost:3105"
echo
echo "Protected APIs require an Auth Service JWT."
echo "=========================================="
