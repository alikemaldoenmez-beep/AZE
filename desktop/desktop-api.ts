export type BrandingAssets = { container?: string; logoLight?: string; logoDark?: string };

export type ClockAction = "in" | "out" | "pause" | "resume";
export type TrayState = {
  status: "signed-out" | "loading" | "stopped" | "working" | "paused";
  canPause: boolean;
  busy: boolean;
};

declare global {
  interface Window {
    desktop?: {
      getBrandingAssets: () => Promise<BrandingAssets>;
      canSaveLogin: () => Promise<boolean>;
      readLogin: (project: string) => Promise<string | null>;
      saveLogin: (project: string, session: string | null) => Promise<boolean>;
      printReport: () => void;
      saveMonthlyPdf: (month: string) => Promise<boolean>;
      setTrayState: (state: TrayState) => void;
      onTrayAction: (listener: (action: ClockAction) => void) => () => void;
      showClockProblem: () => void;
    };
  }
}
