import { useEffect, useState, type FormEvent } from "react";
import { createRoot } from "react-dom/client";
import { CalendarDays, CalendarPlus, ChartNoAxesColumn, ChevronDown, ClipboardList, Clock3, KeyRound, LayoutDashboard, LogOut, UsersRound } from "lucide-react";
import { Fragment } from "react";
import "../app/globals.css";

import { setRememberLogin, supabase, type Profile } from "./supabase";
import { StaffReport } from "./staff-reports";
import { Workbench } from "./workbench";
import { Admin, type AdminSection } from "./admin";
import { Calendar } from "./calendar";
import { Reports } from "./reports";
import { button, field, PasswordForm } from "./ui";
import { Dashboard } from "./dashboard";
import { BrandPhoto, CompanyBrand } from "./branding";
import { AbsenceRequest } from "./absence-request";
import "./theme.css";
import "./branding.css";
import "./print.css";

type Screen = "work" | "entries" | "calendar" | "absence" | "admin" | "reports" | "staff-report";
const adminItems: { id: AdminSection; label: string }[] = [
  { id: "status", label: "Teamstatus heute" },
  { id: "requests", label: "Anträge und offene Buchungen" },
  { id: "staff", label: "Mitarbeiter verwalten" },
  { id: "break", label: "Automatische Mittagspause" },
];
const navigation = [
  { screen: "work", label: "Dashboard", icon: LayoutDashboard },
  { screen: "entries", label: "Arbeitszeiten", icon: Clock3 },
  { screen: "calendar", label: "Teamkalender", icon: CalendarDays },
  { screen: "absence", label: "Abwesenheiten", icon: CalendarPlus },
  { screen: "admin", label: "Verwaltung", icon: UsersRound, admin: true },
  { screen: "staff-report", label: "Mitarbeiterauswertung", icon: ChartNoAxesColumn, admin: true },
  { screen: "reports", label: "Monatsberichte", icon: ClipboardList, admin: true },
] as const;

async function readProfile(id: string): Promise<Profile | null> {
  const { data: account, error } = await supabase.from("profiles")
    .select("full_name, role, is_active, weekly_hours, annual_leave_days").eq("id", id).maybeSingle();
  if (error) throw error;
  if (!account?.is_active || (account.role !== "admin" && account.role !== "employee")) return null;
  return { id, name: account.full_name, role: account.role, weeklyHours: account.weekly_hours,
    annualLeaveDays: account.annual_leave_days };
}

function App() {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const [restoring, setRestoring] = useState(true);
  const [canRemember, setCanRemember] = useState(false);
  const [screen, setScreen] = useState<Screen>("work");
  const [passwordForm, setPasswordForm] = useState(false);
  const [calendarDay, setCalendarDay] = useState<string>();
  const [adminOpen, setAdminOpen] = useState(false);
  const [adminSection, setAdminSection] = useState<AdminSection>("status");
  const [pendingRequests, setPendingRequests] = useState(0);
  const [adminRefresh, setAdminRefresh] = useState(0);
  useEffect(() => {
    let active = true;
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT" && active) {
        setProfile(null);
        setScreen("work");
        setPasswordForm(false);
        setAdminOpen(false);
        setPendingRequests(0);
      }
    });
    void window.desktop?.canSaveLogin().then((value) => { if (active) setCanRemember(value); }).catch(() => undefined);
    void supabase.auth.getSession().then(async ({ data, error }) => {
      if (error) throw error;
      if (!data.session || !active) return;
      const account = await readProfile(data.session.user.id);
      if (!active) return;
      if (account) setProfile(account);
      else {
        await supabase.auth.signOut({ scope: "local" });
        if (active) setError("Dein Konto hat kein aktives Profil. Bitte wende dich an die Geschäftsführung.");
      }
    }).catch(() => {
      if (active) setError("Die gespeicherte Anmeldung konnte nicht geprüft werden. Bitte melde dich erneut an.");
    }).finally(() => { if (active) setRestoring(false); });
    return () => { active = false; subscription.unsubscribe(); };
  }, []);
  useEffect(() => { window.scrollTo(0, 0); }, [screen, adminSection]);
  useEffect(() => {
    if (profile?.role !== "admin") return;
    const controller = new AbortController();
    const signal = controller.signal;
    async function countRequests() {
      const [time, absence] = await Promise.all([
        supabase.from("time_entries").select("id", { count: "exact", head: true }).eq("status", "submitted").abortSignal(signal),
        supabase.from("absences").select("id", { count: "exact", head: true }).eq("status", "submitted").abortSignal(signal),
      ]);
      if (!signal.aborted && !time.error && !absence.error) setPendingRequests((time.count ?? 0) + (absence.count ?? 0));
    }
    const refresh = () => { void countRequests().catch(() => undefined); };
    refresh();
    const timer = window.setInterval(refresh, 30000);
    return () => { controller.abort(); window.clearInterval(timer); };
  }, [profile?.role, adminRefresh]);

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending) return;
    setError("");
    setPending(true);
    const form = event.currentTarget;
    const data = new FormData(form);

    try {
      await setRememberLogin(false);
      const { data: auth, error: authError } = await supabase.auth.signInWithPassword({
        email: String(data.get("email")).trim(),
        password: String(data.get("password")),
      });
      if (authError || !auth.user) {
        setError(authError?.code === "invalid_credentials"
          ? "E-Mail-Adresse oder Passwort ist falsch."
          : "Die Anmeldung ist fehlgeschlagen. Prüfe deine Internetverbindung und versuche es erneut.");
        return;
      }

      const account = await readProfile(auth.user.id);
      if (!account) {
        await supabase.auth.signOut({ scope: "local" });
        setError("Dein Konto hat kein aktives Profil. Bitte wende dich an die Geschäftsführung.");
        return;
      }

      if (canRemember && data.has("remember") && !await setRememberLogin(true)) {
        await setRememberLogin(false);
        setError("Die Anmeldung konnte auf diesem Gerät nicht gespeichert werden.");
      }
      form.reset();
      setProfile(account);
    } catch {
      await supabase.auth.signOut({ scope: "local" }).catch(() => undefined);
      setError("Die Verbindung ist fehlgeschlagen. Bitte versuche es erneut.");
    } finally {
      setPending(false);
    }
  }

  async function signOut() {
    setPending(true);
    setError("");
    try {
      const cleared = await setRememberLogin(false);
      const { error: signOutError } = await supabase.auth.signOut({ scope: "local" });
      if (signOutError && !cleared && window.desktop) throw signOutError;
      setProfile(null);
    } catch {
      setError("Die Abmeldung konnte nicht abgeschlossen werden. Bitte versuche es erneut.");
    } finally {
      setPending(false);
    }
  }

  if (profile) {
    const current = navigation.find((item) => item.screen === screen)!;
    const initials = profile.name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase();
    return (
      <main className="app-shell">
        <aside className="sidebar no-print">
          <CompanyBrand variant="sidebar" />
          <nav aria-label="Hauptnavigation">
            {navigation.filter((item) => !("admin" in item) || profile.role === "admin").map(({ screen: name, label, icon: Icon }) => (
              <Fragment key={name}>
                {name === "admin" && <p className="nav-heading">Administration</p>}
                {name === "admin" ? <>
                  <button type="button" className="nav-button" aria-expanded={adminOpen} aria-controls="admin-navigation"
                    onClick={() => setAdminOpen(!adminOpen)}>
                    <Icon size={18} aria-hidden="true" />{label}
                    {pendingRequests > 0 && <span className="request-count" aria-label={`${pendingRequests} offene Anträge`}>{pendingRequests}</span>}
                    <ChevronDown size={15} aria-hidden="true" className={`ml-auto ${adminOpen ? "rotate-180" : ""}`} />
                  </button>
                  {adminOpen && <div className="admin-subnav" id="admin-navigation">
                    {adminItems.map((item) => <button key={item.id} type="button" className="nav-button"
                      aria-current={screen === "admin" && adminSection === item.id ? "page" : undefined}
                      onClick={() => { setAdminSection(item.id); setScreen("admin"); setPasswordForm(false); }}>{item.label}
                      {item.id === "requests" && pendingRequests > 0 && <span className="request-count">{pendingRequests}</span>}
                    </button>)}
                  </div>}
                </> : <button type="button" className="nav-button" aria-current={screen === name ? "page" : undefined}
                  onClick={() => { if (name === "calendar") setCalendarDay(undefined); setScreen(name); setPasswordForm(false); }}><Icon size={18} aria-hidden="true" />{label}</button>}
              </Fragment>
            ))}
          </nav>
          <div className="sidebar-account">
            <div className="account-card">
              <span className="account-avatar" aria-hidden="true">{initials}</span>
              <div><strong>{profile.name}</strong><small>{profile.role === "admin" ? "Administrator" : "Mitarbeiterkonto"}</small></div>
            </div>
            <div className="account-actions">
              <button className="nav-button" type="button" aria-expanded={passwordForm} disabled={pending}
                onClick={() => { setPasswordForm(!passwordForm); window.scrollTo(0, 0); }}><KeyRound size={16} aria-hidden="true" />Passwort ändern</button>
              <button className="nav-button" type="button" disabled={pending} onClick={signOut}><LogOut size={16} aria-hidden="true" />Abmelden</button>
            </div>
          </div>
        </aside>
        <div className="screen-area">
          <div className="screen-frame space-y-5">
            <header className="screen-header brand-header no-print">
              <BrandPhoto className="brand-header-photo" />
              <div className="brand-header-copy">
                <h1>{screen === "admin" ? adminItems.find((item) => item.id === adminSection)?.label : current.label}</h1>
                {screen === "work" && <p>Willkommen, {profile.name}</p>}
              </div>
            </header>
            {error && <p role="alert" className="no-print app-notice app-notice--error">{error}</p>}
            {passwordForm && <div className="no-print"><PasswordForm onClose={() => setPasswordForm(false)} /></div>}
            <div hidden={screen !== "work"}><Dashboard profile={profile} onEntries={() => setScreen("entries")} onCalendar={(day) => { setCalendarDay(day); setScreen("calendar"); }} onRequests={() => setScreen("absence")} onClockProblem={() => setScreen("work")} /></div>
            {screen === "entries" && <Workbench profile={profile} />}
            {screen === "calendar" && <Calendar profile={profile} initialDay={calendarDay} onRequest={() => setScreen("absence")} />}
            {screen === "absence" && <AbsenceRequest profile={profile} />}
            {screen === "admin" && profile.role === "admin" && <Admin key={adminSection} profile={profile} section={adminSection} onChanged={() => setAdminRefresh((count) => count + 1)} />}
            {screen === "staff-report" && profile.role === "admin" && <StaffReport initialMember={profile.id} />}
            {screen === "reports" && profile.role === "admin" && <Reports profile={profile} />}
          </div>
        </div>
      </main>
    );
  }

  return (
    <main className="login-screen">
      <BrandPhoto className="login-container-photo" />
      <section className="login-panel">
        <CompanyBrand variant="login" />
        <h1>Anmelden</h1>
        {restoring ? <p role="status" className="mt-5">Anmeldung wird geprüft …</p> : <>
        <form onSubmit={signIn} className="mt-5 space-y-4">
          <label className="block text-sm font-semibold">
            E-Mail-Adresse<input name="email" type="email" required autoComplete="username" className={field} />
          </label>
          <label className="block text-sm font-semibold">
            Passwort<input name="password" type="password" required autoComplete="current-password" className={field} />
          </label>
          {canRemember && <label className="flex items-center gap-2 text-sm">
            <input name="remember" type="checkbox" />Auf diesem Gerät angemeldet bleiben
          </label>}
          {error && <p role="alert" className="app-notice app-notice--error">{error}</p>}
          <button type="submit" disabled={pending} className={button}>{pending ? "Anmeldung läuft …" : "Anmelden"}</button>
        </form>
        <details className="mt-4 text-sm">
          <summary className="cursor-pointer font-semibold">Passwort vergessen?</summary>
          <p className="mt-2">Wende dich an die Verwaltung. Sie kann dir ein neues Startpasswort setzen.</p>
        </details>
        </>}
      </section>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
