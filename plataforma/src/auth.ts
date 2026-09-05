import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';

const derive = promisify(scrypt);
export const digest = (text: string) => createHash('sha256').update(text).digest('hex');
export const token = () => randomBytes(32).toString('base64url');

export async function hashPassword(password: string): Promise<string> {
  if (password.length < 12 || password.length > 256) throw new Error('La contraseña debe tener entre 12 y 256 caracteres.');
  const salt = randomBytes(16).toString('hex');
  const key = await derive(password, salt, 64) as Buffer;
  return `scrypt:${salt}:${key.toString('hex')}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [algorithm, salt, expected] = stored.split(':');
  if (algorithm !== 'scrypt' || !/^[a-f0-9]{32}$/.test(salt ?? '') || !/^[a-f0-9]{128}$/.test(expected ?? '')) return false;
  const key = await derive(password, salt, 64) as Buffer;
  return timingSafeEqual(key, Buffer.from(expected, 'hex'));
}

// Mismo coste de derivación para cuentas inexistentes; no es una cuenta real.
export const dummyHash = `scrypt:${'0'.repeat(32)}:${'0'.repeat(128)}`;
export type User = { id: string; email: string; name: string; role: 'admin' | 'operator'; system_admin: boolean };
