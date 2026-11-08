#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
set +a

BASE=http://localhost:3101
EMAIL=ashish.devops@example.com
PASSWORD='DevOpsLab@2026Secure'

echo "===== AUTHENTICATION ====="

LOGIN=$(curl -fsS -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")

TOKEN=$(LOGIN="$LOGIN" node -e \
  'console.log(JSON.parse(process.env.LOGIN).accessToken)')

if [[ -z "$TOKEN" ]]; then
  echo "Login failed: JWT not received"
  exit 1
fi

AUTH=(-H "Authorization: Bearer $TOKEN")
JSON=(-H 'Content-Type: application/json')

echo "JWT authentication successful."

echo
echo "===== EMPLOYEE CREATE ====="

EMPLOYEE=$(curl -fsS -X POST "$BASE/api/employees" \
  "${AUTH[@]}" "${JSON[@]}" \
  -d '{"full_name":"Test Employee","email":"employee.test@example.com","department":"Engineering","job_title":"DevOps Engineer"}')

echo "$EMPLOYEE"
EMPLOYEE_ID=$(EMPLOYEE="$EMPLOYEE" node -e \
  'console.log(JSON.parse(process.env.EMPLOYEE).data.id)')

echo
echo "===== PRODUCT CREATE ====="

PRODUCT=$(curl -fsS -X POST "$BASE/api/products" \
  "${AUTH[@]}" "${JSON[@]}" \
  -d '{"name":"ARM64 Cloud Server","sku":"ARM64-001","description":"Graviton lab product","price":4999.99,"stock":10}')

echo "$PRODUCT"
PRODUCT_ID=$(PRODUCT="$PRODUCT" node -e \
  'console.log(JSON.parse(process.env.PRODUCT).data.id)')

echo
echo "===== ORDER CREATE ====="

ORDER=$(curl -fsS -X POST "$BASE/api/orders" \
  "${AUTH[@]}" "${JSON[@]}" \
  -d '{"order_number":"ORD-DEVOPS-001","status":"pending","total_amount":4999.99}')

echo "$ORDER"

echo
echo "===== EMPLOYEE LIST ====="
curl -fsS "$BASE/api/employees" "${AUTH[@]}"
echo

echo
echo "===== PRODUCT LIST ====="
curl -fsS "$BASE/api/products" "${AUTH[@]}"
echo

echo
echo "===== ORDER LIST ====="
curl -fsS "$BASE/api/orders" "${AUTH[@]}"
echo

echo
echo "===== INTEGRATION TEST COMPLETED ====="
echo "Employee ID: $EMPLOYEE_ID"
echo "Product ID:  $PRODUCT_ID"
echo "Order created successfully."
