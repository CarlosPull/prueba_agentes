-- Las credenciales privadas nunca se almacenan en estas tablas.
CREATE TABLE vm_connections (
  vm_id uuid PRIMARY KEY REFERENCES vms(id),
  host text NOT NULL,
  port integer NOT NULL CHECK(port BETWEEN 1 AND 65535),
  host_fingerprint text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','queued','preparing','ready','failed','review')),
  message text NOT NULL DEFAULT 'Configura la llave pública del servidor en la VM.',
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX one_connection_per_host ON vm_connections(host,port);
CREATE TABLE target_sources (
  target_id uuid PRIMARY KEY REFERENCES targets(id),
  git_url text NOT NULL,
  git_branch text NOT NULL,
  credential_profile text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','queued','preparing','ready','failed','review')),
  message text NOT NULL DEFAULT 'Pendiente de preparación.',
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE preparations (
  id uuid PRIMARY KEY,
  vm_id uuid NOT NULL REFERENCES vms(id),
  target_id uuid REFERENCES targets(id),
  actor_id uuid NOT NULL REFERENCES users(id),
  state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','succeeded','failed','review')),
  stage text NOT NULL DEFAULT 'En cola',
  worker_token uuid,
  heartbeat_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE UNIQUE INDEX preparation_per_vm ON preparations(vm_id) WHERE state IN ('queued','running','review');
CREATE TABLE service_health (name text PRIMARY KEY, heartbeat_at timestamptz NOT NULL);
