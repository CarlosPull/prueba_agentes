import { randomUUID } from 'node:crypto';
import { database, migrate, transaction } from './db.ts';
import { hashPassword } from './auth.ts';

const pool = database(process.env.DATABASE_URL ?? '');
try {
  switch (process.argv[2]) {
    case 'migrate': await migrate(pool); console.log('Migraciones aplicadas.'); break;
    case 'admin': {
      const email = process.env.ADMIN_EMAIL?.toLowerCase();
      const name = process.env.ADMIN_NAME ?? 'Administrador';
      if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('Configura ADMIN_EMAIL.');
      let password = '';
      for await (const chunk of process.stdin) { password += chunk; if (password.length > 1024) throw new Error('Entrada demasiado larga.'); }
      const hash = await hashPassword(password.replace(/\r?\n$/, ''));
      await transaction(pool, async db => {
        await db.query('SELECT pg_advisory_xact_lock(821753092)');
        if ((await db.query('SELECT 1 FROM users WHERE system_admin')).rowCount) throw new Error('El administrador inicial ya existe.');
        const id = randomUUID();
        await db.query("INSERT INTO users(id,email,name,password_hash,role,system_admin) VALUES($1,$2,$3,$4,'admin',true)", [id, email, name, hash]);
        await db.query("INSERT INTO audit(actor_id,action) VALUES($1,'administrador_inicial_creado')", [id]);
      });
      console.log('Administrador creado. La contraseña no se guardó en texto plano.');
      break;
    }
    default: throw new Error('Uso: cli.ts migrate|admin. La contraseña inicial se recibe por entrada estándar.');
  }
} catch (error) { console.error((error as Error).message); process.exitCode = 1; }
finally { await pool.end(); }
