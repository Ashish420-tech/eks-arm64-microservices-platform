import { startCrudService } from '../../shared/crud-server.js';

await startCrudService({
  service: 'product-service',
  table: 'products',
  route: 'products',
  port: 3104,
  fields: ['name', 'sku', 'description', 'price', 'stock'],
  required: ['name', 'sku', 'price']
});
