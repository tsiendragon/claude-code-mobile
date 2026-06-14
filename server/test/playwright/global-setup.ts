import { killTestSessions } from "./helpers.js";

/**
 * Runs once before the whole suite. Removes any `pw-*` CCC sessions left over
 * from previous runs so the bridge starts with a clean session registry — see
 * killTestSessions() for why leaked sessions cause intermittent reply timeouts.
 */
export default async function globalSetup(): Promise<void> {
  const killed = await killTestSessions();
  if (killed > 0) {
    // eslint-disable-next-line no-console
    console.log(`[global-setup] cleaned ${killed} leftover pw-* CCC session(s)`);
  }
}
