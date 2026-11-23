const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("desktop", {
  getBrandingAssets: () => ipcRenderer.invoke("desktop:branding-assets"),
  canSaveLogin: () => ipcRenderer.invoke("desktop:can-save-login"),
  readLogin: (project) => ipcRenderer.invoke("desktop:read-login", project),
  saveLogin: (project, session) => ipcRenderer.invoke("desktop:save-login", project, session),
  printReport: () => ipcRenderer.send("desktop:print-report"),
  saveMonthlyPdf: (month) => ipcRenderer.invoke("desktop:save-monthly-pdf", month),
  setTrayState: (state) => ipcRenderer.send("desktop:tray-state", state),
  showClockProblem: () => ipcRenderer.send("desktop:clock-problem"),
  onTrayAction: (listener) => {
    const handler = (_event, action) => listener(action);
    ipcRenderer.on("desktop:tray-action", handler);
    return () => ipcRenderer.removeListener("desktop:tray-action", handler);
  },
});
