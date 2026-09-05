-- No habilitar módulos antes de verificar el registro y el aislamiento remoto.
ALTER TABLE targets ADD COLUMN execution_ready boolean NOT NULL DEFAULT false;
ALTER TABLE audit ADD COLUMN details jsonb NOT NULL DEFAULT '{}';
