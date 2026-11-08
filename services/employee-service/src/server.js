import { startCrudService } from '../../shared/crud-server.js';

await startCrudService({
  service: 'employee-service',
  table: 'employees',
  route: 'employees',
  port: 3103,
  fields: ['full_name', 'email', 'department', 'job_title'],
  required: ['full_name', 'email']
});
