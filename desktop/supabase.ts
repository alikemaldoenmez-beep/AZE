import { createClient } from "@supabase/supabase-js";
import type {} from "./desktop-api";

const url = import.meta.env.NEXT_PUBLIC_SUPABASE_URL;
const project = new URL(url).hostname.split(".")[0];
const sessionKey = `sb-${project}-auth-token`;
const memory = new Map<string, string>();
let remember = false;
const storedLogin = window.desktop?.readLogin(project).catch(() => null);
const ready = Promise.resolve(storedLogin).then((value) => {
  if (!value) return;
  remember = true;
  memory.set(sessionKey, value);
});

let pendingWrite = Promise.resolve(true);
function saveLogin(value: string | null) {
  pendingWrite = pendingWrite.then(async () => (await window.desktop?.saveLogin(project, value)) ?? false).catch(() => false);
  return pendingWrite;
}

export async function setRememberLogin(enabled: boolean) {
  await ready;
  remember = enabled;
  return saveLogin(enabled ? memory.get(sessionKey) ?? null : null);
}

const storage = {
  async getItem(key: string) {
    await ready;
    return memory.get(key) ?? null;
  },
  async setItem(key: string, value: string) {
    memory.set(key, value);
    if (key === sessionKey && remember) await saveLogin(value);
  },
  async removeItem(key: string) {
    memory.delete(key);
    if (key === sessionKey) {
      remember = false;
      await saveLogin(null);
    }
  },
};

export const supabase = createClient(
  url,
  import.meta.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  { auth: { persistSession: true, storage, storageKey: sessionKey, detectSessionInUrl: false, autoRefreshToken: true } },
);

export type Profile = {
  id: string;
  name: string;
  role: "admin" | "employee";
  weeklyHours: number;
  annualLeaveDays: number;
};
