CREATE TABLE users (
  id uuid PRIMARY KEY,
  email text UNIQUE NOT NULL CHECK (email = lower(email)),
  name text NOT NULL,
  password_hash text NOT NULL,
  role text NOT NULL CHECK (role IN ('admin', 'operator')),
  system_admin boolean NOT NULL DEFAULT false CHECK (NOT system_admin OR role = 'admin'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sessions (
  token_hash text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE TABLE login_attempts (
  key text PRIMARY KEY,
  attempts integer NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE TABLE vms (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true
);
CREATE TABLE vm_admins (
  vm_id uuid NOT NULL REFERENCES vms(id),
  user_id uuid NOT NULL REFERENCES users(id),
  PRIMARY KEY(vm_id, user_id)
);
CREATE TABLE targets (
  id uuid PRIMARY KEY,
  vm_id uuid NOT NULL REFERENCES vms(id),
  name text NOT NULL,
  repository text NOT NULL,
  container text NOT NULL,
  stack text NOT NULL CHECK (stack IN ('backend', 'frontend')),
  active boolean NOT NULL DEFAULT true,
  UNIQUE(vm_id, container, repository)
);
CREATE TABLE grants (
  user_id uuid NOT NULL REFERENCES users(id),
  target_id uuid NOT NULL REFERENCES targets(id),
  can_read boolean NOT NULL DEFAULT true,
  can_write boolean NOT NULL DEFAULT false,
  version integer NOT NULL DEFAULT 1,
  PRIMARY KEY(user_id, target_id),
  CHECK (NOT can_write OR can_read)
);
CREATE TABLE jobs (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),
  target_id uuid NOT NULL REFERENCES targets(id),
  prompt text NOT NULL CHECK (length(prompt) BETWEEN 1 AND 20000),
  read_only boolean NOT NULL DEFAULT true,
  state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','succeeded','failed','cancel_requested','cancelled','reconciliation_required')),
  idempotency_key uuid NOT NULL,
  worker_token uuid,
  heartbeat_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  result text,
  UNIQUE(user_id, idempotency_key)
);
CREATE INDEX jobs_pending ON jobs(created_at) WHERE state = 'queued';
CREATE UNIQUE INDEX one_active_job_per_target ON jobs(target_id)
  WHERE state IN ('running','cancel_requested','reconciliation_required');
CREATE TABLE audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid REFERENCES users(id),
  action text NOT NULL,
  resource_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);
