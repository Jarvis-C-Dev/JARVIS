import { create } from "zustand";

/**
 * Where an open panel (Settings, Activity, Memory, History) appears. Three layouts are offered so
 * they can be compared (issue #144):
 *
 * - `rail`: the panel splits the **talk column** (hologram side): the panel above, the hologram, status and
 *   talk button below it. The conversation is not touched. This is the default.
 * - `stage`: the panel splits the **conversation** side: the panel above the conversation. The talk
 *   column is not touched.
 * - `both`: the panel runs across the **whole width**, above the talk column and the conversation.
 *
 * A look-and-feel choice only: stored on this computer, never sent to the backend.
 */
export type PanelSplit = "rail" | "stage" | "both";

const KEY = "jarvis.panelSplit";
const VALUES: readonly PanelSplit[] = ["rail", "stage", "both"];

function read(): PanelSplit {
  try {
    const v = localStorage.getItem(KEY);
    if (v && (VALUES as readonly string[]).includes(v)) return v as PanelSplit;
  } catch {
    // Storage can be unavailable; the default applies.
  }
  return "rail";
}

export const usePanelSplit = create<{
  split: PanelSplit;
  setSplit: (s: PanelSplit) => void;
}>((set) => ({
  split: read(),
  setSplit: (split) => {
    try {
      localStorage.setItem(KEY, split);
    } catch {
      // The choice still applies until restart.
    }
    set({ split });
  },
}));
