import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createPostgresMock,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "pgrest";
let pgMock;
let resetPgMock;

function lastSql() {
  return pgMock.getLastQuery();
}

describe("pgrest module", () => {
  beforeAll(async () => {
    // Start PostgreSQL mock server
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
    resetPgMock = createPostgresMock(15434);
    resetPgMock.setQueryHandler(/^SELECT \* FROM users$/, () => ({ close: true }));

    // Default handler for SELECT * FROM users (no filters)
    pgMock.setQueryHandler(/^SELECT \* FROM users$/, (query) => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "John Doe", "john@example.com", "active"],
        ["2", "Jane Smith", "jane@example.com", "active"],
        ["3", "Bob Wilson", "bob@example.com", "inactive"],
      ],
    }));

    // Handler for SELECT with specific columns
    pgMock.setQueryHandler(/^SELECT id,name FROM users$/, (query) => ({
      columns: ["id", "name"],
      rows: [
        ["1", "John Doe"],
        ["2", "Jane Smith"],
        ["3", "Bob Wilson"],
      ],
    }));

    pgMock.setQueryHandler(/FROM pg_constraint.*'users'.*'orders'|FROM pg_constraint.*'orders'.*'users'/, () => ({
      columns: ["source", "target", "constraint", "source_cols", "target_cols"],
      rows: [["orders", "users", "orders_user_id_fkey", "user_id", "id"]],
    }));

    pgMock.setQueryHandler(/FROM pg_constraint.*'users'.*'teams'|FROM pg_constraint.*'teams'.*'users'/, () => ({
      columns: ["source", "target", "constraint", "source_cols", "target_cols"],
      rows: [
        ["memberships", "users", "memberships_user_id_fkey", "user_id", "id"],
        ["memberships", "teams", "memberships_team_id_fkey", "team_id", "id"],
        ["teams", "users", "teams_owner_id_fkey", "owner_id", "id"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT id,name,\(SELECT COALESCE\(json_agg\(pgrest_embed_row\), '\[\]'\) FROM \(SELECT id,amount FROM orders AS pgrest_rel_orders WHERE pgrest_rel_orders\.user_id = users\.id\) AS pgrest_embed_row\) AS orders FROM users ORDER BY id ASC$/, () => ({
      columns: ["id", "name", "orders"],
      rows: [
        ["1", "John Doe", '[{"id":"10","amount":"42.50"},{"id":"11","amount":"84.00"}]'],
        ["2", "Jane Smith", '[]'],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT id,name,\(SELECT COALESCE\(json_agg\(pgrest_embed_row\), '\[\]'\) FROM \(SELECT id FROM orders AS pgrest_rel_orders WHERE pgrest_rel_orders\.user_id = users\.id\) AS pgrest_embed_row\) AS orders FROM users WHERE EXISTS \(SELECT 1 FROM orders AS pgrest_rel_orders WHERE pgrest_rel_orders\.user_id = users\.id\) ORDER BY id ASC$/, () => ({
      columns: ["id", "name", "orders"],
      rows: [["1", "John Doe", '[{"id":"10"},{"id":"11"}]']],
    }));

    pgMock.setQueryHandler(/^SELECT id,amount,\(SELECT row_to_json\(pgrest_embed_row\) FROM \(SELECT id,name FROM users AS pgrest_rel_user WHERE pgrest_rel_user\.id = orders\.user_id\) AS pgrest_embed_row\) AS user FROM orders ORDER BY id ASC$/, () => ({
      columns: ["id", "amount", "user"],
      rows: [["10", "42.50", '{"id":"1","name":"John Doe"}']],
    }));

    pgMock.setQueryHandler(/^SELECT id,\(SELECT COALESCE\(json_agg\(pgrest_embed_row\), '\[\]'\) FROM \(SELECT id,name,\(SELECT row_to_json\(pgrest_embed_row\) FROM \(SELECT id,name FROM users AS pgrest_rel_teams_owner WHERE pgrest_rel_teams_owner\.id = pgrest_rel_teams\.owner_id\) AS pgrest_embed_row\) AS owner FROM teams AS pgrest_rel_teams JOIN memberships AS pgrest_junction ON pgrest_rel_teams\.id = pgrest_junction\.team_id WHERE pgrest_junction\.user_id = users\.id\) AS pgrest_embed_row\) AS teams FROM users ORDER BY id ASC$/, () => ({
      columns: ["id", "teams"],
      rows: [["1", '[{"id":"7","name":"Platform","owner":{"id":"2","name":"Jane Smith"}}]']],
    }));

    // Handler for SELECT with single column (name)
    pgMock.setQueryHandler(/^SELECT name FROM users/, (query) => ({
      columns: ["name"],
      rows: [
        ["John Doe"],
        ["Jane Smith"],
        ["Bob Wilson"],
      ],
    }));

    // Handler for SELECT with status filter
    pgMock.setQueryHandler(/SELECT \* FROM users WHERE status = 'active'/, (query) => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "John Doe", "john@example.com", "active"],
        ["2", "Jane Smith", "jane@example.com", "active"],
      ],
    }));

    // Handler for SELECT with id filter
    pgMock.setQueryHandler(/SELECT \* FROM users WHERE id = '1'/, (query) => ({
      columns: ["id", "name", "email", "status"],
      rows: [["1", "John Doe", "john@example.com", "active"]],
    }));

    // Handler for profile header / schema-qualified reads
    pgMock.setQueryHandler(/SELECT \* FROM admin\.users$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["101", "Admin Jane", "admin@example.com", "active"]],
    }));

    pgMock.setQueryHandler(/SELECT \* FROM public\.users$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["201", "Public Jane", "public@example.com", "active"]],
    }));

    // Handler for singular object / null stripping tests
    pgMock.setQueryHandler(/SELECT \* FROM profiles WHERE id = '1'/, () => ({
      columns: ["id", "name", "bio", "avatar"],
      rows: [["1", "John Doe", null, null]],
    }));

    pgMock.setQueryHandler(/SELECT \* FROM profiles WHERE id = '404'/, () => ({
      columns: ["id", "name", "bio", "avatar"],
      rows: [],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM profiles$/, () => ({
      columns: ["id", "name", "bio", "avatar"],
      rows: [
        ["1", "John Doe", null, null],
        ["2", "Jane Smith", "Developer", null],
      ],
    }));

    pgMock.setQueryHandler(/SELECT data FROM files WHERE id = '1'/, () => ({
      columns: ["data"],
      rows: [["PNG\u0000DATA"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM files$/, () => ({
      columns: ["id", "data"],
      rows: [["1", "PNG\u0000DATA"]],
    }));

    // Handlers for additional filter operators and pagination combinations
    pgMock.setQueryHandler(/SELECT \* FROM users WHERE age > '18'/, () => ({
      columns: ["id", "name", "age"],
      rows: [["1", "John Doe", "29"]],
    }));

    pgMock.setQueryHandler(/SELECT \* FROM users WHERE deleted_at IS NULL/, () => ({
      columns: ["id", "name", "deleted_at"],
      rows: [["1", "John Doe", null]],
    }));

    pgMock.setQueryHandler(/SELECT \* FROM users WHERE status IN \('active','pending'\)/, () => ({
      columns: ["id", "name", "status"],
      rows: [
        ["1", "John Doe", "active"],
        ["4", "Pending User", "pending"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users WHERE \(age < '18' OR NOT \(age >= '11' AND age <= '17'\)\)$/, () => ({
      columns: ["id", "name", "age"],
      rows: [["7", "Young User", "10"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users WHERE last_name LIKE ANY \(ARRAY\['O%','P%'\]\)$/, () => ({
      columns: ["id", "last_name"],
      rows: [["1", "Olsen"], ["2", "Parker"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users WHERE last_name LIKE ALL \(ARRAY\['O%','%n'\]\)$/, () => ({
      columns: ["id", "last_name"],
      rows: [["1", "Olsen"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users WHERE name ~ '\^J\.\*n\$'$/, () => ({
      columns: ["id", "name"],
      rows: [["1", "John"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM tsearch WHERE my_tsv @@ to_tsquery\('french', 'amusant'\)$/, () => ({
      columns: ["id", "my_tsv"],
      rows: [["1", "amusant"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM countries WHERE to_jsonb\(location\)->'lat' >= 19 ORDER BY to_jsonb\(location\)->>'lat' ASC$/, () => ({
      columns: ["id", "lat", "long", "primary_language"],
      rows: [["5", "19.741755", "-155.844437", "en"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM vulnerabilities WHERE "information\.cpe" LIKE '%MS%'$/, () => ({
      columns: ["id", "information.cpe"],
      rows: [["1", "MS-123"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM employees WHERE name IN \('Hebdon,John','Williams,Mary'\)$/, () => ({
      columns: ["id", "name"],
      rows: [["1", "Hebdon,John"], ["2", "Williams,Mary"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM people WHERE to_jsonb\(json_data\)->>'blood_type' = 'A-'$/, () => ({
      columns: ["id", "blood_type"],
      rows: [["1", "A-"]],
    }));

    pgMock.setQueryHandler(/^SELECT id,full_name AS fullName,birth_date AS birthDate,salary::text FROM users$/, () => ({
      columns: ["id", "fullName", "birthDate", "salary"],
      rows: [["1", "John Doe", "1988-04-25", "90000.00"]],
    }));

    pgMock.setQueryHandler(/^SELECT sum\(amount\) AS sum,avg\(amount\)::int AS average,order_date FROM orders GROUP BY order_date$/, () => ({
      columns: ["sum", "average", "order_date"],
      rows: [
        ["1234.56", "123", "2023-01-01"],
        ["2345.67", "235", "2023-01-02"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT full_name,job FROM people ORDER BY full_name DESC$/, () => ({
      columns: ["full_name", "job"],
      rows: [["Samuel Beckett", "novelist"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM people WHERE full_name @@ to_tsquery\('Beckett'\)$/, () => ({
      columns: ["first_name", "last_name", "job"],
      rows: [["Samuel", "Beckett", "novelist"]],
    }));

    pgMock.setQueryHandler(/^SELECT id,to_jsonb\(json_data\)->>'blood_type' AS blood_type,to_jsonb\(json_data\)->'phones' AS phones,to_jsonb\(languages\)->0 AS primary_language FROM people$/, () => ({
      columns: ["id", "blood_type", "phones", "primary_language"],
      rows: [["1", "A-", '[{"number":"917-929-5745"}]', "en"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM jsonb_examples$/, () => ({
      columns: ["id", { name: "tags", typeOid: 3802 }],
      rows: [["1", '["openai","anthropic"]']],
    }));

    pgMock.setQueryHandler(/SELECT id,name FROM users WHERE status = 'active' ORDER BY id DESC LIMIT 1 OFFSET 1/, () => ({
      columns: ["id", "name"],
      rows: [["1", "John Doe"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users ORDER BY name ASC NULLS FIRST$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["3", "Bob Wilson", "bob@example.com", "inactive"],
        ["2", "Jane Smith", "jane@example.com", "active"],
        ["1", "John Doe", "john@example.com", "active"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users ORDER BY name DESC NULLS LAST$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "John Doe", "john@example.com", "active"],
        ["2", "Jane Smith", "jane@example.com", "active"],
        ["3", "Bob Wilson", "bob@example.com", "inactive"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users ORDER BY name ASC NULLS LAST,id DESC NULLS FIRST$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "John Doe", "john@example.com", "active"],
        ["2", "Jane Smith", "jane@example.com", "active"],
        ["3", "Bob Wilson", "bob@example.com", "inactive"],
      ],
    }));

    // Handler for SELECT with ORDER BY
    pgMock.setQueryHandler(/SELECT \* FROM users.*ORDER BY name ASC/, (query) => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["3", "Bob Wilson", "bob@example.com", "inactive"],
        ["2", "Jane Smith", "jane@example.com", "active"],
        ["1", "John Doe", "john@example.com", "active"],
      ],
    }));

    // Handler for SELECT with LIMIT
    pgMock.setQueryHandler(/SELECT \* FROM users.*LIMIT 2/, (query) => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "John Doe", "john@example.com", "active"],
        ["2", "Jane Smith", "jane@example.com", "active"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT count\(\*\) FROM users$/, () => ({
      columns: ["count"],
      rows: [["3"]],
    }));

    pgMock.setQueryHandler(/^EXPLAIN \(FORMAT JSON\) SELECT 1 FROM users$/, () => ({
      columns: ["QUERY PLAN"],
      rows: [['[{"Plan":{"Node Type":"Seq Scan","Relation Name":"users","Plan Rows":314}}]']],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM users LIMIT 1 OFFSET 1$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["2", "Jane Smith", "jane@example.com", "active"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO tenant_001\.users/, () => ({
      columns: ["id", "name", "email"],
      rows: [["55", "Tenant User", "tenant@example.com"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(name,email\) VALUES \('Tenant User','tenant@example.com'\) RETURNING \*$/, () => ({
      columns: ["id", "name", "email"],
      rows: [["56", "Tenant User", "tenant@example.com"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(name,email\) VALUES \('Tenant User','tenant@example.com'\)$/, () => ({
      columns: ["id", "name", "email"],
      rows: [["56", "Tenant User", "tenant@example.com"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(name,email,status\) VALUES \('Bulk A','a@example.com','active'\),\('Bulk B','b@example.com','inactive'\) RETURNING \*$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["10", "Bulk A", "a@example.com", "active"],
        ["11", "Bulk B", "b@example.com", "inactive"],
      ],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(name,email,status\) VALUES \('Csv A','csv-a@example.com','active'\),\('Csv B','csv-b@example.com','inactive'\) RETURNING \*$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["20", "Csv A", "csv-a@example.com", "active"],
        ["21", "Csv B", "csv-b@example.com", "inactive"],
      ],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(name,email\) VALUES \('Trimmed User','trimmed@example.com'\) RETURNING \*$/, () => ({
      columns: ["id", "name", "email"],
      rows: [["30", "Trimmed User", "trimmed@example.com"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO foo \(id,bar,baz\) VALUES \(DEFAULT,'val1',DEFAULT\),\(DEFAULT,'val2',15\) RETURNING \*$/, () => ({
      columns: ["id", "bar", "baz"],
      rows: [["1", "val1", "100"], ["2", "val2", "15"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(id,name,email,status\) VALUES \(1,'Old employee 1','old1@example.com','active'\),\(2,'Old employee 2','old2@example.com','inactive'\) ON CONFLICT \(id\) DO UPDATE SET id=EXCLUDED.id,name=EXCLUDED.name,email=EXCLUDED.email,status=EXCLUDED.status RETURNING \*$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "Old employee 1", "old1@example.com", "active"],
        ["2", "Old employee 2", "old2@example.com", "inactive"],
      ],
    }));

    pgMock.setQueryHandler(/^INSERT INTO employees \(name,salary\) VALUES \('Old employee 1',40000\),\('Old employee 2',52000\),\('New employee 3',60000\) ON CONFLICT \(name\) DO UPDATE SET name=EXCLUDED.name,salary=EXCLUDED.salary RETURNING \*$/, () => ({
      columns: ["name", "salary"],
      rows: [
        ["Old employee 1", "40000"],
        ["Old employee 2", "52000"],
        ["New employee 3", "60000"],
      ],
    }));

    pgMock.setQueryHandler(/^INSERT INTO employees \(name,salary\) VALUES \('Old employee 1',40000\),\('Old employee 2',52000\),\('New employee 3',60000\) ON CONFLICT \(name\) DO NOTHING RETURNING \*$/, () => ({
      columns: ["name", "salary"],
      rows: [["New employee 3", "60000"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users \(id,name,email,status\) VALUES \(4,'Sara B.','sara@example.com','active'\) ON CONFLICT \(id\) DO UPDATE SET id=EXCLUDED.id,name=EXCLUDED.name,email=EXCLUDED.email,status=EXCLUDED.status RETURNING \*$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["4", "Sara B.", "sara@example.com", "active"]],
    }));

    // Generic INSERT fallback must come after the more specific INSERT handlers above.
    pgMock.setQueryHandler(/^INSERT INTO users \(name,email,status\) VALUES \('New User','new@example.com','active'\)$/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["4", "New User", "new@example.com", "active"]],
    }));

    pgMock.setQueryHandler(/^INSERT INTO users/, () => ({
      columns: ["id", "name", "email", "status"],
      rows: [["4", "New User", "new@example.com", "active"]],
    }));

    pgMock.setQueryHandler(/^UPDATE tenant_001\.users SET/, () => ({
      columns: ["id", "status"],
      rows: [["5", "inactive"]],
    }));

    pgMock.setQueryHandler(/^DELETE FROM admin\.users WHERE id = '5' RETURNING \*/, () => ({
      columns: ["id", "name"],
      rows: [["5", "Delete Me"]],
    }));

    pgMock.setQueryHandler(/^UPDATE users SET status='inactive' WHERE status = 'active' RETURNING \*/, () => ({
      columns: ["id", "status"],
      rows: [
        ["1", "inactive"],
        ["2", "inactive"],
      ],
    }));

    pgMock.setQueryHandler(/^UPDATE users SET/, (query) => ({
      columns: ["id", "status", "email", "name"],
      rows: [["5", "inactive", null, "Updated User"]],
    }));

    pgMock.setQueryHandler(/^DELETE FROM users WHERE id = '5' RETURNING \*/, () => ({
      columns: ["id", "name"],
      rows: [["5", "Delete Me"]],
    }));

    pgMock.setQueryHandler(/^WITH pgrest_limited AS \(SELECT ctid FROM users WHERE last_login < '2020-01-01' ORDER BY id ASC LIMIT 10\) UPDATE users SET status='inactive' WHERE ctid IN \(SELECT ctid FROM pgrest_limited\) RETURNING \*$/, () => ({
      columns: ["id", "status"],
      rows: [["8", "inactive"], ["9", "inactive"]],
    }));

    pgMock.setQueryHandler(/^WITH pgrest_limited AS \(SELECT ctid FROM users WHERE status = 'inactive' ORDER BY id ASC LIMIT 10\) DELETE FROM users WHERE ctid IN \(SELECT ctid FROM pgrest_limited\) RETURNING \*$/, () => ({
      columns: ["id", "name"],
      rows: [["10", "Inactive A"], ["11", "Inactive B"]],
    }));

    // Handler for RPC: get_user_count
    pgMock.setQueryHandler(/SELECT get_user_count\(\)/, (query) => ({
      columns: ["get_user_count"],
      rows: [["3"]],
    }));

    pgMock.setQueryHandler(/SELECT tenant_001\.get_user_count\(\)/, () => ({
      columns: ["get_user_count"],
      rows: [["9"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'get_user_count'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "f", "f", "f", "0", "", "", "", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'tenant_001' AND p\.proname = 'get_user_count'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "f", "f", "f", "0", "", "", "", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'add_them'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "f", "f", "f", "0", "", "", "a,b", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'process_numbers'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "t", "t", "f", "0", "", "", "ids", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'create_user'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["v", "t", "t", "f", "0", "", "", "data", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'get_profile'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "t", "t", "f", "0", "", "", "id", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'import_csv'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["v", "f", "f", "f", "1", "text", "", "", "1"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'upload_blob'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["v", "f", "f", "f", "1", "bytea", "", "", "1"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'mult_them'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "f", "f", "f", "1", "json", "", "", "1"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'plus_one'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["i", "f", "f", "t", "0", "", "v", "v", "0"]],
    }));

    pgMock.setQueryHandler(/SELECT p\.provolatile, p\.proretset.*pn\.nspname = 'public' AND p\.proname = 'best_films_2017'.*LIMIT 1/, () => ({
      columns: ["provolatile", "proretset", "rettype_is_composite", "has_variadic", "unnamed_count", "single_unnamed_kind", "variadic_param_name", "input_param_names", "match_rank"],
      rows: [["s", "t", "t", "f", "0", "", "", "", "2"]],
    }));

    pgMock.setQueryHandler(/SELECT mult_them\('\{"x":4,"y":2\}'\)/, () => ({
      columns: ["mult_them"],
      rows: [["8"]],
    }));

    pgMock.setQueryHandler(/SELECT plus_one\(v => ARRAY\[1,2,3,4\]\)/, () => ({
      columns: ["plus_one"],
      rows: [["{2,3,4,5}"]],
    }));

    pgMock.setQueryHandler(/^SELECT title,rating FROM "best_films_2017"\(\) WHERE rating > '8' ORDER BY title DESC LIMIT 2$/, () => ({
      columns: ["title", "rating"],
      rows: [
        ["The Worst Person in the World", "8.1"],
        ["Portrait of a Lady on Fire", "8.2"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT count\(\*\) FROM "best_films_2017"\(\) WHERE rating > '8'$/, () => ({
      columns: ["count"],
      rows: [["3"]],
    }));

    pgMock.setQueryHandler(/^EXPLAIN \(FORMAT JSON\) SELECT 1 FROM "best_films_2017"\(\) WHERE rating > '8'$/, () => ({
      columns: ["QUERY PLAN"],
      rows: [['[{"Plan":{"Node Type":"Function Scan","Function Name":"best_films_2017","Plan Rows":271}}]']],
    }));

    // Handler for RPC: add_them
    pgMock.setQueryHandler(/SELECT add_them\(/, (query) => ({
      columns: ["add_them"],
      rows: [["3"]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM "get_profile"\(id => 1\)$/, () => ({
      columns: ["id", "name", "bio"],
      rows: [["1", "John Doe", null]],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM "process_numbers"\(ids => ARRAY\[1,2,3\]\)$/, () => ({
      columns: ["id", "squared"],
      rows: [
        ["1", "1"],
        ["2", "4"],
        ["3", "9"],
      ],
    }));

    pgMock.setQueryHandler(/^SELECT \* FROM "create_user"\(data => '\{"name":"Wrapped User","email":"wrapped@example.com"\}'\)$/, () => ({
      columns: ["id", "name"],
      rows: [["9", "Wrapped User"]],
    }));

    pgMock.setQueryHandler(/SELECT upload_blob\(/, () => ({
      columns: ["ok"],
      rows: [["uploaded"]],
    }));

    pgMock.setQueryHandler(/SELECT import_csv\(/, () => ({
      columns: ["ok"],
      rows: [["imported"]],
    }));
  
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (pgMock) {
      pgMock.stop();
    }
    if (resetPgMock) {
      resetPgMock.stop();
    }
    cleanupRuntime(MODULE);
  });

  // ============================================================================
  // Basic SELECT Tests
  // ============================================================================

  test("GET /api/users returns all users as JSON array", async () => {
    const res = await fetch(`${TEST_URL}/api/users`);
    expect(res.status).toBe(200);

    const contentType = res.headers.get("content-type");
    expect(contentType).toContain("application/json");

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(3);
    expect(body[0]).toHaveProperty("id");
    expect(body[0]).toHaveProperty("name");
    expect(body[0]).toHaveProperty("email");
  });

  test("GET /api/users with select parameter returns specified columns", async () => {
    const res = await fetch(`${TEST_URL}/api/users?select=id,name`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBeGreaterThan(0);

    // Should have id and name columns
    const firstRow = body[0];
    expect(firstRow).toHaveProperty("id");
    expect(firstRow).toHaveProperty("name");
  });

  // ============================================================================
  // Filter Tests (PostgREST-style)
  // ============================================================================

  test("GET /api/users with eq filter returns filtered results", async () => {
    const res = await fetch(`${TEST_URL}/api/users?status=eq.active`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(2);

    // All returned users should be active
    body.forEach((user) => {
      expect(user.status).toBe("active");
    });
  });

  test("GET /api/users with id filter returns single user", async () => {
    const res = await fetch(`${TEST_URL}/api/users?id=eq.1`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(1);
    expect(body[0].id).toBe("1");
    expect(body[0].name).toBe("John Doe");
  });

  test("GET /api/users with gt filter builds numeric comparison SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?age=gt.18`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", name: "John Doe", age: "29" }]);
    expect(lastSql()).toBe("SELECT * FROM users WHERE age > '18'");
  });

  test("GET /api/users with is.null filter emits SQL NULL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?deleted_at=is.null`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", name: "John Doe", deleted_at: null }]);
    expect(lastSql()).toBe("SELECT * FROM users WHERE deleted_at IS NULL");
  });

  test("GET /api/users with in filter emits a proper SQL list", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?status=in.(active,pending)`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toHaveLength(2);
    expect(lastSql()).toBe("SELECT * FROM users WHERE status IN ('active','pending')");
  });

  test("GET /api/users with or and not.and emits grouped logical SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?or=(age.lt.18,not.and(age.gte.11,age.lte.17))`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "7", name: "Young User", age: "10" }]);
    expect(lastSql()).toBe("SELECT * FROM users WHERE (age < '18' OR NOT (age >= '11' AND age <= '17'))");
  });

  test("GET /api/users with like(any) emits ANY array SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?last_name=like(any).{O*,P*}`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toHaveLength(2);
    expect(lastSql()).toBe("SELECT * FROM users WHERE last_name LIKE ANY (ARRAY['O%','P%'])");
  });

  test("GET /api/users with like(all) emits ALL array SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?last_name=like(all).{O*,*n}`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", last_name: "Olsen" }]);
    expect(lastSql()).toBe("SELECT * FROM users WHERE last_name LIKE ALL (ARRAY['O%','%n'])");
  });

  test("GET /api/users with match emits regex SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?name=match.^J.*n$`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", name: "John" }]);
    expect(lastSql()).toBe("SELECT * FROM users WHERE name ~ '^J.*n$'");
  });

  test("GET /api/tsearch with fts language emits to_tsquery SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/tsearch?my_tsv=fts(french).amusant`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", my_tsv: "amusant" }]);
    expect(lastSql()).toBe("SELECT * FROM tsearch WHERE my_tsv @@ to_tsquery('french', 'amusant')");
  });

  test("GET /api/vulnerabilities with quoted identifier decodes into SQL identifier", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/vulnerabilities?%22information.cpe%22=like.*MS*`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", "information.cpe": "MS-123" }]);
    expect(lastSql()).toBe('SELECT * FROM vulnerabilities WHERE "information.cpe" LIKE \'%MS%\'');
  });

  test("GET /api/employees with quoted in values preserves commas", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/employees?name=in.(%22Hebdon,John%22,%22Williams,Mary%22)`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toHaveLength(2);
    expect(lastSql()).toBe("SELECT * FROM employees WHERE name IN ('Hebdon,John','Williams,Mary')");
  });

  test("GET /api/people with json path filter emits to_jsonb SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/people?json_data->>blood_type=eq.A-`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", blood_type: "A-" }]);
    expect(lastSql()).toBe("SELECT * FROM people WHERE to_jsonb(json_data)->>'blood_type' = 'A-'");
  });

  test("GET /api/users with select alias and cast emits projected SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?select=id,fullName:full_name,birthDate:birth_date,salary::text`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body[0]).toEqual({
      id: "1",
      fullName: "John Doe",
      birthDate: "1988-04-25",
      salary: "90000.00",
    });
    expect(lastSql()).toBe("SELECT id,full_name AS fullName,birth_date AS birthDate,salary::text FROM users");
  });

  test("GET /api/orders supports grouped aggregates with alias and output cast", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/orders?select=amount.sum(),average:amount.avg()::int,order_date`);
    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT sum(amount) AS sum,avg(amount)::int AS average,order_date FROM orders GROUP BY order_date");
    expect(await res.json()).toEqual([
      { sum: "1234.56", average: "123", order_date: "2023-01-01" },
      { sum: "2345.67", average: "235", order_date: "2023-01-02" },
    ]);
  });

  test("GET /api/people supports computed fields in select and ordering", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/people?select=full_name,job&order=full_name.desc`);
    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT full_name,job FROM people ORDER BY full_name DESC");
    expect(await res.json()).toEqual([{ full_name: "Samuel Beckett", job: "novelist" }]);
  });

  test("GET /api/people supports computed fields in filters", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/people?full_name=fts.Beckett`);
    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT * FROM people WHERE full_name @@ to_tsquery('Beckett')");
    expect(await res.json()).toEqual([{ first_name: "Samuel", last_name: "Beckett", job: "novelist" }]);
  });

  test("GET /api/people with select json and array paths emits projected SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/people?select=id,json_data->>blood_type,json_data->phones,primary_language:languages->0`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body[0]).toEqual({
      id: "1",
      blood_type: "A-",
      phones: '[{"number":"917-929-5745"}]',
      primary_language: "en",
    });
    expect(lastSql()).toBe("SELECT id,to_jsonb(json_data)->>'blood_type' AS blood_type,to_jsonb(json_data)->'phones' AS phones,to_jsonb(languages)->0 AS primary_language FROM people");
  });

  test("GET /api/jsonb_examples emits jsonb columns as native JSON values", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/jsonb_examples`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([
      {
        id: "1",
        tags: ["openai", "anthropic"],
      },
    ]);
    expect(lastSql()).toBe("SELECT * FROM jsonb_examples");
  });

  // ============================================================================
  // Ordering Tests
  // ============================================================================

  test("GET /api/users with order parameter sorts results", async () => {
    const res = await fetch(`${TEST_URL}/api/users?order=name.asc`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBeGreaterThan(0);

    // First user should be Bob (alphabetically first)
    expect(body[0].name).toBe("Bob Wilson");
  });

  test("GET /api/users with order nullsfirst emits NULLS FIRST SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?order=name.nullsfirst`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body[0].name).toBe("Bob Wilson");
    expect(lastSql()).toBe("SELECT * FROM users ORDER BY name ASC NULLS FIRST");
  });

  test("GET /api/users with order desc nullslast emits NULLS LAST SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?order=name.desc.nullslast`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body[0].name).toBe("John Doe");
    expect(lastSql()).toBe("SELECT * FROM users ORDER BY name DESC NULLS LAST");
  });

  test("GET /api/users with multi-column null ordering emits exact SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?order=name.nullslast,id.desc.nullsfirst`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toHaveLength(3);
    expect(lastSql()).toBe("SELECT * FROM users ORDER BY name ASC NULLS LAST,id DESC NULLS FIRST");
  });

  test("GET /api/users with malformed order returns 400 before SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?order=name.foo`);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ message: "Invalid order parameter" });
    expect(lastSql()).toBe(null);
  });

  test("GET /api/countries with json path order emits to_jsonb ORDER BY SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/countries?location->lat=gte.19&order=location->>lat`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "5", lat: "19.741755", long: "-155.844437", primary_language: "en" }]);
    expect(lastSql()).toBe("SELECT * FROM countries WHERE to_jsonb(location)->'lat' >= 19 ORDER BY to_jsonb(location)->>'lat' ASC");
  });

  // ============================================================================
  // Pagination Tests
  // ============================================================================

  test("GET /api/users with limit parameter limits results", async () => {
    const res = await fetch(`${TEST_URL}/api/users?limit=2`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(2);
  });

  test("GET /api/users combines select, filter, order, limit, and offset", async () => {
    pgMock.clearTracking();

    const res = await fetch(
      `${TEST_URL}/api/users?select=id,name&status=eq.active&order=id.desc&limit=1&offset=1`
    );
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([{ id: "1", name: "John Doe" }]);
    expect(lastSql()).toBe(
      "SELECT id,name FROM users WHERE status = 'active' ORDER BY id DESC LIMIT 1 OFFSET 1"
    );
  });

  test("GET /api/users supports one-level to-many embedding", async () => {
    pgMock.clearTracking();
    const res = await fetch(`${TEST_URL}/api/users?select=id,name,orders(id,amount)&order=id.asc`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      {
        id: "1",
        name: "John Doe",
        orders: [
          { id: "10", amount: "42.50" },
          { id: "11", amount: "84.00" },
        ],
      },
      {
        id: "2",
        name: "Jane Smith",
        orders: [],
      },
    ]);
  });

  test("GET /api/orders supports one-level to-one embedding with alias", async () => {
    const res = await fetch(`${TEST_URL}/api/orders?select=id,amount,user:users(id,name)&order=id.asc`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      {
        id: "10",
        amount: "42.50",
        user: { id: "1", name: "John Doe" },
      },
    ]);
  });

  test("GET /api/users supports !inner embedding to filter parent rows", async () => {
    const res = await fetch(`${TEST_URL}/api/users?select=id,name,orders!inner(id)&order=id.asc`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      {
        id: "1",
        name: "John Doe",
        orders: [{ id: "10" }, { id: "11" }],
      },
    ]);
  });

  test("GET /api/users supports many-to-many plus nested embedding", async () => {
    pgMock.clearTracking();
    const res = await fetch(`${TEST_URL}/api/users?select=id,teams!memberships_team_id_fkey(id,name,owner:users(id,name))&order=id.asc`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      {
        id: "1",
        teams: [
          {
            id: "7",
            name: "Platform",
            owner: { id: "2", name: "Jane Smith" },
          },
        ],
      },
    ]);
  });

  // ============================================================================
  // INSERT Tests (POST)
  // ============================================================================

  test("POST /api/users inserts new user and returns result", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: "New User",
        email: "new@example.com",
        status: "active",
      }),
    });

    expect(res.status).toBe(201);

    const body = await res.json();
    // Response should be an array with the inserted row
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(1);
    expect(body[0]).toHaveProperty("id");
    expect(body[0].name).toBe("New User");
  });

  test("POST /api/users with form-urlencoded body maps fields into INSERT SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "name=Form+User&email=form%40example.com&status=active",
    });

    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body[0].name).toBe("New User");
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('Form User','form@example.com','active') RETURNING *"
    );
  });

  test("POST /api/users with unsupported request media type returns 415", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "text/csv",
      },
      body: "name,email,status\nCsv User,csv@example.com,active\n",
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('Csv User','csv@example.com','active') RETURNING *"
    );
  });

  test("POST /api/users with text/plain body maps payload into data column", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "text/plain",
      },
      body: "raw text payload",
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe(
      "INSERT INTO users (data) VALUES ('raw text payload') RETURNING *"
    );
  });

  test("POST /api/users with text/xml body maps payload into data column", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "text/xml",
      },
      body: "<user>xml payload</user>",
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe(
      "INSERT INTO users (data) VALUES ('<user>xml payload</user>') RETURNING *"
    );
  });

  test("POST /api/users with octet-stream body maps payload into data column", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/octet-stream",
      },
      body: "BLOBDATA",
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe("INSERT INTO users (data) VALUES ('BLOBDATA') RETURNING *");
  });

  test("POST /api/users with Content-Profile writes to schema-qualified table", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Profile": "tenant_001",
      },
      body: JSON.stringify({
        name: "Tenant User",
        email: "tenant@example.com",
      }),
    });

    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body[0].name).toBe("Tenant User");
    expect(lastSql()).toBe(
      "INSERT INTO tenant_001.users (name,email) VALUES ('Tenant User','tenant@example.com') RETURNING *"
    );
  });

  test("POST /api/users without profile uses unqualified default table path", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: "Tenant User",
        email: "tenant@example.com",
      }),
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe("INSERT INTO users (name,email) VALUES ('Tenant User','tenant@example.com') RETURNING *");
  });

  test("POST /api/users ignores Accept-Profile and uses Content-Profile semantics", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept-Profile": "admin",
      },
      body: JSON.stringify({
        name: "Tenant User",
        email: "tenant@example.com",
      }),
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe("INSERT INTO users (name,email) VALUES ('Tenant User','tenant@example.com') RETURNING *");
  });

  test("PATCH /api/users with Content-Profile updates schema-qualified table", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Content-Profile": "tenant_001",
      },
      body: JSON.stringify({ status: "inactive" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body[0].status).toBe("inactive");
    expect(lastSql()).toBe(
      "UPDATE tenant_001.users SET status='inactive' WHERE id = '5' RETURNING *"
    );
  });

  test("DELETE /api/users with Content-Profile deletes from schema-qualified table", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "DELETE",
      headers: {
        "Content-Profile": "admin",
      },
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body[0].id).toBe("5");
    expect(lastSql()).toBe("DELETE FROM admin.users WHERE id = '5' RETURNING *");
  });

  test("DELETE /api/users ignores Accept-Profile and uses unqualified default table path", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "DELETE",
      headers: {
        "Accept-Profile": "admin",
      },
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe("DELETE FROM users WHERE id = '5' RETURNING *");
  });

  test("PATCH /api/users preserves null values in JSON body SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ status: "inactive", email: null, name: "Updated User" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body[0].email).toBeNull();
    expect(lastSql()).toBe(
      "UPDATE users SET status='inactive',email=NULL,name='Updated User' WHERE id = '5' RETURNING *"
    );
  });

  test("POST /api/users with Prefer: return=minimal omits body and RETURNING", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify({ name: "New User", email: "new@example.com", status: "active" }),
    });

    expect(res.status).toBe(201);
    expect(res.headers.get("preference-applied")).toContain("return=minimal");
    expect(await res.text()).toBe("");
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('New User','new@example.com','active')"
    );
  });

  test("POST /api/users bulk JSON array uses one INSERT statement", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify([
        { name: "Bulk A", email: "a@example.com", status: "active" },
        { name: "Bulk B", email: "b@example.com", status: "inactive" },
      ]),
    });

    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body).toHaveLength(2);
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('Bulk A','a@example.com','active'),('Bulk B','b@example.com','inactive') RETURNING *"
    );
  });

  test("POST /api/users bulk CSV uses one INSERT statement", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "text/csv",
      },
      body: "name,email,status\nCsv A,csv-a@example.com,active\nCsv B,csv-b@example.com,inactive\n",
    });

    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body).toHaveLength(2);
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('Csv A','csv-a@example.com','active'),('Csv B','csv-b@example.com','inactive') RETURNING *"
    );
  });

  test("POST /api/users with columns parameter ignores extra JSON keys", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?columns=name,email`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: "Trimmed User",
        email: "trimmed@example.com",
        status: "active",
        ignored: "value",
      }),
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe("INSERT INTO users (name,email) VALUES ('Trimmed User','trimmed@example.com') RETURNING *");
  });

  test("POST /api/foo bulk JSON with missing=default emits DEFAULT for missing fields", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/foo?columns=id,bar,baz`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "missing=default, return=representation",
      },
      body: JSON.stringify([
        { bar: "val1" },
        { bar: "val2", baz: 15 },
      ]),
    });

    expect(res.status).toBe(201);
    expect(res.headers.get("preference-applied")).toContain("missing=default");
    expect(lastSql()).toBe(
      "INSERT INTO foo (id,bar,baz) VALUES (DEFAULT,'val1',DEFAULT),(DEFAULT,'val2',15) RETURNING *"
    );
    expect(await res.json()).toEqual([
      { id: "1", bar: "val1", baz: "100" },
      { id: "2", bar: "val2", baz: "15" },
    ]);
  });

  test("POST /api/users with resolution=merge-duplicates and on_conflict=id builds upsert SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?on_conflict=id`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates, return=representation",
      },
      body: JSON.stringify([
        { id: 1, name: "Old employee 1", email: "old1@example.com", status: "active" },
        { id: 2, name: "Old employee 2", email: "old2@example.com", status: "inactive" },
      ]),
    });

    expect(res.status).toBe(201);
    expect(res.headers.get("preference-applied")).toContain("resolution=merge-duplicates");
    expect(lastSql()).toBe(
      "INSERT INTO users (id,name,email,status) VALUES (1,'Old employee 1','old1@example.com','active'),(2,'Old employee 2','old2@example.com','inactive') ON CONFLICT (id) DO UPDATE SET id=EXCLUDED.id,name=EXCLUDED.name,email=EXCLUDED.email,status=EXCLUDED.status RETURNING *"
    );
  });

  test("POST /api/employees with resolution=ignore-duplicates and on_conflict=name builds do-nothing upsert SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/employees?on_conflict=name`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "resolution=ignore-duplicates, return=representation",
      },
      body: JSON.stringify([
        { name: "Old employee 1", salary: 40000 },
        { name: "Old employee 2", salary: 52000 },
        { name: "New employee 3", salary: 60000 },
      ]),
    });

    expect(res.status).toBe(201);
    expect(res.headers.get("preference-applied")).toContain("resolution=ignore-duplicates");
    expect(lastSql()).toBe(
      "INSERT INTO employees (name,salary) VALUES ('Old employee 1',40000),('Old employee 2',52000),('New employee 3',60000) ON CONFLICT (name) DO NOTHING RETURNING *"
    );
  });

  test("PUT /api/users with eq filter performs single-row upsert", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.4`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ id: 4, name: "Sara B.", email: "sara@example.com", status: "active" }),
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe(
      "INSERT INTO users (id,name,email,status) VALUES (4,'Sara B.','sara@example.com','active') ON CONFLICT (id) DO UPDATE SET id=EXCLUDED.id,name=EXCLUDED.name,email=EXCLUDED.email,status=EXCLUDED.status RETURNING *"
    );
  });

  test("PATCH /api/users with limit and order emits limited update SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?limit=10&order=id&last_login=lt.2020-01-01`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ status: "inactive" }),
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe(
      "WITH pgrest_limited AS (SELECT ctid FROM users WHERE last_login < '2020-01-01' ORDER BY id ASC LIMIT 10) UPDATE users SET status='inactive' WHERE ctid IN (SELECT ctid FROM pgrest_limited) RETURNING *"
    );
  });

  test("DELETE /api/users with limit and order emits limited delete SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?limit=10&order=id&status=eq.inactive`, {
      method: "DELETE",
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe(
      "WITH pgrest_limited AS (SELECT ctid FROM users WHERE status = 'inactive' ORDER BY id ASC LIMIT 10) DELETE FROM users WHERE ctid IN (SELECT ctid FROM pgrest_limited) RETURNING *"
    );
  });

  test("PATCH /api/users with Prefer: return=headers-only omits body and RETURNING", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Prefer: "return=headers-only",
      },
      body: JSON.stringify({ status: "inactive" }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("preference-applied")).toContain("return=headers-only");
    expect(await res.text()).toBe("");
    expect(lastSql()).toBe("UPDATE users SET status='inactive' WHERE id = '5'");
  });

  test("POST /api/users with Prefer: handling=strict rejects invalid preferences before SQL", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "handling=strict, unknown-preference",
      },
      body: JSON.stringify({ name: "New User" }),
    });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ message: "Invalid Prefer header" });
    expect(lastSql()).toBe(null);
  });

  test("POST /api/users with Prefer: handling=lenient ignores invalid preferences", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "handling=lenient, unknown-preference",
      },
      body: JSON.stringify({ name: "New User", email: "new@example.com", status: "active" }),
    });

    expect(res.status).toBe(201);
    expect(lastSql()).toBe(
      "INSERT INTO users (name,email,status) VALUES ('New User','new@example.com','active') RETURNING *"
    );
  });

  test("PATCH /api/users with Prefer: max-affected accepts row counts within limit", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?id=eq.5`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Prefer: "max-affected=1",
      },
      body: JSON.stringify({ status: "inactive" }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("preference-applied")).toContain("max-affected=1");
  });

  test("PATCH /api/users with Prefer: max-affected rejects overflow", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?status=eq.active`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Prefer: "max-affected=1",
      },
      body: JSON.stringify({ status: "inactive" }),
    });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ message: "Query exceeds Prefer: max-affected" });
    expect(lastSql()).toBe(
      "UPDATE users SET status='inactive' WHERE status = 'active' RETURNING *"
    );
  });

  // ============================================================================
  // RPC Tests (Stored Procedures)
  // ============================================================================

  test("GET /rpc/get_user_count calls stored function", async () => {
    const res = await fetch(`${TEST_URL}/rpc/get_user_count`);
    expect(res.status).toBe(200);

    const body = await res.text();
    // Should return result containing count value
    expect(body).toContain("3");
  });

  test("POST /rpc/add_them with JSON body calls function with parameters", async () => {
    const res = await fetch(`${TEST_URL}/rpc/add_them`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ a: 1, b: 2 }),
    });

    expect(res.status).toBe(200);

    const body = await res.text();
    // add_them(1, 2) should return 3
    expect(body).toContain("3");
  });

  test("POST /rpc/process_numbers converts JSON arrays to PostgreSQL ARRAY syntax", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/process_numbers`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ids: [1, 2, 3] }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveLength(3);
    expect(lastSql()).toBe(`SELECT * FROM "process_numbers"(ids => ARRAY[1,2,3])`);
  });

  test("POST /rpc/create_user with Prefer: params=single-object wraps the body into a data parameter", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/create_user`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "params=single-object",
      },
      body: JSON.stringify({ name: "Wrapped User", email: "wrapped@example.com" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body[0].name).toBe("Wrapped User");
    expect(lastSql()).toBe(
      `SELECT * FROM "create_user"(data => '{"name":"Wrapped User","email":"wrapped@example.com"}')`
    );
  });

  test("POST /rpc/add_them with form-urlencoded body parses named RPC params", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/add_them`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "a=1&b=2",
    });

    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("3");
    expect(lastSql()).toBe("SELECT add_them(a => 1, b => 2)");
  });

  test("POST /rpc/add_them with unsupported request media type returns 415", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/add_them`, {
      method: "POST",
      headers: {
        "Content-Type": "text/plain",
      },
      body: "a=1",
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT add_them(data => 'a=1')");
  });

  test("POST /rpc/import_csv with text/csv body maps raw payload into data parameter", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/import_csv`, {
      method: "POST",
      headers: {
        "Content-Type": "text/csv",
      },
      body: "name,email\nCsv User,csv@example.com\n",
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe(
      "SELECT import_csv(data => 'name,email\nCsv User,csv@example.com\n')"
    );
  });

  test("POST /rpc/upload_blob with octet-stream body maps raw payload into data parameter", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/upload_blob`, {
      method: "POST",
      headers: {
        "Content-Type": "application/octet-stream",
      },
      body: "BLOBDATA",
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT upload_blob('BLOBDATA')");
  });

  test("POST /rpc/mult_them with unnamed json parameter uses positional JSON body", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/mult_them`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ x: 4, y: 2 }),
    });

    expect(res.status).toBe(200);
    expect(await res.text()).toContain("8");
    expect(lastSql()).toBe(`SELECT mult_them('{"x":4,"y":2}')`);
  });

  test("GET /rpc/plus_one collapses repeated query params into a variadic ARRAY argument", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/plus_one?v=1&v=2&v=3&v=4`);
    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT plus_one(v => ARRAY[1,2,3,4])");
    expect(await res.text()).toContain("{2,3,4,5}");
  });

  test("GET /rpc/best_films_2017 applies table-style select, filter, order, and limit to a TVF", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/best_films_2017?select=title,rating&rating=gt.8&order=title.desc&limit=2`);
    expect(res.status).toBe(200);
    expect(lastSql()).toBe(`SELECT title,rating FROM "best_films_2017"() WHERE rating > '8' ORDER BY title DESC LIMIT 2`);
    expect(await res.json()).toEqual([
      { title: "The Worst Person in the World", rating: "8.1" },
      { title: "Portrait of a Lady on Fire", rating: "8.2" },
    ]);
  });

  test("GET /users honors Range headers in blocking mode", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: {
        "Range-Unit": "items",
        Range: "1-1",
      },
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("range-unit")).toBe("items");
    expect(res.headers.get("content-range")).toBe("1-1/*");
    expect(lastSql()).toBe("SELECT * FROM users LIMIT 1 OFFSET 1");
    expect(await res.json()).toEqual([
      { id: "2", name: "Jane Smith", email: "jane@example.com", status: "active" },
    ]);
  });

  test("GET /users with Prefer: count=exact returns partial-content metadata in blocking mode", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?limit=2`, {
      headers: {
        Prefer: "count=exact",
      },
    });

    expect(res.status).toBe(206);
    expect(res.headers.get("range-unit")).toBe("items");
    expect(res.headers.get("content-range")).toBe("0-1/3");
    expect(res.headers.get("preference-applied")).toContain("count=exact");
    expect(lastSql()).toBe("SELECT * FROM users LIMIT 2");
  });

  test("GET /rpc/best_films_2017 with Prefer: count=exact returns TVF count metadata in blocking mode", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/best_films_2017?select=title,rating&rating=gt.8&order=title.desc&limit=2`, {
      headers: {
        Prefer: "count=exact",
      },
    });

    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe("0-1/3");
    expect(res.headers.get("preference-applied")).toContain("count=exact");
    expect(lastSql()).toBe(`SELECT title,rating FROM "best_films_2017"() WHERE rating > '8' ORDER BY title DESC LIMIT 2`);
  });

  test("GET /users with Prefer: count=planned uses EXPLAIN instead of count(*)", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users?limit=2`, {
      headers: {
        Prefer: "count=planned",
      },
    });

    expect(res.status).toBe(206);
    expect(res.headers.get("preference-applied")).toContain("count=planned");
    expect(res.headers.get("content-range")).toBe("0-1/314");
    expect(pgMock.getQueryLog()).toContain("EXPLAIN (FORMAT JSON) SELECT 1 FROM users");
    expect(pgMock.getQueryLog()).not.toContain("SELECT count(*) FROM users");
    expect(lastSql()).toBe("SELECT * FROM users LIMIT 2");
  });

  test("GET /rpc/best_films_2017 with Prefer: count=estimated uses EXPLAIN instead of count(*)", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/best_films_2017?select=title,rating&rating=gt.8&order=title.desc&limit=2`, {
      headers: {
        Prefer: "count=estimated",
      },
    });

    expect(res.status).toBe(206);
    expect(res.headers.get("preference-applied")).toContain("count=estimated");
    expect(res.headers.get("content-range")).toBe("0-1/271");
    expect(pgMock.getQueryLog()).toContain(`EXPLAIN (FORMAT JSON) SELECT 1 FROM "best_films_2017"() WHERE rating > '8'`);
    expect(pgMock.getQueryLog()).not.toContain(`SELECT count(*) FROM "best_films_2017"() WHERE rating > '8'`);
    expect(lastSql()).toBe(`SELECT title,rating FROM "best_films_2017"() WHERE rating > '8' ORDER BY title DESC LIMIT 2`);
  });

  test("POST /rpc/plus_one with form body collapses repeated params into a variadic ARRAY argument", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/plus_one`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "v=1&v=2&v=3&v=4",
    });

    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT plus_one(v => ARRAY[1,2,3,4])");
    expect(await res.text()).toContain("{2,3,4,5}");
  });

  test("GET /rpc/create_user rejects GET when function metadata is volatile", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/create_user`);
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("OPTIONS,POST");
    expect(await res.json()).toEqual({
      message: "The HTTP method is not allowed for this RPC function",
    });
    expect(lastSql()).not.toContain("SELECT create_user(");
  });

  // ============================================================================
  // Content Negotiation (Accept Header) Tests
  // ============================================================================

  test("GET /api/users with Accept: text/csv returns CSV format", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: { Accept: "text/csv" },
    });
    expect(res.status).toBe(200);

    const contentType = res.headers.get("content-type");
    expect(contentType).toContain("text/csv");

    const body = await res.text();
    // CSV should have header row and data rows
    const lines = body.trim().split("\n");
    expect(lines.length).toBeGreaterThan(1);
    // Header row should contain column names
    expect(lines[0]).toContain("id");
    expect(lines[0]).toContain("name");
  });

  test("GET /api/users with Accept: text/xml returns XML format", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: { Accept: "text/xml" },
    });
    expect(res.status).toBe(200);

    const contentType = res.headers.get("content-type");
    expect(contentType).toContain("text/xml");

    const body = await res.text();
    // XML should have root element and row elements
    expect(body).toContain("<?xml");
    expect(body).toContain("<root>");
    expect(body).toContain("<row>");
    expect(body).toContain("</root>");
  });

  test("GET /api/users with Accept: text/plain returns plain text", async () => {
    const res = await fetch(`${TEST_URL}/api/users?select=name`, {
      headers: { Accept: "text/plain" },
    });
    expect(res.status).toBe(200);

    const contentType = res.headers.get("content-type");
    expect(contentType).toContain("text/plain");

    const body = await res.text();
    expect(body).toBe("John Doe\nJane Smith\nBob Wilson");
  });

  test("GET /api/users with Accept: application/json returns JSON (default)", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: { Accept: "application/json" },
    });
    expect(res.status).toBe(200);

    const contentType = res.headers.get("content-type");
    expect(contentType).toContain("application/json");

    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
  });

  test("GET /api/users with Accept-Profile reads from schema-qualified table", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: { "Accept-Profile": "admin" },
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      {
        id: "101",
        name: "Admin Jane",
        email: "admin@example.com",
        status: "active",
      },
    ]);
    expect(lastSql()).toBe("SELECT * FROM admin.users");
  });

  test("GET /api/users without profile uses unqualified default table path", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toHaveLength(3);
    expect(lastSql()).toBe("SELECT * FROM users");
  });

  test("GET /api/users rejects disallowed Accept-Profile schema", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/api/users`, {
      headers: { "Accept-Profile": "tenant_999" },
    });
    expect(res.status).toBe(406);
    expect(await res.json()).toEqual({
      code: "PGRST106",
      details: null,
      hint: null,
      message: "The schema must be one of the following: public, admin, tenant_001",
    });
    expect(lastSql()).toBe(null);
  });

  test("GET /api/profiles with pgrst object accept returns a single object", async () => {
    const res = await fetch(`${TEST_URL}/api/profiles?id=eq.1`, {
      headers: { Accept: "application/vnd.pgrst.object+json" },
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(Array.isArray(body)).toBe(false);
    expect(body).toEqual({
      id: "1",
      name: "John Doe",
      bio: null,
      avatar: null,
    });
    expect(res.headers.get("content-range")).toBe("0-0/*");
  });

  test("GET /api/profiles with pgrst object accept returns 406 when zero rows are returned", async () => {
    const res = await fetch(`${TEST_URL}/api/profiles?id=eq.404`, {
      headers: { Accept: "application/vnd.pgrst.object+json" },
    });
    expect(res.status).toBe(406);

    const body = await res.json();
    expect(body.message).toContain("JSON object requested");
  });

  test("GET /api/profiles with pgrst object accept returns 406 when multiple rows are returned", async () => {
    const res = await fetch(`${TEST_URL}/api/profiles`, {
      headers: { Accept: "application/vnd.pgrst.object+json" },
    });
    expect(res.status).toBe(406);

    const body = await res.json();
    expect(body.message).toContain("JSON object requested");
  });

  test("GET /api/profiles with nulls=stripped removes null fields from array results", async () => {
    const res = await fetch(`${TEST_URL}/api/profiles`, {
      headers: { Accept: "application/vnd.pgrst.array+json;nulls=stripped" },
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual([
      { id: "1", name: "John Doe" },
      { id: "2", name: "Jane Smith", bio: "Developer" },
    ]);
  });

  test("GET /api/profiles with object+nulls=stripped combines both JSON options", async () => {
    const res = await fetch(`${TEST_URL}/api/profiles?id=eq.1`, {
      headers: { Accept: "application/vnd.pgrst.object+json;nulls=stripped" },
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual({ id: "1", name: "John Doe" });
  });

  test("GET /api/files with Accept: application/octet-stream returns raw payload", async () => {
    const res = await fetch(`${TEST_URL}/api/files?id=eq.1&select=data`, {
      headers: { Accept: "application/octet-stream" },
    });
    expect(res.status).toBe(200);

    expect(res.headers.get("content-type")).toContain("application/octet-stream");
    const body = await res.text();
    expect(body).toBe("PNG\u0000DATA");
  });

  test("GET /api/files with octet-stream rejects multi-column results", async () => {
    const res = await fetch(`${TEST_URL}/api/files`, {
      headers: { Accept: "application/octet-stream" },
    });
    expect(res.status).toBe(406);

    const body = await res.json();
    expect(body.message).toContain("exactly one row and one column");
  });

  test("POST /rpc/get_profile with pgrst object accept returns a single object", async () => {
    const res = await fetch(`${TEST_URL}/rpc/get_profile`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/vnd.pgrst.object+json;nulls=stripped",
      },
      body: JSON.stringify({ id: 1 }),
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body).toEqual({ id: "1", name: "John Doe" });
  });

  test("POST /rpc/get_user_count with Content-Profile calls schema-qualified function", async () => {
    pgMock.clearTracking();

    const res = await fetch(`${TEST_URL}/rpc/get_user_count`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Profile": "tenant_001",
      },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(200);
    expect(lastSql()).toBe("SELECT tenant_001.get_user_count()");
  });

  test("POST /rpc/create_user returns Preference-Applied for params=single-object", async () => {
    const res = await fetch(`${TEST_URL}/rpc/create_user`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "params=single-object",
      },
      body: JSON.stringify({ name: "Wrapped User", email: "wrapped@example.com" }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("preference-applied")).toContain("params=single-object");
  });

  test("HEAD /api/users returns headers without a body", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(res.headers.get("range-unit")).toBe("items");
    expect(res.headers.get("content-range")).toBe("0-2/*");
    const body = await res.text();
    expect(body).toBe("");
  });

  test("OPTIONS /api/users returns allow and CORS headers", async () => {
    const res = await fetch(`${TEST_URL}/api/users`, {
      method: "OPTIONS",
      headers: {
        Origin: "https://example.com",
        "Access-Control-Request-Method": "GET",
      },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("allow")).toBe("OPTIONS,GET,HEAD,POST,PATCH,PUT,DELETE");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  test("OPTIONS /rpc/add_them returns rpc allow and CORS headers", async () => {
    const res = await fetch(`${TEST_URL}/rpc/add_them`, {
      method: "OPTIONS",
      headers: {
        Origin: "https://example.com",
        "Access-Control-Request-Method": "POST",
      },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("allow")).toBe("OPTIONS,GET,HEAD,POST");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  test("GET /api/ returns an OpenAPI discovery document", async () => {
    const res = await fetch(`${TEST_URL}/api/`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.openapi).toBe("3.1.0");
    expect(body.paths["/api/{table}"]).toBeDefined();
  });
  // ============================================================================
  // Health Check
  // ============================================================================

  test("GET /health returns OK", async () => {
    const res = await fetch(`${TEST_URL}/health`);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body.trim()).toBe("OK");
  });

  // ============================================================================
  // JWT Role-Based Access Control Tests
  // ============================================================================

  describe("JWT role-based access", () => {
    // Helper to create a HS256 JWT
    function createJwt(payload, secret) {
      const header = { alg: "HS256", typ: "JWT" };
      const b64Header = Buffer.from(JSON.stringify(header)).toString("base64url");
      const b64Payload = Buffer.from(JSON.stringify(payload)).toString("base64url");
      const data = `${b64Header}.${b64Payload}`;

      // Create HMAC-SHA256 signature
      const crypto = require("crypto");
      const signature = crypto
        .createHmac("sha256", secret)
        .update(data)
        .digest("base64url");

      return `${data}.${signature}`;
    }

    const JWT_SECRET = "test-secret-key-for-hs256-jwt";

    beforeEach(() => {
      // Clear tracking between tests
      pgMock.clearTracking();

      // Handler for jwt-api/users endpoint
      pgMock.setQueryHandler(/^SELECT \* FROM users$/, (query) => ({
        columns: ["id", "name", "role"],
        rows: [["1", "Test User", "authenticated"]],
      }));
    });

    test("valid JWT with role claim sets PostgreSQL role", async () => {
      const jwt = createJwt(
        { sub: "user123", role: "authenticated_user", exp: Math.floor(Date.now() / 1000) + 3600 },
        JWT_SECRET
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(200);

      // Check that SET ROLE was called with the role from JWT
      expect(pgMock.getLastSetRole()).toBe("authenticated_user");
    });

    test("valid JWT without role claim uses anon_role", async () => {
      const jwt = createJwt(
        { sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 },
        JWT_SECRET
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(200);

      // Should fall back to anon role since no role claim in JWT
      expect(pgMock.getLastSetRole()).toBe("anon");
    });

    test("invalid JWT signature returns 401", async () => {
      const jwt = createJwt(
        { sub: "user123", role: "admin", exp: Math.floor(Date.now() / 1000) + 3600 },
        "wrong-secret-key" // Different secret = invalid signature
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.message).toBe("Invalid JWT signature");
    });

    test("expired JWT returns 401", async () => {
      const jwt = createJwt(
        { sub: "user123", role: "admin", exp: Math.floor(Date.now() / 1000) - 3600 },
        JWT_SECRET
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.message).toBe("JWT token has expired");
    });

    test("future iat JWT returns 401", async () => {
      const jwt = createJwt(
        { sub: "user123", role: "admin", exp: Math.floor(Date.now() / 1000) + 3600, iat: Math.floor(Date.now() / 1000) + 1800 },
        JWT_SECRET
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.message).toBe("JWT token is not yet valid");
    });

    test("malformed JWT returns 401", async () => {
      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer not.a.valid.jwt.token` },
      });
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.message).toBe("Invalid JWT format");
    });

    test("JWT without signature segment returns 401", async () => {
      const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
      const payload = Buffer.from(JSON.stringify({ sub: "user123", role: "admin" })).toString("base64url");
      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${header}.${payload}` },
      });
      expect(res.status).toBe(401);
      const body = await res.json();
      expect(body.message).toBe("Invalid JWT format");
    });

    test("missing JWT uses anon_role", async () => {
      const res = await fetch(`${TEST_URL}/jwt-api/users`);
      expect(res.status).toBe(200);

      // Should use anon role since no JWT provided
      expect(pgMock.getLastSetRole()).toBe("anon");
    });

    test("JWT is passed to PostgreSQL via request.jwt claim", async () => {
      const jwt = createJwt(
        { sub: "user123", role: "authenticated_user", exp: Math.floor(Date.now() / 1000) + 3600 },
        JWT_SECRET
      );

      const res = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res.status).toBe(200);

      // Check that the JWT was also set as request.jwt
      expect(pgMock.getLastSetJwt()).toBe(jwt);
    });

    test("every request starts with RESET ROLE to prevent cross-request role leakage", async () => {
      pgMock.clearTracking();

      const res = await fetch(`${TEST_URL}/jwt-api/users`);
      expect(res.status).toBe(200);

      // RESET ROLE must be the first query so any role set by a previous
      // request on the same pooled connection is always cleared.
      // The combined setup query packs RESET ROLE, SET request.jwt, and SET
      // ROLE into a single multi-statement query to reduce round-trips.
      const log = pgMock.getQueryLog();
      expect(log[0]).toStartWith("RESET ROLE");
      expect(pgMock.getResetRoleCount()).toBeGreaterThanOrEqual(1);
    });

    test("request without JWT clears request.jwt session variable", async () => {
      pgMock.clearTracking();

      const res = await fetch(`${TEST_URL}/jwt-api/users`);
      expect(res.status).toBe(200);

      // The JWT session variable must be cleared so a stale token from a
      // previous request on the same pooled connection cannot leak.
      expect(pgMock.getLastSetJwt()).toBe("");
    });

    test("role does not leak from authenticated to unauthenticated request on same connection", async () => {
      // Request 1: authenticated, sets a specific role via JWT
      const jwt = createJwt(
        { sub: "user123", role: "authenticated_user", exp: Math.floor(Date.now() / 1000) + 3600 },
        JWT_SECRET
      );
      const res1 = await fetch(`${TEST_URL}/jwt-api/users`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(res1.status).toBe(200);
      expect(pgMock.getLastSetRole()).toBe("authenticated_user");

      // Request 2: no JWT — after RESET ROLE the connection-level role is
      // the database user (anon is configured for jwt-api, so anon is set).
      pgMock.clearTracking();
      const res2 = await fetch(`${TEST_URL}/jwt-api/users`);
      expect(res2.status).toBe(200);

      // RESET ROLE must have fired, clearing the previous role.
      expect(pgMock.getResetRoleCount()).toBeGreaterThanOrEqual(1);
      // Then anon_role was re-applied for this request.
      expect(pgMock.getLastSetRole()).toBe("anon");
    });
  });

  describe("parameterized query execution", () => {
    test("filter value is sent as $1 parameter, not interpolated into SQL", async () => {
      pgMock.clearTracking();
      const res = await fetch(`${TEST_URL}/api/users?name=eq.Alice`);
      expect(res.status).toBe(200);
      const log = pgMock.getQueryLog();
      const dataQuery = log.find((q) => q.includes("FROM users") && q.includes("name"));
      expect(dataQuery).toBeDefined();
      // The injected value must appear as a quoted literal $1 placeholder resolved to 'Alice',
      // never as a bare SQL fragment from the original string
      expect(dataQuery).toMatch(/name\s*=\s*'\w+'/);
      expect(dataQuery).not.toContain("$1"); // mock resolved $1 → 'Alice'
    });

    test("SQL injection string in filter value is treated as data, not SQL", async () => {
      pgMock.clearTracking();
      // Set up a handler that records the received query
      let capturedQuery = null;
      pgMock.setQueryHandler(/FROM users/, (q) => {
        capturedQuery = q;
        return { columns: ["id", "name"], rows: [] };
      });
      const injected = encodeURIComponent("' OR '1'='1");
      const res = await fetch(`${TEST_URL}/api/users?name=eq.${injected}`);
      expect(res.status).toBe(200);
      // The dangerous string must not appear unquoted; it must be SQL-safe
      expect(capturedQuery).not.toBeNull();
      expect(capturedQuery).not.toMatch(/OR '1'='1/);
      // It should appear escaped inside single-quoted literal or as a param
      pgMock.queryHandlers.delete(/FROM users/);
    });

    test("parameter overflow returns 400 instead of sending mixed placeholder SQL", async () => {
      pgMock.clearTracking();
      const values = Array.from({ length: 65 }, (_, i) => `v${i}`).join(",");
      const res = await fetch(`${TEST_URL}/api/users?name=in.(${values})`);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ message: "Too many SQL parameters" });

      const log = pgMock.getQueryLog();
      expect(log.find((q) => q.includes("FROM users"))).toBeUndefined();
    });
  });

  describe("malformed payload handling", () => {
    test("malformed Range header returns 400", async () => {
      const res = await fetch(`${TEST_URL}/api/users`, {
        headers: { Range: "invalid-range" },
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.message).toBe("Invalid Range header");
    });

    test("Range header with dash at start returns 400", async () => {
      const res = await fetch(`${TEST_URL}/api/users`, {
        headers: { Range: "-10" },
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.message).toBe("Invalid Range header");
    });
  });

  describe("embedding format rejection", () => {
    test("non-JSON Accept with embedding returns 406", async () => {
      const res = await fetch(`${TEST_URL}/api/users?select=id,name,orders(id)`, {
        headers: { Accept: "text/csv" },
      });
      expect(res.status).toBe(406);
      const body = await res.json();
      expect(body.message).toBe("Embedded resources are only available for JSON responses");
    });
  });
});
