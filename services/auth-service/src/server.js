import Fastify from 'fastify';
import jwt from '@fastify/jwt';
import bcrypt from 'bcryptjs';
import pg from 'pg';

const { Pool } = pg;

const app = Fastify({
  logger: { level: process.env.LOG_LEVEL || 'info' },
  requestIdHeader: 'x-request-id',
  bodyLimit: 1048576
});

const PORT = Number(process.env.PORT || 3102);
const HOST = process.env.HOST || '0.0.0.0';
const JWT_SECRET = process.env.JWT_SECRET;

if (!JWT_SECRET || JWT_SECRET.length < 32) {
  throw new Error('JWT_SECRET must be configured with at least 32 characters');
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.DB_POOL_SIZE || 10),
  connectionTimeoutMillis: 3000,
  idleTimeoutMillis: 30000
});

await app.register(jwt, {
  secret: JWT_SECRET,
  sign: { expiresIn: process.env.JWT_EXPIRES_IN || '15m' }
});

app.decorate('authenticate', async function (request, reply) {
  try {
    await request.jwtVerify();
  } catch {
    return reply.code(401).send({ error: 'Unauthorized' });
  }
});

app.get('/health', async () => ({
  status: 'healthy',
  service: 'auth-service'
}));

app.get('/ready', async (request, reply) => {
  try {
    await pool.query('SELECT 1');
    return { status: 'ready', service: 'auth-service' };
  } catch {
    return reply.code(503).send({
      status: 'not-ready',
      service: 'auth-service'
    });
  }
});

app.post('/api/auth/register', async (request, reply) => {
  const { email, password, fullName } = request.body || {};

  if (
    typeof email !== 'string' ||
    typeof password !== 'string' ||
    typeof fullName !== 'string'
  ) {
    return reply.code(400).send({ error: 'Email, password and fullName are required' });
  }

  const normalizedEmail = email.trim().toLowerCase();
  const normalizedName = fullName.trim();

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)) {
    return reply.code(400).send({ error: 'Invalid email address' });
  }

  if (password.length < 12 || Buffer.byteLength(password, 'utf8') > 72) {
    return reply.code(400).send({
      error: 'Password must be at least 12 characters and no more than 72 UTF-8 bytes'
    });
  }

  if (normalizedName.length < 2 || normalizedName.length > 150) {
    return reply.code(400).send({ error: 'Full name must be 2–150 characters' });
  }

  const passwordHash = await bcrypt.hash(password, 12);

  try {
    const result = await pool.query(
      `INSERT INTO users (email, password_hash, full_name)
       VALUES ($1, $2, $3)
       RETURNING id, email, full_name, role, created_at`,
      [normalizedEmail, passwordHash, normalizedName]
    );

    return reply.code(201).send({ user: result.rows[0] });
  } catch (error) {
    if (error.code === '23505') {
      return reply.code(409).send({ error: 'Email is already registered' });
    }

    request.log.error(error);
    return reply.code(500).send({ error: 'Registration failed' });
  }
});

app.post('/api/auth/login', async (request, reply) => {
  const { email, password } = request.body || {};

  if (typeof email !== 'string' || typeof password !== 'string') {
    return reply.code(400).send({ error: 'Email and password are required' });
  }

  try {
    const result = await pool.query(
      `SELECT id, email, full_name, password_hash, role, is_active
       FROM users WHERE email = $1`,
      [email.trim().toLowerCase()]
    );

    const user = result.rows[0];

    if (!user || !user.is_active || !(await bcrypt.compare(password, user.password_hash))) {
      return reply.code(401).send({ error: 'Invalid email or password' });
    }

    const accessToken = app.jwt.sign({
      sub: user.id,
      email: user.email,
      role: user.role
    });

    return {
      accessToken,
      tokenType: 'Bearer',
      expiresIn: process.env.JWT_EXPIRES_IN || '15m',
      user: {
        id: user.id,
        email: user.email,
        fullName: user.full_name,
        role: user.role
      }
    };
  } catch (error) {
    request.log.error(error);
    return reply.code(500).send({ error: 'Login failed' });
  }
});

app.get('/api/auth/me', {
  onRequest: [app.authenticate]
}, async (request, reply) => {
  try {
    const result = await pool.query(
      `SELECT id, email, full_name, role, created_at
       FROM users WHERE id = $1 AND is_active = TRUE`,
      [request.user.sub]
    );

    if (!result.rows[0]) {
      return reply.code(404).send({ error: 'User not found' });
    }

    return { user: result.rows[0] };
  } catch (error) {
    request.log.error(error);
    return reply.code(500).send({ error: 'Could not retrieve user' });
  }
});

app.addHook('onClose', async () => {
  await pool.end();
});

try {
  await app.listen({ port: PORT, host: HOST });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
