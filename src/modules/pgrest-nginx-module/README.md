# pgrest-nginx-module

A PostgREST-like nginx module written in Zig that provides a RESTful API for PostgreSQL databases.

## Module Layout

The pgrest implementation is no longer a single growing file. The current split keeps nginx-facing module glue in `ngx_http_pgrest.zig` and moves reusable logic into focused submodules:

- `ngx_http_pgrest.zig` - nginx module entrypoint, directives, request orchestration, pooled execution glue
- `pgrest_auth.zig` - JWT extraction/validation and query helpers with Zig tests
- `pgrest_query.zig` - SQL grammar, table query builders, and write-query helpers with Zig tests
- `pgrest_rpc.zig` - RPC metadata/query-shaping helpers with Zig tests

This split is intentionally mechanical so future batches can grow one concern without dragging the whole module into context.

## Current Hard Limits

`pgrest` now correctly reconstructs nginx temp-file-spilled request bodies, so large-body handling is no longer limited by the old in-memory-only transport path. But the module still has several explicit fixed-size parser and query ceilings. Those are hard limits today, not soft guidance:

| Area | Limit | Source |
|---|---:|---|
| SQL query buffer | `4096` bytes | `pgrest_query.zig:MAX_QUERY_SIZE` |
| Response JSON formatting buffer | `65536` bytes | `ngx_http_pgrest.zig:MAX_JSON_SIZE` |
| SQL parameter arena | `8192` bytes total | `ngx_http_pgrest.zig:MAX_PARAM_BUFFER` |
| Write columns per row | `32` | `pgrest_query.zig:MAX_COLUMNS` |
| Select columns | `32` | `pgrest_query.zig:MAX_SELECT_COLUMNS` |
| Order columns | `8` | `pgrest_query.zig:MAX_ORDER_COLUMNS` |
| Filters | `16` | `pgrest_query.zig:MAX_FILTERS` |
| Bulk write rows | `16` | `ngx_http_pgrest.zig:MAX_WRITE_ROWS` |
| JSON/form field name scratch | `256` bytes per field name | `pgrest_query.zig:name_buf`, `ngx_http_pgrest.zig` write-field storage |
| Query/filter field value scratch | `1024` bytes per field value | `pgrest_query.zig:value_buf` |
| JSON parser scratch for single-object write bodies | `< 4096` body bytes | `ngx_http_pgrest.zig` object-body parsing path |
| JSON parser scratch for RPC JSON bodies | `< 4096` body bytes | `ngx_http_pgrest.zig` RPC body parsing path |
| JSON parser scratch for bulk JSON array writes | `< 8192` body bytes | `ngx_http_pgrest.zig` bulk-array parsing path |
| CSV single-row field value | `1024` bytes per field | `ngx_http_pgrest.zig:MAX_CSV_VALUE_LEN` |
| RPC parameter count | `16` | `pgrest_rpc.zig:MAX_RPC_PARAMS` |
| RPC parameter encoded-value scratch | `2048` bytes | `pgrest_rpc.zig:RpcParam.value_buf` |
| RPC variadic parameter name scratch | `128` bytes | `pgrest_rpc.zig:variadic_param_name_buf` |
| RPC input-parameter names scratch | `256` bytes | `pgrest_rpc.zig:input_param_names_buf` |

Important nuance:

- The spill-file fix means plain text and raw RPC request bodies are no longer artificially capped by the old local copy buffers on the transport path.
- That does **not** mean every `pgrest` request body is effectively unbounded. JSON write bodies, JSON RPC bodies, SQL generation, parameter shaping, and response formatting still run into the fixed ceilings above.
- Requests that exceed the active parameter/query/parser budget should fail explicitly rather than degrading into partial parsing or mixed raw/parameterized SQL.

## Features

### Core Features
- **RESTful CRUD operations** - Maps HTTP methods to SQL operations
- **PostgREST-compatible filtering** - Query string filters like `?column=op.value`
- **Column selection** - Select specific columns with `?select=col1,col2`
- **Resource embedding** - Direct FK one-to-one/one-to-many plus many-to-many embedding with nested JSON reads on the table path
- **Ordering** - Sort results with `?order=column.desc`
- **Pagination** - Limit/offset with `?limit=N&offset=M`
- **JSON response formatting** - Query results returned as JSON array
- **Non-blocking I/O** - Connection pooling with async operations

### RPC/Stored Procedures
- **RPC/Stored Procedures** - Call PostgreSQL functions via `/rpc/function_name`
- **Smart response formatting** - Auto-detects scalar, object, or array results
- **Request body media parsing** - `application/json`, `application/x-www-form-urlencoded`, `text/csv`, `text/plain`, `text/xml`, and `application/octet-stream` with explicit narrow mappings for supported function and table parameters
- **Query string parameters** - GET requests with function parameters

### Response Format Control
- **Accept header negotiation** - `Accept: application/json`, `text/csv`, `text/plain`, `text/xml`, `application/octet-stream`
- **Multiple format support** - JSON, CSV, plain text, XML, and deterministic octet-stream output formats
- **Schema selection** - `Accept-Profile` for GET/HEAD, `Content-Profile` for POST/PATCH/PUT/DELETE, with `pgrest_schemas` allowlist enforcement and first-schema default selection
- **RPC parameter wrapping** - `Prefer: params=single-object` header for single JSON object parameters

## Configuration

```nginx
location /api/ {
    # Connection string for PostgreSQL
    pgrest_pass "host=localhost dbname=mydb user=postgres password=secret";
}
```

## JWT Authentication

pgrest supports JWT authentication that integrates directly with PostgreSQL. The JWT token is passed to PostgreSQL via the `request.jwt` claim, allowing your database functions to enforce authorization and access control.

### How It Works

1. Client sends a request with `Authorization: Bearer <JWT_TOKEN>` header
2. nginz extracts the JWT token from the Authorization header
3. nginz executes `SET request.jwt TO '<token>'` in PostgreSQL before running the query
4. PostgreSQL functions can access the JWT via `current_setting('request.jwt')`
5. Your functions can validate and use JWT claims for authorization

### Basic Configuration

No special configuration needed for basic JWT passthrough. Just send JWT tokens in the `Authorization` header using the standard Bearer scheme.

### Role-Based Access Control (PostgREST-style)

pgrest supports automatic PostgreSQL role switching based on JWT claims. This enables Row-Level Security (RLS) policies that work transparently with your API.

#### Configuration

```nginx
location /api/ {
    pgrest_pass "host=localhost dbname=mydb user=authenticator password=secret";

    # JWT secret for HS256 signature validation
    pgrest_jwt_secret "your-256-bit-secret-key-here";

    # Default role when no valid JWT is provided
    pgrest_anon_role "anon";

    # JWT claim containing the role (default: "role")
    pgrest_jwt_role_claim "role";
}
```

#### How Role Switching Works

1. Client sends request with JWT containing a `role` claim
2. nginz validates the JWT signature using `pgrest_jwt_secret`
3. If valid, nginz extracts the role from the JWT and executes `SET ROLE '<role>'`
4. If invalid or missing, nginz uses `pgrest_anon_role`
5. PostgreSQL RLS policies now apply based on the current role

#### JWT Token Structure

Your JWT should include a `role` claim:

```json
{
  "sub": "user123",
  "role": "authenticated_user",
  "email": "user@example.com",
  "exp": 1704067200
}
```

#### PostgreSQL Setup

```sql
-- Create roles
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated_user NOLOGIN;

-- The authenticator role that pgrest connects as
CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'secret';
GRANT anon TO authenticator;
GRANT authenticated_user TO authenticator;

-- Create table with RLS
CREATE TABLE documents (
  id serial PRIMARY KEY,
  owner_id text NOT NULL,
  title text,
  content text
);

-- Enable RLS
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Anonymous users can only read public documents
CREATE POLICY anon_read ON documents FOR SELECT TO anon
  USING (owner_id = 'public');

-- Authenticated users can read their own documents
CREATE POLICY user_read ON documents FOR SELECT TO authenticated_user
  USING (owner_id = current_setting('request.jwt', true)::json->>'sub');

-- Authenticated users can insert their own documents
CREATE POLICY user_insert ON documents FOR INSERT TO authenticated_user
  WITH CHECK (owner_id = current_setting('request.jwt', true)::json->>'sub');
```

#### Directives

| Directive | Description |
|-----------|-------------|
| `pgrest_jwt_secret` | HS256 secret key for JWT signature validation |
| `pgrest_anon_role` | PostgreSQL role to use when no valid JWT is provided |
| `pgrest_jwt_role_claim` | JWT claim name containing the role (default: "role") |

### Usage Examples

#### Basic JWT Usage in Functions

```sql
-- Function that accesses JWT claims
CREATE OR REPLACE FUNCTION get_user_profile() 
RETURNS TABLE(id integer, name text, email text) AS $$
  DECLARE
    jwt_token text;
    user_id integer;
  BEGIN
    -- Get the JWT token passed from nginz
    jwt_token := current_setting('request.jwt', true);
    
    IF jwt_token IS NULL THEN
      RAISE EXCEPTION 'Unauthorized: No JWT provided';
    END IF;
    
    -- In production, you would decode the JWT and extract claims
    -- For this example, we just use it to verify presence
    RETURN QUERY
      SELECT u.id, u.name, u.email
      FROM users u
      WHERE u.id = 1;  -- In production, extract user_id from JWT
  END;
$$ LANGUAGE plpgsql;
```

#### Client-Side Request

```bash
# Include JWT in Authorization header
curl -X GET "http://localhost/rpc/get_user_profile" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
```

### Row-Level Security (RLS)

Combine JWT authentication with PostgreSQL Row-Level Security for powerful access control:

```sql
-- Create a table with RLS
CREATE TABLE documents (
  id serial PRIMARY KEY,
  owner_id integer NOT NULL,
  title text,
  content text
);

-- Enable RLS
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Create a policy that uses JWT claims
CREATE POLICY user_documents ON documents
  USING (owner_id = CAST((current_setting('request.jwt', true) -> 'user_id')::text AS integer));

-- Create a function
CREATE OR REPLACE FUNCTION get_my_documents()
RETURNS TABLE(id integer, title text, content text) AS $$
  SELECT id, title, content FROM documents;
$$ LANGUAGE SQL;
```

#### Client Request (with JWT)

```bash
# PostgreSQL RLS will automatically filter results based on JWT claims
curl -X GET "http://localhost/rpc/get_my_documents" \
  -H "Authorization: Bearer <JWT_WITH_USER_ID_CLAIM>"

# Response will only include documents where owner_id matches the JWT claim
```

### JWT Token Structure

The JWT token is passed as-is to PostgreSQL. Your functions receive the entire token string via `current_setting('request.jwt')`. 

To use JWT claims, you'll need to:
1. Decode the JWT in your PostgreSQL function using an extension like `pgcrypto` or `pgjwt`
2. OR use a trusted JWT validation in your application before passing to nginz
3. OR validate the JWT signature in a PostgreSQL function

### Example: Decoding JWT in PostgreSQL

```sql
-- Using the pgjwt extension (if installed)
CREATE OR REPLACE FUNCTION get_user_from_jwt()
RETURNS TABLE(user_id integer, role text, email text) AS $$
  SELECT 
    (jwt_claims ->> 'sub')::integer,
    jwt_claims ->> 'role',
    jwt_claims ->> 'email'
  FROM (
    SELECT jwt_decode(current_setting('request.jwt'), 'secret-key') as jwt_claims
  ) decoded;
$$ LANGUAGE SQL;
```

### Security Best Practices

1. **Always use HTTPS** - JWT tokens must be transmitted securely
2. **Validate JWT signature** - Validate the JWT signature in your PostgreSQL functions
3. **Set short expiration times** - Use JWT `exp` claim with reasonable TTL
4. **Use environment variables** - Store JWT secret keys in environment variables, not in code
5. **Combine with RLS** - Use PostgreSQL Row-Level Security for data access control
6. **Rate limiting** - Implement rate limiting at the nginx level to prevent abuse

### Comparison with PostgREST

**PostgREST:**
- Supports JWT validation with signature verification
- Can set PostgreSQL role from JWT `role` claim
- Supports JWT audience and issuer validation

**nginz pgrest (this implementation):**
- Passes raw JWT token to PostgreSQL via `request.jwt` claim
- Allows custom JWT validation in PostgreSQL functions
- More flexible - your functions control validation logic
- Simpler integration - no external JWT library needed

Both approaches allow PostgreSQL functions to access JWT data for authorization decisions.

## RPC (Remote Procedure Call) - Stored Procedures

Call PostgreSQL stored functions and procedures via HTTP endpoints. Perfect for complex operations involving multiple tables or business logic.

### Configuration

```nginx
location /rpc/ {
    # PostgreSQL connection string
    pgrest_pass "host=localhost dbname=mydb user=postgres password=secret";
}
```

### Usage

Call stored functions with the `/rpc/function_name` endpoint:

```bash
# Simple function call (GET)
curl "http://localhost/rpc/get_user_count"

# Function with query string parameters (GET)
curl "http://localhost/rpc/get_users_by_status?status=active&limit=10"

# Function with JSON body (POST) - NEW!
curl -X POST "http://localhost/rpc/add_them" \
  -H "Content-Type: application/json" \
  -d '{"a": 1, "b": 2}'

# Complex POST request
curl -X POST "http://localhost/rpc/create_order" \
  -H "Content-Type: application/json" \
  -d '{"user_id": 5, "amount": 100.50, "status": "pending"}'
```

### Array Parameters

pgrest supports JSON arrays as function parameters. Arrays are automatically converted to PostgreSQL `ARRAY[...]` syntax:

```bash
# Array of numbers
curl -X POST "http://localhost/rpc/process_numbers" \
  -H "Content-Type: application/json" \
  -d '{"ids": [1, 2, 3, 4, 5]}'
# Calls: process_numbers(ids => ARRAY[1,2,3,4,5])

# Array of strings
curl -X POST "http://localhost/rpc/add_users" \
  -H "Content-Type: application/json" \
  -d '{"names": ["Alice", "Bob", "Charlie"]}'
# Calls: add_users(names => ARRAY['Alice','Bob','Charlie'])

# Mixed with other parameters
curl -X POST "http://localhost/rpc/create_items" \
  -H "Content-Type: application/json" \
  -d '{"user_id": 42, "tags": ["important", "urgent"], "status": "active"}'
# Calls: create_items(user_id => 42, tags => ARRAY['important','urgent'], status => 'active')
```

**Function signature example:**
```sql
CREATE FUNCTION process_numbers(ids integer[]) RETURNS TABLE(id integer, squared integer) AS $$
  SELECT unnest(ids) as id, unnest(ids) * unnest(ids) as squared;
$$ LANGUAGE SQL;
```

### Parameter Passing Methods

Current metadata-backed RPC notes:

- `GET` and `HEAD` are currently allowed only when the function metadata resolves to non-`VOLATILE`; `VOLATILE` functions return `405` with `Allow: OPTIONS,POST`.
- Single unnamed `json/jsonb`, `text`, `xml`, and `bytea` parameters now use positional RPC calls from matching request-body media types.
- Variadic RPC parameters now collapse repeated GET query parameters and repeated `application/x-www-form-urlencoded` body parameters into one PostgreSQL `ARRAY[...]` argument when the function metadata marks that parameter as variadic.
- Table-valued/composite-return RPC functions now reuse the table read grammar for `select`, filters, ordering, and pagination, while separating true function arguments from read-shaping query parameters.
- Named JSON/form RPC calls continue to use named PostgreSQL arguments, and `Prefer: params=single-object` still uses the existing named wrapper behavior.

#### Method 1: Query String Parameters (GET)

For simple function calls with a few parameters, use query string parameters:

```bash
curl "http://localhost/rpc/add_them?a=1&b=2"
```

Parameters are passed directly to the function:
- `?a=1&b=2` → `add_them(a => 1, b => 2)`
- `?status=active&limit=10` → `function(status => 'active', limit => 10)`

**Limitations:**
- Query string values are always treated as strings
- Complex data types (arrays, objects) not supported
- URL encoding required for special characters

#### Method 2: JSON Request Body (POST) - Recommended for Complex Data

For functions with multiple parameters or complex data types, use JSON request body:

```bash
curl -X POST "http://localhost/rpc/add_them" \
  -H "Content-Type: application/json" \
  -d '{"a": 1, "b": 2}'
```

**Key Features:**
- JSON object keys are automatically mapped to function parameter names
- Preserves data types (numbers, booleans, nulls)
- Cleaner syntax for multiple parameters
- Supports all PostgreSQL scalar types

**Examples:**

```bash
# Simple function call
curl -X POST "http://localhost/rpc/add_them" \
  -H "Content-Type: application/json" \
  -d '{"a": 1, "b": 2}'
# Maps to: add_them(a => 1, b => 2)

# Create user with multiple parameters
curl -X POST "http://localhost/rpc/create_user" \
  -H "Content-Type: application/json" \
  -d '{"user_id": 5, "email": "test@example.com", "is_active": true}'
# Maps to: create_user(user_id => 5, email => 'test@example.com', is_active => true)

# With null values
curl -X POST "http://localhost/rpc/update_profile" \
  -H "Content-Type: application/json" \
  -d '{"user_id": 42, "bio": null, "is_verified": true}'
# Maps to: update_profile(user_id => 42, bio => NULL, is_verified => true)
```

**Data Type Mapping:**

| JSON Type | PostgreSQL Type | Example |
|-----------|-----------------|---------|
| String | `text`, `varchar` | `"email": "user@example.com"` |
| Number | `integer`, `bigint`, `decimal`, `float` | `"age": 25`, `"price": 99.99` |
| Boolean | `boolean` | `"is_active": true` |
| Null | `NULL` | `"bio": null` |

**Advantages over Query String:**
- Preserves numeric types (not all strings)
- Direct boolean values (true/false, not "true"/"false" strings)
- Proper null handling
- More readable for multiple parameters
- Standard REST convention for POST

### Function Signature Examples

Here's how to define stored functions that work with pgrest RPC:

```sql
-- Function returning a scalar value
CREATE FUNCTION get_user_count() RETURNS integer AS $$
  SELECT COUNT(*) FROM users;
$$ LANGUAGE SQL;

-- Function with parameters
CREATE FUNCTION get_users_by_status(status text) RETURNS TABLE(id int, name text, email text) AS $$
  SELECT id, name, email FROM users WHERE status = $1;
$$ LANGUAGE SQL;

-- Function returning a single object
CREATE FUNCTION get_user(user_id int) RETURNS TABLE(id int, name text, email text) AS $$
  SELECT id, name, email FROM users WHERE id = $1;
$$ LANGUAGE SQL;

-- Function with multiple parameters
CREATE FUNCTION search_products(category text, price_max decimal) 
RETURNS TABLE(id int, name text, price decimal) AS $$
  SELECT id, name, price 
  FROM products 
  WHERE category = $1 AND price <= $2
  ORDER BY price;
$$ LANGUAGE SQL;

-- Procedure with side effects (INSERT, UPDATE, DELETE)
CREATE FUNCTION create_user(name text, email text) 
RETURNS TABLE(id int, name text, email text) AS $$
  INSERT INTO users(name, email) 
  VALUES($1, $2) 
  RETURNING id, name, email;
$$ LANGUAGE SQL;
```

### Response Format

The response format depends on what your function returns:

**Scalar value** (COUNT, SUM, single value):
```json
42
```

**Single row object**:
```json
{"id": 1, "name": "John", "email": "john@example.com"}
```

**Array of objects**:
```json
[
  {"id": 1, "name": "John", "email": "john@example.com"},
  {"id": 2, "name": "Jane", "email": "jane@example.com"}
]
```

**Error response**:
```json
{"message": "Undefined function"}
```

### Parameter Types

- **Query string parameters**: Passed as function arguments
  - `?param1=value1&param2=value2`
  - Converted to PostgreSQL function parameters
  
- **POST body**: For complex data structures
  - Send JSON or URL-encoded data in request body
  - Can be used with procedures expecting complex input

### Advanced Examples

**Complex business logic with JOINs**:
```sql
CREATE FUNCTION get_user_with_orders(user_id int) 
RETURNS TABLE(
  user_id int, 
  user_name text,
  order_count int,
  total_spent decimal
) AS $$
  SELECT 
    u.id,
    u.name,
    COUNT(o.id) as order_count,
    COALESCE(SUM(o.total), 0) as total_spent
  FROM users u
  LEFT JOIN orders o ON u.id = o.user_id
  WHERE u.id = $1
  GROUP BY u.id, u.name;
$$ LANGUAGE SQL;
```

**Stored procedure with transactions**:
```sql
CREATE FUNCTION transfer_balance(from_user int, to_user int, amount decimal) 
RETURNS TABLE(success boolean, message text) AS $$
BEGIN
  UPDATE accounts SET balance = balance - amount WHERE user_id = from_user;
  UPDATE accounts SET balance = balance + amount WHERE user_id = to_user;
  RETURN QUERY SELECT true::boolean, 'Transfer successful'::text;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT false::boolean, SQLERRM;
END;
$$ LANGUAGE plpgsql;
```

Usage with GET (query parameters):
```bash
curl "http://localhost/rpc/transfer_balance?from_user=1&to_user=2&amount=100"
```

Usage with POST (JSON body):
```bash
curl -X POST "http://localhost/rpc/transfer_balance" \
  -H "Content-Type: application/json" \
  -d '{"from_user": 1, "to_user": 2, "amount": 100}'
```

## API Usage

### SELECT (GET)

```bash
# Get all rows from users table
curl http://localhost/api/users

# Select specific columns
curl "http://localhost/api/users?select=id,name,email"

# Filter rows
curl "http://localhost/api/users?status=eq.active"
curl "http://localhost/api/users?age=gt.18&status=eq.active"

# Order results
curl "http://localhost/api/users?order=created_at.desc"
curl "http://localhost/api/users?order=name.asc,id.desc"
curl "http://localhost/api/users?order=name.nullsfirst"
curl "http://localhost/api/users?order=name.desc.nullslast"

# Pagination
curl "http://localhost/api/users?limit=10&offset=20"

# HTTP range-based pagination
curl "http://localhost/api/users" \
  -H "Range-Unit: items" \
  -H "Range: 10-19"

# Count-aware pagination metadata
curl "http://localhost/api/users?limit=10" \
  -H "Prefer: count=exact"

# Combined
curl "http://localhost/api/users?select=id,name&status=eq.active&order=name.asc&limit=10"
```

### Pagination and Count Headers

For `GET` and `HEAD` reads, pgrest now emits HTTP item-range metadata on table reads and table-valued RPC reads:

- `Range-Unit: items`
- `Content-Range: start-end/*` when no total count is requested
- `Content-Range: start-end/total` when `Prefer: count=*` is requested and a total count is available

Current pagination/count behavior:

- query-parameter pagination (`limit`/`offset`) still works and now drives the emitted `Content-Range`
- `Range: start-end` and open-ended `Range: start-` requests override read pagination for top-level reads
- `Prefer: count=exact|planned|estimated` is accepted on table reads and table-valued RPC reads
- partial counted responses return `206 Partial Content` when the selected window is smaller than the known total

Current boundary:

- `count=exact` uses `COUNT(*)`
- `count=planned` and `count=estimated` use PostgreSQL planner estimates via `EXPLAIN (FORMAT JSON)` on the filtered read shape
- because this module does not yet expose a PostgREST-style row-threshold setting, `count=estimated` currently uses the same planner-estimate path as `count=planned` instead of a threshold-based hybrid strategy
- range/count handling is currently implemented for top-level table reads and table-valued RPC reads, not for embedding (which remains future work)

### INSERT (POST)

```bash
# Insert a new row
curl -X POST http://localhost/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "John", "email": "john@example.com", "status": "active"}'
```

### UPDATE (PATCH)

```bash
# Update rows matching filter
curl -X PATCH "http://localhost/api/users?id=eq.5" \
  -H "Content-Type: application/json" \
  -d '{"status": "inactive"}'
```

### DELETE (DELETE)

```bash
# Delete rows matching filter
curl -X DELETE "http://localhost/api/users?id=eq.5"
```

## Schema Selection & Request Headers

### Accept-Profile & Content-Profile Headers

pgrest supports schema-qualified table access via Profile headers. This allows you to work with tables in different PostgreSQL schemas without modifying the table name in the URI.

#### Accept-Profile (GET/HEAD)

Use the `Accept-Profile` header to select a schema for GET and HEAD requests:

```bash
# Query from the public schema (default if no header)
curl "http://localhost/api/users"

# Query from a specific schema
curl "http://localhost/api/users" \
  -H "Accept-Profile: admin_schema"

# This will query: SELECT * FROM admin_schema.users
```

#### Content-Profile (POST/PATCH/PUT/DELETE)

Use the `Content-Profile` header to select a schema for POST, PATCH, PUT, and DELETE requests:

```bash
# Insert into the public schema (default)
curl -X POST "http://localhost/api/users" \
  -H "Content-Type: application/json" \
  -d '{"name": "John", "email": "john@example.com"}'

# Insert into a specific schema
curl -X POST "http://localhost/api/users" \
  -H "Content-Type: application/json" \
  -H "Content-Profile: tenant_schema" \
  -d '{"name": "John", "email": "john@example.com"}'

# This will execute: INSERT INTO tenant_schema.users (name, email) VALUES (...)

# Delete from a specific schema
curl -X DELETE "http://localhost/api/users?id=eq.5" \
  -H "Content-Profile: tenant_schema"

# This will execute: DELETE FROM tenant_schema.users WHERE id = '5' RETURNING *
```

#### Allowlisted Schemas and Default Schema

Configure the exposed schema set with `pgrest_schemas`:

```nginx
location /api/ {
    pgrest_pass "host=localhost dbname=mydb user=postgres password=secret";
    pgrest_schemas "public, admin, tenant_001";
}
```

The first configured schema becomes the default schema when no profile header is provided. In that default case, pgrest keeps the generated SQL unqualified and relies on the selected schema as the request's effective search path. Requests that specify a different allowed schema are schema-qualified explicitly. Requests that specify a schema outside `pgrest_schemas` are rejected with the PostgREST-style `PGRST106` error.

#### Schema Profile Examples

**Multi-tenant application:**
```bash
# User A's data (tenant_001 schema)
curl "http://localhost/api/orders" \
  -H "Accept-Profile: tenant_001"

# User B's data (tenant_002 schema)
curl "http://localhost/api/orders" \
  -H "Accept-Profile: tenant_002"
```

**Separate admin schema:**
```bash
# Regular user access (public schema)
curl "http://localhost/api/users"

# Admin access (admin schema)
curl "http://localhost/api/users" \
  -H "Accept-Profile: admin"
  -H "Accept: application/json"
```

### Prefer Header

The `Prefer` header controls both RPC parameter wrapping and the write-response contract for current table write paths.

#### Prefer: params=single-object

For RPC functions that accept a single JSON object parameter, use this header to wrap all parameters in a single object:

```bash
# Function definition:
# CREATE FUNCTION create_user(data json) RETURNS TABLE(id int, name text) AS ...

# Without Prefer header (parameter mapping):
curl -X POST "http://localhost/rpc/create_user" \
  -H "Content-Type: application/json" \
  -d '{"data": "{\"name\": \"John\", \"email\": \"john@example.com\"}"}'

# With Prefer header (single object wrapping):
curl -X POST "http://localhost/rpc/create_user" \
  -H "Content-Type: application/json" \
  -H "Prefer: params=single-object" \
  -d '{"name": "John", "email": "john@example.com"}'
# Automatically wrapped as: {"data": <entire JSON body>}
```

This is useful for:
- Functions expecting JSON or JSONB parameters
- Simplifying RPC calls with complex nested objects
- Avoiding double-encoding of JSON data

### Prefer Header for Table Writes

Batch 3 and Batch 6 add write-side Prefer handling for the current table write paths:

- `Prefer: return=representation` - default behavior, returns the written rows in the response body
- `Prefer: return=minimal` - executes the write and returns headers only, with no response body
- `Prefer: return=headers-only` - same no-body contract as the current implementation’s header-only write response mode
- `Prefer: handling=strict|lenient` - strict rejects unsupported/malformed Prefer values before SQL execution; lenient ignores unknown values
- `Prefer: max-affected=<n>` - rejects responses that affect more than `n` rows
- `Prefer: missing=default` - on supported bulk insert flows, missing keys listed by the write column set are emitted as SQL `DEFAULT` instead of `NULL`
- `Prefer: resolution=merge-duplicates|ignore-duplicates` - on supported insert upsert flows, generates `ON CONFLICT ... DO UPDATE` or `DO NOTHING`

When a write-side preference is honored, pgrest emits a `Preference-Applied` header for the applied values.

Current Batch 3 boundary:

- `max-affected` is enforced at response-contract level for the current write paths
- `tx=commit|rollback` remains out of scope

### Bulk Insert and Upsert Semantics

Batch 6 adds the current advanced table-write subset:

- JSON array bodies are emitted as a single multi-row `INSERT ... VALUES (...), (...)`
- `text/csv` table writes support multi-row inserts using the header row as the write column list
- `columns=col1,col2,...` constrains the effective insert column set and ignores extra JSON keys outside that set
- `Prefer: missing=default` applies to supported bulk JSON insert flows so omitted columns render as SQL `DEFAULT`
- `Prefer: resolution=merge-duplicates|ignore-duplicates` plus `on_conflict=...` adds explicit conflict-target upserts for object and bulk insert flows
- `PUT` with `eq` filters on the target row and a complete body performs a single-row upsert using those filtered columns as the conflict target
- `PATCH` and `DELETE` support PostgREST-style limited writes when `limit` is paired with an explicit `order`

Examples:

```bash
# Bulk JSON insert
curl -X POST "http://localhost/api/users" \
  -H "Content-Type: application/json" \
  -d '[
    {"name":"Bulk A","email":"a@example.com","status":"active"},
    {"name":"Bulk B","email":"b@example.com","status":"inactive"}
  ]'

# Bulk CSV insert
curl -X POST "http://localhost/api/users" \
  -H "Content-Type: text/csv" \
  --data-binary $'name,email,status\nCsv A,csv-a@example.com,active\nCsv B,csv-b@example.com,inactive\n'

# Restrict insert columns and ignore extra keys
curl -X POST "http://localhost/api/users?columns=name,email" \
  -H "Content-Type: application/json" \
  -d '{"name":"Trimmed User","email":"trimmed@example.com","status":"active","ignored":"value"}'

# Use DEFAULT for omitted values in a bulk JSON insert
curl -X POST "http://localhost/api/foo?columns=id,bar,baz" \
  -H "Content-Type: application/json" \
  -H "Prefer: missing=default, return=representation" \
  -d '[
    {"bar":"val1"},
    {"bar":"val2","baz":15}
  ]'

# Explicit upsert on a unique column set
curl -X POST "http://localhost/api/employees?on_conflict=name" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates, return=representation" \
  -d '[
    {"name":"Old employee 1","salary":40000},
    {"name":"Old employee 2","salary":52000},
    {"name":"New employee 3","salary":60000}
  ]'

# Single-row PUT upsert
curl -X PUT "http://localhost/api/users?id=eq.4" \
  -H "Content-Type: application/json" \
  -d '{"id":4,"name":"Sara B.","email":"sara@example.com","status":"active"}'

# Limited PATCH with explicit ordering
curl -X PATCH "http://localhost/api/users?limit=10&order=id&last_login=lt.2020-01-01" \
  -H "Content-Type: application/json" \
  -d '{"status":"inactive"}'

# Limited DELETE with explicit ordering
curl -X DELETE "http://localhost/api/users?limit=10&order=id&status=eq.inactive"
```

Current Batch 6 boundary:

- bulk support currently covers insert-only JSON-array and CSV flows, not bulk update/delete
- default-primary-key upsert inference without an explicit conflict target is intentionally not implemented because this upstream module does not maintain PostgREST-style schema-cache metadata
- CSV support is intentionally narrow and does not attempt full PostgREST CSV grammar parity
- limited update/delete support follows the documented `limit` + explicit `order` contract and does not attempt broader hidden uniqueness inference

## Content Negotiation & Response Formats

### Accept Header Support

pgrest supports multiple response formats via the `Accept` header. The server will automatically convert query results to your requested format.

#### JSON Format (default)
```bash
curl "http://localhost/api/users" \
  -H "Accept: application/json"
```

Response:
```json
[
  {"id": 1, "name": "John", "email": "john@example.com"},
  {"id": 2, "name": "Jane", "email": "jane@example.com"}
]
```

#### CSV Format
```bash
curl "http://localhost/api/users" \
  -H "Accept: text/csv"
```

Response:
```csv
id,name,email
1,John,john@example.com
2,Jane,jane@example.com
```

#### Plain Text Format
```bash
curl "http://localhost/api/users?select=name" \
  -H "Accept: text/plain"
```

Response:
```
John
Jane
```

#### XML Format
```bash
curl "http://localhost/api/users" \
  -H "Accept: text/xml"
```

Response:
```xml
<?xml version="1.0"?>
<root>
  <row>
    <id>1</id>
    <name>John</name>
    <email>john@example.com</email>
  </row>
  <row>
    <id>2</id>
    <name>Jane</name>
    <email>jane@example.com</email>
  </row>
</root>
```

#### Binary/Octet-Stream Format
```bash
curl "http://localhost/api/files?id=eq.1&select=data" \
  -H "Accept: application/octet-stream"
```

Returns the raw field payload when the query result shape is exactly one row and one column. Wider result shapes are rejected explicitly instead of being coerced to JSON.

### Accept Header Behavior

- If no `Accept` header is provided, defaults to `application/json`
- For single-row results with CSV/plain text, outputs the first column value
- For multi-column results, CSV includes all columns with proper escaping
- XML wraps results in `<root>` with `<row>` elements for each record
- `application/octet-stream` is supported only for single-row, single-column responses
- Unsupported response formats return `406 Not Acceptable`

### Request Body Media Types

pgrest accepts the following request body media types with explicit mappings that stay within the current upstream module contract:

- `application/json` - object payloads plus supported JSON-array bulk inserts for table writes, and named RPC parameters
- `application/x-www-form-urlencoded` - key/value payloads for table writes and named RPC parameters
- `text/csv` - header-driven table inserts, including supported multi-row bulk inserts; raw `data` payload for RPC
- `text/plain`, `text/xml`, `application/octet-stream` - raw body mapped to a single `data` field/parameter

These mappings are intentionally narrow so content-type support does not silently introduce broader write-contract or RPC semantics.

### Response Format Options

#### Singular Object vs Array

pgrest can return results as either an array (default) or a single object. For endpoints that guarantee a single row, you can request object format:

```bash
# Default: returns array
curl "http://localhost/api/users?id=eq.1"
# Response: [{"id": 1, "name": "John"}]

# Request single object format
curl "http://localhost/api/users?id=eq.1" \
  -H "Accept: application/vnd.pgrst.object+json"
# Response: {"id": 1, "name": "John"}

# Works with RPC too
curl -X POST "http://localhost/rpc/get_user_by_id" \
  -H "Content-Type: application/json" \
  -H "Accept: application/vnd.pgrst.object+json" \
  -d '{"id": 1}'
# Response: {"id": 1, "name": "John", "email": "john@example.com"}
```

#### Stripped Nulls

Remove null-valued fields from JSON responses to reduce payload size:

```bash
# Normal response includes null fields
curl "http://localhost/api/users"
# Response: [
#   {"id": 1, "name": "John", "bio": null, "avatar": null},
#   {"id": 2, "name": "Jane", "bio": "Developer", "avatar": null}
# ]

# Request stripped nulls
curl "http://localhost/api/users" \
  -H "Accept: application/vnd.pgrst.array+json;nulls=stripped"
# Response: [
#   {"id": 1, "name": "John"},
#   {"id": 2, "name": "Jane", "bio": "Developer"}
# ]
```

**Combining options:**
```bash
# Single object with stripped nulls
curl "http://localhost/api/users?id=eq.1" \
  -H "Accept: application/vnd.pgrst.object+json;nulls=stripped"
# Response: {"id": 1, "name": "John"}

# Works with all formats
curl "http://localhost/api/users" \
  -H "Accept: text/csv;nulls=stripped"
# Returns CSV with null values omitted from fields
```

Benefits of stripped nulls:
- Reduces response payload size, especially for sparse data
- Simplifies client-side JSON parsing
- Useful for APIs with many optional fields

## Filter Operators

| Operator | SQL Equivalent | Example |
|----------|---------------|---------|
| `eq` | `=` | `?id=eq.5` |
| `neq` | `<>` | `?status=neq.deleted` |
| `gt` | `>` | `?age=gt.18` |
| `gte` | `>=` | `?age=gte.21` |
| `lt` | `<` | `?price=lt.100` |
| `lte` | `<=` | `?price=lte.50` |
| `like` | `LIKE` | `?name=like.John%` |
| `ilike` | `ILIKE` | `?name=ilike.john%` |
| `match` | `~` | `?name=match.^J.*n$` |
| `imatch` | `~*` | `?name=imatch.^j.*n$` |
| `is` | `IS` | `?deleted_at=is.null` |
| `isdistinct` | `IS DISTINCT FROM` | `?deleted_at=isdistinct.null` |
| `in` | `IN` | `?status=in.(active,pending)` |
| `fts` / `plfts` / `phfts` / `wfts` | `@@` | `?my_tsv=fts(french).amusant` |
| `cs` / `cd` / `ov` | `@>` / `<@` / `&&` | `?tags=cs.{example,new}` |
| `sl` / `sr` / `nxr` / `nxl` / `adj` | range operators | `?range=adj.(1,10)` |

Logical operators and modifiers supported by the current Batch 4 implementation:

- `or=(...)`, `and=(...)`, `not.and(...)`, `not.or(...)`
- `not.<operator>` on simple filters
- `any` / `all` modifiers on `eq`, `like`, `ilike`, `gt`, `gte`, `lt`, `lte`, `match`, and `imatch`
- reserved-character escaping for quoted identifiers and quoted `in(...)` values
- JSON/composite/array path filters using `->` and `->>` with `to_jsonb(...)` SQL rendering

## Ordering

pgrest currently supports plain-column and JSON/composite/array-path ordering with optional direction and null ordering modifiers:

- `?order=name` → `ORDER BY name ASC`
- `?order=name.asc` → `ORDER BY name ASC`
- `?order=name.desc` → `ORDER BY name DESC`
- `?order=name.nullsfirst` → `ORDER BY name ASC NULLS FIRST`
- `?order=name.nullslast` → `ORDER BY name ASC NULLS LAST`
- `?order=name.desc.nullslast` → `ORDER BY name DESC NULLS LAST`
- `?order=location->>lat` → `ORDER BY to_jsonb(location)->>'lat' ASC`

Multiple order items are comma-separated:

```bash
curl "http://localhost/api/users?order=name.nullslast,id.desc.nullsfirst"
```

Malformed `order=` values are rejected with `400` before SQL execution.

## Select Grammar

Batch 4 also expands `select=` beyond plain column lists:

- aliasing with `alias:column`
- casts with `column::type`
- JSON/composite/array path expressions with `->` and `->>`
- auto-aliasing of path tail segments
- percent-decoded path operators from real HTTP requests

Examples:

```bash
curl "http://localhost/api/users?select=id,fullName:full_name,birthDate:birth_date,salary::text"
curl "http://localhost/api/people?select=id,json_data->>blood_type,json_data->phones,primary_language:languages->0"
```

## Aggregate Functions and Computed Fields

Batch 9 adds the current top-level aggregate/computed-field subset for table reads.

Supported aggregate select forms:

- `amount.sum()`
- `amount.avg()`
- `amount.min()`
- `amount.max()`
- `amount.count()`
- `count()`

Current aggregate notes:

- aggregate items can be mixed with plain selected columns, and non-aggregate selected columns become the generated `GROUP BY` list
- aggregate outputs support aliasing, e.g. `average:amount.avg()`
- aggregate outputs support output casts, e.g. `average:amount.avg()::int`
- aggregate inputs support the existing path/cast grammar, e.g. `order_details->tax_amount::numeric.sum()`
- the same aggregate select grammar is reused for table-valued RPC reads

Examples:

```bash
# Aggregate over all rows
curl "http://localhost/api/orders?select=amount.sum()"

# Grouped aggregate query
curl "http://localhost/api/orders?select=amount.sum(),average:amount.avg()::int,order_date"

# Aggregate over a JSON path with input cast
curl "http://localhost/api/orders?select=order_details->tax_amount::numeric.sum()"
```

Computed fields currently ride on the regular top-level grammar and can be used as selectable, filterable, and orderable columns when PostgreSQL exposes them in the active schema/search path.

Examples:

```bash
# Select a computed field
curl "http://localhost/api/people?select=full_name,job"

# Filter on a computed field
curl "http://localhost/api/people?full_name=fts.Beckett"

# Order by a computed field
curl "http://localhost/api/people?select=full_name,job&order=full_name.desc"
```

Current Batch 9 boundary:

- ordering by aggregate outputs is still out of scope
- `HAVING`-style aggregate filtering is not implemented
- embedding-aware aggregate behavior remains deferred to later embedding batches

## Resource Embedding and Relationships

Batch 10 and the core relationship parts of Batch 11 now land on the table-read path for JSON responses.

Supported embedding forms:

- one-level to-one embedding via direct foreign keys, e.g. `select=id,user:users(id,name)`
- one-level to-many embedding via reverse foreign keys, e.g. `select=id,name,orders(id,amount)`
- many-to-many embedding via join-table inference, e.g. `select=id,teams!memberships_team_id_fkey(id,name)`
- nested embedding on top of those relationships, e.g. `select=id,teams!memberships_team_id_fkey(id,name,owner:users(id,name))`
- `!inner` on embeds to filter parent rows by related-row existence, e.g. `select=id,name,orders!inner(id)`
- basic `!fk` disambiguation using the PostgreSQL constraint name
- embedded filtering/order/limit/offset using scoped query parameters such as `orders.limit=2`, `orders.order=id.desc`, or `orders.status=eq.paid`

Current relationship scope:

- relationships are currently table-to-table only
- relationship metadata is derived from PostgreSQL foreign-key introspection in the active schema
- embedded responses are currently JSON-only; non-JSON embedded reads are rejected explicitly

Current Batch 11 boundary:

- advanced embed semantics such as spread syntax, null-based embed filters, and mutation-time embedding are still out of scope
- view/computed/table-valued-function relationship inference remains out of scope

## RPC Response Formats

The response format for RPC calls depends on what your function returns. The format can be controlled via the `Accept` header:

### JSON Response (default)

```bash
curl -X POST "http://localhost/rpc/get_users" \
  -H "Accept: application/json"
```

**Scalar value** (COUNT, SUM, single value):
```json
42
```

**Single row object**:
```json
{"id": 1, "name": "John", "email": "john@example.com"}
```

**Array of objects**:
```json
[
  {"id": 1, "name": "John", "email": "john@example.com"},
  {"id": 2, "name": "Jane", "email": "jane@example.com"}
]
```

**Error response**:
```json
{"message": "PostgreSQL query failed"}
```

### CSV Response

```bash
curl -X POST "http://localhost/rpc/get_users" \
  -H "Accept: text/csv"
```

Output:
```csv
id,name,email
1,John,john@example.com
2,Jane,jane@example.com
```

### Plain Text Response

For single-column results:
```bash
curl -X POST "http://localhost/rpc/get_user_names" \
  -H "Accept: text/plain"
```

Output:
```
John
Jane
```

### XML Response

```bash
curl -X POST "http://localhost/rpc/get_users" \
  -H "Accept: text/xml"
```

Output:
```xml
<?xml version="1.0"?>
<root>
  <row>
    <id>1</id>
    <name>John</name>
    <email>john@example.com</email>
  </row>
  <row>
    <id>2</id>
    <name>Jane</name>
    <email>jane@example.com</email>
  </row>
</root>
```

## Standard Query Response Format

Successful queries return a JSON array by default:

```json
[
  {"id": 1, "name": "John", "email": "john@example.com"},
  {"id": 2, "name": "Jane", "email": "jane@example.com"}
]
```

Other formats (CSV, XML, plain text) are available via `Accept` header as documented in the Content Negotiation section.

Error responses:

```json
{"message": "Undefined table"}
```

## Completed Features (v1.0+)

- ✅ **Request body media types** - JSON, form-urlencoded, CSV, plain text, XML, and octet-stream with explicit narrow mappings
- ✅ **Accept header support** - JSON, CSV, XML, plain text, and deterministic octet-stream output
- ✅ **Prefer write contract** - `return=representation|minimal|headers-only`, `handling=strict|lenient`, `max-affected`, and consistent `Preference-Applied` on current table writes
- ✅ **Advanced table writes** - bulk JSON-array inserts, CSV bulk inserts, `columns=...`, `Prefer: missing=default`, explicit `on_conflict` upserts, `PUT` single-row upserts, and limited `PATCH`/`DELETE` with `limit` + explicit `order`
- ✅ **Batch 4 URL grammar subset** - logical operators, `any`/`all`, advanced filter operators, reserved-character escapes, alias/cast `select`, JSON/composite/array path filters and selects, and path-aware ordering with explicit malformed-order rejection
- ✅ **RPC POST requests** - Call functions with structured JSON data
- ✅ **Schema allowlist and default schema selection** - `pgrest_schemas` enforces allowed profiles, uses the first schema as the default selection, and rejects disallowed schemas with `PGRST106`
- ✅ **Accept-Profile header** - Schema selection for GET/HEAD requests
- ✅ **Content-Profile header** - Schema selection for POST/PATCH/PUT/DELETE requests
- ✅ **Prefer: params=single-object** - Single JSON object parameter wrapping for RPC functions
- ✅ **Singular object responses** - Accept: application/vnd.pgrst.object+json for single-row object format
- ✅ **Stripped nulls** - Accept: application/vnd.pgrst.array+json;nulls=stripped to omit null fields
- ✅ **Array parameters** - JSON arrays automatically converted to PostgreSQL ARRAY[] syntax in RPC calls
- ✅ **RPC volatility gating** - RPC GET/HEAD now respects metadata-backed volatility checks and rejects `VOLATILE` functions with `405`
- ✅ **Single unnamed RPC parameters** - matching `json/jsonb`, `text`, `xml`, and `bytea` single-unnamed-parameter functions now use positional body binding
- ✅ **Variadic repeated parameters** - repeated GET and form-urlencoded RPC parameters now collapse into one variadic `ARRAY[...]` argument when metadata marks the target parameter as variadic
- ✅ **Table-valued RPC read grammar** - composite/table-returning RPC functions now support `select`, filters, ordering, and pagination
- ✅ **Embedded resource reads** - table reads now support direct-FK to-one/to-many embedding, many-to-many join-table inference, nested embedding, and basic `!fk` disambiguation on JSON responses
- ✅ **Interface/discovery surface** - table and RPC routes now respond to `OPTIONS`, emit basic CORS headers for simple/preflight flows, and expose a minimal OpenAPI discovery document on `/api/` and `/rpc/`
- ✅ **JWT Authentication** - Authorization header support with JWT passed to PostgreSQL via request.jwt claim

## Planned Features

- **Broader binary response format** - widen application/octet-stream beyond the current single-row/single-column response contract
- **Broader write semantics** - transaction preferences, default conflict-target inference without explicit schema metadata, and richer RPC-specific Prefer behavior
- **Variadic functions** - Multiple parameter values for variadic functions
- **Embedding and aggregate grammar** - relationship embedding, spread syntax, and aggregate/computed-field `select` semantics remain future work outside the current Batch 4 subset
 - **Advanced embed semantics** - `!inner`, spread syntax, null-based embed filtering, mutation-time embedding, and non-table relationship inference remain future work

## Directive Reference

| Directive | Syntax | Context | Default | Description |
|-----------|--------|---------|---------|-------------|
| `pgrest_pass` | `pgrest_pass "conninfo"` | `location` | — | PostgreSQL connection string for the location. Registers the pgrest content handler. All `pgrest_pass` locations in a worker process share one connection pool; pointing two locations at different hosts is not supported while connections are active. |
| `pgrest_pool_size` | `pgrest_pool_size N` | `location` | 16 | Maximum number of pooled connections (1–32). Inherited by nested locations. |
| `pgrest_timeout` | `pgrest_timeout 15s` | `location` | 15s | Connect/query socket timeout. Inherited by nested locations. The default accommodates dashboard-style analytical reads during sustained telemetry ingestion; latency-sensitive APIs can set a shorter value. |
| `pgrest_schemas` | `pgrest_schemas "schema1, schema2"` | `location` | — | Allowlist of schemas. The first schema becomes the default. Disallowed schemas receive `PGRST106`. |
| `pgrest_jwt_secret` | `pgrest_jwt_secret "secret"` | `location` | — | HS256 secret for JWT signature validation. When set, tokens are validated before role extraction. |
| `pgrest_anon_role` | `pgrest_anon_role "role"` | `location` | — | PostgreSQL role to use when no valid JWT is provided. |
| `pgrest_jwt_role_claim` | `pgrest_jwt_role_claim "claim"` | `location` | `role` | JWT claim name that contains the PostgreSQL role. |

### Runtime diagnostics

Routine pooled-connection state events (`pgrest-trace` and `pgrest-watch`) are
debug-only and appear only with `error_log ... debug`. Timeouts and connection
failures remain warning/error events. Long-running production configurations
should normally use `error_log ... warn` and enable debug logging only for a
bounded troubleshooting window.

## PostgREST Parity Matrix

| Category | Status | Notes |
|----------|--------|-------|
| Tables / URL grammar | Partial | Logical ops, advanced operators, escaping, aliasing, casting, JSON paths supported. Embedding grammar beyond direct FK is partial. |
| Media types / representation | Partial | JSON, CSV, plain text, XML, and constrained octet-stream supported. Custom media handlers are out of scope. |
| RPC | Partial | Volatility gating, unnamed params, variadics, table-valued return with filtering/order/pagination supported. RPC embedding is out of scope. |
| Pagination / count | Partial | Range headers, `Prefer: count=exact|planned|estimated`, planner-backed estimate counts for table reads and table-valued RPC reads. Embedding counts remain out of scope. |
| Prefer header | Partial | `return`, `handling`, `max-affected`, `missing=default`, `resolution` supported. `tx=commit/rollback` is out of scope. |
| Schema / profiles | Implemented | `pgrest_schemas` allowlist, `Accept-Profile`, `Content-Profile`, default schema selection. |
| Bulk writes / upsert | Partial | Bulk JSON/CSV inserts, `columns`, `missing=default`, explicit upsert, limited update/delete supported. Default PK upsert inference is out of scope. |
| Embedding / relationships | Partial | One-level to-one/to-many, many-to-many, nested embedding, `!inner`, `!fk` disambiguation supported. Spread syntax, null embed filters, mutation-time embedding are out of scope. |
| Aggregates / computed fields | Partial | `sum`, `avg`, `min`, `max`, `count`, grouped queries, computed field select/filter/order supported. Aggregate ordering and `HAVING` are out of scope. |
| OPTIONS / CORS / OpenAPI | Partial | Basic `OPTIONS`, CORS simple/preflight, minimal OpenAPI root documents supported. Full OpenAPI customization is out of scope. |
| JWT auth | Implemented | Signature validation, `exp`/`iat`/`nbf` enforcement, role claim extraction, passthrough to PostgreSQL. |
| Execution-path parity | Partial | The active implementation is the pooled/nonblocking path. Connection/runtime failure coverage, pooled-state isolation, and bounded parameterized-query execution are in place on the active path. |

## Batch 12 Changes

This section documents the Batch 12 hardening fixes that are now in place.

- **JWT validation hardening** — Tokens with invalid format, invalid signature, expired `exp`, future `iat`, or not-yet-valid `nbf` now return `401 Unauthorized` instead of falling back to the anonymous role.
- **Error response parity** — All client-facing errors now use the consistent `{"message":"..."}` shape. Server errors also use `{"message":"..."}` for consistency.
- **Runtime and transport error classification** — PostgreSQL syntax errors, undefined tables/functions, constraint violations, insufficient-privilege failures, unreachable hosts, DNS failures, connection resets, and timed-out pooled requests now return explicit HTTP status/message pairs instead of collapsing into a generic `500 Query failed`.
- **Malformed Range header rejection** — Invalid `Range` headers (missing dash, dash at start/end) now return `400 Bad Request` with a clear message instead of being silently ignored.
- **Embedded resource format boundary** — Non-JSON response formats for embedded reads are explicitly rejected with `406 Not Acceptable` and a clear message.
- **View semantics audit** — integration coverage now verifies filtering, ordering, pagination, and writes on ordinary PostgreSQL views; simple single-table views work with the existing table path, while non-updatable views fail with PostgreSQL-driven errors.
- **Planner-backed count semantics** — `Prefer: count=planned|estimated` no longer falls back to exact counts on the active read path.
- **ROADMAP coverage audit** — roadmap sections 1–11 now have explicit integration coverage evidence in `tests/pgrest/`, with section 11 tracked as documentation/audit evidence rather than a synthetic runtime feature.

## Limitations

- **Parameterized-query limits** - String filter/RPC/write values use bounded positional parameters on the active path. Requests that exceed the current parameter budget fail with `400 Bad Request` instead of degrading into mixed placeholder/raw SQL execution.
- **Single table operations** - CRUD on single tables only (use RPC for JOINs/complex queries)
- **Simple query building** - Complex filters use AND logic only
- **Binary format** - application/octet-stream currently requires exactly one row and one column on output
- **Request body media types** - non-JSON formats are intentionally mapped to narrow write/RPC contracts rather than inferred automatically

## Future Improvements

- Relationship handling (embedded resources, foreign key expansion)
- Bulk operations (multiple INSERT/UPDATE/DELETE)
- Materialized view support
- Custom response headers per endpoint
- Rate limiting and caching headers
- Request/response compression
- GraphQL support

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/pgrest/`.
- [x] Gap recorded: this audit pass expanded Bun coverage for schema-profile headers, combined query shaping, PATCH/DELETE write paths, singular-object and `nulls=stripped` JSON formats, RPC array parameters, and `Prefer: params=single-object` behavior.
- [x] Gap recorded: real bugs were fixed in request-body handling, SQL value rendering for JSON/RPC parameters, `is`/`in` filter SQL generation, text/plain formatting, and binary Accept fallback behavior.
- [x] Gap closed: directive reference table now covers all active directives. `pgrest_server`/`pgrest_keepalive` were removed (broken dead code); `pgrest_pool_size` replaces them with a working LOC-level pool-size directive.
- [x] Gap recorded: Batch 2 now documents octet-stream as a constrained single-row/single-column response format and records the explicit request-body media mappings.
- [x] ROADMAP section coverage map:
  - 1. Tables / URL grammar → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 2. Media types / representation → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 3. RPC → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 4. Pagination / count / HTTP semantics → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 5. Prefer header parity → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 6. Schemas / profiles → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 7. Embedding / relationships → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 8. Aggregates / computed fields → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 9. OPTIONS / CORS / OpenAPI → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 10. Execution-path correctness / hardening → `tests/pgrest/pgrest.test.js`, `tests/pgrest/pgrest.connection.test.js`, `tests/pgrest/pgrest.container.test.js`
  - 11. Documentation / coverage alignment → this checklist plus the pgrest Bun suites under `tests/pgrest/`
- [x] No additional documentation gaps were identified in this audit pass.

## Performance Study Notes

This section records a code-reading performance study of the current pgrest implementation and a design comparison against the local PostgREST checkout at `/home/kaiwu/Documents/github/postgrest`. This is not yet a benchmark report. The goal is to identify the likely hot path, the most credible bottlenecks, and the optimization order that has the best chance of improving common general-query scenarios.

### Scope and workload assumption

The analysis is centered on the most common table-read path:

- `GET /api/<table>`
- optional `select=`, filters, ordering, limit/offset, and count preferences
- JSON responses
- warm pooled PostgreSQL connections
- no unusual RPC, embedding-heavy, CSV/XML, or large binary-response edge paths

That matters because the dominant costs for these requests are different from write-heavy flows, RPC metadata lookups, or large relationship-embedding responses.

### Confirmed pgrest hot path

For a normal table read, the current execution path is:

1. `ngx_http_pgrest_upstream_handler`
2. request parsing, JWT/profile/prefer/range handling, and SQL-shaping setup
3. `start_pooled_request`
4. `start_pooled_query`
5. nginx event-driven libpq read/write handlers
6. `finalize_pg_response`
7. `format_result_for_response`
8. `format_result_as_json_with_options`
9. `format_row_as_json_object_impl`
10. `finalize_response_send`

For common reads, the hottest CPU path is very likely the last third of that chain, especially row/column iteration and JSON formatting after PostgreSQL has already returned the result.

### Code-level bottleneck hypotheses

These are the highest-confidence bottlenecks from the current code structure.

#### 1. Per-cell JSON formatting is likely the main CPU hot spot

`format_row_as_json_object_impl` sits inside the row loop and performs repeated per-column work:

- `pgGetvalue`, `pgGetisnull`, and `pgFname` calls per cell
- character-by-character JSON escaping
- repeated output-buffer bookkeeping and bounds checks

This is the strongest candidate for CPU time on successful read requests. If the result set is modest and the database query itself is already fast, this formatting path can easily dominate request cost.

#### 2. There is at least one unavoidable full response copy

The module builds the response body in its own buffer and then copies it into nginx output storage before sending. That means the common path includes at least:

- PostgreSQL result memory read
- copy/encode into the JSON response buffer
- copy into the nginx output buffer

Even before deeper optimization, the current structure suggests that bytes moved per response matters almost as much as instructions executed per row.

#### 3. Query parsing and SQL shaping are meaningful front-half costs

`pgrest_query.zig` does a non-trivial amount of request-time string processing for filters, select grammar, ordering, pagination, and parameter shaping. For tiny queries returning few rows, this front-half work may be a noticeable fraction of total request cost.

This is probably not the first bottleneck for medium result sets, but it can matter for small high-RPS reads where the database is already warm and selective.

#### 4. The connection-pool policy is simple and probably fine until concurrency rises

The pool is worker-local, capped at a small fixed size, and scanned linearly. The linear scan itself is not the primary concern; the small maximum pool size is. Under heavier concurrency, the bigger risk is not the scan cost but:

- requests waiting for a free pooled connection
- insufficient DB parallelism per worker
- tail-latency spikes once the worker saturates its connection budget

In other words, this is more likely to be a throughput and p95/p99 limiter than a per-request CPU limiter.

#### 5. Fixed-size eager buffering limits large-response behavior

The current design eagerly formats the whole response into a bounded in-memory buffer instead of streaming rows progressively. That is friendly to simple control flow, but it has two performance consequences:

- large payloads have a hard implementation ceiling
- medium payloads pay the latency of complete formatting before the first byte is sent

This is a likely area where PostgREST keeps an architectural advantage on bigger reads.

### Comparison with PostgREST

PostgREST and this module solve similar problems, but the performance tradeoffs are different.

#### Where pgrest should be able to win

For simple general queries, pgrest has some structural advantages:

- no separate application server hop beyond nginx itself
- a shorter, more direct request path for straightforward CRUD reads
- no Haskell runtime or GC behavior in the request path
- predictable worker-local state and event-loop integration with nginx

That means pgrest has a real chance to beat PostgREST on low-latency simple reads if the result set is not large and if JSON formatting is made materially cheaper.

#### Where PostgREST is still advantaged

PostgREST appears stronger on architectural breadth and sustained concurrency:

- richer schema-cache-driven planning
- more mature connection-pool behavior and observability
- streaming-friendly response handling for larger bodies
- less risk from fixed response buffers

That means pgrest should not expect a blanket win everywhere. The realistic target is to outperform PostgREST on common small-to-medium JSON reads, not necessarily on large streamed responses or more feature-heavy query shapes.

### Most credible optimization order

The likely winning order is:

1. **Prove time split first** with end-to-end benchmarking and profiling.
2. **Optimize JSON serialization and copy count** before touching minor parsing code.
3. **Re-evaluate pool size and wait behavior** under concurrency.
4. **Only then** chase smaller effects such as FFI call granularity or SQL-builder micro-optimizations.

This order matters because gateway-style systems usually lose more time in database work, serialization, and buffering than in language-boundary overhead.

### Optimization opportunities with the best payoff potential

#### A. Reduce JSON formatting overhead

This is the clearest place to look first.

Possible directions:

- reduce repeated per-cell libpq metadata calls where values can be cached per column
- special-case common safe strings to avoid fully generic escaping work
- reduce branchiness and repeated bounds checks in the row formatter
- investigate a faster escaping strategy for the hot JSON path

If pgrest is going to “edge” PostgREST on general queries, this is the most plausible breakthrough area.

#### B. Reduce copies on the response path

If the JSON body is already built in one contiguous buffer, any extra copy becomes visible at higher throughput. A lower-copy or streaming-friendly response path is likely more valuable than small parser cleanups.

#### C. Make concurrency scaling less pool-bound

The current pool cap looks conservative. If common deployments run multiple busy workers, a small per-worker cap can become the first throughput wall. Raising configurability and understanding queueing behavior is likely more important than trying to optimize the connection-slot scan itself.

#### D. Cache or precompute cheap repeated shape information

For hot repeated endpoints, repeated parsing of the same select/filter/order grammar may become visible. This is a second-tier optimization, but it becomes worthwhile once serialization and response-copy costs are under control.

### What is probably *not* the first breakthrough

The code structure does not suggest that the primary win will come from exotic Zig-level tricks or generic “FFI is slow” assumptions. Zig↔C boundary cost exists, but for a REST-to-Postgres gateway it is usually not the dominant factor unless the system is doing extremely fine-grained calls in tight loops. Here, the more credible first-order costs are:

- database time
- per-row/per-cell serialization cost
- copying and buffering behavior
- pool/backpressure behavior under concurrency

### Recommended benchmark matrix

Before claiming performance wins over PostgREST, run both systems through the same workload matrix and compare cost decomposition, not only raw RPS:

- single-table reads with small payloads
- single-table reads with medium payloads
- filtered reads with ordering and pagination
- count-enabled reads (`Prefer: count=*`)
- concurrency ramps to identify the latency knee

For each workload, record at least:

- p50 / p95 / p99 latency
- throughput
- CPU usage
- response size
- PostgreSQL CPU/time share
- connection wait behavior

### Current conclusion

The current pgrest module already has the right broad shape for strong simple-query performance: direct nginx integration, non-blocking pooled PostgreSQL access, and no heavyweight application runtime in the middle. The clearest obstacles to beating PostgREST on common general queries are the current eager-buffered response path, per-cell JSON formatting cost, and the small pool/concurrency envelope. If those three areas improve materially, pgrest has a credible path to outperform PostgREST on the narrow but important class of small-to-medium JSON table reads.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0/S1 CORE FIXED; S2 POOL ENVELOPE MEASURED.** Per-worker pools are isolated by backend and have explicit lifecycle/capacity behavior. pgrest serializes directly into its nginx output buffer and rejects representations above its bound. The pool remains 16 connections by default but can be configured up to 32. A ReleaseSmall small-page matrix showed that 32 removes concurrency-32 pool-exhaustion 503s (200/200 correct), while peak throughput remained at concurrency 8; larger pools are therefore an explicit deployment tuning choice, not a new default. The 124-case focused suite is green.
