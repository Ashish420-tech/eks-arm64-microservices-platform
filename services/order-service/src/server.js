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
